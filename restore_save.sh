#!/usr/bin/env bash
# ==============================================================================
# restore_save.sh - 세이브 복원 / 타 서버 데이터 이사
#
#   두 가지 용도:
#     1) 이 스크립트로 만든 백업(tar.gz) 되돌리기
#     2) 다른 서버(윈도우/리눅스/호스팅)에서 가져온 Saved 폴더 이식
#
#   사용법:
#     ./restore_save.sh --list                  # 복원 가능한 백업 목록
#     ./restore_save.sh --latest                # 가장 최근 백업으로 복원
#     ./restore_save.sh <백업파일.tar.gz>       # 특정 백업으로 복원
#     ./restore_save.sh --import <Saved폴더경로> # 타 서버 Saved 폴더 이식
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

[[ $# -ge 1 ]] || usage 1

# 복원은 반드시 서버가 꺼진 상태에서. 켜진 채로 덮으면 즉시 덮어써집니다.
require_stopped() {
  if is_running; then
    die "서버가 실행 중입니다. ./stop_server.sh 로 먼저 종료하세요."
  fi
}

# 복원 직전 현재 상태를 자동 백업 — 잘못 복원했을 때 되돌아갈 지점
snapshot_current() {
  if [[ -d "$SAVEGAMES_DIR" ]] && [[ -n "$(ls -A "$SAVEGAMES_DIR" 2>/dev/null)" ]]; then
    local snap="$BACKUP_DIR/prerestore_$(date '+%Y%m%d_%H%M%S').tar.gz"
    mkdir -p "$BACKUP_DIR"
    tar -czf "$snap" -C "$PAL_ROOT" "Pal/Saved" 2>/dev/null || true
    ok "복원 전 현재 상태 스냅샷: $snap"
  fi
}

case "$1" in

  # ---------------------------------------------------------------- 목록 보기
  --list)
    exec ./backup_save.sh --list
    ;;

  # ------------------------------------------------------- 최근 백업으로 복원
  --latest)
    latest="$(ls -1t "$BACKUP_DIR"/palworld_backup_*.tar.gz 2>/dev/null | head -n1 || true)"
    [[ -n "$latest" ]] || die "복원할 백업이 없습니다: $BACKUP_DIR"
    exec "$0" "$latest"
    ;;

  # --------------------------------------------- 타 서버 Saved 폴더 이식(이사)
  --import)
    SRC="${2:-}"
    [[ -n "$SRC" ]] || die "이식할 Saved 폴더 경로를 지정하세요.\n    예: ./restore_save.sh --import ~/Downloads/Saved"
    [[ -d "$SRC" ]] || die "폴더를 찾을 수 없습니다: $SRC"
    require_stopped

    # 사용자가 Saved 상위/하위 어디를 주든 SaveGames/0 을 찾아냅니다.
    if   [[ -d "$SRC/SaveGames/0" ]];       then SRC_SAVES="$SRC/SaveGames/0"
    elif [[ -d "$SRC/Saved/SaveGames/0" ]]; then SRC_SAVES="$SRC/Saved/SaveGames/0"
    elif [[ -d "$SRC/0" ]];                 then SRC_SAVES="$SRC/0"
    else die "SaveGames/0 을 찾지 못했습니다. Saved 폴더 자체 또는 SaveGames/0 을 지정하세요."
    fi

    info "원본 세이브: $SRC_SAVES"
    ls -1 "$SRC_SAVES" | while read -r w; do printf '    월드 ID: %s\n' "$w"; done

    snapshot_current
    mkdir -p "$SAVEGAMES_DIR" "$CONFIG_DIR"

    # 기존 월드는 지우지 않고 병합합니다. 같은 월드 ID 면 덮어씁니다.
    cp -R "$SRC_SAVES"/* "$SAVEGAMES_DIR"/
    ok "세이브 이식 완료 → $SAVEGAMES_DIR"

    # 설정 파일도 같이 왔다면 안내만 하고 자동 적용하지 않습니다.
    # (플랫폼별 경로/옵션 차이가 있어 사람이 확인하는 편이 안전합니다)
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

  # ----------------------------------------------------- 특정 백업으로 복원
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
