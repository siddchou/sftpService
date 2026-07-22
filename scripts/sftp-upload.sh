#!/usr/bin/env bash
# sftp-upload.sh — convenience wrapper: run an UPLOAD job by name
set -euo pipefail

SFTP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

JOB_NAME="${1:?Usage: sftp-upload.sh <job-name>}"

# Validate direction before running
source "${SFTP_ROOT}/config/defaults.conf"
source "${SFTP_ROOT}/lib/common.sh"

DIRECTION="$(yq -r ".jobs[] | select(.name == \"${JOB_NAME}\") | .direction" \
  "${SFTP_ROOT}/config/sftp-jobs.yml")"

if [[ "$DIRECTION" != "UPLOAD" ]]; then
  die "Job '${JOB_NAME}' is not an UPLOAD job (direction: ${DIRECTION:-missing})"
fi

exec "${SFTP_ROOT}/scripts/sftp-run.sh" "$JOB_NAME"
