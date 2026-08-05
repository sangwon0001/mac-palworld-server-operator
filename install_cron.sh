#!/usr/bin/env bash
# ==============================================================================
# install_cron.sh - Helper for scheduling backups and automatic restarts
#
#   Default schedule:
#     hourly :30   back up the save
#     daily 05:00  back up and restart (clears the memory leak)
#     daily 06:00  restart only if memory exceeds 8 GB (secondary safety net)
#
#   [Why :30] auto_restart.sh runs a backup of its own before stopping the
#   server. An hourly backup on the hour would collide with both daily jobs —
#   two archives of the same save at once, one of them being written while the
#   server shuts down. Half past the hour keeps them apart. (The run lock in
#   config.sh is the backstop if they ever do overlap.)
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
# Hourly save backup (:30 — deliberately off the hour; see the header)
30 * * * * cd $DIR && ./backup_save.sh >> $LOG_DIR/cron.log 2>&1
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
    ok "crontab entries installed"
    echo
    crontab -l | sed -n "/$MARK_BEGIN/,/$MARK_END/p"
    echo
    warn "On macOS, cron needs Full Disk Access to reach your home directory."
    printf '    System Settings > Privacy & Security > Full Disk Access > add /usr/sbin/cron\n'
    printf '    (In Finder press Cmd+Shift+G, go to /usr/sbin, then drag cron in)\n'
    ;;

  --remove)
    current="$(crontab -l 2>/dev/null || true)"
    if ! printf '%s' "$current" | grep -qF "$MARK_BEGIN"; then
      info "Nothing is installed."
      exit 0
    fi
    printf '%s\n' "$current" | sed "/$MARK_BEGIN/,/$MARK_END/d" | crontab -
    ok "crontab entries removed"
    ;;

  *)
    die "Usage: ./install_cron.sh --show | --install | --remove"
    ;;
esac
