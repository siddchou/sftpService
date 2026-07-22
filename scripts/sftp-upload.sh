#!/usr/bin/env bash
# sftp-upload.sh — convenience wrapper: run an UPLOAD job by name
set -euo pipefail

SFTP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Parse args — pass -e flag through
ENV_PROFILE=""
JOB_NAME=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -e|--env)
      ENV_PROFILE="$2"; shift 2 ;;
    -e*)
      ENV_PROFILE="${1#-e}"; shift ;;
    --)
      shift; JOB_NAME="${1:-}" ; break ;;
    -*)
      echo "Usage: sftp-upload.sh [-e <env>] <job-name>"; exit 1 ;;
    *)
      JOB_NAME="$1"; shift ;;
  esac
done

if [[ -z "$JOB_NAME" ]]; then
  echo "Usage: sftp-upload.sh [-e <env>] <job-name>"
  exit 1
fi

# Validate direction before running
source "${SFTP_ROOT}/config/defaults.conf"
source "${SFTP_ROOT}/lib/common.sh"

BASE_DIR="$(yq -r ".jobs[] | select(.name == \"${JOB_NAME}\") | .direction" \
  "${SFTP_ROOT}/config/sftp-jobs.yml")"

ENV_DIR=""
ENV_FILE="${SFTP_ROOT}/config/sftp-jobs.${ENV_PROFILE}.yml"
if [[ -n "$ENV_PROFILE" && -f "$ENV_FILE" ]]; then
  ENV_DIR="$(yq -r ".jobs[] | select(.name == \"${JOB_NAME}\") | .direction" "$ENV_FILE")"
fi

DIRECTION="${ENV_DIR:-$BASE_DIR}"

if [[ "$DIRECTION" != "UPLOAD" ]]; then
  echo "Error: Job '${JOB_NAME}' is not an UPLOAD job (direction: ${DIRECTION:-missing})"
  exit 1
fi

exec "${SFTP_ROOT}/scripts/sftp-run.sh" -e "$ENV_PROFILE" "$JOB_NAME"
