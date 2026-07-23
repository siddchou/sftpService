#!/usr/bin/env bash
# sftp-core.sh — connect, upload, download primitives

# shellcheck source=lib/common.sh
# source "$(dirname "${BASH_SOURCE[0]}")/common.sh"  # done by caller

# ── Build SSH/SFTP command base ───────────────────────────────────────────────

# Build the common sftp command prefix from job config (JSON via stdin).
# Usage: sftp_build_cmd < job_json
# Populates _sftp_cmd_arr (array) and _sftp_cmd (string, for logging).
_sftp_cmd_arr=()
_sftp_cmd=""

sftp_build_cmd() {
  local host port username auth_type auth_value cred_ref

  # Read stdin once — /dev/stdin gets consumed on pipe-backed inputs (Linux).
  local job_json
  job_json="$(cat)"

  host="$(yq -r '.host' <<<"$job_json")"
  port="$(yq -r '.port // empty' <<<"$job_json")"
  username="$(yq -r '.username' <<<"$job_json")"
  cred_ref="$(yq -r '.credential_ref' <<<"$job_json")"
  auth_type="$(cred_type "$cred_ref")"
  auth_value="$(resolve_credential "$cred_ref")"

  port="${port:-$SFTP_DEFAULT_PORT}"

  local ssh_opts=(
    -P "$port"
    -o ConnectTimeout="$SFTP_CONN_TIMEOUT"
    -o LoginTimeout="$SFTP_AUTH_TIMEOUT"
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

  _sftp_cmd_arr=(timeout "$SFTP_TRANSFER_TIMEOUT" sftp "${ssh_opts[@]}" "${username}@${host}")
  _sftp_cmd="timeout $SFTP_TRANSFER_TIMEOUT sftp ${ssh_opts[*]} ${username}@${host}"
}

# ── Auth helper ───────────────────────────────────────────────────────────────

# Run the sftp command with proper auth. Uses sshpass -e (env var) for PASSWORD
# to avoid exposing the password in the process list.
# Args: <batch_file>
# Returns: stdout from sftp on success, exit code via $?.
_sftp_exec() {
  local batch_file="$1" auth_type="$2" auth_value="$3"

  if [[ "$auth_type" == "PASSWORD" ]]; then
    SSHPASS="$auth_value" sshpass -e "${_sftp_cmd_arr[@]}" -b "$batch_file"
  else
    "${_sftp_cmd_arr[@]}" -b "$batch_file"
  fi
}

# ── Retry helper ──────────────────────────────────────────────────────────────

# Run a command with retries. Wraps _sftp_put and _sftp_get.
# Args: <command> [args...]
_sftp_retry() {
  local attempts=1
  while [[ "$attempts" -le "$SFTP_MAX_RETRIES" ]]; do
    if "$@"; then
      return 0
    fi
    if [[ "$attempts" -lt "$SFTP_MAX_RETRIES" ]]; then
      log_warn "Attempt $attempts/$SFTP_MAX_RETRIES failed, retrying in ${SFTP_RETRY_DELAY}s…"
      # Check cancellation during backoff sleep (1s granularity)
      local _count=0
      while [[ $_count -lt "$SFTP_RETRY_DELAY" ]]; do
        if is_cancelled; then
          return 2
        fi
        sleep 1
        _count=$((_count + 1))
      done
    fi
    attempts=$((attempts + 1))
  done
  return 1
}

# ── Upload ────────────────────────────────────────────────────────────────────

# Upload files matching pattern from working_dir to remote_dir.
# Args: <job_json_path> <auth_value>
# Returns: 0 if all files succeeded, non-zero if any file failed.
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

    local retry_rc=0
    _sftp_retry _sftp_put "$local_file" "$remote_dir" "$dest_name" "$auth_type" "$auth_value" || retry_rc=$?
    if [[ "$retry_rc" -eq 2 ]]; then
      log_warn "Upload cancelled by user."
      break
    elif [[ "$retry_rc" -ne 0 ]]; then
      log_error "FAIL ${basename} -> ${dest_name}"
      failed=$((failed + 1))
    else
      log_info "OK ${basename} (${file_size}KB) -> ${dest_name}"
      transferred=$((transferred + 1))
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
cd "${remote_dir}"
put "${local_file}" "${dest_name}"
quit
EOF

  local stderr_out=""
  stderr_out="$(_sftp_exec "$batch_file" "$auth_type" "$auth_value" 2>&1)" && {
    rm -f "$batch_file"
    return 0
  }
  # Log the last line of stderr for diagnostics (avoid flooding on retries)
  log_debug "sftp-put stderr: $(printf '%s' "$stderr_out" | tail -1)"
  rm -f "$batch_file"
  return 1
}

# ── Download ──────────────────────────────────────────────────────────────────

# Download files matching pattern from remote_dir to working_dir.
# Uses 2 connections: one ls -l, one batch get (regardless of file count).
# Args: <job_json_path> <auth_value>
# Returns: 0 if all files succeeded, non-zero if any file failed.
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

  # 1. Single ls -l to get file list + sizes (connection #1)
  local ls_output
  ls_output="$(sftp_ls_long "$remote_dir" "$auth_type" "$auth_value")" || {
    die "Failed to list remote directory: ${remote_dir}"
  }

  # 2. Parse listing: collect matching files and their sizes
  # Assumption: ls -l output has 9 space-separated fields:
  #   perms links owner group bytes mon day time name
  # This matches OpenSSH sftp-server. Non-OpenSSH servers may differ.
  local -a match_names=()
  local -A match_sizes=()
  local -A match_bytes=()
  # Convert glob pattern to anchored regex:
  # 1. Escape regex metacharacters (., [, ], (, ), {, }, +, ^, $, |, \)
  # 2. Convert glob wildcards (* → .*, ? → .)
  # 3. Anchor with ^...$
  local regex
  regex="$(printf '%s' "$file_pattern" | sed \
    -e 's/[][{}().^$|+\\]/\\&/g' \
    -e 's/\*/.*/g' \
    -e 's/?/./g')"
  regex="^${regex}$"

  while read -r _perms _links _owner _group _bytes _mon _day _time _name; do
    [[ -z "$_name" || "$_name" == "." || "$_name" == ".." ]] && continue
    # P2-1: Only match regular files (perms start with '-')
    [[ "${_perms:0:1}" == "-" ]] || continue
    if printf '%s' "$_name" | grep -qE "$regex" 2>/dev/null; then
      match_names+=("$_name")
      match_sizes["$_name"]=$(( _bytes / 1024 ))
      match_bytes["$_name"]="$_bytes"
    fi
  done <<< "$ls_output"

  if [[ ${#match_names[@]} -eq 0 ]]; then
    log_info "No files matching pattern '${file_pattern}' found."
    return 0
  fi

  # 3. Build batch get for all matching files (connection #2)
  local batch_file
  batch_file="$(mktemp)"
  printf 'lcd "%s"\n' "$working_dir" >> "$batch_file"
  printf 'cd "%s"\n' "$remote_dir" >> "$batch_file"
  for fname in "${match_names[@]}"; do
    printf 'get "%s"\n' "$fname" >> "$batch_file"
  done
  printf 'quit\n' >> "$batch_file"

  local download_output
  download_output="$(_sftp_exec "$batch_file" "$auth_type" "$auth_value" 2>&1)" || true
  log_debug "sftp-download output: $(printf '%s' "$download_output" | tail -3 | tr '\n' '; ')"
  rm -f "$batch_file"

  # 4. Verify which files arrived; compare sizes; report per-file OK/FAIL
  local transferred=0
  local failed=0

  for fname in "${match_names[@]}"; do
    if is_cancelled; then
      log_warn "Download cancelled by user."
      break
    fi

    local file_size="${match_sizes[$fname]:-?}"
    local expected_bytes="${match_bytes[$fname]:-0}"

    if [[ -f "$working_dir/$fname" ]]; then
      local actual_bytes
      actual_bytes="$(stat -c%s "$working_dir/$fname" 2>/dev/null)" || actual_bytes=-1
      if [[ "$actual_bytes" -ge 0 && "$expected_bytes" -ge 0 && "$actual_bytes" -ne "$expected_bytes" ]]; then
        log_error "FAIL ${fname} (size mismatch: expected ${expected_bytes}B, got ${actual_bytes}B)"
        failed=$((failed + 1))
      else
        log_info "OK ${fname} (${file_size}KB)"
        transferred=$((transferred + 1))
      fi
    else
      log_error "FAIL ${fname}"
      failed=$((failed + 1))
    fi
  done

  log_info "Download summary: ${transferred} succeeded, ${failed} failed"
  return "$failed"
}

# List remote directory with ls -l (raw output).
sftp_ls_long() {
  local remote_dir="$1" auth_type="$2" auth_value="$3"
  local batch_file
  batch_file="$(mktemp)"

  cat > "$batch_file" <<EOF
ls -l "${remote_dir}"
quit
EOF

  local output
  output="$(_sftp_exec "$batch_file" "$auth_type" "$auth_value" 2>/dev/null)" || true

  rm -f "$batch_file"

  # Return raw ls -l lines (filter sftp prompts)
  echo "$output" | grep -vE '^[sS]FTP|^[0-9]+ bytes|Cannot' || true
}

# List files in remote directory (simple names).
sftp_ls() {
  local remote_dir="$1" auth_type="$2" auth_value="$3"
  local batch_file
  batch_file="$(mktemp)"

  cat > "$batch_file" <<EOF
ls "${remote_dir}"
quit
EOF

  local output
  output="$(_sftp_exec "$batch_file" "$auth_type" "$auth_value" 2>/dev/null)" || true

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
  output="$(_sftp_exec "$batch_file" "$auth_type" "$auth_value" 2>/dev/null)" || true

  rm -f "$batch_file"

  # Extract size (5th field in ls -l output) and convert to KB
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
lcd "${local_dir}"
cd "${remote_dir}"
get "${remote_file}"
quit
EOF

  local stderr_out=""
  stderr_out="$(_sftp_exec "$batch_file" "$auth_type" "$auth_value" 2>&1)" && {
    rm -f "$batch_file"
    return 0
  }
  log_debug "sftp-get stderr: $(printf '%s' "$stderr_out" | tail -1)"
  rm -f "$batch_file"
  return 1
}
