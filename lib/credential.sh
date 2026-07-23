#!/usr/bin/env bash
# credential.sh — resolve, encrypt, and manage credentials

# shellcheck source=lib/common.sh
# source "$(dirname "${BASH_SOURCE[0]}")/common.sh"  # done by caller

CRED_FILE="${SFTP_CRED_FILE:-${SFTP_ROOT}/config/credentials.yml}"

# ── Encryption / Decryption ──────────────────────────────────────────────────

# Encrypt plaintext → ENC[AESGCM;base64…]
# Uses ORCHESTRATOR_ENCRYPTION_KEY (32-byte hex key) + random IV.
cred_encrypt() {
  local plaintext="$1"
  require_env ORCHESTRATOR_ENCRYPTION_KEY
  require_cmd openssl

  local key_hex="$ORCHESTRATOR_ENCRYPTION_KEY"
  local iv
  iv="$(openssl rand -hex 12)"

  local ciphertext
  ciphertext="$(printf '%s' "$plaintext" \
    | openssl enc -aes-256-gcm \
        -K "$key_hex" -iv "$iv" \
        -nosalt 2>/dev/null \
    | base64 -w0)" || die "Encryption failed."

  echo "ENC[AESGCM;${iv};${ciphertext}]"
}

# Decrypt ENC[AESGCM;iv;ciphertext] → plaintext
cred_decrypt() {
  local encrypted="$1"
  require_env ORCHESTRATOR_ENCRYPTION_KEY

  # Parse ENC[AESGCM;iv;base64data]
  local regex='^ENC\[AESGCM;([0-9a-f]+);(.+)\]$'
  if [[ "$encrypted" =~ $regex ]]; then
    local iv="${BASH_REMATCH[1]}"
    local ciphertext="${BASH_REMATCH[2]}"
    local key_hex="$ORCHESTRATOR_ENCRYPTION_KEY"

    echo "$ciphertext" \
      | base64 -d \
      | openssl enc -d -aes-256-gcm \
          -K "$key_hex" -iv "$iv" \
          -nosalt 2>/dev/null \
      || die "Decryption failed."
  else
    # Not encrypted — return as-is only when explicitly allowed.
    echo "WARNING: Credential value is not encrypted (plaintext)." >&2
    if [[ "${SFTP_ALLOW_PLAINTEXT_CREDS:-false}" != "true" ]]; then
      die "Plaintext credentials are not allowed. Set SFTP_ALLOW_PLAINTEXT_CREDS=true to override, or encrypt the credential with 'sftp-credential.sh encrypt'."
    fi
    echo "$encrypted"
  fi
}

# Verify the local openssl actually validates GCM auth tags.
# Some openssl versions silently ignore a bad tag on decrypt.
verify_gcm_integrity() {
  local test_key
  test_key="$(openssl rand -hex 32)"
  local test_iv
  test_iv="$(openssl rand -hex 12)"

  local encrypted
  encrypted="$(printf 'gcm-test' | openssl enc -aes-256-gcm -K "$test_key" -iv "$test_iv" -nosalt 2>/dev/null)" || return 0

  # Corrupt a byte in the middle of the ciphertext (truncation-safe)
  local len=${#encrypted}
  [[ "$len" -lt 4 ]] && return 0
  local mid=$((len / 2))
  local corrupted="${encrypted:0:mid}X${encrypted:mid+1}"

  if printf '%s' "$corrupted" | openssl enc -d -aes-256-gcm -K "$test_key" -iv "$test_iv" -nosalt >/dev/null 2>&1; then
    die "OpenSSL GCM integrity check failed: corrupted ciphertext was accepted. Your openssl version does not validate GCM auth tags. Upgrade openssl or switch to AES-256-CBC."
  fi
}

# ── Credential Store (YAML) ─────────────────────────────────────────────────

# Validate a credential ref — must be a safe identifier.
_validate_cred_ref() {
  local cred_ref="$1"
  if [[ ! "$cred_ref" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    die "Invalid credential ref '$cred_ref': must match ^[A-Za-z0-9._/-]+$"
  fi
}

# Resolve a credential by ref name → decrypted value
resolve_credential() {
  local cred_ref="$1"
  _validate_cred_ref "$cred_ref"
  [[ -f "$CRED_FILE" ]] || die "Credential file not found: $CRED_FILE"
  require_yq

  local raw_value
  raw_value="$(yq -r --arg ref "$cred_ref" '.credentials[] | select(.ref == $ref) | .value' "$CRED_FILE")"

  if [[ -z "$raw_value" ]]; then
    die "Credential ref '$cred_ref' not found in $CRED_FILE"
  fi

  cred_decrypt "$raw_value"
}

# Get credential type by ref.
cred_type() {
  local cred_ref="$1"
  _validate_cred_ref "$cred_ref"
  [[ -f "$CRED_FILE" ]] || die "Credential file not found: $CRED_FILE"
  require_yq
  yq -r --arg ref "$cred_ref" '.credentials[] | select(.ref == $ref) | .type' "$CRED_FILE"
}

# Add or update a credential in the store.
cred_add() {
  local cred_ref="$1" cred_type="$2" plaintext="$3"
  _validate_cred_ref "$cred_ref"
  [[ -f "$CRED_FILE" ]] || die "Credential file not found: $CRED_FILE"
  require_yq

  local encrypted
  encrypted="$(cred_encrypt "$plaintext")"

  # Check if ref exists — update in place.
  local existing
  existing="$(yq -r --arg ref "$cred_ref" '.credentials[] | select(.ref == $ref) | .ref' "$CRED_FILE")"

  if [[ -n "$existing" ]]; then
    yq -i --arg ref "$cred_ref" --arg val "$encrypted" '.credentials[] | select(.ref == $ref) | .value = $val' "$CRED_FILE"
    log_info "Updated credential '$cred_ref'."
  else
    yq -i --arg ref "$cred_ref" --arg type "$cred_type" --arg val "$encrypted" '.credentials += [{"ref": $ref, "type": $type, "value": $val}]' "$CRED_FILE"
    log_info "Added credential '$cred_ref' (type: $cred_type)."
  fi
  chmod 600 "$CRED_FILE" 2>/dev/null || true
}

# List all credential refs and types (no values).
cred_list() {
  [[ -f "$CRED_FILE" ]] || die "Credential file not found: $CRED_FILE"
  require_yq
  yq -r '.credentials[] | "  \(.ref)  \(.type)"' "$CRED_FILE"
}

# Delete a credential by ref.
cred_delete() {
  local cred_ref="$1"
  _validate_cred_ref "$cred_ref"
  [[ -f "$CRED_FILE" ]] || die "Credential file not found: $CRED_FILE"
  require_yq
  yq -i --arg ref "$cred_ref" 'del(.credentials[] | select(.ref == $ref))' "$CRED_FILE"
  log_info "Deleted credential '$cred_ref'."
}

# ── SSH Key Generation ───────────────────────────────────────────────────────

# Generate SSH key pair and store in keys/ directory.
# Usage: generate_ssh_key <name> [ed25519|rsa-2048|rsa-4096]
generate_ssh_key() {
  local name="$1"
  local key_type="${2:-ed25519}"
  require_cmd ssh-keygen
  mkdir -p "$SFTP_KEYS_DIR"

  local key_path="${SFTP_KEYS_DIR}/${name}"
  local algo bits

  case "$key_type" in
    ed25519)  algo="ed25519"; bits="" ;;
    rsa-2048) algo="rsa";    bits="-b 2048" ;;
    rsa-4096) algo="rsa";    bits="-b 4096" ;;
    *) die "Unsupported key type: $key_type (ed25519, rsa-2048, rsa-4096)" ;;
  esac

  ssh-keygen -t "$algo" $bits -f "$key_path" -N "" -C "sftp-service:${name}" >/dev/null 2>&1 \
    || die "Key generation failed for '$name'."

  log_info "Generated $key_type key pair: $key_path"
  echo "$key_path"
}
