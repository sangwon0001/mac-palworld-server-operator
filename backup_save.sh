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
find_backup() {
  local want="$1" hit
  [[ -f "$want" ]] && { printf '%s' "$want"; return 0; }
  [[ -f "$BACKUP_DIR/$want" ]] && { printf '%s' "$BACKUP_DIR/$want"; return 0; }
  hit="$(ls -1 "$BACKUP_DIR"/${BACKUP_PREFIX}*.tar.gz 2>/dev/null | grep -F "$want" || true)"
  [[ "$(printf '%s\n' "$hit" | grep -c .)" == "1" ]] || return 1
  printf '%s' "$hit"
}

list_backups() {
  info "백업 목록 ($BACKUP_DIR)"
  local found=0 f stamp label size pretty
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    found=1
    stamp="$(backup_stamp "$f")"; label="$(backup_label "$f")"
    size="$(du -h "$f" | cut -f1 | tr -d ' ')"
    # 20260805_113000 → 2026-08-05 11:30
    pretty="${stamp:0:4}-${stamp:4:2}-${stamp:6:2} ${stamp:9:2}:${stamp:11:2}"
    if [[ -n "$label" ]]; then
      printf '  %s  %6s  %s%s%s %s(자동 삭제 안 됨)%s\n' \
        "$pretty" "$size" "$_c_grn" "$label" "$_c_reset" "$_c_dim" "$_c_reset"
    else
      printf '  %s  %6s  %s-%s\n' "$pretty" "$size" "$_c_dim" "$_c_reset"
    fi
  done < <(ls -1t "$BACKUP_DIR"/${BACKUP_PREFIX}*.tar.gz 2>/dev/null || true)
  [[ $found -eq 1 ]] || warn "백업이 없습니다. ./backup_save.sh 로 첫 백업을 만드세요."
}

PRUNE=1
LABEL=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) ensure_dirs; list_backups; exit 0 ;;
    --name|-n)
      [[ $# -ge 2 ]] || die "이름을 지정하세요: --name \"보스전 직전\""
      LABEL="$(sanitize_label "$2")"
      [[ -n "$LABEL" ]] || die "쓸 수 있는 문자가 없는 이름입니다: $2"
      shift 2 ;;
    --rename)
      [[ $# -ge 3 ]] || die "사용법: --rename <대상> \"새이름\"   (이름을 지우려면 \"\")"
      ensure_dirs
      target="$(find_backup "$2")" \
        || die "백업을 찾을 수 없거나 여러 개가 걸립니다: $2
    ./backup_save.sh --list 로 확인한 뒤 더 구체적으로 지정하세요."
      new_label="$(sanitize_label "$3")"
      stamp="$(backup_stamp "$target")"
      if [[ -n "$new_label" ]]; then
        newpath="$BACKUP_DIR/${BACKUP_PREFIX}${stamp}_${new_label}.tar.gz"
      else
        newpath="$BACKUP_DIR/${BACKUP_PREFIX}${stamp}.tar.gz"
      fi
      [[ "$target" == "$newpath" ]] && { info "이미 그 이름입니다."; exit 0; }
      [[ -e "$newpath" ]] && die "같은 이름의 백업이 이미 있습니다: $(basename "$newpath")"
      mv "$target" "$newpath"
      ok "이름 변경: $(basename "$target")"
      printf '           → %s\n' "$(basename "$newpath")"
      [[ -n "$new_label" ]] && note_kept=1 || note_kept=0
      [[ $note_kept -eq 1 ]] && printf '    %s이름이 있으므로 자동 정리 대상에서 제외됩니다%s\n' "$_c_dim" "$_c_reset"
      audit "backup 이름 변경 $(basename "$target") → $(basename "$newpath")"
      exit 0 ;;
    --no-prune) PRUNE=0; shift ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "알 수 없는 옵션: $1 (--name | --list | --rename | --no-prune)" ;;
  esac
done

ensure_dirs

[[ -d "$SAVEGAMES_DIR" ]] || die "세이브 폴더가 없습니다: $SAVEGAMES_DIR
    (서버를 한 번도 기동하지 않았거나 PAL_ROOT 설정이 잘못되었습니다)"

# ------------------------- If the server is running, flush the save to disk first
# Otherwise progress still held in memory would be missing from the backup.
if is_running && [[ -n "$RCON_PASSWORD" ]]; then
  info "서버 실행 중 — RCON 으로 세이브 플러시 요청"
  if rcon_cmd "Save" >/dev/null 2>&1; then
    ok "세이브 플러시 완료"
    sleep 3   # let the write land on disk
  else
    warn "RCON 플러시 실패 — 마지막 자동 세이브 시점 기준으로 백업합니다."
  fi
elif is_running; then
  warn "서버 실행 중이지만 RCON 미설정 — 마지막 자동 세이브 시점 기준으로 백업합니다."
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

info "백업 생성 중..."
info "  대상 월드 ID: ${world_ids:-(없음)}"
tar -czf "$ARCHIVE" -C "$PAL_ROOT" "${TAR_ITEMS[@]}" 2>/dev/null \
  || die "tar 압축 실패. 디스크 공간과 권한을 확인하세요."

# Verify the archive — so nobody relies on a backup that turns out to be corrupt
if ! tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
  rm -f "$ARCHIVE"
  die "생성된 아카이브가 손상되었습니다. 백업을 중단했습니다."
fi

size="$(du -h "$ARCHIVE" | cut -f1)"
ok "백업 완료: $ARCHIVE ($size)"
audit "backup 생성 $ARCHIVE ($size, worlds=${world_ids:-none})"

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
  [[ $deleted -gt 0 ]] && ok "오래된 백업 ${deleted}개 삭제 (${BACKUP_RETENTION_DAYS}일 초과, 최소 ${BACKUP_RETENTION_MIN}개 보존)"
fi

count="$(ls -1 "$BACKUP_DIR"/palworld_backup_*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
info "현재 보관 중인 백업: ${count}개"
