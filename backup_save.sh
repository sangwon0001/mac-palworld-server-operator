#!/usr/bin/env bash
# ==============================================================================
# backup_save.sh - Back up save data and settings
#   Covers: Pal/Saved/SaveGames/0/ and PalWorldSettings.ini
#   Output: ~/palworld_backups/palworld_backup_YYYYMMDD_HHMMSS.tar.gz
#           with a name: palworld_backup_YYYYMMDD_HHMMSS_<name>.tar.gz
#
#   [Design note] The name goes *after* the timestamp so the existing glob
#   (palworld_backup_*.tar.gz) and the fixed-width 15-character date parsing keep
#   working untouched. Named backups are also exempt from automatic cleanup —
#   naming one means you want to keep it.
#
#   Usage:
#     ./backup_save.sh                        # back up (RCON Save first if running)
#     ./backup_save.sh --name "before boss"   # named backup (never auto-deleted)
#     ./backup_save.sh --list                 # list backups
#     ./backup_save.sh --rename <target> "new name"   # rename ("" clears the name)
#     ./backup_save.sh --no-prune             # skip cleanup of old backups
#
#   <target> is a full filename or part of the timestamp (e.g. 20260805_1130).
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

BACKUP_PREFIX="palworld_backup_"

# Sanitize a name so it is safe inside a filename: spaces become underscores, and
# characters that break paths or globs are replaced. Non-ASCII text is preserved.
#
# Length limiting with `cut -c` counts *bytes*, which slices multi-byte characters
# in half and puts a broken byte sequence in the filename. python3 handles this by
# character instead (this toolkit already requires python3).
sanitize_label() {
  LABEL_RAW="$1" python3 -c '
import os, re, sys, unicodedata
s = os.environ["LABEL_RAW"]
s = unicodedata.normalize("NFC", s)
s = "".join(ch for ch in s if ord(ch) >= 32)      # strip control characters
s = re.sub(r"[/\\\\:*?\"<>|]", "_", s)              # characters unsafe in paths/globs
s = re.sub(r"\s+", "_", s).strip("._-")            # spaces to underscores, trim the ends
sys.stdout.write(s[:40])                           # 40 characters, not bytes
'
}

# Split a backup filename into its fixed-width 15-character timestamp and its name.
#   palworld_backup_20260805_113000_boss.tar.gz → "20260805_113000" "boss"
backup_label() {
  local base="${1##*/}"
  base="${base#$BACKUP_PREFIX}"; base="${base%.tar.gz}"
  local rest="${base:15}"          # everything after the timestamp
  printf '%s' "${rest#_}"
}
backup_stamp() {
  local base="${1##*/}"
  base="${base#$BACKUP_PREFIX}"
  printf '%s' "${base:0:15}"
}

# Find exactly one backup, given a full filename or part of the timestamp.
# Matching walks the glob and compares basenames rather than piping ls into grep:
# a name is arbitrary user text, and matching against the full path would also
# hit anything that happened to appear in BACKUP_DIR itself.
find_backup() {
  local want="$1" hit="" f count=0
  [[ -f "$want" ]] && { printf '%s' "$want"; return 0; }
  [[ -f "$BACKUP_DIR/$want" ]] && { printf '%s' "$BACKUP_DIR/$want"; return 0; }
  for f in "$BACKUP_DIR/${BACKUP_PREFIX}"*.tar.gz; do
    [[ -f "$f" ]] || continue                      # unmatched glob stays literal
    case "${f##*/}" in
      *"$want"*) hit="$f"; count=$((count + 1)) ;;
    esac
  done
  [[ $count -eq 1 ]] || return 1                   # ambiguous or nothing found
  printf '%s' "$hit"
}

list_backups() {
  info "Backups in $BACKUP_DIR"
  local found=0 f stamp label size pretty
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    found=1
    stamp="$(backup_stamp "$f")"; label="$(backup_label "$f")"
    size="$(du -h "$f" | cut -f1 | tr -d ' ')"
    # 20260805_113000 → 2026-08-05 11:30
    pretty="${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}"
    if [[ -n "$label" ]]; then
      printf '  %s  %6s  %s%s%s %s(kept)%s\n' \
        "$pretty" "$size" "$_c_grn" "$label" "$_c_reset" "$_c_dim" "$_c_reset"
    else
      printf '  %s  %6s  %s-%s\n' "$pretty" "$size" "$_c_dim" "$_c_reset"
    fi
  done < <(ls -1t "$BACKUP_DIR"/${BACKUP_PREFIX}*.tar.gz 2>/dev/null || true)
  [[ $found -eq 1 ]] || warn "No backups yet. Run ./backup_save.sh to create one."
}

PRUNE=1
LABEL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) ensure_dirs; list_backups; exit 0 ;;
    --name|-n)
      [[ $# -ge 2 ]] || die "Give a name: --name \"before boss\""
      LABEL="$(sanitize_label "$2")"
      [[ -n "$LABEL" ]] || die "That name has no usable characters: $2"
      shift 2 ;;
    --rename)
      [[ $# -ge 3 ]] || die "Usage: --rename <target> \"new name\"   (empty string clears the name)"
      ensure_dirs
      target="$(find_backup "$2")" \
        || die "No single backup matches: $2
    Check ./backup_save.sh --list and be more specific."
      new_label="$(sanitize_label "$3")"
      stamp="$(backup_stamp "$target")"
      if [[ -n "$new_label" ]]; then
        newpath="$BACKUP_DIR/${BACKUP_PREFIX}${stamp}_${new_label}.tar.gz"
      else
        newpath="$BACKUP_DIR/${BACKUP_PREFIX}${stamp}.tar.gz"
      fi
      [[ "$target" == "$newpath" ]] && { info "It already has that name."; exit 0; }
      [[ -e "$newpath" ]] && die "A backup with that name already exists: $(basename "$newpath")"
      mv "$target" "$newpath"
      ok "Renamed: $(basename "$target")"
      printf '           → %s\n' "$(basename "$newpath")"
      [[ -n "$new_label" ]] && note_kept=1 || note_kept=0
      [[ $note_kept -eq 1 ]] && printf '    %sNamed backups are excluded from automatic cleanup%s\n' "$_c_dim" "$_c_reset"
      audit "backup renamed $(basename "$target") -> $(basename "$newpath")"
      exit 0 ;;
    --no-prune) PRUNE=0; shift ;;
    -h|--help) sed -n '2,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "Unknown option: $1 (--name | --list | --rename | --no-prune)" ;;
  esac
done

ensure_dirs
# Taken before the RCON flush: a restart that stops the server mid-archive would
# otherwise produce a backup of a half-written save.
acquire_lock "backup"

[[ -d "$SAVEGAMES_DIR" ]] || die "Save folder not found: $SAVEGAMES_DIR
    (the server has never started, or PAL_ROOT is wrong)"

# ------------------------- If the server is running, flush the save to disk first
# Otherwise progress still held in memory would be missing from the backup.
if is_running && [[ -n "$RCON_PASSWORD" ]]; then
  info "Server is running — asking it to flush the save over RCON"
  if rcon_cmd "Save" >/dev/null 2>&1; then
    ok "Save flushed"
    sleep 3   # let the write land on disk
  else
    warn "RCON flush failed — backing up as of the last autosave."
  fi
elif is_running; then
  warn "Server is running but RCON is not configured — backing up as of the last autosave."
fi

# ------------------------------------------------------------------ Create archive
TS="$(date '+%Y%m%d_%H%M%S')"
if [[ -n "$LABEL" ]]; then
  ARCHIVE="$BACKUP_DIR/${BACKUP_PREFIX}${TS}_${LABEL}.tar.gz"
else
  ARCHIVE="$BACKUP_DIR/${BACKUP_PREFIX}${TS}.tar.gz"
fi

# Store paths relative to PAL_ROOT so restoring is a plain extract
declare -a TAR_ITEMS=()
TAR_ITEMS+=("Pal/Saved/SaveGames/0")
[[ -f "$SETTINGS_INI" ]] && TAR_ITEMS+=("Pal/Saved/Config/WindowsServer/PalWorldSettings.ini")

# Record which worlds went in, to help identify the archive when restoring.
world_ids="$(ls -1 "$SAVEGAMES_DIR" 2>/dev/null | tr '\n' ' ')"

# The archive compresses, so the uncompressed size plus a little headroom is a
# generous bar — but a full disk mid-tar leaves a corrupt archive, and a backup
# you cannot trust is worse than an error message.
save_mb="$(du -sm "$SAVEGAMES_DIR" 2>/dev/null | cut -f1)"
[[ "$save_mb" =~ ^[0-9]+$ ]] || save_mb=0
require_free_mb "$BACKUP_DIR" $((save_mb + 100)) "a backup of the ${save_mb}MB save"

info "Creating backup..."
info "  World IDs: ${world_ids:-(none)}"
tar -czf "$ARCHIVE" -C "$PAL_ROOT" "${TAR_ITEMS[@]}" 2>/dev/null \
  || die "tar failed. Check disk space and permissions."

# Verify the archive — so nobody relies on a backup that turns out to be corrupt
if ! tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
  rm -f "$ARCHIVE"
  die "The archive came out corrupt. Backup aborted."
fi

size="$(du -h "$ARCHIVE" | cut -f1)"
ok "Backed up: $ARCHIVE ($size)"
audit "backup created $ARCHIVE ($size, worlds=${world_ids:-none})"

# ------------------------------------------------------------- Prune old backups
if [[ $PRUNE -eq 1 ]]; then
  # Always keep the newest BACKUP_RETENTION_MIN archives; beyond those, delete only
  # ones older than BACKUP_RETENTION_DAYS.
  # (Pipeline instead of mapfile for bash 3.2 compatibility — cron runs /bin/bash 3.2)
  # Skip named backups: naming one means keeping it, so the retention period
  # does not apply.
  deleted=0; kept_named=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ -n "$(backup_label "$f")" ]]; then
      kept_named=$((kept_named + 1)); continue
    fi
    if [[ -n "$(find "$f" -mtime +"$BACKUP_RETENTION_DAYS" 2>/dev/null)" ]]; then
      rm -f "$f" && deleted=$((deleted + 1))
    fi
  done < <(ls -1t "$BACKUP_DIR"/${BACKUP_PREFIX}*.tar.gz 2>/dev/null | tail -n +$((BACKUP_RETENTION_MIN + 1)))
  [[ $deleted -gt 0 ]] && ok "Deleted ${deleted} old backups (older than ${BACKUP_RETENTION_DAYS}d, newest ${BACKUP_RETENTION_MIN} always kept)"
  [[ $kept_named -gt 0 ]] && info "Kept ${kept_named} named backups regardless of age"

  # --- Everything else that grows without limit ------------------------------
  # These are not palworld_backup_* files, so the loop above never saw them, and
  # nothing else ever deleted them. On a server that has run for months they are
  # the largest thing in the folder after the backups themselves.

  # restore_save.sh snapshots the current save before every restore. Useful for
  # undoing a wrong restore, worthless a fortnight later — same retention as a
  # backup, but with a smaller floor since they are whole-Saved archives.
  pre_deleted=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ -n "$(find "$f" -mtime +"$BACKUP_RETENTION_DAYS" 2>/dev/null)" ]]; then
      rm -f "$f" && pre_deleted=$((pre_deleted + 1))
    fi
  done < <(ls -1t "$BACKUP_DIR"/prerestore_*.tar.gz 2>/dev/null | tail -n +$((PRERESTORE_RETENTION_MIN + 1)))
  [[ $pre_deleted -gt 0 ]] && ok "Deleted ${pre_deleted} old pre-restore snapshots"

  # settings.sh copies the ini aside on every single write, so editing settings a
  # few dozen times leaves a few dozen files next to the live config. They are
  # small, so cap the count rather than the age.
  # Ordered by the timestamp in the name, not by mtime: settings.sh copies with
  # shutil.copy2, which preserves the *source* file's mtime, so a backup made
  # today can carry a date from whenever the ini was last written. The names sort
  # chronologically on their own (bak_YYYYMMDD_HHMMSS).
  ini_deleted=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    rm -f "$f" && ini_deleted=$((ini_deleted + 1))
  done < <(ls -1 "$SETTINGS_INI".bak_* 2>/dev/null | sort -r | tail -n +$((INI_BACKUP_KEEP + 1)))
  [[ $ini_deleted -gt 0 ]] && ok "Deleted ${ini_deleted} old settings backups (newest ${INI_BACKUP_KEEP} kept)"

  # cron writes here with >> and nothing rotates it.
  trim_log "$LOG_DIR/cron.log"
fi

count="$(ls -1 "$BACKUP_DIR"/palworld_backup_*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
info "Backups on hand: ${count}"
