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
#     ./uninstall.sh --backups      # the backup archives too — asks for DELETE
#                                   #   (typed at the terminal, before anything
#                                   #    is removed; only this toolkit's own
#                                   #    archives are deleted, not the folder)
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

# Physical path, with symlinks and .. resolved. The overlap checks below compare
# strings, and "$HOME/backups" vs "$HOME/server/../backups" are the same folder
# written two ways — a lexical comparison would call them unrelated and delete
# one while claiming to spare it.
canonical() {
  local p="$1"
  if [[ -d "$p" ]]; then (cd -P "$p" 2>/dev/null && pwd -P) || printf '%s' "$p"
  else printf '%s' "$p"; fi
}

# Does the server folder actually hold a server? A PAL_ROOT left pointing at the
# wrong place (a typo in config.local.sh, an old export still in the shell) turns
# --server into "delete that folder", whatever it happens to be.
looks_like_server_dir() {
  local d="$1" entry
  [[ -d "$d" ]] || return 1
  [[ -d "$d/Pal" || -d "$d/steamapps" || -f "$d/PalServer.exe" ]] && return 0
  # A server that was never installed leaves only what this toolkit created.
  for entry in "$d"/* "$d"/.*; do
    entry="${entry##*/}"
    case "$entry" in
      '*'|'.*'|.|..|logs|run) continue ;;
      *) return 1 ;;
    esac
  done
  return 0
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
[[ $DO_BACKUPS  -eq 1 ]] && printf '  · backup archives in %s  %severy backup you have%s\n' "$BACKUP_DIR" "$_c_red" "$_c_reset"

if [[ $DO_SERVER -eq 1 && $FINAL_BACKUP -eq 1 && -d "$SAVEGAMES_DIR" ]]; then
  printf '\n  A final backup is taken first (skip it with --no-final-backup).\n'
fi

# BACKUP_DIR defaults outside PAL_ROOT, but nothing stops config.local.sh putting
# one inside the other — and then removing one would silently take the other with
# it. Compared on physical paths, and in both directions, since either nesting is
# equally easy to configure and equally destructive.
pal_c="$(canonical "$PAL_ROOT")"
bak_c="$(canonical "$BACKUP_DIR")"
if [[ $((DO_SERVER + DO_BACKUPS)) -eq 1 ]] \
   && { [[ "$bak_c/" == "$pal_c/"* ]] || [[ "$pal_c/" == "$bak_c/"* ]]; }; then
  die "The server folder and the backup folder overlap, so removing one would
    delete the other:
    server:  $pal_c
    backups: $bak_c
    Move one of them, or pass both --server and --backups if you mean to lose both."
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  printf '\nContinue? [y/N] '
  # An empty read (EOF, no terminal) must cancel, not abort part-way through
  # under `set -e`, which would skip the "Cancelled" message entirely.
  read -r answer || answer=""
  [[ "$answer" =~ ^[Yy]$ ]] || { info "Cancelled."; exit 0; }
fi

# The backups question is settled here, before anything is deleted. Asking after
# the server folder was already gone meant a "no" left you with neither the
# server nor the final backup that was skipped on account of this flag.
BACKUPS_CONFIRMED=0
if [[ $DO_BACKUPS -eq 1 ]]; then
  count="$(find "$BACKUP_DIR" \( -name 'palworld_backup_*.tar.gz' -o -name 'prerestore_*.tar.gz' \) 2>/dev/null | grep -c . || true)"
  printf '\n%sThis deletes %s archives in %s and cannot be undone.%s\n' \
         "$_c_red" "${count:-0}" "$BACKUP_DIR" "$_c_reset"
  # Read from the terminal, not stdin. --yes deliberately does not cover this,
  # and neither should a pipe that happens to contain the word.
  if [[ -r /dev/tty ]]; then
    printf 'Type DELETE to confirm: '
    read -r confirm </dev/tty || confirm=""
  else
    confirm=""
    warn "No terminal to confirm on — backups will be kept."
  fi
  [[ "$confirm" == "DELETE" ]] && BACKUPS_CONFIRMED=1 || info "Backups will be kept."
fi

# Held for the whole removal, so a scheduled backup cannot start reading files
# midway through deleting them. Taken *before* the running-server check: the
# other way round left a gap in which start_server.sh could take the lock and
# bring a server up against files about to be deleted.
acquire_lock "uninstall"

# A running server holds the files being deleted, and killing it this way is how
# a save gets damaged. Checked under the lock, so nothing can start after it.
if [[ $DO_SERVER -eq 1 ]] && is_running; then
  die "The server is running. Stop it first: ./stop_server.sh"
fi

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
  # Keyed on the answer actually given, not on the flag: --backups where DELETE
  # was declined means the backups are staying, so the final one is worth taking.
  if [[ $FINAL_BACKUP -eq 1 && -d "$SAVEGAMES_DIR" && $BACKUPS_CONFIRMED -eq 0 ]]; then
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

  if [[ -d "$PAL_ROOT" ]]; then
    looks_like_server_dir "$PAL_ROOT" \
      || die "This does not look like a Palworld server folder, so it was left alone:
    $PAL_ROOT
    Expected Pal/, steamapps/ or PalServer.exe inside it. Check PAL_ROOT in
    config.local.sh — deleting the wrong folder is not something to guess at."
    safe_rm "$PAL_ROOT"; ok "Removed $PAL_ROOT"
  fi

  # Only the prefix this toolkit creates. A custom WINEPREFIX may well be shared
  # with other Wine applications, and --server does not read as "remove those".
  if [[ -d "$WINEPREFIX" ]]; then
    if [[ "$(canonical "$WINEPREFIX")" == "$(canonical "$HOME/.palworld_wine")" ]]; then
      safe_rm "$WINEPREFIX"; ok "Removed $WINEPREFIX"
    else
      info "Left the custom Wine prefix alone: $WINEPREFIX"
      printf '    %sIt may be shared with other apps. Remove it yourself if not.%s\n' \
             "$_c_dim" "$_c_reset"
    fi
  fi
fi

# ------------------------------------------------------------------ SteamCMD
if [[ $DO_STEAMCMD -eq 1 ]]; then
  [[ -d "$STEAMCMD_DIR" ]] && { safe_rm "$STEAMCMD_DIR"; ok "Removed $STEAMCMD_DIR"; }
fi

# ------------------------------------------------------------------ Backups
if [[ $BACKUPS_CONFIRMED -eq 1 ]]; then
  # Only the archives this toolkit writes, never the folder wholesale. BACKUP_DIR
  # is a user setting, and pointing it at somewhere that already holds other
  # files — ~/Documents, say — should cost you your backups, not everything else
  # in there.
  deleted=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    rm -f "$f" && deleted=$((deleted + 1))
  done < <(find "$BACKUP_DIR" -maxdepth 1 \
             \( -name 'palworld_backup_*.tar.gz' -o -name 'prerestore_*.tar.gz' \) 2>/dev/null)
  ok "Deleted ${deleted} backup archives from $BACKUP_DIR"
  # Take the folder as well only if this emptied it.
  rmdir "$BACKUP_DIR" 2>/dev/null && ok "Removed the (now empty) $BACKUP_DIR" \
    || info "Kept $BACKUP_DIR — other files are still in it"
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
