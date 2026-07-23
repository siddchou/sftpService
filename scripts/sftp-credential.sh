#!/usr/bin/env bash
# sftp-credential.sh — CLI for credential management
set -euo pipefail

SFTP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../config/defaults.conf
source "${SFTP_ROOT}/config/defaults.conf"
# shellcheck source=../lib/common.sh
source "${SFTP_ROOT}/lib/common.sh"
# shellcheck source=../lib/credential.sh
source "${SFTP_ROOT}/lib/credential.sh"

usage() {
  cat <<EOF
Usage: sftp-credential.sh [-e <env>] <command> [args...]

Commands:
  add <ref> <type> <value>       Encrypt and store a credential
                                 type: PASSWORD or SSH_KEY (SSH_KEY value = path to private key)
  list                           List all credential refs and types
  delete <ref>                   Remove a credential by ref
  gen-key <name> [key-type]      Generate an SSH key pair
                                 key-type: ed25519 (default), rsa-2048, rsa-4096
  encrypt <plaintext>            Encrypt a value and print to stdout
  decrypt <encrypted_value>      Decrypt a value and print to stdout

Options:
  -e, --env <env>                Target environment (dev, sit, uat, prod)
                                 Uses credentials.<env>.yml instead of credentials.yml

Environment:
  ORCHESTRATOR_ENCRYPTION_KEY    64-char hex string (32-byte AES-256 key)

Examples:
  sftp-credential.sh -e prod add prod_sftp_key SSH_KEY "/opt/sftp-service/keys/prod_ed25519"
  sftp-credential.sh -e dev add dev_pass PASSWORD "dev-secret"
  sftp-credential.sh -e prod list
  sftp-credential.sh gen-key myserver ed25519
EOF
}

# ── Parse args ───────────────────────────────────────────────────────────────

parse_env_args "$@"

# Set credential file based on environment
if [[ -n "$ENV_PROFILE" ]]; then
  CRED_FILE="${SFTP_ROOT}/config/credentials.${ENV_PROFILE}.yml"
  if [[ -f "${SFTP_ROOT}/config/env/${ENV_PROFILE}.conf" ]]; then
    # shellcheck source=/dev/null
    source "${SFTP_ROOT}/config/env/${ENV_PROFILE}.conf"
  fi
else
  CRED_FILE="${SFTP_ROOT}/config/credentials.yml"
fi

if [[ "${#_LEFTOVER_ARGS[@]}" -lt 1 ]]; then
  usage
  exit 1
fi

COMMAND="${_LEFTOVER_ARGS[0]}"
_rest=("${_LEFTOVER_ARGS[@]:1}")

case "$COMMAND" in
  add)
    [[ "${#_rest[@]}" -ge 3 ]] || die "add requires: <ref> <type> <value>"
    cred_add "${_rest[0]}" "${_rest[1]}" "${_rest[2]}"
    ;;
  list)
    echo "Credentials ($CRED_FILE):"
    cred_list
    ;;
  delete)
    [[ "${#_rest[@]}" -ge 1 ]] || die "delete requires: <ref>"
    cred_delete "${_rest[0]}"
    ;;
  gen-key)
    [[ "${#_rest[@]}" -ge 1 ]] || die "gen-key requires: <name>"
    generate_ssh_key "${_rest[0]}" "${_rest[1]:-ed25519}"
    ;;
  encrypt)
    [[ "${#_rest[@]}" -ge 1 ]] || die "encrypt requires: <plaintext>"
    cred_encrypt "${_rest[0]}"
    ;;
  decrypt)
    [[ "${#_rest[@]}" -ge 1 ]] || die "decrypt requires: <encrypted_value>"
    cred_decrypt "${_rest[0]}"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "Unknown command: $COMMAND"
    ;;
esac
