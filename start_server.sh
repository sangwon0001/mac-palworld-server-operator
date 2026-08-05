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
  *)      die "알 수 없는 옵션: $1 (--tmux | --fg)" ;;
esac

ensure_dirs
require_wine

# --------------------------------------------------------- Prevent double start
# Running the same server twice makes the two instances overwrite each other's
# saves. macOS has no flock(1), so guard with both the PID file and a name check.
if is_running; then
  pid="$(server_pid)"
  die "이미 실행 중입니다 (PID $pid). ./status.sh 로 확인하세요."
fi
if orphan="$(server_pid_by_name)" && [[ -n "$orphan" ]]; then
  die "PID 파일에는 없지만 PalServer 프로세스(PID $orphan)가 살아 있습니다. ./stop_server.sh --force 로 정리하세요."
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
  die "PalServer 실행 파일이 없습니다. ./install_update.sh 를 먼저 실행하세요."
fi

# ------------------------------------------------------- Prepare Wine prefix
if [[ ! -d "$WINEPREFIX" ]]; then
  info "Wine 프리픽스 초기화: $WINEPREFIX"
  WINEDLLOVERRIDES="mscoree=d;mshtml=d" "$WINE_BIN" wineboot --init >/dev/null 2>&1 || true
  # wineboot is asynchronous; wait until the prefix is fully created
  "${WINE_BIN%/*}/wineserver" -w 2>/dev/null || true
  ok "Wine 프리픽스 준비 완료"
fi

# ---------------------------------------------------------------- Log rotation
# Keep the previous log under a timestamped name on each start (latest 10 only)
if [[ -f "$SERVER_LOG" ]]; then
  mv "$SERVER_LOG" "$LOG_DIR/palserver_$(date '+%Y%m%d_%H%M%S').log"
  ls -1t "$LOG_DIR"/palserver_*.log 2>/dev/null | tail -n +11 | while read -r old; do rm -f "$old"; done
fi

info "Wine     : $WINE_BIN"
info "실행 파일: $EXE"
info "포트     : UDP $GAME_PORT (게임) / TCP $RCON_PORT (RCON)"
info "로그     : $SERVER_LOG"

# --------------------------------------------------------------------- Launch
launch_cmd=( "$WINE_BIN" "$EXE" "${EXE_ARGS[@]}" )

case "$MODE" in
  fg)
    cd "$WORKDIR"
    audit "start (foreground)"
    exec "${launch_cmd[@]}" 2>&1 | tee "$SERVER_LOG"
    ;;

  tmux)
    command -v tmux >/dev/null 2>&1 || die "tmux 가 없습니다: brew install tmux"
    tmux has-session -t palworld 2>/dev/null && die "tmux 세션 'palworld' 가 이미 있습니다."
    tmux new-session -d -s palworld -c "$WORKDIR" \
      "'${launch_cmd[0]}' $(printf "'%s' " "${launch_cmd[@]:1}") 2>&1 | tee '$SERVER_LOG'"
    sleep 3
    pid="$(server_pid_by_name || true)"
    [[ -n "$pid" ]] || die "기동 실패. 로그 확인: $SERVER_LOG"
    printf '%s' "$pid" > "$PID_FILE"
    audit "start (tmux) pid=$pid"
    ok "tmux 세션 'palworld' 에서 기동 (PID $pid)"
    info "콘솔 부착: tmux attach -t palworld   (분리: Ctrl-b d)"
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
      audit "start 실패"
      die "기동 직후 프로세스가 죽었습니다. 로그 확인: $SERVER_LOG"
    fi
    audit "start (nohup) pid=$pid"
    ok "백그라운드 기동 완료 (PID $pid)"
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
    ok "잠자기 방지: $keeper 이(가) 이미 처리 중 — 건드리지 않습니다"
  elif [[ -n "$guard_pid" ]] && command -v caffeinate >/dev/null 2>&1; then
    nohup caffeinate -dims -w "$guard_pid" >/dev/null 2>&1 &
    disown 2>/dev/null || true
    ok "잠자기 방지 활성 (caffeinate — 서버 종료 시 자동 해제)"
    printf '    %smacOS 정책은 %s분 후 잠자기이지만 서버가 도는 동안은 억제됩니다%s\n' \
           "$_c_dim" "$sleep_policy" "$_c_reset"
    printf '    %s덮개를 닫으면 외장 디스플레이 없이는 그래도 잠듭니다%s\n' \
           "$_c_dim" "$_c_reset"
  fi
fi

# ------------------------------------------------------- Wait for the port
# UE5 servers can take tens of seconds to load the world, so allow generous time.
info "UDP $GAME_PORT 바인딩 대기 중 (최대 120초)..."
for i in $(seq 1 60); do
  if lsof -nP -iUDP:"$GAME_PORT" >/dev/null 2>&1; then
    ok "UDP $GAME_PORT 바인딩 확인. 서버가 접속을 받을 준비가 되었습니다."
    exit 0
  fi
  is_running || die "기동 중 프로세스가 종료되었습니다. 로그 확인: $SERVER_LOG"
  sleep 2
done

warn "120초 안에 포트가 열리지 않았습니다. 프로세스는 살아 있으니 로그를 확인하세요:"
printf '    tail -f %s\n' "$SERVER_LOG"
