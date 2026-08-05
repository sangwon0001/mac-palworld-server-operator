#!/usr/bin/env bash
# ==============================================================================
# install_cron.sh - Helper for scheduling backups and automatic restarts
#
#   Default schedule:
#     hourly       back up the save
#     daily 05:00  back up and restart (clears the memory leak)
#     daily 06:00  restart only if memory exceeds 8 GB (secondary safety net)
#
#   Usage:
#     ./install_cron.sh --show      # preview what would be installed
#     ./install_cron.sh --install   # write it into crontab
#     ./install_cron.sh --remove    # take it back out
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

DIR="$PWD"
MARK_BEGIN="# >>> palworld-server cron >>>"
MARK_END="# <<< palworld-server cron <<<"

# cron runs with a minimal PATH, so brew's bin must be spelled out for tar/lsof/python3.
CRON_BLOCK="$MARK_BEGIN
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
SHELL=/bin/bash
# Hourly save backup
0 * * * * cd $DIR && ./backup_save.sh >> $LOG_DIR/cron.log 2>&1
# Daily 05:00 backup and restart (clears the memory leak)
0 5 * * * cd $DIR && ./auto_restart.sh >> $LOG_DIR/cron.log 2>&1
# Daily 06:00 restart only if memory exceeds 8 GB and nobody is connected
0 6 * * * cd $DIR && ./auto_restart.sh --if-over 8192 --if-empty >> $LOG_DIR/cron.log 2>&1
$MARK_END"

case "${1:-}" in
  --show)
    printf '%s\n' "$CRON_BLOCK"
    ;;

  --install)
    ensure_dirs
    current="$(crontab -l 2>/dev/null || true)"
    # Remove any existing block before re-adding, to avoid duplicates
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
