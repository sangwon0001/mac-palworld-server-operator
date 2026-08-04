#!/usr/bin/env bash
# ==============================================================================
# install_update.sh - 1단계: SteamCMD 로 팰월드 데디케이티드 서버 설치/업데이트
#   App ID 2394010 의 Windows 뎁포를 내려받습니다.
#   (macOS 용 빌드는 존재하지 않으므로 Windows 빌드를 Wine 으로 구동합니다)
#
#   사용법:
#     ./install_update.sh            # 설치 또는 업데이트
#     ./install_update.sh --validate # 파일 무결성 검증까지 (느림, 손상 복구용)
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

VALIDATE=""
[[ "${1:-}" == "--validate" ]] && VALIDATE="validate"

ensure_dirs

# ------------------------------------------------------------- steamcmd 위치
if [[ -x "$STEAMCMD_DIR/steamcmd.sh" ]]; then
  STEAMCMD="$STEAMCMD_DIR/steamcmd.sh"
elif command -v steamcmd >/dev/null 2>&1; then
  STEAMCMD="$(command -v steamcmd)"
else
  die "steamcmd 를 찾을 수 없습니다. ./setup.sh --install 을 먼저 실행하세요."
fi

# 서버가 켜져 있으면 업데이트 중 파일이 잠겨 손상될 수 있습니다.
if is_running; then
  die "서버가 실행 중입니다. ./stop_server.sh 로 먼저 종료한 뒤 업데이트하세요."
fi

info "SteamCMD: $STEAMCMD"
info "설치 경로: $PAL_ROOT"
info "App ID   : $STEAM_APPID (Windows 플랫폼 강제)"
audit "install_update 시작 (validate=${VALIDATE:-no})"

# ------------------------------------------------------- 부트스트랩 워밍업
# steamcmd 는 최초 실행 시 자기 자신을 업데이트한 뒤 재실행하는데,
# 이 과정에서 한 번 SIGABRT(exit 134) 로 죽는 알려진 문제가 있습니다.
# 본 작업 전에 +quit 만으로 한 번 돌려 자체 업데이트를 끝내 둡니다. (실패해도 무시)
if [[ ! -f "$STEAMCMD_DIR/package/steam_cmd_osx.zip.version" ]] 2>/dev/null; then
  info "SteamCMD 자체 업데이트 워밍업 중 (최초 1회)..."
  "$STEAMCMD" +quit >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------ 설치 수행
# @sSteamCmdForcePlatformType windows : macOS 에서 Windows 뎁포를 받기 위한 핵심 옵션
# +login anonymous                    : 팰월드 데디 서버는 익명 계정으로 배포됨
# 주의: +force_install_dir 는 반드시 +login 보다 먼저 와야 경로가 정상 적용됩니다.
run_steamcmd() {
  "$STEAMCMD" \
    +@sSteamCmdForcePlatformType windows \
    +@ShutdownOnFailedCommand 1 \
    +@NoPromptForPassword 1 \
    +force_install_dir "$PAL_ROOT" \
    +login anonymous \
    +app_update "$STEAM_APPID" $VALIDATE \
    +quit
}

set +e
run_steamcmd
rc=$?
# 자체 업데이트 직후의 일회성 크래시(134)나 일시적 네트워크 오류는 한 번 재시도합니다.
if [[ $rc -ne 0 ]]; then
  warn "SteamCMD 가 exit=$rc 로 종료했습니다. 10초 후 1회 재시도합니다."
  sleep 10
  run_steamcmd
  rc=$?
fi
set -e

if [[ $rc -ne 0 ]]; then
  audit "install_update 실패 (exit=$rc)"
  die "SteamCMD 가 두 번 모두 실패했습니다 (exit=$rc). 네트워크·디스크 공간을 확인하고 --validate 로 재시도하세요."
fi

# ------------------------------------------------------------- 설치 결과 검증
if [[ ! -f "$PAL_EXE_SHIPPING" && ! -f "$PAL_EXE_LAUNCHER" ]]; then
  die "설치는 끝났지만 PalServer 실행 파일을 찾을 수 없습니다. --validate 로 재시도하세요."
fi
ok "서버 바이너리 확인됨"

# --------------------------------------------- 설정 파일 초기 스캐폴딩
# 최초 실행 전에는 Config/WindowsServer 가 비어 있습니다.
# 기본 템플릿을 복사해 두면 첫 기동 전에 미리 설정을 편집할 수 있습니다.
mkdir -p "$CONFIG_DIR" "$SAVEGAMES_DIR"

if [[ ! -f "$SETTINGS_INI" ]]; then
  if [[ -f "$DEFAULT_SETTINGS_INI" ]]; then
    # 템플릿 헤더에는 "이 파일의 변경은 반영되지 않는다"는 주석이 들어 있는데,
    # 복사된 위치(PalWorldSettings.ini)에서는 실제로 반영되므로 오해를 부릅니다.
    # 복사하면서 해당 안내 문구를 실제 상황에 맞게 교체합니다.
    sed -e 's/^; This configuration file is a sample.*$/; Palworld 실제 적용 설정 파일 (이 파일의 변경은 서버에 반영됩니다)/' \
        -e 's/^; Changes to this file will NOT be reflected.*$/; 수정 후에는 서버 재시작이 필요합니다./' \
        -e '/^; To change the server settings/d' \
        "$DEFAULT_SETTINGS_INI" > "$SETTINGS_INI"
    ok "PalWorldSettings.ini 생성 (기본 템플릿 복사)"
    warn "RCON 안전 종료를 쓰려면 아래 값을 수정하세요:"
    printf '    %s\n' "$SETTINGS_INI"
    printf '      RCONEnabled=True, RCONPort=%s, AdminPassword=\"강한비밀번호\"\n' "$RCON_PORT"
  else
    warn "DefaultPalWorldSettings.ini 가 없습니다. 서버를 한 번 기동하면 자동 생성됩니다."
  fi
else
  ok "기존 PalWorldSettings.ini 유지 (덮어쓰지 않음)"
fi

# ------------------------------------------------------------------- 버전 기록
buildid="$(awk '/"buildid"/ {gsub(/"/,"",$2); print $2; exit}' \
  "$PAL_ROOT/steamapps/appmanifest_${STEAM_APPID}.acf" 2>/dev/null || true)"
[[ -n "$buildid" ]] && ok "설치된 buildid: $buildid"
audit "install_update 완료 (buildid=${buildid:-unknown})"

echo
info "다음 단계"
printf '  1) 설정 편집:  %s\n' "$SETTINGS_INI"
printf '  2) 서버 기동:  ./start_server.sh\n'
printf '  3) 상태 확인:  ./status.sh\n'
