#!/usr/bin/env bash
# ==============================================================================
# auto_restart.sh - Scheduled restart to cope with the memory leak (for cron)
#
#   Palworld servers grow their RSS over long uptimes until they start swapping or
#   crash. This runs: back up → safe shutdown → (optionally) update → start → verify.
#
#   Written for non-interactive (cron) use, so everything is also written to a log.
#
#   Usage:
#     ./auto_restart.sh                  # restart unconditionally
#     ./auto_restart.sh --if-over 8192   # only if RSS exceeds 8192 MB
#     ./auto_restart.sh --if-empty       # only when no players are connected
#     ./auto_restart.sh --update         # also update the server while restarting
#   (Options combine: ./auto_restart.sh --if-over 8192 --if-empty --update)
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

ensure_dirs

RESTART_LOG="$LOG_DIR/auto_restart.log"
# Send stdout/stderr to both the console and the log (cron only sees the log)
exec > >(tee -a "$RESTART_LOG") 2>&1

MEM_THRESHOLD=0
ONLY_IF_EMPTY=0
DO_UPDATE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --if-over)  MEM_THRESHOLD="${2:-0}"; shift 2 ;;
    --if-empty) ONLY_IF_EMPTY=1; shift ;;
    --update)   DO_UPDATE=1; shift ;;
    *) die "Unknown option: $1" ;;
  esac
done

printf '\n'
log "===== auto_restart begin (threshold=${MEM_THRESHOLD}MB, if-empty=${ONLY_IF_EMPTY}, update=${DO_UPDATE}) ====="

# --------------------------------------------------------------- Preconditions
pid="$(server_pid || server_pid_by_name || true)"

if [[ -z "$pid" ]]; then
  # A dead server means this is recovery, not a restart — just bring it up.
  warn "The server is not running. Attempting a recovery start."
  audit "auto_restart: found stopped, starting for recovery"
  ./start_server.sh && log "Recovery start succeeded" || log "Recovery start failed"
  log "===== auto_restart end ====="
  exit 0
fi

# Condition 1: memory threshold
if [[ "$MEM_THRESHOLD" -gt 0 ]]; then
  rss_kb="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
  rss_mb=$(( ${rss_kb:-0} / 1024 ))
  log "Memory in use: ${rss_mb}MB (threshold ${MEM_THRESHOLD}MB)"
  if [[ "$rss_mb" -lt "$MEM_THRESHOLD" ]]; then
    log "Below the threshold — exiting without restarting."
    log "===== auto_restart end ====="
    exit 0
  fi
  warn "Above the memory threshold — restarting."
fi

# Condition 2: nobody connected
if [[ "$ONLY_IF_EMPTY" -eq 1 ]]; then
  if [[ -z "$RCON_PASSWORD" ]]; then
    warn "--if-empty needs RCON. RCON_PASSWORD is unset, so the condition is ignored."
  else
    players="$(rcon_cmd "ShowPlayers" 2>/dev/null || true)"
    if [[ -n "$players" ]]; then
      n=$(( $(printf '%s\n' "$players" | grep -c .) - 1 ))
      [[ $n -lt 0 ]] && n=0
      log "Players connected: ${n}"
      if [[ "$n" -gt 0 ]]; then
        log "Players are connected — skipping the restart."
        log "===== auto_restart end ====="
        exit 0
      fi
    else
      warn "Could not read the player list — ignoring the condition and proceeding."
    fi
  fi
fi

# ------------------------------------------------------ 1) Warn the players
if [[ -n "$RCON_PASSWORD" ]]; then
  rcon_cmd "Broadcast Server_restarting_in_${RCON_SHUTDOWN_DELAY}_seconds" >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------ 2) Back up first
# Secure a point to return to before anything else can go wrong.
log "[1/4] Backing up the save"
if ./backup_save.sh; then
  log "Backup succeeded"
else
  # Pressing on after a failed backup risks data loss, so stop here.
  die "Backup failed — aborting the restart for safety."
fi

# ------------------------------------------------------------------ 3) Safe shutdown
log "[2/4] Shutting the server down safely"
if ! ./stop_server.sh; then
  warn "Clean shutdown failed — escalating to a forced stop."
  ./stop_server.sh --force || die "Even the forced stop failed. Manual intervention needed."
fi

# Give the port and Wine's resources time to be released.
sleep 5

# ------------------------------------------------------------- 4) Optional update
if [[ "$DO_UPDATE" -eq 1 ]]; then
  log "[3/4] Updating the server"
  ./install_update.sh || warn "Update failed — starting the existing version instead."
else
  log "[3/4] Skipping the update"
fi

# ------------------------------------------------------------------ 5) Start again
log "[4/4] Starting the server again"
if ./start_server.sh; then
  log "Restart succeeded"
  audit "auto_restart done (success)"
else
  # A failed start leaves the server down — the worst outcome, so log it loudly.
  warn "Restart FAILED — the server is down. Check the log: $SERVER_LOG"
  audit "auto_restart failed (could not restart)"
  log "===== auto_restart end (failed) ====="
  exit 1
fi

log "===== auto_restart end ====="
