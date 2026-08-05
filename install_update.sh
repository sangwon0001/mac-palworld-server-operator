#!/usr/bin/env bash
# ==============================================================================
# install_update.sh - Install or update the Palworld dedicated server via SteamCMD
#   Downloads the Windows depot for App ID 2394010.
#   (No macOS build exists, so the Windows build is run under Wine.)
#
#   Usage:
#     ./install_update.sh            # install or update
#     ./install_update.sh --validate # also verify file integrity (slow; for repairs)
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

VALIDATE=""
[[ "${1:-}" == "--validate" ]] && VALIDATE="validate"

ensure_dirs

# ------------------------------------------------------------- Locate steamcmd
if [[ -x "$STEAMCMD_DIR/steamcmd.sh" ]]; then
  STEAMCMD="$STEAMCMD_DIR/steamcmd.sh"
elif command -v steamcmd >/dev/null 2>&1; then
  STEAMCMD="$(command -v steamcmd)"
else
  die "steamcmd 를 찾을 수 없습니다. ./setup.sh --install 을 먼저 실행하세요."
fi

# Updating with the server running can lock and corrupt files.
if is_running; then
  die "서버가 실행 중입니다. ./stop_server.sh 로 먼저 종료한 뒤 업데이트하세요."
fi

info "SteamCMD: $STEAMCMD"
info "설치 경로: $PAL_ROOT"
info "App ID   : $STEAM_APPID (Windows 플랫폼 강제)"
audit "install_update 시작 (validate=${VALIDATE:-no})"

# ------------------------------------------------------- Bootstrap warm-up
# On its first run steamcmd updates itself and relaunches, and there is a known
# issue where that relaunch dies with SIGABRT (exit 134). Run it once with just
# +quit beforehand so the self-update is out of the way. (Failure is ignored.)
if [[ ! -f "$STEAMCMD_DIR/package/steam_cmd_osx.zip.version" ]] 2>/dev/null; then
  info "SteamCMD 자체 업데이트 워밍업 중 (최초 1회)..."
  "$STEAMCMD" +quit >/dev/null 2>&1 || true
fi

# ------------------------------------------------------------------ Install
# @sSteamCmdForcePlatformType windows : the key flag for pulling a Windows depot on macOS
# +login anonymous                    : the dedicated server ships under anonymous login
# Note: +force_install_dir must come before +login or the path is ignored.
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
# Retry once: the one-off post-self-update crash (134) and transient network errors.
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

# ------------------------------------------------------------- Verify the result
if [[ ! -f "$PAL_EXE_SHIPPING" && ! -f "$PAL_EXE_LAUNCHER" ]]; then
  die "설치는 끝났지만 PalServer 실행 파일을 찾을 수 없습니다. --validate 로 재시도하세요."
fi
ok "서버 바이너리 확인됨"

# --------------------------------------------- Scaffold the settings file
# Config/WindowsServer is empty before the first run. Copying the default template
# there lets settings be edited before the server ever starts.
mkdir -p "$CONFIG_DIR" "$SAVEGAMES_DIR"

if [[ ! -f "$SETTINGS_INI" ]]; then
  if [[ -f "$DEFAULT_SETTINGS_INI" ]]; then
    # The template header says changes to it are not reflected — true for the
    # template, misleading once copied to PalWorldSettings.ini where they are.
    # Rewrite that notice while copying.
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

# ------------------------------------------------------------------- Record version
buildid="$(awk '/"buildid"/ {gsub(/"/,"",$2); print $2; exit}' \
  "$PAL_ROOT/steamapps/appmanifest_${STEAM_APPID}.acf" 2>/dev/null || true)"
[[ -n "$buildid" ]] && ok "설치된 buildid: $buildid"
audit "install_update 완료 (buildid=${buildid:-unknown})"

echo
info "다음 단계"
printf '  1) 설정 편집:  %s\n' "$SETTINGS_INI"
printf '  2) 서버 기동:  ./start_server.sh\n'
printf '  3) 상태 확인:  ./status.sh\n'
