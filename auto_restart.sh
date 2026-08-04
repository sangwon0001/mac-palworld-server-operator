#!/usr/bin/env bash
# ==============================================================================
# auto_restart.sh - 메모리 누수 대응 자동 재시작 (cron 등록용)
#
#   팰월드 서버는 장시간 가동 시 RSS 가 계속 증가하다가 스와핑/크래시로 이어집니다.
#   이 스크립트는 [백업 → 안전 종료 → (선택)업데이트 → 기동 → 검증] 순으로 처리합니다.
#
#   비대화형(cron) 실행을 전제로 모든 출력을 로그 파일에 남깁니다.
#
#   사용법:
#     ./auto_restart.sh                  # 조건 없이 재시작
#     ./auto_restart.sh --if-over 8192   # RSS 가 8192MB 초과일 때만 재시작
#     ./auto_restart.sh --if-empty       # 접속자가 0명일 때만 재시작
#     ./auto_restart.sh --update         # 재시작 김에 서버 업데이트도 수행
#   (옵션은 조합 가능: ./auto_restart.sh --if-over 8192 --if-empty --update)
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

ensure_dirs

RESTART_LOG="$LOG_DIR/auto_restart.log"
# stdout/stderr 를 화면과 로그 양쪽으로 (cron 에서는 로그에만 남습니다)
exec > >(tee -a "$RESTART_LOG") 2>&1

MEM_THRESHOLD=0
ONLY_IF_EMPTY=0
DO_UPDATE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --if-over)  MEM_THRESHOLD="${2:-0}"; shift 2 ;;
    --if-empty) ONLY_IF_EMPTY=1; shift ;;
    --update)   DO_UPDATE=1; shift ;;
    *) die "알 수 없는 옵션: $1" ;;
  esac
done

printf '\n'
log "===== auto_restart 시작 (threshold=${MEM_THRESHOLD}MB, if-empty=${ONLY_IF_EMPTY}, update=${DO_UPDATE}) ====="

# --------------------------------------------------------------- 사전 조건 검사
pid="$(server_pid || server_pid_by_name || true)"

if [[ -z "$pid" ]]; then
  # 서버가 죽어 있으면 이건 재시작이 아니라 '복구'입니다. 바로 띄웁니다.
  warn "서버가 실행 중이 아닙니다. 복구 기동을 시도합니다."
  audit "auto_restart: 정지 상태 감지 → 복구 기동"
  ./start_server.sh && log "복구 기동 성공" || log "복구 기동 실패"
  log "===== auto_restart 종료 ====="
  exit 0
fi

# 조건 1: 메모리 임계치
if [[ "$MEM_THRESHOLD" -gt 0 ]]; then
  rss_kb="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
  rss_mb=$(( ${rss_kb:-0} / 1024 ))
  log "현재 메모리 사용량: ${rss_mb}MB (임계치 ${MEM_THRESHOLD}MB)"
  if [[ "$rss_mb" -lt "$MEM_THRESHOLD" ]]; then
    log "임계치 미만 — 재시작하지 않고 종료합니다."
    log "===== auto_restart 종료 ====="
    exit 0
  fi
  warn "메모리 임계치 초과 — 재시작을 진행합니다."
fi

# 조건 2: 접속자 없음
if [[ "$ONLY_IF_EMPTY" -eq 1 ]]; then
  if [[ -z "$RCON_PASSWORD" ]]; then
    warn "--if-empty 는 RCON 이 필요합니다. RCON_PASSWORD 미설정이라 조건을 무시합니다."
  else
    players="$(rcon_cmd "ShowPlayers" 2>/dev/null || true)"
    if [[ -n "$players" ]]; then
      n=$(( $(printf '%s\n' "$players" | grep -c .) - 1 ))
      [[ $n -lt 0 ]] && n=0
      log "현재 접속자: ${n}명"
      if [[ "$n" -gt 0 ]]; then
        log "접속자가 있어 재시작을 건너뜁니다."
        log "===== auto_restart 종료 ====="
        exit 0
      fi
    else
      warn "접속자 조회 실패 — 조건을 무시하고 진행합니다."
    fi
  fi
fi

# ------------------------------------------------------ 1) 접속자에게 사전 공지
if [[ -n "$RCON_PASSWORD" ]]; then
  rcon_cmd "Broadcast Server_restarting_in_${RCON_SHUTDOWN_DELAY}_seconds" >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------ 2) 백업 우선
# 재시작 도중 문제가 생기더라도 되돌아갈 지점을 먼저 확보합니다.
log "[1/4] 세이브 백업"
if ./backup_save.sh; then
  log "백업 성공"
else
  # 백업 실패 시 재시작을 강행하면 데이터를 잃을 수 있으므로 중단합니다.
  die "백업 실패 — 안전을 위해 재시작을 중단합니다."
fi

# ------------------------------------------------------------------ 3) 안전 종료
log "[2/4] 서버 안전 종료"
if ! ./stop_server.sh; then
  warn "정상 종료 실패 — 강제 종료로 전환합니다."
  ./stop_server.sh --force || die "강제 종료마저 실패했습니다. 수동 확인이 필요합니다."
fi

# 포트와 Wine 자원이 완전히 해제될 시간을 줍니다.
sleep 5

# ------------------------------------------------------------- 4) 선택적 업데이트
if [[ "$DO_UPDATE" -eq 1 ]]; then
  log "[3/4] 서버 업데이트"
  ./install_update.sh || warn "업데이트 실패 — 기존 버전으로 기동을 계속합니다."
else
  log "[3/4] 업데이트 건너뜀"
fi

# ------------------------------------------------------------------ 5) 재기동
log "[4/4] 서버 재기동"
if ./start_server.sh; then
  log "재기동 성공"
  audit "auto_restart 완료 (성공)"
else
  # 기동 실패는 서버가 내려간 상태로 방치되는 최악의 경우이므로 크게 남깁니다.
  warn "재기동 실패! 서버가 내려가 있습니다. 로그를 확인하세요: $SERVER_LOG"
  audit "auto_restart 실패 (재기동 불가)"
  log "===== auto_restart 종료 (실패) ====="
  exit 1
fi

log "===== auto_restart 종료 ====="
