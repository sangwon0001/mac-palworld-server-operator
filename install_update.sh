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
acquire_lock "server update"

# ------------------------------------------------------------- Locate steamcmd
if [[ -x "$STEAMCMD_DIR/steamcmd.sh" ]]; then
  STEAMCMD="$STEAMCMD_DIR/steamcmd.sh"
elif command -v steamcmd >/dev/null 2>&1; then
  STEAMCMD="$(command -v steamcmd)"
else
  die "steamcmd not found. Run ./setup.sh --install first."
fi

# Updating with the server running can lock and corrupt files.
if is_running; then
  die "The server is running. Stop it with ./stop_server.sh before updating."
fi

info "SteamCMD: $STEAMCMD"
info "Install path: $PAL_ROOT"
info "App ID   : $STEAM_APPID (forcing the Windows platform)"
audit "install_update begin (validate=${VALIDATE:-no})"

# ------------------------------------------------------- Bootstrap warm-up
# On its first run steamcmd updates itself and relaunches, and there is a known
# issue where that relaunch dies with SIGABRT (exit 134). Run it once with just
# +quit beforehand so the self-update is out of the way. (Failure is ignored.)
if [[ ! -f "$STEAMCMD_DIR/package/steam_cmd_osx.zip.version" ]] 2>/dev/null; then
  info "Warming up SteamCMD self-update (first run only)..."
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
  warn "SteamCMD exited with $rc. Retrying once in 10 seconds."
  sleep 10
  run_steamcmd
  rc=$?
fi
set -e

if [[ $rc -ne 0 ]]; then
  audit "install_update failed (exit=$rc)"
  die "SteamCMD failed twice (exit=$rc). Check network and disk space, then retry with --validate."
fi

# ------------------------------------------------------------- Verify the result
if [[ ! -f "$PAL_EXE_SHIPPING" && ! -f "$PAL_EXE_LAUNCHER" ]]; then
  die "Install finished but the PalServer executable is missing. Retry with --validate."
fi
ok "Server binary present"

# --------------------------------------------- Scaffold the settings file
# Config/WindowsServer is empty before the first run. Copying the default template
# there lets settings be edited before the server ever starts.
mkdir -p "$CONFIG_DIR" "$SAVEGAMES_DIR"

if [[ ! -f "$SETTINGS_INI" ]]; then
  if [[ -f "$DEFAULT_SETTINGS_INI" ]]; then
    # The template header says changes to it are not reflected — true for the
    # template, misleading once copied to PalWorldSettings.ini where they are.
    # Rewrite that notice while copying.
    sed -e 's/^; This configuration file is a sample.*$/; Live Palworld server settings (changes here DO take effect)/' \
        -e 's/^; Changes to this file will NOT be reflected.*$/; A server restart is required after editing./' \
        -e '/^; To change the server settings/d' \
        "$DEFAULT_SETTINGS_INI" > "$SETTINGS_INI"
    ok "Created PalWorldSettings.ini from the default template"
    warn "For RCON safe shutdown, edit these values:"
    printf '    %s\n' "$SETTINGS_INI"
    printf '      RCONEnabled=True, RCONPort=%s, AdminPassword=\"a-strong-password\"\n' "$RCON_PORT"
  else
    warn "DefaultPalWorldSettings.ini is missing. Starting the server once creates it."
  fi
else
  ok "Kept the existing PalWorldSettings.ini (not overwritten)"
fi

# ------------------------------------------------------------------- Record version
buildid="$(awk '/"buildid"/ {gsub(/"/,"",$2); print $2; exit}' \
  "$PAL_ROOT/steamapps/appmanifest_${STEAM_APPID}.acf" 2>/dev/null || true)"
[[ -n "$buildid" ]] && ok "Installed buildid: $buildid"
audit "install_update done (buildid=${buildid:-unknown})"

echo
info "Next steps"
printf '  1) Edit settings:  %s\n' "$SETTINGS_INI"
printf '  2) Start server:   ./start_server.sh\n'
printf '  3) Check status:   ./status.sh\n'
