#!/usr/bin/env bash
# ==============================================================================
# backup_save.sh - 세이브 데이터 + 설정 백업
#   대상: Pal/Saved/SaveGames/0/  및  PalWorldSettings.ini
#   결과: ~/palworld_backups/palworld_backup_YYYYMMDD_HHMMSS.tar.gz
#
#   사용법:
#     ./backup_save.sh              # 백업 (서버 실행 중이면 RCON Save 선행)
#     ./backup_save.sh --list       # 백업 목록 보기
#     ./backup_save.sh --no-prune   # 오래된 백업 정리 건너뛰기
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

PRUNE=1
case "${1:-}" in
  --list)
    info "백업 목록 ($BACKUP_DIR)"
    listing="$(ls -lht "$BACKUP_DIR"/palworld_backup_*.tar.gz 2>/dev/null || true)"
    if [[ -z "$listing" ]]; then
      warn "백업이 없습니다. ./backup_save.sh 로 첫 백업을 만드세요."
    else
      printf '%s\n' "$listing" | awk '{printf "  %-8s %s %s %s  %s\n", $5, $6, $7, $8, $9}'
    fi
    exit 0 ;;
  --no-prune) PRUNE=0 ;;
  "") ;;
  *) die "알 수 없는 옵션: $1 (--list | --no-prune)" ;;
esac

ensure_dirs

[[ -d "$SAVEGAMES_DIR" ]] || die "세이브 폴더가 없습니다: $SAVEGAMES_DIR
    (서버를 한 번도 기동하지 않았거나 PAL_ROOT 설정이 잘못되었습니다)"

# --------------------------------- 실행 중이면 먼저 세이브를 디스크로 플러시
# 메모리에만 있는 진행분을 백업에서 놓치지 않기 위함입니다.
if is_running && [[ -n "$RCON_PASSWORD" ]]; then
  info "서버 실행 중 — RCON 으로 세이브 플러시 요청"
  if rcon_cmd "Save" >/dev/null 2>&1; then
    ok "세이브 플러시 완료"
    sleep 3   # 디스크 기록 완료 대기
  else
    warn "RCON 플러시 실패 — 마지막 자동 세이브 시점 기준으로 백업합니다."
  fi
elif is_running; then
  warn "서버 실행 중이지만 RCON 미설정 — 마지막 자동 세이브 시점 기준으로 백업합니다."
fi

# ------------------------------------------------------------------ 백업 생성
TS="$(date '+%Y%m%d_%H%M%S')"
ARCHIVE="$BACKUP_DIR/palworld_backup_${TS}.tar.gz"

# tar 안에서의 경로를 PAL_ROOT 기준 상대 경로로 유지 → 복원 시 그대로 풀면 됨
declare -a TAR_ITEMS=()
TAR_ITEMS+=("Pal/Saved/SaveGames/0")
[[ -f "$SETTINGS_INI" ]] && TAR_ITEMS+=("Pal/Saved/Config/WindowsServer/PalWorldSettings.ini")

# 어떤 월드가 담겼는지 로그에 남겨 복원 시 식별을 돕습니다.
world_ids="$(ls -1 "$SAVEGAMES_DIR" 2>/dev/null | tr '\n' ' ')"

info "백업 생성 중..."
info "  대상 월드 ID: ${world_ids:-(없음)}"
tar -czf "$ARCHIVE" -C "$PAL_ROOT" "${TAR_ITEMS[@]}" 2>/dev/null \
  || die "tar 압축 실패. 디스크 공간과 권한을 확인하세요."

# 압축 파일 무결성 검증 — 깨진 백업을 믿고 있다가 당하는 사고 방지
if ! tar -tzf "$ARCHIVE" >/dev/null 2>&1; then
  rm -f "$ARCHIVE"
  die "생성된 아카이브가 손상되었습니다. 백업을 중단했습니다."
fi

size="$(du -h "$ARCHIVE" | cut -f1)"
ok "백업 완료: $ARCHIVE ($size)"
audit "backup 생성 $ARCHIVE ($size, worlds=${world_ids:-none})"

# ------------------------------------------------------------- 오래된 백업 정리
if [[ $PRUNE -eq 1 ]]; then
  # 최신 BACKUP_RETENTION_MIN 개는 무조건 보존하고,
  # 그 밖에서 BACKUP_RETENTION_DAYS 일보다 오래된 것만 삭제합니다.
  # (bash 3.2 호환을 위해 mapfile 대신 파이프라인 사용 — cron 은 /bin/bash 3.2)
  deleted=0
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ -n "$(find "$f" -mtime +"$BACKUP_RETENTION_DAYS" 2>/dev/null)" ]]; then
      rm -f "$f" && deleted=$((deleted + 1))
    fi
  done < <(ls -1t "$BACKUP_DIR"/palworld_backup_*.tar.gz 2>/dev/null | tail -n +$((BACKUP_RETENTION_MIN + 1)))
  [[ $deleted -gt 0 ]] && ok "오래된 백업 ${deleted}개 삭제 (${BACKUP_RETENTION_DAYS}일 초과, 최소 ${BACKUP_RETENTION_MIN}개 보존)"
fi

count="$(ls -1 "$BACKUP_DIR"/palworld_backup_*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
info "현재 보관 중인 백업: ${count}개"
