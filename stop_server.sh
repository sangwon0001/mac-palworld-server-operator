#!/usr/bin/env bash
# ==============================================================================
# stop_server.sh - 서버 안전 종료 (세이브 유실 방지)
#
#   종료 단계 (앞 단계가 성공하면 뒤는 실행하지 않음):
#     1) RCON Save + Shutdown  ← 가장 안전. 게임이 직접 세이브를 플러시함
#     2) SIGINT  (Ctrl-C 상당) ← Wine 이 Windows 콘솔 종료 이벤트로 변환
#     3) SIGTERM
#     4) SIGKILL + wineserver -k  ← 최후 수단. 세이브 손상 위험 있음
#
#   사용법:
#     ./stop_server.sh              # 안전 종료 (RCON 예고 후 종료)
#     ./stop_server.sh --now        # 예고 없이 즉시 저장 후 종료
#     ./stop_server.sh --force      # 유령 프로세스까지 강제 정리
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

FORCE=0; DELAY="$RCON_SHUTDOWN_DELAY"
case "${1:-}" in
  --now)   DELAY=1 ;;
  --force) FORCE=1 ;;
  "")      ;;
  *)       die "알 수 없는 옵션: $1 (--now | --force)" ;;
esac

# ------------------------------------------------------------ 대상 PID 확정
pid="$(server_pid || true)"
if [[ -z "$pid" ]]; then
  pid="$(server_pid_by_name || true)"
  if [[ -n "$pid" ]]; then
    warn "PID 파일과 실제 프로세스가 어긋납니다. 이름으로 찾은 PID $pid 를 종료합니다."
  fi
fi

if [[ -z "$pid" ]]; then
  rm -f "$PID_FILE"
  ok "실행 중인 서버가 없습니다."
  exit 0
fi

info "종료 대상 PID: $pid"
audit "stop 시작 pid=$pid"

# 프로세스가 사라질 때까지 최대 N초 대기
wait_gone() {
  local p="$1" limit="$2" i
  for ((i = 0; i < limit; i++)); do
    kill -0 "$p" 2>/dev/null || return 0
    sleep 1
  done
  return 1
}

# ------------------------------------------------ 1단계: RCON 우아한 종료
if [[ -n "$RCON_PASSWORD" ]]; then
  info "RCON 으로 세이브 후 종료를 시도합니다 (예고 ${DELAY}초)"
  if rcon_cmd "Save" >/dev/null 2>&1; then
    ok "월드 세이브 플러시 완료"
    # Shutdown <초> <메시지> : 접속자에게 예고 후 정상 종료
    rcon_cmd "Shutdown ${DELAY} Server_is_shutting_down" >/dev/null 2>&1 || true
    if wait_gone "$pid" $((DELAY + 45)); then
      rm -f "$PID_FILE"
      audit "stop 완료 (RCON)"
      ok "RCON 정상 종료 완료 — 세이브 안전"
      exit 0
    fi
    warn "RCON 종료가 시간 내에 끝나지 않았습니다. 시그널로 전환합니다."
  else
    warn "RCON 연결 실패 (RCONEnabled/AdminPassword 확인). 시그널로 전환합니다."
  fi
else
  warn "RCON_PASSWORD 미설정 — 시그널 종료를 사용합니다."
  warn "가장 안전한 종료를 위해 config.local.sh 에 RCON_PASSWORD 를 설정하세요."
fi

# ---------------------------------------------------- 2단계: SIGINT (권장)
info "SIGINT 전송 (최대 60초 대기)"
kill -INT "$pid" 2>/dev/null || true
if wait_gone "$pid" 60; then
  rm -f "$PID_FILE"
  audit "stop 완료 (SIGINT)"
  ok "SIGINT 로 정상 종료되었습니다."
  exit 0
fi

# --------------------------------------------------------- 3단계: SIGTERM
warn "SIGINT 무응답. SIGTERM 전송 (최대 45초 대기)"
kill -TERM "$pid" 2>/dev/null || true
if wait_gone "$pid" 45; then
  rm -f "$PID_FILE"
  audit "stop 완료 (SIGTERM)"
  ok "SIGTERM 으로 종료되었습니다."
  exit 0
fi

# ------------------------------------------- 4단계: SIGKILL (최후 수단)
if [[ $FORCE -eq 0 ]]; then
  audit "stop 교착 pid=$pid"
  die "프로세스가 응답하지 않습니다 (PID $pid).
    강제 종료는 세이브 손상 위험이 있습니다. 감수하려면: ./stop_server.sh --force"
fi

warn "SIGKILL 강제 종료 — 최근 진행분이 유실될 수 있습니다."
kill -KILL "$pid" 2>/dev/null || true
sleep 2

# Wine 잔여 프로세스 정리 (wineserver 가 남으면 다음 기동이 실패합니다)
if detect_wine; then
  "${WINE_BIN%/*}/wineserver" -k 2>/dev/null || true
fi
pkill -9 -f 'PalServer-Win64-Shipping\.exe|PalServer\.exe' 2>/dev/null || true

rm -f "$PID_FILE"
tmux kill-session -t palworld 2>/dev/null || true
audit "stop 완료 (SIGKILL 강제)"
warn "강제 종료 완료. 다음 기동 전 ./backup_save.sh 로 세이브 상태를 확인하세요."
