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
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

[[ $# -ge 1 ]] || usage 1

# Restores require a stopped server; writing underneath a running one is pointless.
require_stopped() {
  if is_running; then
    die "서버가 실행 중입니다. ./stop_server.sh 로 먼저 종료하세요."
  fi
}

# Snapshot the current state first, so a wrong restore can still be undone
snapshot_current() {
  if [[ -d "$SAVEGAMES_DIR" ]] && [[ -n "$(ls -A "$SAVEGAMES_DIR" 2>/dev/null)" ]]; then
    local snap="$BACKUP_DIR/prerestore_$(date '+%Y%m%d_%H%M%S').tar.gz"
    mkdir -p "$BACKUP_DIR"
    tar -czf "$snap" -C "$PAL_ROOT" "Pal/Saved" 2>/dev/null || true
    ok "복원 전 현재 상태 스냅샷: $snap"
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
    [[ -n "$latest" ]] || die "복원할 백업이 없습니다: $BACKUP_DIR"
    exec "$0" "$latest"
    ;;

  # --------------------------------------------- Import a foreign Saved folder
  --import)
    SRC="${2:-}"
    [[ -n "$SRC" ]] || die "이식할 Saved 폴더 경로를 지정하세요.\n    예: ./restore_save.sh --import ~/Downloads/Saved"
    [[ -d "$SRC" ]] || die "폴더를 찾을 수 없습니다: $SRC"
    require_stopped

    # Locate SaveGames/0 whether the user points above or below the Saved folder.
    if   [[ -d "$SRC/SaveGames/0" ]];       then SRC_SAVES="$SRC/SaveGames/0"
    elif [[ -d "$SRC/Saved/SaveGames/0" ]]; then SRC_SAVES="$SRC/Saved/SaveGames/0"
    elif [[ -d "$SRC/0" ]];                 then SRC_SAVES="$SRC/0"
    else die "SaveGames/0 을 찾지 못했습니다. Saved 폴더 자체 또는 SaveGames/0 을 지정하세요."
    fi

    info "원본 세이브: $SRC_SAVES"
    ls -1 "$SRC_SAVES" | while read -r w; do printf '    월드 ID: %s\n' "$w"; done

    snapshot_current
    mkdir -p "$SAVEGAMES_DIR" "$CONFIG_DIR"

    # Merge rather than wipe; a matching world ID is overwritten.
    cp -R "$SRC_SAVES"/* "$SAVEGAMES_DIR"/
    ok "세이브 이식 완료 → $SAVEGAMES_DIR"

    # If a settings file came along, mention it but do not apply it automatically —
    # paths and options differ per platform, so a human should check.
    found_ini="$(find "$SRC" -name 'PalWorldSettings.ini' -maxdepth 4 2>/dev/null | head -n1 || true)"
    if [[ -n "$found_ini" ]]; then
      warn "원본에 PalWorldSettings.ini 가 있습니다: $found_ini"
      printf '    적용하려면 직접 복사하세요:\n      cp "%s" "%s"\n' "$found_ini" "$SETTINGS_INI"
    fi

    echo
    warn "중요: 이사 온 월드로 접속하려면 DedicatedServerName 이 일치해야 합니다."
    printf '    %s 의 [/Script/Pal.PalGameWorldSettings] 항목과\n' "$SETTINGS_INI"
    printf '    아래 월드 ID 폴더명이 원본 서버와 같아야 캐릭터가 유지됩니다.\n'
    ls -1 "$SAVEGAMES_DIR" | while read -r w; do printf '      %s\n' "$w"; done
    audit "import 완료 from=$SRC"
    ;;

  -h|--help) usage 0 ;;

  # ----------------------------------------------------- Restore a given backup
  *)
    ARCHIVE="$1"
    [[ -f "$ARCHIVE" ]] || ARCHIVE="$BACKUP_DIR/$1"
    [[ -f "$ARCHIVE" ]] || die "백업 파일을 찾을 수 없습니다: $1"

    tar -tzf "$ARCHIVE" >/dev/null 2>&1 || die "손상된 아카이브입니다: $ARCHIVE"
    require_stopped

    info "복원할 백업: $ARCHIVE"
    info "포함된 항목:"
    tar -tzf "$ARCHIVE" | grep -E 'SaveGames/0/[^/]+/?$|PalWorldSettings\.ini$' \
      | sed 's/^/    /' | head -20

    printf '\n이 내용으로 현재 세이브를 덮어씁니다. 계속할까요? [y/N] '
    read -r answer
    [[ "$answer" =~ ^[Yy]$ ]] || { info "취소했습니다."; exit 0; }

    snapshot_current
    mkdir -p "$PAL_ROOT"
    tar -xzf "$ARCHIVE" -C "$PAL_ROOT" || die "압축 해제 실패"

    ok "복원 완료"
    audit "restore 완료 from=$ARCHIVE"
    info "서버 기동: ./start_server.sh"
    ;;
esac
