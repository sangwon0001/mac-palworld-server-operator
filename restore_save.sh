#!/usr/bin/env bash
# ==============================================================================
# restore_save.sh - Restore a save, or migrate one in from another server
#
#   Two jobs:
#     1) Roll back to a backup (tar.gz) made by this toolkit
#     2) Import a Saved folder taken from another server (Windows/Linux/hosted)
#
#   Usage:
#     ./restore_save.sh --list                  # list restorable backups
#     ./restore_save.sh --latest                # restore the most recent backup
#     ./restore_save.sh <backup.tar.gz>         # restore a specific backup
#     ./restore_save.sh --import <path/to/Saved>  # import a foreign Saved folder
#     ./restore_save.sh --yes <backup.tar.gz>   # skip the confirmation prompt
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

usage() { sed -n '2,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

# --yes is pulled out before the mode is decided, so it can be given on either
# side of the filename. The app passes it instead of piping "y" into the prompt —
# that coupled the GUI to the exact wording of a shell read.
ASSUME_YES=0
ARGS=()
for a in "$@"; do
  case "$a" in
    --yes|-y) ASSUME_YES=1 ;;
    *)        ARGS+=("$a") ;;
  esac
done
set -- "${ARGS[@]+"${ARGS[@]}"}"

[[ $# -ge 1 ]] || usage 1

# Restores require a stopped server; writing underneath a running one is pointless.
#
# Checked twice on purpose: once early for immediate feedback, and again after the
# lock is held. Between the first check and the extraction there is a prompt to
# answer, and someone could start the server in that gap — the second check
# happens under the lock, where no start can slip in behind it.
require_stopped() {
  if is_running; then
    die "The server is running. Stop it first with ./stop_server.sh"
  fi
}

# Snapshot the current state first, so a wrong restore can still be undone
snapshot_current() {
  if [[ -d "$SAVEGAMES_DIR" ]] && [[ -n "$(ls -A "$SAVEGAMES_DIR" 2>/dev/null)" ]]; then
    local snap saved_mb
    snap="$BACKUP_DIR/prerestore_$(date '+%Y%m%d_%H%M%S').tar.gz"
    mkdir -p "$BACKUP_DIR"
    # This snapshot is the only way back from a wrong restore, so refuse rather
    # than write a truncated one.
    saved_mb="$(du -sm "$SAVED_DIR" 2>/dev/null | cut -f1)"
    [[ "$saved_mb" =~ ^[0-9]+$ ]] || saved_mb=0
    require_free_mb "$BACKUP_DIR" $((saved_mb + 100)) "the pre-restore snapshot"
    tar -czf "$snap" -C "$PAL_ROOT" "Pal/Saved" 2>/dev/null || true
    ok "Snapshot of the current state: $snap"
  fi
}

case "$1" in

  # ---------------------------------------------------------------- List
  --list)
    exec ./backup_save.sh --list
    ;;

  # ------------------------------------------------- Restore the latest backup
  --latest)
    latest="$(ls -1t "$BACKUP_DIR"/palworld_backup_*.tar.gz 2>/dev/null | head -n1 || true)"
    [[ -n "$latest" ]] || die "No backups to restore from: $BACKUP_DIR"
    [[ $ASSUME_YES -eq 1 ]] && exec "$0" --yes "$latest"
    exec "$0" "$latest"
    ;;

  # --------------------------------------------- Import a foreign Saved folder
  --import)
    SRC="${2:-}"
    [[ -n "$SRC" ]] || die "Give the path to the Saved folder to import.\n    e.g. ./restore_save.sh --import ~/Downloads/Saved"
    [[ -d "$SRC" ]] || die "Folder not found: $SRC"
    require_stopped

    # Locate SaveGames/0 whether the user points above or below the Saved folder.
    if   [[ -d "$SRC/SaveGames/0" ]];       then SRC_SAVES="$SRC/SaveGames/0"
    elif [[ -d "$SRC/Saved/SaveGames/0" ]]; then SRC_SAVES="$SRC/Saved/SaveGames/0"
    elif [[ -d "$SRC/0" ]];                 then SRC_SAVES="$SRC/0"
    else die "Could not find SaveGames/0. Point at the Saved folder itself, or at SaveGames/0."
    fi

    info "Source saves: $SRC_SAVES"
    ls -1 "$SRC_SAVES" | while read -r w; do printf '    World ID: %s\n' "$w"; done

    acquire_lock "import"
    require_stopped          # re-check: nothing can start while the lock is held
    snapshot_current
    mkdir -p "$SAVEGAMES_DIR" "$CONFIG_DIR"

    # Merge rather than wipe; a matching world ID is overwritten.
    cp -R "$SRC_SAVES"/* "$SAVEGAMES_DIR"/
    ok "Imported into $SAVEGAMES_DIR"

    # If a settings file came along, mention it but do not apply it automatically —
    # paths and options differ per platform, so a human should check.
    found_ini="$(find "$SRC" -name 'PalWorldSettings.ini' -maxdepth 4 2>/dev/null | head -n1 || true)"
    if [[ -n "$found_ini" ]]; then
      warn "The source also contains PalWorldSettings.ini: $found_ini"
      printf '    Copy it yourself to apply it:\n      cp "%s" "%s"\n' "$found_ini" "$SETTINGS_INI"
    fi

    echo
    warn "Important: DedicatedServerName must match for players to reach the imported world."
    printf '    In %s, under [/Script/Pal.PalGameWorldSettings],\n' "$SETTINGS_INI"
    printf '    the world ID folder below must match the original server to keep characters.\n'
    ls -1 "$SAVEGAMES_DIR" | while read -r w; do printf '      %s\n' "$w"; done
    audit "import done from=$SRC"
    ;;

  -h|--help) usage 0 ;;

  # ----------------------------------------------------- Restore a given backup
  *)
    ARCHIVE="$1"
    [[ -f "$ARCHIVE" ]] || ARCHIVE="$BACKUP_DIR/$1"
    [[ -f "$ARCHIVE" ]] || die "Backup file not found: $1"

    tar -tzf "$ARCHIVE" >/dev/null 2>&1 || die "Corrupt archive: $ARCHIVE"
    require_stopped

    info "Restoring from: $ARCHIVE"
    info "Contents:"
    tar -tzf "$ARCHIVE" | grep -E 'SaveGames/0/[^/]+/?$|PalWorldSettings\.ini$' \
      | sed 's/^/    /' | head -20

    if [[ $ASSUME_YES -eq 0 ]]; then
      printf '\nThis overwrites the current save. Continue? [y/N] '
      # Reading nothing (EOF, no terminal) means cancel. Without the fallback,
      # `set -e` would abort here and never print why.
      read -r answer || answer=""
      [[ "$answer" =~ ^[Yy]$ ]] || { info "Cancelled."; exit 0; }
    fi

    acquire_lock "restore"
    require_stopped          # re-check: nothing can start while the lock is held
    snapshot_current
    mkdir -p "$PAL_ROOT"
    tar -xzf "$ARCHIVE" -C "$PAL_ROOT" || die "Extraction failed"

    ok "Restored"
    audit "restore done from=$ARCHIVE"
    info "Start the server: ./start_server.sh"
    ;;
esac
