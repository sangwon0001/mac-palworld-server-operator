#!/usr/bin/env bash
# ==============================================================================
# stop_server.sh - Shut the server down safely, without losing the save
#
#   Escalation (each stage only runs if the previous one failed):
#     1) RCON Save + Shutdown  ← safest; the game flushes its own save
#     2) SIGINT (like Ctrl-C)  ← Wine turns this into a Windows console close event
#     3) SIGTERM
#     4) SIGKILL + wineserver -k  ← last resort; risks a damaged save
#
#   Usage:
#     ./stop_server.sh              # safe shutdown (warn over RCON, then stop)
#     ./stop_server.sh --now        # save and stop immediately, no warning
#     ./stop_server.sh --force      # also clean up an unresponsive process
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

FORCE=0; DELAY="$RCON_SHUTDOWN_DELAY"
# A loop rather than a single case: --now and --force are independent choices,
# and "stop right now, and force it if it hangs" is the combination you reach for
# when a server is misbehaving.
while [[ $# -gt 0 ]]; do
  case "$1" in
    --now)   DELAY=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) sed -n '2,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)       die "Unknown option: $1 (--now | --force)" ;;
  esac
done

acquire_lock "server stop"

# ------------------------------------------------------------ Resolve target PID
pid="$(server_pid || true)"
if [[ -z "$pid" ]]; then
  pid="$(server_pid_by_name || true)"
  if [[ -n "$pid" ]]; then
    warn "The PID file disagrees with reality. Stopping PID $pid, found by name."
  fi
fi

if [[ -z "$pid" ]]; then
  rm -f "$PID_FILE"
  ok "No server is running."
  exit 0
fi

info "Target PID: $pid"
audit "stop begin pid=$pid"

# Wait up to N seconds for the process to disappear
wait_gone() {
  local p="$1" limit="$2" i
  for ((i = 0; i < limit; i++)); do
    kill -0 "$p" 2>/dev/null || return 0
    sleep 1
  done
  return 1
}

# ------------------------------------------------ Stage 1: graceful via RCON
if [[ -n "$RCON_PASSWORD" ]]; then
  info "Trying RCON: save, then shut down (${DELAY}s warning)"
  if rcon_cmd "Save" >/dev/null 2>&1; then
    ok "World save flushed"
    # Shutdown <seconds> <message>: warn players, then stop cleanly
    rcon_cmd "Shutdown ${DELAY} Server_is_shutting_down" >/dev/null 2>&1 || true
    if wait_gone "$pid" $((DELAY + 45)); then
      rm -f "$PID_FILE"
      audit "stop done (RCON)"
      ok "Clean RCON shutdown — save is safe"
      exit 0
    fi
    warn "RCON shutdown did not finish in time. Falling back to signals."
  else
    warn "RCON connection failed (check RCONEnabled/AdminPassword). Falling back to signals."
  fi
else
  warn "RCON_PASSWORD is not set — using signal shutdown."
  warn "For the safest shutdown, set RCON_PASSWORD in config.local.sh."
fi

# ---------------------------------------------------- Stage 2: SIGINT
info "Sending SIGINT (waiting up to 60s)"
kill -INT "$pid" 2>/dev/null || true
if wait_gone "$pid" 60; then
  rm -f "$PID_FILE"
  audit "stop done (SIGINT)"
  ok "Stopped cleanly via SIGINT."
  exit 0
fi

# --------------------------------------------------------- Stage 3: SIGTERM
warn "No response to SIGINT. Sending SIGTERM (waiting up to 45s)"
kill -TERM "$pid" 2>/dev/null || true
if wait_gone "$pid" 45; then
  rm -f "$PID_FILE"
  audit "stop done (SIGTERM)"
  ok "Stopped via SIGTERM."
  exit 0
fi

# ------------------------------------------- Stage 4: SIGKILL (last resort)
if [[ $FORCE -eq 0 ]]; then
  audit "stop stuck pid=$pid"
  die "The process is not responding (PID $pid).
    Forcing it risks a damaged save. To accept that: ./stop_server.sh --force"
fi

warn "Forcing SIGKILL — recent progress may be lost."
kill -KILL "$pid" 2>/dev/null || true
sleep 2

# Clean up leftover Wine processes; a stray wineserver breaks the next start
if detect_wine; then
  "${WINE_BIN%/*}/wineserver" -k 2>/dev/null || true
fi
pkill -9 -f 'PalServer-Win64-Shipping\.exe|PalServer\.exe' 2>/dev/null || true

rm -f "$PID_FILE"
tmux kill-session -t palworld 2>/dev/null || true
audit "stop done (forced SIGKILL)"
warn "Force-stopped. Check the save with ./backup_save.sh before starting again."
