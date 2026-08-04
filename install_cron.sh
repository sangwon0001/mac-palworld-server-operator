#!/usr/bin/env bash
# ==============================================================================
# install_cron.sh - 정기 백업 / 자동 재시작 crontab 등록 도우미
#
#   기본 스케줄:
#     매시 정각        세이브 백업
#     매일 05:00       백업 + 재시작 (메모리 누수 해소)
#     매일 06:00       메모리 8GB 초과 시에만 재시작 (보조 안전망)
#
#   사용법:
#     ./install_cron.sh --show      # 등록될 내용 미리보기
#     ./install_cron.sh --install   # crontab 에 등록
#     ./install_cron.sh --remove    # 등록 해제
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

DIR="$PWD"
MARK_BEGIN="# >>> palworld-server cron >>>"
MARK_END="# <<< palworld-server cron <<<"

# cron 은 PATH 가 최소라 brew 경로를 명시해야 tar/lsof/python3 등을 찾습니다.
CRON_BLOCK="$MARK_BEGIN
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
SHELL=/bin/bash
# 매시 정각 세이브 백업
0 * * * * cd $DIR && ./backup_save.sh >> $LOG_DIR/cron.log 2>&1
# 매일 05:00 백업 후 재시작 (메모리 누수 해소)
0 5 * * * cd $DIR && ./auto_restart.sh >> $LOG_DIR/cron.log 2>&1
# 매일 06:00 메모리 8GB 초과 & 접속자 0명일 때만 재시작
0 6 * * * cd $DIR && ./auto_restart.sh --if-over 8192 --if-empty >> $LOG_DIR/cron.log 2>&1
$MARK_END"

case "${1:-}" in
  --show)
    printf '%s\n' "$CRON_BLOCK"
    ;;

  --install)
    ensure_dirs
    current="$(crontab -l 2>/dev/null || true)"
    # 기존 블록이 있으면 제거 후 재등록 (중복 방지)
    cleaned="$(printf '%s\n' "$current" | sed "/$MARK_BEGIN/,/$MARK_END/d")"
    printf '%s\n%s\n' "$cleaned" "$CRON_BLOCK" | sed '/^$/N;/^\n$/D' | crontab -
    ok "crontab 등록 완료"
    echo
    crontab -l | sed -n "/$MARK_BEGIN/,/$MARK_END/p"
    echo
    warn "macOS 는 cron 이 사용자 파일에 접근하려면 '전체 디스크 접근 권한'이 필요합니다."
    printf '    시스템 설정 → 개인정보 보호 및 보안 → 전체 디스크 접근 권한 → /usr/sbin/cron 추가\n'
    printf '    (Finder 에서 Cmd+Shift+G 로 /usr/sbin 이동 후 cron 을 드래그)\n'
    ;;

  --remove)
    current="$(crontab -l 2>/dev/null || true)"
    if ! printf '%s' "$current" | grep -qF "$MARK_BEGIN"; then
      info "등록된 항목이 없습니다."
      exit 0
    fi
    printf '%s\n' "$current" | sed "/$MARK_BEGIN/,/$MARK_END/d" | crontab -
    ok "crontab 등록 해제 완료"
    ;;

  *)
    die "사용법: ./install_cron.sh --show | --install | --remove"
    ;;
esac
