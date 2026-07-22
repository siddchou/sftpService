#!/usr/bin/env bash
# sftp-core.sh — connect, upload, download primitives

# shellcheck source=lib/common.sh
# source "$(dirname "${BASH_SOURCE[0]}")/common.sh"  # done by caller

# ── Build SSH/SFTP command base ───────────────────────────────────────────────

# Build the common sftp command prefix from job config (JSON via stdin).
# Usage: sftp_build_cmd < job_json
_sftp_cmd=""

sftp_build_cmd() {
  local host port username auth_type auth_value

  host="$(yq -r '.host' /dev/stdin)"
  port="$(yq -r '.port // empty' /dev/stdin)"
  username="$(yq -r '.username' /dev/stdin)"
  auth_type="$(cred_type "$(yq -r '.credential_ref' /dev/stdin)")"

  port="${port:-$SFTP_DEFAULT_PORT}"

  local ssh_opts=(
    -P "$port"
    -o ConnectTimeout="$SFTP_CONN_TIMEOUT"
    -o ServerAliveInterval=60
    -o ServerAliveCountMax=3
  )

  if [[ "$SFTP_STRICT_HOST" == "true" && -f "$SFTP_KNOWN_HOSTS" ]]; then
    ssh_opts+=(
      -o StrictHostKeyChecking=yes
      -o UserKnownHostsFile="$SFTP_KNOWN_HOSTS"
    )
  else
    ssh_opts+=(
      -o StrictHostKeyChecking=accept-new
    )
  fi

  case "$auth_type" in
    SSH_KEY)
      local key_path="$auth_value"
      ssh_opts+=(
        -o PasswordAuthentication=no
        -o PubkeyAuthentication=yes
        -i "$key_path"
      )
      ;;
    PASSWORD)
      require_cmd sshpass
      ssh_opts+=(
        -o PubkeyAuthentication=no
      )
      ;;
    *)
      die "Unknown credential type: $auth_type"
      ;;
  esac

  _sftp_cmd="sftp ${ssh_opts[*]} ${username}@${host}"
}

# ── Upload ────────────────────────────────────────────────────────────────────

# Upload files matching pattern from working_dir to remote_dir.
# Args: <job_json_path> <auth_value>
sftp_upload() {
  local job_json="$1"
  local auth_value="$2"

  local host remote_dir file_pattern working_dir remote_file_name auth_type
  host="$(yq -r '.host' "$job_json")"
  remote_dir="$(yq -r '.remote_dir' "$job_json")"
  file_pattern="$(yq -r '.file_pattern' "$job_json")"
  working_dir="$(yq -r '.working_dir // empty' "$job_json")"
  remote_file_name="$(yq -r '.remote_file_name // empty' "$job_json")"
  auth_type="$(cred_type "$(yq -r '.credential_ref' "$job_json")")"

  working_dir="${working_dir:-$SFTP_WORKING_DIR}"

  log_info "UPLOAD to ${host}:${remote_dir} pattern=${file_pattern}"
  log_info "Local directory: ${working_dir}"

  [[ -d "$working_dir" ]] || die "Working directory does not exist: $working_dir"

  local transferred=0
  local failed=0

  while IFS= read -r -d '' local_file; do
    if is_cancelled; then
      log_warn "Upload cancelled by user."
      break
    fi

    local basename
    basename="$(basename "$local_file")"
    local dest_name="$basename"

    if [[ -n "$remote_file_name" ]]; then
      dest_name="$(expand_template "$remote_file_name" "$local_file")"
    fi

    local file_size
    file_size="$(du -k "$local_file" | cut -f1)"

    if _sftp_put "$local_file" "$remote_dir" "$dest_name" "$auth_type" "$auth_value"; then
      log_info "OK ${basename} (${file_size}KB) -> ${dest_name}"
      ((transferred++))
    else
      log_error "FAIL ${basename} -> ${dest_name}"
      ((failed++))
    fi
  done < <(find "$working_dir" -maxdepth 1 -type f -name "$file_pattern" -print0 2>/dev/null)

  log_info "Upload summary: ${transferred} succeeded, ${failed} failed"
  return "$failed"
}

# Put a single file via sftp batch.
_sftp_put() {
  local local_file="$1" remote_dir="$2" dest_name="$3" auth_type="$4" auth_value="$5"
  local batch_file
  batch_file="$(mktemp)"

  cat > "$batch_file" <<EOF
cd ${remote_dir}
put "${local_file}" "${dest_name}"
quit
EOF

  local rc=0
  if [[ "$auth_type" == "PASSWORD" ]]; then
    sshpass -p "$auth_value" sftp -b "$batch_file" "$_sftp_cmd" 2>/dev/null || rc=1
  else
    sftp -b "$batch_file" "$_sftp_cmd" 2>/dev/null || rc=1
  fi

  rm -f "$batch_file"
  return "$rc"
}

# ── Download ──────────────────────────────────────────────────────────────────

# Download files matching pattern from remote_dir to working_dir.
# Args: <job_json_path> <auth_value>
sftp_download() {
  local job_json="$1"
  local auth_value="$2"

  local host remote_dir file_pattern working_dir auth_type
  host="$(yq -r '.host' "$job_json")"
  remote_dir="$(yq -r '.remote_dir' "$job_json")"
  file_pattern="$(yq -r '.file_pattern' "$job_json")"
  working_dir="$(yq -r '.working_dir // empty' "$job_json")"
  auth_type="$(cred_type "$(yq -r '.credential_ref' "$job_json")")"

  working_dir="${working_dir:-$SFTP_WORKING_DIR}"

  log_info "DOWNLOAD from ${host}:${remote_dir} pattern=${file_pattern}"
  log_info "Local directory: ${working_dir}"

  [[ -d "$working_dir" ]] || die "Working directory does not exist: $working_dir"

  # List remote files matching pattern
  local remote_files
  remote_files="$(sftp_ls "$remote_dir" "$auth_type" "$auth_value")" || {
    die "Failed to list remote directory: ${remote_dir}"
  }

  local transferred=0
  local failed=0

  while IFS= read -r remote_file; do
    [[ -z "$remote_file" ]] && continue

    # Filter by pattern (bash glob match)
    local basename
    basename="$(basename "$remote_file")"

    # Use find to match the glob pattern
    if ! echo "$basename" | grep -q "$(echo "$file_pattern" | sed 's/\*/.*/g; s/\?/./g')" 2>/dev/null; then
      continue
    fi

    if is_cancelled; then
      log_warn "Download cancelled by user."
      break
    fi

    local file_size
    file_size="$(sftp_size "$remote_file" "$auth_type" "$auth_value")"
    file_size="${file_size:-?}"

    if _sftp_get "$remote_dir" "$basename" "$working_dir" "$auth_type" "$auth_value"; then
      log_info "OK ${basename} (${file_size}KB)"
      ((transferred++))
    else
      log_error "FAIL ${basename}"
      ((failed++))
    fi
  done <<< "$remote_files"

  log_info "Download summary: ${transferred} succeeded, ${failed} failed"
  return "$failed"
}

# List files in remote directory.
sftp_ls() {
  local remote_dir="$1" auth_type="$2" auth_value="$3"
  local batch_file
  batch_file="$(mktemp)"

  cat > "$batch_file" <<EOF
ls ${remote_dir}
quit
EOF

  local output
  if [[ "$auth_type" == "PASSWORD" ]]; then
    output="$(sshpass -p "$auth_value" sftp -b "$batch_file" "$_sftp_cmd" 2>/dev/null)" || true
  else
    output="$(sftp -b "$batch_file" "$_sftp_cmd" 2>/dev/null)" || true
  fi

  rm -f "$batch_file"

  # Filter out sftp prompt lines and summary lines
  echo "$output" | grep -vE '^[sS]FTP|^[0-9]+ bytes|Cannot' || true
}

# Get file size from remote listing.
sftp_size() {
  local remote_file="$1" auth_type="$2" auth_value="$3"
  local batch_file
  batch_file="$(mktemp)"

  cat > "$batch_file" <<EOF
ls -l "${remote_file}"
quit
EOF

  local output
  if [[ "$auth_type" == "PASSWORD" ]]; then
    output="$(sshpass -p "$auth_value" sftp -b "$batch_file" "$_sftp_cmd" 2>/dev/null)" || true
  else
    output="$(sftp -b "$batch_file" "$_sftp_cmd" 2>/dev/null)" || true
  fi

  rm -f "$batch_file"

  # Extract size (4th field in ls -l output) and convert to KB
  local bytes
  bytes="$(echo "$output" | awk '{print $5}')"
  if [[ -n "$bytes" && "$bytes" =~ ^[0-9]+$ ]]; then
    echo $(( bytes / 1024 ))
  fi
}

# Get a single file via sftp batch.
_sftp_get() {
  local remote_dir="$1" remote_file="$2" local_dir="$3" auth_type="$4" auth_value="$5"
  local batch_file
  batch_file="$(mktemp)"

  cat > "$batch_file" <<EOF
lcd ${local_dir}
cd ${remote_dir}
get "${remote_file}"
quit
EOF

  local rc=0
  if [[ "$auth_type" == "PASSWORD" ]]; then
    sshpass -p "$auth_value" sftp -b "$batch_file" "$_sftp_cmd" 2>/dev/null || rc=1
  else
    sftp -b "$batch_file" "$_sftp_cmd" 2>/dev/null || rc=1
  fi

  rm -f "$batch_file"
  return "$rc"
}
