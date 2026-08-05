#!/usr/bin/env bash
# ==============================================================================
# start_server.sh - Start the server in the background through Wine / Rosetta 2
#   Default is nohup plus a PID file. With tmux installed, --tmux gives an
#   attachable console session.
#
#   Usage:
#     ./start_server.sh           # background via nohup
#     ./start_server.sh --tmux    # run inside a tmux session named 'palworld'
#     ./start_server.sh --fg      # foreground (for debugging)
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

MODE="nohup"
case "${1:-}" in
  --tmux) MODE="tmux" ;;
  --fg)   MODE="fg" ;;
  "")     ;;
  *)      die "Unknown option: $1 (--tmux | --fg)" ;;
esac

ensure_dirs
require_wine
# Held for the start sequence only. Blocks a backup or a cron restart from
# running underneath a half-started server.
acquire_lock "server start"

# --------------------------------------------------------- Prevent double start
# Running the same server twice makes the two instances overwrite each other's
# saves. macOS has no flock(1), so guard with both the PID file and a name check.
if is_running; then
  pid="$(server_pid)"
  die "Already running (PID $pid). Check with ./status.sh"
fi
if orphan="$(server_pid_by_name)" && [[ -n "$orphan" ]]; then
  die "A PalServer process (PID $orphan) is alive but absent from the PID file. Clean up with ./stop_server.sh --force"
fi

# ----------------------------------------------------------- Pick the binary
if [[ "$USE_SHIPPING_EXE" == "1" && -f "$PAL_EXE_SHIPPING" ]]; then
  EXE="$PAL_EXE_SHIPPING"
  WORKDIR="$(dirname "$PAL_EXE_SHIPPING")"
  # Pass the project-name argument the launcher would normally supply.
  EXE_ARGS=("Pal" "${SERVER_ARGS[@]}")
elif [[ -f "$PAL_EXE_LAUNCHER" ]]; then
  EXE="$PAL_EXE_LAUNCHER"
  WORKDIR="$PAL_ROOT"
  EXE_ARGS=("${SERVER_ARGS[@]}")
else
  die "PalServer executable not found. Run ./install_update.sh first."
fi

# ------------------------------------------------------- Prepare Wine prefix
if [[ ! -d "$WINEPREFIX" ]]; then
  info "Initializing Wine prefix: $WINEPREFIX"
  WINEDLLOVERRIDES="mscoree=d;mshtml=d" "$WINE_BIN" wineboot --init >/dev/null 2>&1 || true
  # wineboot is asynchronous; wait until the prefix is fully created
  "${WINE_BIN%/*}/wineserver" -w 2>/dev/null || true
  ok "Wine prefix ready"
fi

# ---------------------------------------------------------------- Log rotation
# Keep the previous log under a timestamped name on each start (latest 10 only)
if [[ -f "$SERVER_LOG" ]]; then
  mv "$SERVER_LOG" "$LOG_DIR/palserver_$(date '+%Y%m%d_%H%M%S').log"
  ls -1t "$LOG_DIR"/palserver_*.log 2>/dev/null | tail -n +11 | while read -r old; do rm -f "$old"; done
fi

info "Wine     : $WINE_BIN"
info "Executable: $EXE"
info "Ports    : UDP $GAME_PORT (game) / TCP $RCON_PORT (RCON)"
info "Log      : $SERVER_LOG"

# --------------------------------------------------------------------- Launch
launch_cmd=( "$WINE_BIN" "$EXE" "${EXE_ARGS[@]}" )

case "$MODE" in
  fg)
    cd "$WORKDIR"
    audit "start (foreground)"
    # The server itself is not an "operation", so the lock must not be held for
    # the hours it runs — that would block every scheduled backup. But it cannot
    # be dropped before the server exists either: another start arriving in that
    # window would find nothing running and launch a second one.
    #
    # So launch, record the PID (which is what the double-start guard reads), and
    # only then release. Backgrounding rather than exec'ing is deliberate: in
    # `exec cmd | tee` the exec applies to the pipeline's subshell, not to this
    # shell, so it never had the meaning the old code assumed.
    "${launch_cmd[@]}" > >(tee "$SERVER_LOG") 2>&1 &
    fg_pid=$!
    printf '%s' "$fg_pid" > "$PID_FILE"
    release_lock
    # Foreground mode exists for debugging, so the server's own exit status is
    # the useful answer — don't swallow it.
    fg_rc=0; wait "$fg_pid" || fg_rc=$?
    rm -f "$PID_FILE"
    exit "$fg_rc"
    ;;

  tmux)
    command -v tmux >/dev/null 2>&1 || die "tmux not found: brew install tmux"
    tmux has-session -t palworld 2>/dev/null && die "A tmux session named 'palworld' already exists."
    tmux new-session -d -s palworld -c "$WORKDIR" \
      "'${launch_cmd[0]}' $(printf "'%s' " "${launch_cmd[@]:1}") 2>&1 | tee '$SERVER_LOG'"
    sleep 3
    pid="$(server_pid_by_name || true)"
    [[ -n "$pid" ]] || die "Start failed. Check the log: $SERVER_LOG"
    printf '%s' "$pid" > "$PID_FILE"
    audit "start (tmux) pid=$pid"
    ok "Started in tmux session 'palworld' (PID $pid)"
    info "Attach: tmux attach -t palworld   (detach: Ctrl-b d)"
    ;;

  nohup)
    (
      cd "$WORKDIR"
      nohup "${launch_cmd[@]}" >> "$SERVER_LOG" 2>&1 &
      printf '%s' "$!" > "$PID_FILE"
    )
    sleep 2
    pid="$(cat "$PID_FILE")"
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$PID_FILE"
      audit "start failed"
      die "The process died immediately after starting. Check the log: $SERVER_LOG"
    fi
    audit "start (nohup) pid=$pid"
    ok "Started in the background (PID $pid)"
    ;;
esac

# ------------------------------------------------------- Keep the Mac awake
# If the Mac sleeps, the server stops with it. But the `sleep` value in
# `pmset -g custom` is only the configured *policy* — whether it actually sleeps
# depends on the assertions currently held. (With a resident app such as
# Amphetamine, a 1-minute policy still never sleeps.)
#
# So check the effective state rather than the policy, leave things alone if
# something already holds sleep off, and only reach for caffeinate otherwise.

# Look for a long-lived process holding idle sleep off. Assertions from powerd,
# WindowServer, useractivityd and sharingd come and go with screen state or brief
# activity, so they don't count as protection for a server.
existing_sleep_guard() {
  pmset -g assertions 2>/dev/null \
    | sed -n '/Listed by owning process/,$p' \
    | grep 'PreventUserIdleSystemSleep' \
    | grep -vE '\((powerd|WindowServer|useractivityd|sharingd|coreaudiod)\)' \
    | sed -E 's/.*pid [0-9]+\(([^)]+)\).*/\1/' \
    | head -n1
}

# `caffeinate -w <PID>` holds the assertion only while that process lives, which
# matches the server's lifetime exactly — it releases automatically on shutdown.
#   -d display  -i idle system sleep  -m disk  -s system sleep (on AC power)
if [[ "$MODE" != "fg" ]]; then
  guard_pid="$(server_pid || server_pid_by_name || true)"
  sleep_policy="$(pmset -g custom 2>/dev/null | awk '/AC Power/{f=1} f&&/^ *sleep /{print $2; exit}')"

  if [[ "${sleep_policy:-0}" == "0" ]]; then
    : # Policy is already 'never sleep' — nothing to do
  elif keeper="$(existing_sleep_guard)" && [[ -n "$keeper" ]]; then
    ok "Sleep prevention: $keeper already handles it — leaving it alone"
  elif [[ -n "$guard_pid" ]] && command -v caffeinate >/dev/null 2>&1; then
    nohup caffeinate -dims -w "$guard_pid" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    ok "Sleep prevention active (caffeinate — released when the server stops)"
    printf '    %smacOS policy sleeps after %s min, but it is held off while the server runs%s\n' \
           "$_c_dim" "$sleep_policy" "$_c_reset"
    printf '    %sClosing the lid still sleeps without an external display%s\n' \
           "$_c_dim" "$_c_reset"
  fi
fi

# ------------------------------------------------------- Wait for the port
# UE5 servers can take tens of seconds to load the world, so allow generous time.
info "Waiting for UDP $GAME_PORT to bind (up to 120s)..."
for _ in $(seq 1 60); do
  if lsof -nP -iUDP:"$GAME_PORT" >/dev/null 2>&1; then
    ok "UDP $GAME_PORT is bound. The server is ready for connections."
    exit 0
  fi
  is_running || die "The process exited while starting. Check the log: $SERVER_LOG"
  sleep 2
done

warn "The port did not open within 120s. The process is alive; check the log:"
printf '    tail -f %s\n' "$SERVER_LOG"
