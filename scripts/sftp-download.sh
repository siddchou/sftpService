#!/usr/bin/env bash
# sftp-download.sh — convenience wrapper: run a DOWNLOAD job by name
set -euo pipefail

SFTP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "${SFTP_ROOT}/config/defaults.conf"
source "${SFTP_ROOT}/lib/common.sh"

# Parse args — pass -e flag through
parse_env_args "$@"
JOB_NAME="${_LEFTOVER_ARGS[0]:-}"

if [[ -z "$JOB_NAME" ]]; then
  echo "Usage: sftp-download.sh [-e <env>] <job-name>"
  exit 1
fi

# Validate direction before running
BASE_DIR="$(yq -r --arg name "$JOB_NAME" '.jobs[] | select(.name == $name) | .direction' \
  "${SFTP_ROOT}/config/sftp-jobs.yml")"

ENV_DIR=""
if [[ -n "$ENV_PROFILE" ]]; then
  ENV_FILE="${SFTP_ROOT}/config/sftp-jobs.${ENV_PROFILE}.yml"
  if [[ -f "$ENV_FILE" ]]; then
    ENV_DIR="$(yq -r --arg name "$JOB_NAME" '.jobs[] | select(.name == $name) | .direction' "$ENV_FILE")"
  fi
fi

DIRECTION="${ENV_DIR:-$BASE_DIR}"

if [[ "$DIRECTION" != "DOWNLOAD" ]]; then
  echo "Error: Job '${JOB_NAME}' is not a DOWNLOAD job (direction: ${DIRECTION:-missing})"
  exit 1
fi

if [[ -n "$ENV_PROFILE" ]]; then
  exec "${SFTP_ROOT}/scripts/sftp-run.sh" -e "$ENV_PROFILE" "$JOB_NAME"
else
  exec "${SFTP_ROOT}/scripts/sftp-run.sh" "$JOB_NAME"
fi
