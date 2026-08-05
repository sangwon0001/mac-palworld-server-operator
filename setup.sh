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

info "환경 점검을 시작합니다"
hr

# ------------------------------------------------------------ 1. CPU architecture
arch="$(uname -m)"
if [[ "$arch" == "arm64" ]]; then
  ok "Apple Silicon (arm64) 확인"
else
  warn "arm64 가 아닙니다 ($arch). Intel Mac 이면 Rosetta 단계는 건너뛰어도 됩니다."
fi

# --------------------------------------------------------------- 2. Rosetta 2
# steamcmd and most Wine builds are x86_64, so Rosetta 2 is required.
if [[ "$arch" == "arm64" ]]; then
  if /usr/bin/pgrep -q oahd || [[ -d /Library/Apple/usr/libexec/oah ]]; then
    ok "Rosetta 2 설치됨"
  else
    warn "Rosetta 2 미설치"
    missing+=("rosetta")
  fi
fi

# --------------------------------------------------------------- 3. Homebrew
if command -v brew >/dev/null 2>&1; then
  ok "Homebrew 설치됨 ($(brew --prefix))"
else
  warn "Homebrew 미설치"
  missing+=("brew")
fi

# ---------------------------------------------------------------- 4. steamcmd
if [[ -x "$STEAMCMD_DIR/steamcmd.sh" ]]; then
  ok "steamcmd 설치됨 ($STEAMCMD_DIR/steamcmd.sh)"
elif command -v steamcmd >/dev/null 2>&1; then
  ok "steamcmd 설치됨 (PATH: $(command -v steamcmd))"
else
  warn "steamcmd 미설치"
  missing+=("steamcmd")
fi

# --------------------------------------------------------------------- 5. Wine
if detect_wine; then
  ok "Wine 발견: $WINE_BIN"
else
  warn "Wine 미설치 (Windows 빌드 구동에 필수)"
  missing+=("wine")
fi

# ------------------------------------------------------------------ 6. Extras
for tool in tmux lsof python3; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool 사용 가능"
  else
    warn "$tool 없음 (일부 기능 제한)"
  fi
done

hr

# ============================================================ Guidance / install
if [[ ${#missing[@]} -eq 0 ]]; then
  ensure_dirs
  ok "모든 사전 요구사항 충족. 다음 단계: ./install_update.sh"
  exit 0
fi

info "빠진 항목: ${missing[*]}"
echo

for item in "${missing[@]}"; do
  case "$item" in
    rosetta)
      cat <<'EOS'
[Rosetta 2]
  Apple Silicon 에서 x86_64 바이너리(steamcmd, Wine)를 돌리기 위해 필요합니다.
  설치 명령:

    softwareupdate --install-rosetta --agree-to-license

EOS
      if [[ $AUTO_INSTALL -eq 1 ]]; then
        info "Rosetta 2 설치 중..."
        softwareupdate --install-rosetta --agree-to-license
      fi
      ;;
    brew)
      cat <<'EOS'
[Homebrew]
  설치 명령:

    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

  설치 후 PATH 등록(Apple Silicon):
    echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> ~/.zprofile && exec zsh

EOS
      ;;
    steamcmd)
      cat <<EOS
[steamcmd]
  Homebrew cask 'steamcmd' 는 현재 환경에서 정의 오류가 있어,
  Valve 공식 tarball 직접 설치를 권장합니다:

    mkdir -p "$STEAMCMD_DIR" && cd "$STEAMCMD_DIR"
    curl -sSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz | tar zxvf -

  (이 스크립트를 --install 로 실행하면 위 작업을 대신 수행합니다)

EOS
      if [[ $AUTO_INSTALL -eq 1 ]]; then
        info "steamcmd 다운로드 중..."
        mkdir -p "$STEAMCMD_DIR"
        curl -sSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz \
          | tar zxf - -C "$STEAMCMD_DIR"
        chmod +x "$STEAMCMD_DIR/steamcmd.sh"
        ok "steamcmd 설치 완료: $STEAMCMD_DIR/steamcmd.sh"
      fi
      ;;
    wine)
      cat <<'EOS'
[Wine 호환 레이어] — 아래 중 하나를 고르세요. (권장순)

  A) Game Porting Toolkit — Gcenx 재패키징판  ★무료, 현재 최선★
       brew tap gcenx/wine
       brew install --cask game-porting-toolkit

     · 무료. Apple 개발자 계정도, Xcode 도, x86_64 Homebrew 도 필요 없습니다.
       (그 조건들은 Apple 공식 formula 얘기이고 이 cask 에는 해당 없음)
     · 설치 시 quarantine 속성을 떼고 ad-hoc 코드서명을 다시 합니다.
       → 공식 WineHQ cask 들을 막아버린 Gatekeeper 문제를 우회합니다.
     · wine64 / wineserver 를 brew bin 에 링크하므로 자동 탐색이 바로 잡습니다.
     설치 후 WINE_BIN: $(brew --prefix)/bin/wine64

  B) CrossOver — 유료 (연 구독, 14일 체험판)
       brew install --cask crossover
     · 상용 지원과 GUI 관리 도구가 필요할 때. 서버 성능 자체는 A 와 동일합니다.
     설치 후 WINE_BIN:
       /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine

  C) Gcenx 순정 Wine 빌드 (무료, 수동 설치) — A 가 실패할 때의 대안
       https://github.com/Gcenx/macOS_Wine_builds/releases
       wine-staging-<버전>-osx64.tar.xz 를 받아 압축을 풀고,
       xattr -drs com.apple.quarantine <풀어낸경로>
     설치 후 WINE_BIN 은 압축을 푼 경로의 bin/wine64

  ※ 공식 WineHQ cask(wine-stable, wine@devel, wine@staging)는 macOS Gatekeeper
     검사를 통과하지 못해 deprecated 되었고 2026-09-01 에 비활성화됩니다. 쓰지 마세요.
  ※ gcenx/wine 탭의 wine-crossover cask 는 없어졌습니다 (A 로 대체됨).
  ※ Whisky 는 개발이 중단되어 권장하지 않습니다.
  ※ Box64 는 ARM Linux 용이라 macOS 에서는 해당 사항이 없습니다.

  ※ 참고: GPTK 의 강점인 D3DMetal(Direct3D→Metal)은 헤드리스인 PalServer 에는
     쓰이지 않습니다. A 를 1순위로 둔 이유는 성능이 아니라 "무료 + 설치가 깨끗함"입니다.

  설치 후 config.local.sh 에 경로를 명시하세요:
       echo 'WINE_BIN="/your/path/to/wine"' >> config.local.sh

EOS
      ;;
  esac
done

hr
if [[ $AUTO_INSTALL -eq 1 ]]; then
  info "자동 설치 가능한 항목을 처리했습니다. 다시 ./setup.sh 로 확인하세요."
else
  info "위 명령들을 실행한 뒤 ./setup.sh 를 다시 실행하세요."
  info "(Rosetta/steamcmd 자동 설치: ./setup.sh --install)"
fi
exit 1
