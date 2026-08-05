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
INSTALL_DIR="$PWD"

ASSUME_YES=0
BUILD_APP=1
CHECK_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes|-y)  ASSUME_YES=1; shift ;;
    --no-app)  BUILD_APP=0; shift ;;
    --check)   CHECK_ONLY=1; shift ;;
    -h|--help) sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf '알 수 없는 옵션: %s\n' "$1" >&2; exit 1 ;;
  esac
done

# --------------------------------------------------------------------- Output
c_rst=$'\033[0m'; c_red=$'\033[31m'; c_grn=$'\033[32m'
c_ylw=$'\033[33m'; c_blu=$'\033[34m'; c_dim=$'\033[2m'; c_bold=$'\033[1m'

step()  { printf '\n%s▶ [%s/%s] %s%s\n' "$c_bold$c_blu" "$1" "$TOTAL_STEPS" "$2" "$c_rst"; }
ok()    { printf '  %s✔%s %s\n' "$c_grn" "$c_rst" "$*"; }
skip()  { printf '  %s·%s %s %s(이미 완료 — 건너뜀)%s\n' "$c_dim" "$c_rst" "$*" "$c_dim" "$c_rst"; }
warn()  { printf '  %s⚠%s %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die()   { printf '\n%s✘ 설치 중단%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }
note()  { printf '    %s%s%s\n' "$c_dim" "$*" "$c_rst"; }

confirm() {
  [[ $ASSUME_YES -eq 1 ]] && return 0
  printf '  %s?%s %s [Y/n] ' "$c_ylw" "$c_rst" "$1"
  read -r a </dev/tty || a=""
  [[ -z "$a" || "$a" =~ ^[Yy]$ ]]
}

TOTAL_STEPS=7

# ============================================================ Preflight
printf '%s╔════════════════════════════════════════════════════════════╗%s\n' "$c_bold" "$c_rst"
printf '%s║   팰월드 전용 서버 설치 프로그램  (macOS / Apple Silicon)  ║%s\n' "$c_bold" "$c_rst"
printf '%s╚════════════════════════════════════════════════════════════╝%s\n' "$c_bold" "$c_rst"

[[ "$(uname -s)" == "Darwin" ]] || die "macOS 전용입니다."

# --- Is python3 actually runnable? (Command Line Tools) ----------------------
# On a fresh Mac /usr/bin/python3 exists as a file but is a stub: running it only
# pops the developer-tools installer and fails. `command -v` therefore cannot tell
# the difference — it has to actually be executed.
# The RCON client (config.sh), status queries and settings editing all depend on
# python3, so without it the install would finish with its core features broken.
if ! python3 -c 'pass' >/dev/null 2>&1; then
  printf '\n%s✘ Command Line Tools 가 필요합니다%s\n\n' "$c_red" "$c_rst"
  printf '  python3 를 실행할 수 없습니다. 이 도구 모음은 RCON 안전 종료·상태 조회·\n'
  printf '  설정 편집에 python3 를 사용합니다.\n\n'
  printf '  아래를 실행해 설치를 마친 뒤 다시 시도하세요 (대화상자가 뜹니다):\n\n'
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
  local wine_state="미설치"
  detect_wine 2>/dev/null && wine_state="$WINE_BIN"
  printf '\n%s현재 설치 상태%s\n' "$c_bold" "$c_rst"
  kv "Rosetta 2" "$(/usr/bin/pgrep -q oahd && echo '설치됨' || echo '미설치')"
  kv "Homebrew"  "$(command -v brew >/dev/null && brew --prefix || echo '미설치')"
  kv "Wine"      "$wine_state"
  kv "SteamCMD"  "$([[ -x "$STEAMCMD_DIR/steamcmd.sh" ]] && echo "$STEAMCMD_DIR" || echo '미설치')"
  kv "서버 본체"  "$([[ -f "$PAL_EXE_SHIPPING" ]] && du -sh "$PAL_ROOT" 2>/dev/null | cut -f1 || echo '미설치')"
  kv "개인 설정"  "$([[ -f config.local.sh ]] && echo '있음' || echo '없음')"
  kv "GUI 앱"    "$([[ -d "/Applications/Palworld 서버.app" ]] && echo '설치됨' || echo '미설치')"
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
step 1 "Rosetta 2 확인"
if [[ "$(uname -m)" != "arm64" ]]; then
  ok "Intel Mac — Rosetta 불필요"
elif /usr/bin/pgrep -q oahd || [[ -d /Library/Apple/usr/libexec/oah ]]; then
  skip "Rosetta 2"
else
  warn "Rosetta 2 가 필요합니다 (Wine 과 Windows 서버 바이너리 구동에 필수)."
  note "설치 시 관리자 암호를 물어볼 수 있습니다."
  if confirm "지금 설치할까요?"; then
    softwareupdate --install-rosetta --agree-to-license || die "Rosetta 설치 실패"
    ok "Rosetta 2 설치 완료"
  else
    die "Rosetta 2 없이는 진행할 수 없습니다."
  fi
fi

# ============================================================ 2. Homebrew
step 2 "Homebrew 확인"
if command -v brew >/dev/null 2>&1; then
  skip "Homebrew ($(brew --prefix))"
else
  warn "Homebrew 가 없습니다. 보안상 이 스크립트가 대신 설치하지 않습니다."
  printf '\n  아래 명령을 직접 실행한 뒤 이 스크립트를 다시 실행하세요:\n\n'
  printf '    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"\n\n'
  die "Homebrew 필요"
fi

# ============================================================ 3. Wine
step 3 "Wine 호환 레이어 확인"
if detect_wine 2>/dev/null; then
  skip "Wine ($WINE_BIN)"
else
  note "무료 배포판인 Gcenx 재패키징 Game Porting Toolkit 을 설치합니다."
  note "공식 WineHQ cask 들은 Gatekeeper 검사 실패로 2026-09-01 비활성화 예정이라 쓰지 않습니다."
  note "설치 중 서드파티 탭 신뢰(brew trust)가 필요합니다 — 해당 저장소의 코드 실행을 허용한다는 뜻입니다."
  if confirm "Wine 을 설치할까요? (약 220MB)"; then
    brew tap gcenx/wine 2>&1 | tail -2 || true
    brew trust gcenx/wine 2>&1 | tail -1 || true
    brew install --cask game-porting-toolkit 2>&1 | tail -3 \
      || die "Wine 설치 실패. 수동 설치는 ./setup.sh 안내를 참고하세요."
    detect_wine || die "설치는 됐지만 wine 실행 파일을 찾지 못했습니다."
    ok "Wine 설치 완료 ($("$WINE_BIN" --version 2>/dev/null | head -1))"
  else
    die "Wine 없이는 서버를 구동할 수 없습니다."
  fi
fi

# ============================================================ 4. SteamCMD
step 4 "SteamCMD 확인"
if [[ -x "$STEAMCMD_DIR/steamcmd.sh" ]]; then
  skip "SteamCMD ($STEAMCMD_DIR)"
else
  note "Homebrew cask 'steamcmd' 는 정의 오류가 있어 Valve 공식 tarball 을 직접 받습니다."
  mkdir -p "$STEAMCMD_DIR"
  curl -fsSL https://steamcdn-a.akamaihd.net/client/installer/steamcmd_osx.tar.gz \
    | tar zxf - -C "$STEAMCMD_DIR" || die "SteamCMD 다운로드 실패"
  chmod +x "$STEAMCMD_DIR/steamcmd.sh"
  ok "SteamCMD 설치 완료"
fi

# ============================================================ 5. Local settings
step 5 "개인 설정 생성"
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
  ok "config.local.sh 생성 (권한 600)"
  note "생성된 RCON 비밀번호: $PW"
fi

# ============================================================ 6. The server
step 6 "팰월드 서버 설치"
if [[ -f "$PAL_EXE_SHIPPING" ]]; then
  skip "서버 본체 ($(du -sh "$PAL_ROOT" 2>/dev/null | cut -f1))"
else
  note "약 5.6GB 를 내려받습니다. 회선에 따라 10~30분 걸릴 수 있습니다."
  confirm "지금 다운로드할까요?" || die "서버 본체 없이는 사용할 수 없습니다."
  ./install_update.sh || die "서버 설치 실패"
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
    ok "PalWorldSettings.ini 에 RCON 설정 반영"
  else
    skip "RCON 설정 (AdminPassword 가 이미 지정되어 있음)"
  fi
fi

# ============================================================ 7. GUI app
step 7 "GUI 앱 빌드 및 설치"
if [[ $BUILD_APP -eq 0 ]]; then
  skip "GUI 앱 (--no-app)"
elif ! command -v swiftc >/dev/null 2>&1; then
  warn "swiftc 가 없어 앱을 빌드할 수 없습니다. CLI 는 정상 사용 가능합니다."
  note "앱이 필요하면: xcode-select --install 후 'cd app && ./build.sh --install'"
else
  if confirm "메뉴 막대 GUI 앱을 빌드해 /Applications 에 설치할까요?"; then
    ( cd app && ./build.sh --install ) || warn "앱 빌드 실패 — CLI 는 정상 사용 가능합니다."
    [[ -d "/Applications/Palworld 서버.app" ]] && ok "GUI 앱 설치 완료"
  else
    skip "GUI 앱"
  fi
fi

# ============================================================ Done
print_state

cat <<EOF

$c_bold$c_grn설치 완료$c_rst

  서버 시작    ./start_server.sh          또는 GUI 앱의 '서버 시작'
  상태 확인    ./status.sh
  안전 종료    ./stop_server.sh
  백업         ./backup_save.sh

$c_bold다음으로 할 만한 것$c_rst
  · 서버 이름/난이도 등 설정 편집
      open -e "$SETTINGS_INI"
  · 정기 백업 + 자동 재시작 등록 (메모리 누수 대응)
      ./install_cron.sh --install
  · 접속 주소 확인 (내부망 · 외부 모두)
      ./status.sh --address
      같은 공유기 안: $(lan_ip 2>/dev/null || echo '확인 불가'):$GAME_PORT
  · 외부 접속을 받으려면 공유기에서 UDP $GAME_PORT 포트포워딩

$c_dim자세한 내용은 README.md 를 참고하세요.$c_rst
EOF
