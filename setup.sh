#!/usr/bin/env bash
# ==============================================================================
# setup.sh - Check prerequisites and explain how to install what is missing
#   Reports on Homebrew / Rosetta 2 / Wine / steamcmd and prints the commands for
#   anything absent. (--install handles the ones that can be automated.)
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

AUTO_INSTALL=0
[[ "${1:-}" == "--install" ]] && AUTO_INSTALL=1

missing=()

hr() { printf '%s\n' "------------------------------------------------------------"; }

info "Checking your environment"
hr

# ------------------------------------------------------------ 1. CPU architecture
# Apple Silicon only. Nothing here was ever tested on Intel, and app/build.sh
# targets arm64, so an Intel machine would get a GUI app it cannot launch.
arch="$(uname -m)"
if [[ "$arch" == "arm64" ]]; then
  ok "Apple Silicon (arm64)"
else
  die "Apple Silicon (arm64) only — this Mac reports '$arch'."
fi

# --------------------------------------------------------------- 2. Rosetta 2
# steamcmd and most Wine builds are x86_64, so Rosetta 2 is required.
if /usr/bin/pgrep -q oahd || [[ -d /Library/Apple/usr/libexec/oah ]]; then
  ok "Rosetta 2 installed"
else
  warn "Rosetta 2 not installed"
  missing+=("rosetta")
fi

# --------------------------------------------------------------- 3. Homebrew
if command -v brew >/dev/null 2>&1; then
  ok "Homebrew installed ($(brew --prefix))"
else
  warn "Homebrew not installed"
  missing+=("brew")
fi

# ---------------------------------------------------------------- 4. steamcmd
if [[ -x "$STEAMCMD_DIR/steamcmd.sh" ]]; then
  ok "steamcmd installed ($STEAMCMD_DIR/steamcmd.sh)"
elif command -v steamcmd >/dev/null 2>&1; then
  ok "steamcmd installed (PATH: $(command -v steamcmd))"
else
  warn "steamcmd not installed"
  missing+=("steamcmd")
fi

# --------------------------------------------------------------------- 5. Wine
if detect_wine; then
  ok "Wine found: $WINE_BIN"
else
  warn "Wine not installed (required to run the Windows build)"
  missing+=("wine")
fi

# ------------------------------------------------------------------ 6. Extras
for tool in tmux lsof python3; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool available"
  else
    warn "$tool missing (some features limited)"
  fi
done

hr

# ============================================================ Guidance / install
if [[ ${#missing[@]} -eq 0 ]]; then
  ensure_dirs
  ok "All prerequisites met. Next: ./install_update.sh"
  exit 0
fi

info "Missing: ${missing[*]}"
echo

for item in "${missing[@]}"; do
  case "$item" in
    rosetta)
      cat <<'EOS'
[Rosetta 2]
  Needed to run x86_64 binaries (steamcmd, Wine) on Apple Silicon.
  Install with:

    softwareupdate --install-rosetta --agree-to-license

EOS
      if [[ $AUTO_INSTALL -eq 1 ]]; then
        info "Installing Rosetta 2..."
        softwareupdate --install-rosetta --agree-to-license
      fi
      ;;
    brew)
      cat <<'EOS'
[Homebrew]
  Install with:

    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  Then add it to PATH (Apple Silicon):
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile && exec zsh

EOS
      ;;
    steamcmd)
      cat <<EOS
[steamcmd]
  The Homebrew cask 'steamcmd' currently has a broken definition, so installing
  Valve's official tarball directly is recommended:

    mkdir -p "$STEAMCMD_DIR" && cd "$STEAMCMD_DIR"
    curl -sSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz | tar zxvf -

  (Running this script with --install does the above for you)

EOS
      if [[ $AUTO_INSTALL -eq 1 ]]; then
        info "Downloading steamcmd..."
        mkdir -p "$STEAMCMD_DIR"
        curl -sSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz \
          | tar zxf - -C "$STEAMCMD_DIR"
        chmod +x "$STEAMCMD_DIR/steamcmd.sh"
        ok "steamcmd installed: $STEAMCMD_DIR/steamcmd.sh"
      fi
      ;;
    wine)
      cat <<'EOS'
[Wine compatibility layer] — pick one (in recommended order)

  A) Game Porting Toolkit — Gcenx repackaging   ★free, currently the best★
       brew tap gcenx/wine
       brew install --cask game-porting-toolkit

     - Free. No Apple developer account, no Xcode, no x86_64 Homebrew.
       (Those requirements apply to Apple's official formula, not this cask.)
     - Installation strips the quarantine attribute and re-signs ad-hoc,
       sidestepping the Gatekeeper problem that killed the official WineHQ casks.
     - Links wine64 / wineserver into brew's bin, so auto-detection finds it.
     WINE_BIN afterwards: $(brew --prefix)/bin/wine64

  B) CrossOver — paid (annual subscription, 14-day trial)
       brew install --cask crossover
     - For commercial support and a GUI. Server performance is identical to A.
     WINE_BIN afterwards:
       /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine

  C) Gcenx plain Wine builds (free, manual) — fallback if A fails
       https://github.com/Gcenx/macOS_Wine_builds/releases
       Download wine-staging-<version>-osx64.tar.xz, extract it, then:
       xattr -drs com.apple.quarantine <extracted path>
     WINE_BIN is bin/wine64 inside the extracted folder

  NOTE: The official WineHQ casks (wine-stable, wine@devel, wine@staging) fail the
     macOS Gatekeeper check, are deprecated, and will be disabled on 2026-09-01.
  NOTE: The wine-crossover cask is gone from the gcenx/wine tap (A replaces it).
  NOTE: Whisky is discontinued and not recommended.
  NOTE: Box64 targets ARM Linux and does not apply on macOS.

  NOTE: GPTK's strength, D3DMetal (Direct3D to Metal), is unused by the headless
     PalServer. A ranks first for being free and installing cleanly, not for speed.

  Afterwards, record the path in config.local.sh:
       echo 'WINE_BIN="/your/path/to/wine"' >> config.local.sh

EOS
      ;;
  esac
done

hr
if [[ $AUTO_INSTALL -eq 1 ]]; then
  info "Handled what could be automated. Run ./setup.sh again to re-check."
else
  info "Run the commands above, then run ./setup.sh again."
  info "(Automatic Rosetta/steamcmd install: ./setup.sh --install)"
fi
exit 1
