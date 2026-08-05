#!/usr/bin/env bash
# ==============================================================================
# backup_save.sh - 세이브 데이터 + 설정 백업
#   대상: Pal/Saved/SaveGames/0/  및  PalWorldSettings.ini
#   결과: ~/palworld_backups/palworld_backup_YYYYMMDD_HHMMSS.tar.gz
#         이름을 주면  palworld_backup_YYYYMMDD_HHMMSS_<이름>.tar.gz
#
#   [설계 메모] 이름은 타임스탬프 '뒤'에 붙입니다. 그래야 기존 glob
#   (palworld_backup_*.tar.gz)과 날짜 파싱(앞 15자 고정폭)이 그대로 통합니다.
#   또 이름을 붙인 백업은 자동 정리에서 제외합니다 — 이름을 지었다는 건
#   남겨 두고 싶다는 뜻이기 때문입니다.
#
#   사용법:
#     ./backup_save.sh                      # 백업 (실행 중이면 RCON Save 선행)
#     ./backup_save.sh --name "보스전 직전"   # 이름을 붙여 백업 (자동 삭제 안 됨)
#     ./backup_save.sh --list               # 백업 목록 보기
#     ./backup_save.sh --rename <대상> "새이름"  # 이름 바꾸기 (지우려면 "")
#     ./backup_save.sh --no-prune           # 오래된 백업 정리 건너뛰기
#
#   <대상> 은 파일명 전체, 또는 타임스탬프 일부(예: 20260805_1130)로 지정합니다.
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

BACKUP_PREFIX="palworld_backup_"

# 파일명에 넣어도 안전하도록 이름을 다듬습니다.
# 공백은 밑줄로, 경로/글로브를 깨뜨리는 문자는 밑줄로 바꿉니다. 한글은 유지합니다.
#
# 길이 제한을 cut -c 로 하면 '바이트' 기준이라 한글이 중간에서 잘려
# 깨진 바이트열이 파일명에 들어갑니다. 그래서 문자 단위로 다루는 python3 를 씁니다
# (이 도구 모음은 이미 python3 를 필수로 요구합니다).
sanitize_label() {
  LABEL_RAW="$1" python3 -c '
import os, re, sys, unicodedata
s = os.environ["LABEL_RAW"]
s = unicodedata.normalize("NFC", s)
s = "".join(ch for ch in s if ord(ch) >= 32)      # 제어문자 제거
s = re.sub(r"[/\\\\:*?\"<>|]", "_", s)              # 경로·글로브 위험 문자
s = re.sub(r"\s+", "_", s).strip("._-")            # 공백 → 밑줄, 양끝 정리
sys.stdout.write(s[:40])                           # 문자 40자 (바이트 아님)
'
}

# 백업 파일명에서 타임스탬프(고정폭 15자)와 이름을 분리합니다.
#   palworld_backup_20260805_113000_보스전.tar.gz → "20260805_113000" "보스전"
backup_label() {
  local base="${1##*/}"
  base="${base#$BACKUP_PREFIX}"; base="${base%.tar.gz}"
  local rest="${base:15}"          # 타임스탬프 이후
  printf '%s' "${rest#_}"
}
backup_stamp() {
  local base="${1##*/}"
  base="${base#$BACKUP_PREFIX}"
  printf '%s' "${base:0:15}"
}

# 대상 백업 하나를 찾습니다. 파일명 전체 또는 타임스탬프 일부를 받습니다.
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
if [[ -n "$LABEL" ]]; then
  ARCHIVE="$BACKUP_DIR/${BACKUP_PREFIX}${TS}_${LABEL}.tar.gz"
else
  ARCHIVE="$BACKUP_DIR/${BACKUP_PREFIX}${TS}.tar.gz"
fi

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
  # 이름 붙은 백업은 건너뜁니다. 이름을 지었다는 건 남겨 두겠다는 뜻이므로
  # 보관 기간이 지나도 자동으로 지우지 않습니다.
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
