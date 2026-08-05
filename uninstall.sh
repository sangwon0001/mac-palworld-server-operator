#!/usr/bin/env bash
# ==============================================================================
# uninstall.sh - Take back what this toolkit installed
#
#   With no options it removes nothing: it reports what exists and what each
#   option would delete. Every destructive part is opt-in, because the server
#   folder holds your save games and the backup folder is the only copy of
#   everything before today.
#
#   Usage:
#     ./uninstall.sh                # report only (default)
#     ./uninstall.sh --scheduling   # cron entries and launchd agents
#     ./uninstall.sh --app          # the app in /Applications
#     ./uninstall.sh --server       # server files and the Wine prefix
#     ./uninstall.sh --steamcmd     # SteamCMD (you may use it for other games)
#     ./uninstall.sh --all          # scheduling + app + server + Wine prefix
#     ./uninstall.sh --backups      # the backups too — asks you to type DELETE
#     ./uninstall.sh --all --yes    # skip the confirmation (never for backups)
#
#   --server takes a final backup first, unless you pass --no-final-backup.
#   Homebrew packages (Wine) are never touched; the command is printed instead.
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./config.sh

APP_PATH="${APP_PATH:-/Applications/Palworld Server.app}"
LAUNCHD_LABELS=(local.palworld.backup local.palworld.restart local.palworld.restart-if-over)

DO_SCHED=0; DO_APP=0; DO_SERVER=0; DO_STEAMCMD=0; DO_BACKUPS=0
ASSUME_YES=0; FINAL_BACKUP=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --scheduling) DO_SCHED=1; shift ;;
    --app)        DO_APP=1; shift ;;
    --server)     DO_SERVER=1; shift ;;
    --steamcmd)   DO_STEAMCMD=1; shift ;;
    --backups)    DO_BACKUPS=1; shift ;;
    --all)        DO_SCHED=1; DO_APP=1; DO_SERVER=1; shift ;;
    --yes|-y)     ASSUME_YES=1; shift ;;
    --no-final-backup) FINAL_BACKUP=0; shift ;;
    -h|--help)    sed -n '2,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1 (see --help)" ;;
  esac
done

# Never let a mistyped or empty variable turn into `rm -rf /` or `rm -rf $HOME`.
safe_rm() {
  local target="$1"
  [[ -n "$target" && "$target" != "/" && "$target" != "$HOME" && "$target" == /* ]] \
    || die "Refusing to delete a suspicious path: '$target'"
  rm -rf "$target"
}

size_of() { [[ -e "$1" ]] && du -sh "$1" 2>/dev/null | cut -f1 || printf '-'; }

cron_installed()    { crontab -l 2>/dev/null | grep -qF "palworld-server cron"; }
launchd_installed() { launchctl print "gui/$(id -u)/${LAUNCHD_LABELS[0]}" >/dev/null 2>&1; }

# ------------------------------------------------------------------ Report
printf '\n%sWhat is installed%s\n' "$_c_blu" "$_c_reset"
row() { printf '  %-22s %-10s %s\n' "$1" "$2" "$3"; }

sched_state="none"
cron_installed    && sched_state="cron"
launchd_installed && sched_state="${sched_state/none/}launchd"
row "Scheduling" "$sched_state" "--scheduling"
row "App" "$([[ -d "$APP_PATH" ]] && echo present || echo '-')" "--app  ($APP_PATH)"
row "Server files" "$(size_of "$PAL_ROOT")" "--server  ($PAL_ROOT)"
row "Wine prefix" "$(size_of "$WINEPREFIX")" "--server  ($WINEPREFIX)"
row "SteamCMD" "$(size_of "$STEAMCMD_DIR")" "--steamcmd  ($STEAMCMD_DIR)"
row "Backups" "$(size_of "$BACKUP_DIR")" "--backups  ($BACKUP_DIR)"

if [[ $((DO_SCHED + DO_APP + DO_SERVER + DO_STEAMCMD + DO_BACKUPS)) -eq 0 ]]; then
  printf '\n'
  info "Nothing was removed. Choose what to remove with the options above."
  printf '    %sconfig.local.sh (your RCON password) is never touched by this script.%s\n' \
         "$_c_dim" "$_c_reset"
  exit 0
fi

# ------------------------------------------------------------------ Plan
printf '\n%sAbout to delete%s\n' "$_c_ylw" "$_c_reset"
[[ $DO_SCHED    -eq 1 ]] && printf '  · scheduled jobs (cron entries and launchd agents)\n'
[[ $DO_APP      -eq 1 ]] && printf '  · %s\n' "$APP_PATH"
[[ $DO_SERVER   -eq 1 ]] && printf '  · %s  %s(includes the save games)%s\n' "$PAL_ROOT" "$_c_red" "$_c_reset"
[[ $DO_SERVER   -eq 1 ]] && printf '  · %s\n' "$WINEPREFIX"
[[ $DO_STEAMCMD -eq 1 ]] && printf '  · %s\n' "$STEAMCMD_DIR"
[[ $DO_BACKUPS  -eq 1 ]] && printf '  · %s  %severy backup you have%s\n' "$BACKUP_DIR" "$_c_red" "$_c_reset"

if [[ $DO_SERVER -eq 1 && $FINAL_BACKUP -eq 1 && -d "$SAVEGAMES_DIR" ]]; then
  printf '\n  A final backup is taken first (skip it with --no-final-backup).\n'
fi

# BACKUP_DIR defaults outside PAL_ROOT, but nothing stops config.local.sh putting
# it inside — and then removing the server folder would take every backup with
# it, without --backups ever being mentioned.
if [[ $DO_SERVER -eq 1 && $DO_BACKUPS -eq 0 && "$BACKUP_DIR/" == "$PAL_ROOT/"* ]]; then
  die "Your backups live inside the server folder, so removing it would delete them too:
    backups: $BACKUP_DIR
    server:  $PAL_ROOT
    Move the backups elsewhere first, or say --backups if you mean to lose them."
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  printf '\nContinue? [y/N] '
  # An empty read (EOF, no terminal) must cancel, not abort part-way through
  # under `set -e`, which would skip the "Cancelled" message entirely.
  read -r answer || answer=""
  [[ "$answer" =~ ^[Yy]$ ]] || { info "Cancelled."; exit 0; }
fi

# A running server holds the files being deleted, and killing it this way is how
# a save gets damaged.
if [[ $DO_SERVER -eq 1 ]] && is_running; then
  die "The server is running. Stop it first: ./stop_server.sh"
fi

# Held for the whole removal, so a scheduled backup cannot start reading files
# midway through deleting them.
acquire_lock "uninstall"

# Recorded before anything is deleted, not after: the operations log lives inside
# PAL_ROOT, so writing to it afterwards would recreate the very directory this
# script had just removed.
audit "uninstall (sched=$DO_SCHED app=$DO_APP server=$DO_SERVER steamcmd=$DO_STEAMCMD backups=$DO_BACKUPS)"

# ------------------------------------------------------------------ Scheduling
if [[ $DO_SCHED -eq 1 ]]; then
  if cron_installed; then
    ./install_cron.sh --remove >/dev/null && ok "cron entries removed"
  fi
  removed=0
  for label in "${LAUNCHD_LABELS[@]}"; do
    launchctl bootout "gui/$(id -u)/$label" 2>/dev/null && removed=$((removed + 1)) || true
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
  done
  [[ $removed -gt 0 ]] && ok "launchd agents removed (${removed})"
  [[ $removed -eq 0 ]] && ! cron_installed && info "No scheduled jobs were installed"
fi

# ------------------------------------------------------------------ App
if [[ $DO_APP -eq 1 ]]; then
  if [[ -d "$APP_PATH" ]]; then
    safe_rm "$APP_PATH"; ok "Removed $APP_PATH"
  else
    info "The app was not installed"
  fi
fi

# ------------------------------------------------------------------ Server
if [[ $DO_SERVER -eq 1 ]]; then
  # One last copy of the save before the folder holding it disappears. It lands
  # in BACKUP_DIR, which --backups deletes afterwards if you asked for that too.
  if [[ $FINAL_BACKUP -eq 1 && -d "$SAVEGAMES_DIR" && $DO_BACKUPS -eq 0 ]]; then
    info "Taking a final backup..."
    if ./backup_save.sh --name "before uninstall" --no-prune >/dev/null; then
      ok "Final backup saved in $BACKUP_DIR"
    else
      # Deleting the save anyway would be the one unrecoverable outcome here, and
      # a final backup is what was asked for. Make it a decision, not a warning.
      die "The final backup failed, so the save has NOT been deleted.
    Fix the cause (disk space? permissions?) and try again,
    or pass --no-final-backup if you genuinely do not want the save kept."
    fi
  fi

  [[ -d "$PAL_ROOT"   ]] && { safe_rm "$PAL_ROOT";   ok "Removed $PAL_ROOT"; }
  [[ -d "$WINEPREFIX" ]] && { safe_rm "$WINEPREFIX"; ok "Removed $WINEPREFIX"; }
fi

# ------------------------------------------------------------------ SteamCMD
if [[ $DO_STEAMCMD -eq 1 ]]; then
  [[ -d "$STEAMCMD_DIR" ]] && { safe_rm "$STEAMCMD_DIR"; ok "Removed $STEAMCMD_DIR"; }
fi

# ------------------------------------------------------------------ Backups
if [[ $DO_BACKUPS -eq 1 ]]; then
  # Deliberately not covered by --yes. Backups are the one thing here that cannot
  # be reinstalled, so this always asks, and asks for a word rather than a key.
  count="$(find "$BACKUP_DIR" -name '*.tar.gz' 2>/dev/null | grep -c . || true)"
  printf '\n%sThis deletes %s archives in %s and cannot be undone.%s\n' \
         "$_c_red" "${count:-0}" "$BACKUP_DIR" "$_c_reset"
  printf 'Type DELETE to confirm: '
  read -r confirm || confirm=""
  if [[ "$confirm" == "DELETE" ]]; then
    safe_rm "$BACKUP_DIR"; ok "Removed $BACKUP_DIR"
  else
    info "Backups kept."
  fi
fi

printf '\n'
ok "Done."
if [[ $DO_SERVER -eq 1 ]]; then
  info "Homebrew packages are left alone. To remove Wine as well:"
  printf '    brew uninstall --cask game-porting-toolkit\n'
fi
[[ -f config.local.sh ]] && printf '    %sconfig.local.sh was kept — delete it yourself if you are done.%s\n' \
                                   "$_c_dim" "$_c_reset"
:
