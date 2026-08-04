#!/usr/bin/env bash
# ==============================================================================
# start_server.sh - 서버 기동 (Wine/Rosetta 2 경유, 백그라운드)
#   기본은 nohup + PID 파일. tmux 가 있으면 --tmux 로 세션 부착 실행 가능.
#
#   사용법:
#     ./start_server.sh           # nohup 백그라운드 기동
#     ./start_server.sh --tmux    # tmux 세션(palworld)에서 기동, 콘솔 부착 가능
#     ./start_server.sh --fg      # 포그라운드 기동 (디버깅용)
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

# --------------------------------------------------------- 중복 기동 방지
# 같은 서버를 두 번 띄우면 세이브가 서로 덮어써져 데이터가 깨집니다.
# macOS 에는 flock(1) 이 없으므로 PID 파일 + 프로세스명 이중 검사로 막습니다.
if is_running; then
  pid="$(server_pid)"
  die "이미 실행 중입니다 (PID $pid). ./status.sh 로 확인하세요."
fi
if orphan="$(server_pid_by_name)" && [[ -n "$orphan" ]]; then
  die "PID 파일에는 없지만 PalServer 프로세스(PID $orphan)가 살아 있습니다. ./stop_server.sh --force 로 정리하세요."
fi

# ----------------------------------------------------------- 실행 대상 결정
if [[ "$USE_SHIPPING_EXE" == "1" && -f "$PAL_EXE_SHIPPING" ]]; then
  EXE="$PAL_EXE_SHIPPING"
  WORKDIR="$(dirname "$PAL_EXE_SHIPPING")"
  # 런처가 넘겨주던 프로젝트명 인자를 직접 전달해야 합니다.
  EXE_ARGS=("Pal" "${SERVER_ARGS[@]}")
elif [[ -f "$PAL_EXE_LAUNCHER" ]]; then
  EXE="$PAL_EXE_LAUNCHER"
  WORKDIR="$PAL_ROOT"
  EXE_ARGS=("${SERVER_ARGS[@]}")
else
  die "PalServer 실행 파일이 없습니다. ./install_update.sh 를 먼저 실행하세요."
fi

# ------------------------------------------------------- Wine 프리픽스 준비
if [[ ! -d "$WINEPREFIX" ]]; then
  info "Wine 프리픽스 초기화: $WINEPREFIX"
  WINEDLLOVERRIDES="mscoree=d;mshtml=d" "$WINE_BIN" wineboot --init >/dev/null 2>&1 || true
  # wineboot 는 비동기라 프리픽스 생성이 끝날 때까지 대기
  "${WINE_BIN%/*}/wineserver" -w 2>/dev/null || true
  ok "Wine 프리픽스 준비 완료"
fi

# ---------------------------------------------------------------- 로그 롤링
# 기동 때마다 이전 로그를 타임스탬프로 보존 (최근 10개만)
if [[ -f "$SERVER_LOG" ]]; then
  mv "$SERVER_LOG" "$LOG_DIR/palserver_$(date '+%Y%m%d_%H%M%S').log"
  ls -1t "$LOG_DIR"/palserver_*.log 2>/dev/null | tail -n +11 | while read -r old; do rm -f "$old"; done
fi

info "Wine     : $WINE_BIN"
info "실행 파일: $EXE"
info "포트     : UDP $GAME_PORT (게임) / TCP $RCON_PORT (RCON)"
info "로그     : $SERVER_LOG"

# --------------------------------------------------------------------- 기동
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

# ------------------------------------------------------- 포트 바인딩 대기 확인
# UE5 서버는 월드 로딩에 수십 초가 걸릴 수 있어 넉넉히 기다립니다.
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
