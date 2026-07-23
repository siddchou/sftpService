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

# ── Verify crypto integrity ──────────────────────────────────────────────────

if [[ -n "${ORCHESTRATOR_ENCRYPTION_KEY:-}" ]]; then
  verify_gcm_integrity
fi

# ── Parse args ───────────────────────────────────────────────────────────────

parse_env_args "$@"
JOB_NAME="${_LEFTOVER_ARGS[0]:-}"

if [[ -z "$JOB_NAME" ]]; then
  die "Usage: sftp-run.sh [-e <env>] <job-name>"
fi

# ── Load environment profile ─────────────────────────────────────────────────

if [[ -n "$ENV_PROFILE" ]]; then
  ENV_CONF="${SFTP_ROOT}/config/env/${ENV_PROFILE}.conf"
  if [[ -f "$ENV_CONF" ]]; then
    log_info "Loading environment profile: ${ENV_PROFILE}"
    # shellcheck source=/dev/null
    source "$ENV_CONF"
  else
    die "Environment config not found: ${ENV_CONF}"
  fi

  # Re-create log dir after env override may have changed it
  mkdir -p "$SFTP_LOG_DIR"

  # Set per-environment credential file
  CRED_FILE="${SFTP_ROOT}/config/credentials.${ENV_PROFILE}.yml"
else
  ENV_PROFILE="default"
  CRED_FILE="${SFTP_ROOT}/config/credentials.yml"
fi

# ── Set up per-job log file (before log_rotate so debug messages are captured) ─

LOG_FILE="${SFTP_LOG_DIR}/${ENV_PROFILE}_${JOB_NAME}_$(date '+%Y%m%d').log"
log_set_file "$LOG_FILE"
# Harden log file permissions on multi-user hosts
chmod 600 "$LOG_FILE" 2>/dev/null || true

# ── Concurrency guard (flock) ────────────────────────────────────────────────

mkdir -p "${SFTP_LOCK_DIR:-$SFTP_LOG_DIR}/locks"
LOCK_FILE="${SFTP_LOCK_DIR:-$SFTP_LOG_DIR}/locks/${ENV_PROFILE}_${JOB_NAME}.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  die "Job '${JOB_NAME}' (env=${ENV_PROFILE}) is already running (lock: ${LOCK_FILE})"
fi
# Lock auto-released when fd 9 closes on exit

# ── Rotate old logs before starting ──────────────────────────────────────────

log_rotate

# ── Read merged job config ───────────────────────────────────────────────────

JOB_JSON_FILE="$(mktemp)"
trap "rm -f '$JOB_JSON_FILE'" EXIT

yq_read_job "$JOB_NAME" "$ENV_PROFILE" > "$JOB_JSON_FILE"

if [[ ! -s "$JOB_JSON_FILE" ]]; then
  die "Job '$JOB_NAME' not found in sftp-jobs.yml${ENV_PROFILE:+ (or sftp-jobs.${ENV_PROFILE}.yml)}"
fi

# ── Job start ────────────────────────────────────────────────────────────────

JOB_HOST="$(yq -r '.host' "$JOB_JSON_FILE")"
log_info "=== Starting job: ${JOB_NAME} (env=${ENV_PROFILE}) ==="
log_info "Host: ${JOB_HOST}, Log: ${LOG_FILE}"

# ── Resolve credential ───────────────────────────────────────────────────────

CRED_REF="$(yq -r '.credential_ref' "$JOB_JSON_FILE")"
AUTH_VALUE="$(resolve_credential "$CRED_REF")"

# ── Build connection ─────────────────────────────────────────────────────────

sftp_build_cmd < "$JOB_JSON_FILE"
log_debug "Connection ready"

# ── Dispatch ─────────────────────────────────────────────────────────────────

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

log_info "=== Job '${JOB_NAME}' (env=${ENV_PROFILE}) complete ==="
