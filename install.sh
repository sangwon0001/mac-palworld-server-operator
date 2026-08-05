#!/usr/bin/env bash
# ==============================================================================
# install.sh - One-shot installer for the Palworld server (macOS / Apple Silicon)
#
#   Covers everything from dependency checks through the server download, config
#   generation and building/installing the GUI app.
#
#   Design rules:
#     · Idempotent — finished steps are skipped, so re-running after an interruption
#       is safe.
#     · Runs as the user — Homebrew refuses to run as root, so nothing is wrapped in
#       sudo. Only the step that genuinely needs it (Rosetta) asks for a password.
#     · Non-destructive — existing saves and settings are never overwritten.
#
#   Usage:
#     ./install.sh              # full install (with interactive confirmations)
#     ./install.sh --yes        # unattended, no prompts
#     ./install.sh --no-app     # skip the GUI app (CLI only)
#     ./install.sh --check      # report installation state and exit
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

ASSUME_YES=0
BUILD_APP=1
CHECK_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)  ASSUME_YES=1; shift ;;
    --no-app)  BUILD_APP=0; shift ;;
    --check)   CHECK_ONLY=1; shift ;;
    -h|--help) sed -n '2,/^# ===/p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------------- Output
c_rst=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'
c_ylw=$'\033[33m'; c_blu=$'\033[34m'; c_dim=$'\033[2m'; c_bold=$'\033[1m'

step()  { printf '\n%s▶ [%s/%s] %s%s\n' "$c_bold$c_blu" "$1" "$TOTAL_STEPS" "$2" "$c_rst"; }
ok()    { printf '  %s✔%s %s\n' "$c_grn" "$c_rst" "$*"; }
skip()  { printf '  %s·%s %s %s(already done — skipped)%s\n' "$c_dim" "$c_rst" "$*" "$c_dim" "$c_rst"; }
warn()  { printf '  %s⚠%s %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die()   { printf '\n%s✘ Install aborted%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }
note()  { printf '    %s%s%s\n' "$c_dim" "$*" "$c_rst"; }

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  printf '  %s?%s %s [Y/n] ' "$c_ylw" "$c_rst" "$1"
  read -r a </dev/tty || a=""
  [[ -z "$a" || "$a" =~ ^[Yy]$ ]]
}

TOTAL_STEPS=7

# ============================================================ Preflight
printf '%s╔════════════════════════════════════════════════════════════════╗%s\n' "$c_bold" "$c_rst"
printf '%s║   Palworld Dedicated Server installer (macOS / Apple Silicon)  ║%s\n' "$c_bold" "$c_rst"
printf '%s╚════════════════════════════════════════════════════════════════╝%s\n' "$c_bold" "$c_rst"

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only."
# Apple Silicon only: app/build.sh targets arm64, so on Intel step 7 would
# produce a GUI app the machine cannot run. Better to say so before downloading
# 5.6GB of server files.
[[ "$(uname -m)" == "arm64" ]] || die "Apple Silicon (arm64) only — this Mac reports '$(uname -m)'."

# --- Is python3 actually runnable? (Command Line Tools) ----------------------
# On a fresh Mac /usr/bin/python3 exists as a file but is a stub: running it only
# pops the developer-tools installer and fails. `command -v` therefore cannot tell
# the difference — it has to actually be executed.
# The RCON client (config.sh), status queries and settings editing all depend on
# python3, so without it the install would finish with its core features broken.
if ! python3 -c 'pass' >/dev/null 2>&1; then
  printf '\n%s✘ The Xcode Command Line Tools are required%s\n\n' "$c_red" "$c_rst"
  printf '  python3 cannot be run. This toolkit uses it for RCON safe shutdown,\n'
  printf '  status queries and settings editing.\n\n'
  printf '  Run the following, finish the installer dialog, then try again:\n\n'
  printf '    xcode-select --install\n\n'
  exit 1
fi

source ./config.sh

# Align labels by display width. printf's %-18s pads by bytes, which misaligns as
# soon as wide characters (3 bytes, 2 columns) are involved.
kv() {
  python3 -c '
import sys, unicodedata
label, value, width = sys.argv[1], sys.argv[2], 16
disp = sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in label)
print("  " + label + " " * max(1, width - disp) + value)
' "$1" "$2"
}

# Shared by --check and the final summary
print_state() {
  local wine_state="not installed"
  detect_wine 2>/dev/null && wine_state="$WINE_BIN"
  printf '\n%sCurrent state%s\n' "$c_bold" "$c_rst"
  kv "Rosetta 2" "$(/usr/bin/pgrep -q oahd && echo 'installed' || echo 'not installed')"
  kv "Homebrew"  "$(command -v brew >/dev/null && brew --prefix || echo 'not installed')"
  kv "Wine"      "$wine_state"
  kv "SteamCMD"  "$([[ -x "$STEAMCMD_DIR/steamcmd.sh" ]] && echo "$STEAMCMD_DIR" || echo 'not installed')"
  kv "Server"    "$([[ -f "$PAL_EXE_SHIPPING" ]] && du -sh "$PAL_ROOT" 2>/dev/null | cut -f1 || echo 'not installed')"
  kv "Local config" "$([[ -f config.local.sh ]] && echo 'present' || echo 'absent')"
  kv "GUI app"   "$([[ -d "/Applications/Palworld Server.app" ]] && echo 'installed' || echo 'not installed')"
}

if [[ $CHECK_ONLY -eq 1 ]]; then
  print_state
  exit 0
fi

# Make the scripts executable, but skip config.local.sh: it holds a password and
# must stay at 600 (a blanket `chmod +x ./*.sh` would turn it into 700/711).
for f in ./*.sh; do
  [[ "$(basename "$f")" == "config.local.sh" ]] && continue
  chmod +x "$f" 2>/dev/null || true
done
[[ -f config.local.sh ]] && chmod 600 config.local.sh

# ============================================================ 1. Rosetta 2
step 1 "Checking Rosetta 2"
if /usr/bin/pgrep -q oahd || [[ -d /Library/Apple/usr/libexec/oah ]]; then
  skip "Rosetta 2"
else
  warn "Rosetta 2 is required (Wine and the Windows server binary both need it)."
  note "You may be asked for your administrator password."
  if confirm "Install it now?"; then
    softwareupdate --install-rosetta --agree-to-license || die "Rosetta install failed"
    ok "Rosetta 2 installed"
  else
    die "Cannot continue without Rosetta 2."
  fi
fi

# ============================================================ 2. Homebrew
step 2 "Checking Homebrew"
if command -v brew >/dev/null 2>&1; then
  skip "Homebrew ($(brew --prefix))"
else
  warn "Homebrew is missing. For safety this script will not install it for you."
  printf '\n  Run this yourself, then run this script again:\n\n'
  printf '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"\n\n'
  die "Homebrew required"
fi

# ============================================================ 3. Wine
step 3 "Checking the Wine compatibility layer"
if detect_wine 2>/dev/null; then
  skip "Wine ($WINE_BIN)"
else
  note "Installing the free Gcenx repackaging of Apple's Game Porting Toolkit."
  note "The official WineHQ casks fail Gatekeeper and are disabled on 2026-09-01, so they are not used."
  note "This requires trusting a third-party tap (brew trust) — it permits running code from that repository."
  if confirm "Install Wine? (about 220MB)"; then
    brew tap gcenx/wine 2>&1 | tail -2 || true
    brew trust gcenx/wine 2>&1 | tail -1 || true
    brew install --cask game-porting-toolkit 2>&1 | tail -3 \
      || die "Wine install failed. See ./setup.sh for manual instructions."
    detect_wine || die "Installed, but the wine executable could not be found."
    ok "Wine installed ($("$WINE_BIN" --version 2>/dev/null | head -1))"
  else
    die "The server cannot run without Wine."
  fi
fi

# ============================================================ 4. SteamCMD
step 4 "Checking SteamCMD"
if [[ -x "$STEAMCMD_DIR/steamcmd.sh" ]]; then
  skip "SteamCMD ($STEAMCMD_DIR)"
else
  note "The Homebrew 'steamcmd' cask is broken, so Valve's official tarball is used instead."
  mkdir -p "$STEAMCMD_DIR"
  curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz \
    | tar zxf - -C "$STEAMCMD_DIR" || die "SteamCMD download failed"
  chmod +x "$STEAMCMD_DIR/steamcmd.sh"
  ok "SteamCMD installed"
fi

# ============================================================ 5. Local settings
step 5 "Creating local settings"
if [[ -f config.local.sh ]]; then
  skip "config.local.sh"
else
  # The RCON password is what makes safe shutdown possible, so always generate one.
  PW="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  cat > config.local.sh <<EOF
#!/usr/bin/env bash
# Local settings — these override the defaults in config.sh. Do not commit this file.

# Wine path detected by install.sh
WINE_BIN="${WINE_BIN}"

# RCON — used for safe shutdown, player queries and auto-restart conditions.
# Must match AdminPassword in PalWorldSettings.ini.
RCON_PASSWORD="${PW}"
EOF
  chmod 600 config.local.sh
  ok "Created config.local.sh (mode 600)"
  note "Generated RCON password: $PW"
fi

# ============================================================ 6. The server
step 6 "Installing the Palworld server"
if [[ -f "$PAL_EXE_SHIPPING" ]]; then
  skip "Server files ($(du -sh "$PAL_ROOT" 2>/dev/null | cut -f1))"
else
  note "This downloads about 5.6GB; expect 10-30 minutes depending on your connection."
  confirm "Download it now?" || die "Nothing works without the server files."
  ./install_update.sh || die "Server install failed"
fi

# --- Write RCON settings into the ini, but only if it is still unset ---
source ./config.sh   # pick up the config.local.sh just created
if [[ -f "$SETTINGS_INI" && -n "${RCON_PASSWORD:-}" ]]; then
  if grep -q 'AdminPassword=""' "$SETTINGS_INI" 2>/dev/null; then
    INI="$SETTINGS_INI" PW="$RCON_PASSWORD" python3 - <<'PY'
import os
p, pw = os.environ["INI"], os.environ["PW"]
s = open(p, encoding="utf-8").read()
s = s.replace('AdminPassword=""', f'AdminPassword="{pw}"')
s = s.replace('RCONEnabled=False', 'RCONEnabled=True')
open(p, "w", encoding="utf-8").write(s)
PY
    ok "Wrote RCON settings into PalWorldSettings.ini"
  else
    skip "RCON settings (AdminPassword is already set)"
  fi
fi

# ============================================================ 7. GUI app
step 7 "Building and installing the GUI app"
if [[ $BUILD_APP -eq 0 ]]; then
  skip "GUI app (--no-app)"
elif ! command -v swiftc >/dev/null 2>&1; then
  warn "swiftc is missing, so the app cannot be built. The CLI works fine."
  note "To get the app: xcode-select --install, then 'cd app && ./build.sh --install'"
else
  if confirm "Build the menu bar app and install it into /Applications?"; then
    ( cd app && ./build.sh --install ) || warn "App build failed — the CLI works fine."
    [[ -d "/Applications/Palworld Server.app" ]] && ok "GUI app installed"
  else
    skip "GUI app"
  fi
fi

# ============================================================ Done
print_state

cat <<EOF

$c_bold${c_grn}Installation complete$c_rst

  Start        ./start_server.sh          (or Start Server in the app)
  Status       ./status.sh
  Safe stop    ./stop_server.sh
  Back up      ./backup_save.sh

${c_bold}Worth doing next$c_rst
  - Edit settings such as the server name and difficulty
      open -e "$SETTINGS_INI"
  - Schedule backups and automatic restarts (for the memory leak)
      ./install_cron.sh --install
  - Check the addresses players connect to (LAN and external)
      ./status.sh --address
      Same network: $(lan_ip 2>/dev/null || echo 'unavailable'):$GAME_PORT
  - For external access, forward UDP $GAME_PORT on your router

${c_dim}See README.md for details.$c_rst
EOF
