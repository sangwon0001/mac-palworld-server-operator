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
    *) die "알 수 없는 옵션: $1" ;;
  esac
done

printf '\n'
log "===== auto_restart 시작 (threshold=${MEM_THRESHOLD}MB, if-empty=${ONLY_IF_EMPTY}, update=${DO_UPDATE}) ====="

# --------------------------------------------------------------- Preconditions
pid="$(server_pid || server_pid_by_name || true)"

if [[ -z "$pid" ]]; then
  # A dead server means this is recovery, not a restart — just bring it up.
  warn "서버가 실행 중이 아닙니다. 복구 기동을 시도합니다."
  audit "auto_restart: 정지 상태 감지 → 복구 기동"
  ./start_server.sh && log "복구 기동 성공" || log "복구 기동 실패"
  log "===== auto_restart 종료 ====="
  exit 0
fi

# Condition 1: memory threshold
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

# Condition 2: nobody connected
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

# ------------------------------------------------------ 1) Warn the players
if [[ -n "$RCON_PASSWORD" ]]; then
  rcon_cmd "Broadcast Server_restarting_in_${RCON_SHUTDOWN_DELAY}_seconds" >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------ 2) Back up first
# Secure a point to return to before anything else can go wrong.
log "[1/4] 세이브 백업"
if ./backup_save.sh; then
  log "백업 성공"
else
  # Pressing on after a failed backup risks data loss, so stop here.
  die "백업 실패 — 안전을 위해 재시작을 중단합니다."
fi

# ------------------------------------------------------------------ 3) Safe shutdown
log "[2/4] 서버 안전 종료"
if ! ./stop_server.sh; then
  warn "정상 종료 실패 — 강제 종료로 전환합니다."
  ./stop_server.sh --force || die "강제 종료마저 실패했습니다. 수동 확인이 필요합니다."
fi

# Give the port and Wine's resources time to be released.
sleep 5

# ------------------------------------------------------------- 4) Optional update
if [[ "$DO_UPDATE" -eq 1 ]]; then
  log "[3/4] 서버 업데이트"
  ./install_update.sh || warn "업데이트 실패 — 기존 버전으로 기동을 계속합니다."
else
  log "[3/4] 업데이트 건너뜀"
fi

# ------------------------------------------------------------------ 5) Start again
log "[4/4] 서버 재기동"
if ./start_server.sh; then
  log "재기동 성공"
  audit "auto_restart 완료 (성공)"
else
  # A failed start leaves the server down — the worst outcome, so log it loudly.
  warn "재기동 실패! 서버가 내려가 있습니다. 로그를 확인하세요: $SERVER_LOG"
  audit "auto_restart 실패 (재기동 불가)"
  log "===== auto_restart 종료 (실패) ====="
  exit 1
fi

log "===== auto_restart 종료 ====="
