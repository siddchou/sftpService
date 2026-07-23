#!/usr/bin/env bash
# common.sh — logging, error handling, utility functions

set -euo pipefail

# Resolve script root so lib/ can be sourced from any depth.
SFTP_ROOT="${SFTP_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

# Source defaults if not already loaded.
if [[ -z "${SFTP_DEFAULT_PORT:-}" ]]; then
  # shellcheck source=/dev/null
  source "${SFTP_ROOT}/config/defaults.conf"
fi

# Ensure log directory exists.
mkdir -p "$SFTP_LOG_DIR"

# ── Log Rotation ─────────────────────────────────────────────────────────────

log_rotate() {
  log_debug "Log rotation: retention=${SFTP_LOG_RETENTION_DAYS}d, max=${SFTP_LOG_MAX_SIZE_KB}KB"

  # 1. Age-based cleanup
  find "$SFTP_LOG_DIR" -maxdepth 1 -type f \( -name '*.log' -o -name '*.log.gz' \) \
    -mtime +"$SFTP_LOG_RETENTION_DAYS" -exec rm -f {} + 2>/dev/null || true

  # 2. Size-based rotation — compress + truncate any log that grew too large
  find "$SFTP_LOG_DIR" -maxdepth 1 -type f -name '*.log' -size +"${SFTP_LOG_MAX_SIZE_KB}k" \
    | while IFS= read -r big_log; do
      local rotated="${big_log}.$(date '+%Y%m%d_%H%M%S').gz"
      gzip -c "$big_log" > "$rotated" 2>/dev/null || true
      : > "$big_log"
      log_debug "Rotated ${big_log} -> ${rotated}"
    done
}

# ── Logging ──────────────────────────────────────────────────────────────────

_log_file=""

log_set_file() {
  _log_file="$1"
}

_log() {
  local level="$1"; shift
  local ts
  ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local msg="[$ts] [$level] $*"
  echo "$msg"
  if [[ -n "$_log_file" ]]; then
    echo "$msg" >> "$_log_file"
  fi
}

log_info()  { _log INFO  "$@"; }
log_warn()  { _log WARN  "$@"; }
log_error() { _log ERROR "$@"; }
log_debug() { [[ "${SFTP_DEBUG:-false}" == "true" ]] && _log DEBUG "$@" || true; }

# ── Error handling ───────────────────────────────────────────────────────────

die() {
  log_error "$@"
  exit 1
}

# ── Prerequisites ────────────────────────────────────────────────────────────

require_env() {
  local var="$1"
  if [[ -z "${!var:-}" ]]; then
    die "Environment variable $var is not set."
  fi
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" &>/dev/null; then
    die "Required command '$cmd' not found in PATH."
  fi
}

# ── String helpers ───────────────────────────────────────────────────────────

timestamp() {
  date '+%Y%m%d_%H%M%S'
}

file_base() {
  local f="${1##*/}"
  echo "${f%.*}"
}

file_ext() {
  local f="${1##*/}"
  echo "${f##*.}"
}

expand_template() {
  local template="$1"
  local src_file="$2"
  local name ext ts
  name="$(file_base "$src_file")"
  ext="$(file_ext "$src_file")"
  ts="$(timestamp)"

  # Use sed to avoid bash ${//} breaking on values containing //
  printf '%s\n' "$template" \
    | sed \
        -e "s|\${fileName}|${name}|" \
        -e "s|\${fileExtension}|${ext}|" \
        -e "s|\${timestamp}|${ts}|"
}

# ── YAML helpers ─────────────────────────────────────────────────────────────

require_yq() {
  require_cmd yq
  # Verify go-yq (not python-yq which has incompatible syntax)
  local yq_version
  yq_version="$(yq --version 2>/dev/null)" || true
  if [[ "$yq_version" == *"python"* ]]; then
    die "python-yq detected. This project requires go-yq (mikefarah/yq). See https://github.com/mikefarah/yq/#install"
  fi
}

# Read a job config block from sftp-jobs.yml, merged with env override if present.
# Args: <job-name> [env-profile]
yq_read_job() {
  local job_name="$1"
  local env_profile="${2:-}"
  local jobs_file="${SFTP_ROOT}/config/sftp-jobs.yml"
  [[ -f "$jobs_file" ]] || die "Base job definitions file not found: $jobs_file"
  require_yq

  if [[ -n "$env_profile" ]]; then
    local env_file="${SFTP_ROOT}/config/sftp-jobs.${env_profile}.yml"
    if [[ -f "$env_file" ]]; then
      # Merge: env override wins for same job name
      yq -o json -n \
        "$(yq -o json "$jobs_file") *+ $(yq -o json "$env_file")" \
        | yq -o json --arg name "$job_name" '.jobs[] | select(.name == $name)'
    else
      yq -o json --arg name "$job_name" '.jobs[] | select(.name == $name)' "$jobs_file"
    fi
  else
    yq -o json --arg name "$job_name" '.jobs[] | select(.name == $name)' "$jobs_file"
  fi
}

# ── Common arg parsing ───────────────────────────────────────────────────────

# Parse -e/--env flag from arguments.
# Sets: ENV_PROFILE (may be empty), _LEFTOVER_ARGS array.
# Usage: parse_env_args "$@"
parse_env_args() {
  ENV_PROFILE=""
  _LEFTOVER_ARGS=()

  while [[ $# -gt 0 ]]; do
    case "$1" in
      -e|--env)
        ENV_PROFILE="$2"; shift 2 ;;
      -e*)
        ENV_PROFILE="${1#-e}"; shift ;;
      --)
        shift; _LEFTOVER_ARGS=("$@"); break ;;
      -*)
        die "Unknown option: $1" ;;
      *)
        _LEFTOVER_ARGS=("$@"); break ;;
    esac
  done
}

# ── Signal handling ──────────────────────────────────────────────────────────

_CANCELLED=false

trap_cancel() {
  log_warn "Cancellation signal received. Finishing current transfer…"
  _CANCELLED=true
}

is_cancelled() {
  "$_CANCELLED"
}

install_cancel_trap() {
  trap trap_cancel SIGINT SIGTERM
}
