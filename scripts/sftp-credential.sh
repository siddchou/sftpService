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

ENV_PROFILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env)
      ENV_PROFILE="$2"; shift 2 ;;
    -e*)
      ENV_PROFILE="${1#-e}"; shift ;;
    --)
      shift; break ;;
    *)
      break ;;
  esac
done

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

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

COMMAND="$1"; shift

case "$COMMAND" in
  add)
    [[ $# -ge 3 ]] || die "add requires: <ref> <type> <value>"
    cred_add "$1" "$2" "$3"
    ;;
  list)
    echo "Credentials ($CRED_FILE):"
    cred_list
    ;;
  delete)
    [[ $# -ge 1 ]] || die "delete requires: <ref>"
    cred_delete "$1"
    ;;
  gen-key)
    [[ $# -ge 1 ]] || die "gen-key requires: <name>"
    generate_ssh_key "$1" "${2:-ed25519}"
    ;;
  encrypt)
    [[ $# -ge 1 ]] || die "encrypt requires: <plaintext>"
    cred_encrypt "$1"
    ;;
  decrypt)
    [[ $# -ge 1 ]] || die "decrypt requires: <encrypted_value>"
    cred_decrypt "$1"
    ;;
  help|--help|-h)
    usage
    ;;
  *)
    die "Unknown command: $COMMAND"
    ;;
esac
