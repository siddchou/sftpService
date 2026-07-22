#!/usr/bin/env bash
# sftp-run.sh — main entry point: run a single SFTP job by name
set -euo pipefail

SFTP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../config/defaults.conf
source "${SFTP_ROOT}/config/defaults.conf"
# shellcheck source=../lib/common.sh
source "${SFTP_ROOT}/lib/common.sh"
# shellcheck source=../lib/credential.sh
source "${SFTP_ROOT}/lib/credential.sh"
# shellcheck source=../lib/sftp-core.sh
source "${SFTP_ROOT}/lib/sftp-core.sh"

install_cancel_trap

# Rotate old logs before starting
log_rotate

JOB_NAME="${1:?Usage: sftp-run.sh <job-name>}"

# Read job config and write to temp file (sftp-core expects a file path)
JOB_JSON_FILE="$(mktemp)"
trap "rm -f '$JOB_JSON_FILE'" EXIT

yq_read_job "$JOB_NAME" > "$JOB_JSON_FILE"

# Verify we got something
if [[ ! -s "$JOB_JSON_FILE" ]]; then
  die "Job '$JOB_NAME' not found in sftp-jobs.yml"
fi

# Set up per-job log file
JOB_DIR="$(yq -r '.remote_dir // empty' "$JOB_JSON_FILE")"
JOB_HOST="$(yq -r '.host' "$JOB_JSON_FILE")"
LOG_FILE="${SFTP_LOG_DIR}/${JOB_NAME}_$(date '+%Y%m%d').log"
log_set_file "$LOG_FILE"

log_info "=== Starting job: ${JOB_NAME} ==="
log_info "Host: ${JOB_HOST}, Log: ${LOG_FILE}"

# Resolve credential
CRED_REF="$(yq -r '.credential_ref' "$JOB_JSON_FILE")"
AUTH_VALUE="$(resolve_credential "$CRED_REF")"

# Build connection
sftp_build_cmd < "$JOB_JSON_FILE"
log_debug "Connection ready: ${_sftp_cmd}"

# Dispatch to upload or download
DIRECTION="$(yq -r '.direction' "$JOB_JSON_FILE")"

case "$DIRECTION" in
  UPLOAD)
    sftp_upload "$JOB_JSON_FILE" "$AUTH_VALUE"
    ;;
  DOWNLOAD)
    sftp_download "$JOB_JSON_FILE" "$AUTH_VALUE"
    ;;
  *)
    die "Unknown direction: $DIRECTION (expected UPLOAD or DOWNLOAD)"
    ;;
esac

log_info "=== Job '${JOB_NAME}' complete ==="
