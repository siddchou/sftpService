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
    # Not encrypted — return as-is (supports plain-text dev mode).
    echo "$encrypted"
  fi
}

# ── Credential Store (YAML) ─────────────────────────────────────────────────

# Resolve a credential by ref name → decrypted value
resolve_credential() {
  local cred_ref="$1"
  [[ -f "$CRED_FILE" ]] || die "Credential file not found: $CRED_FILE"
  require_yq

  local raw_value
  raw_value="$(yq -r ".credentials[] | select(.ref == \"$cred_ref\") | .value" "$CRED_FILE")"

  if [[ -z "$raw_value" ]]; then
    die "Credential ref '$cred_ref' not found in $CRED_FILE"
  fi

  cred_decrypt "$raw_value"
}

# Get credential type by ref.
cred_type() {
  local cred_ref="$1"
  [[ -f "$CRED_FILE" ]] || die "Credential file not found: $CRED_FILE"
  require_yq
  yq -r ".credentials[] | select(.ref == \"$cred_ref\") | .type" "$CRED_FILE"
}

# Add or update a credential in the store.
cred_add() {
  local cred_ref="$1" cred_type="$2" plaintext="$3"
  [[ -f "$CRED_FILE" ]] || die "Credential file not found: $CRED_FILE"
  require_yq

  local encrypted
  encrypted="$(cred_encrypt "$plaintext")"

  # Check if ref exists — update in place.
  local existing
  existing="$(yq -r ".credentials[] | select(.ref == \"$cred_ref\") | .ref" "$CRED_FILE")"

  if [[ -n "$existing" ]]; then
    yq -i ".credentials[] | select(.ref == \"$cred_ref\") | .value = \"$encrypted\"" "$CRED_FILE"
    log_info "Updated credential '$cred_ref'."
  else
    yq -i ".credentials += [{\"ref\": \"$cred_ref\", \"type\": \"$cred_type\", \"value\": \"$encrypted\"}]" "$CRED_FILE"
    log_info "Added credential '$cred_ref' (type: $cred_type)."
  fi
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
  [[ -f "$CRED_FILE" ]] || die "Credential file not found: $CRED_FILE"
  require_yq
  yq -i "del(.credentials[] | select(.ref == \"$cred_ref\"))" "$CRED_FILE"
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
