#!/usr/bin/env bash
# ==============================================================================
# install.sh - 팰월드 서버 원클릭 설치 프로그램 (macOS / Apple Silicon)
#
#   의존성 점검·설치부터 서버 다운로드, 설정 생성, GUI 앱 빌드·설치까지
#   한 번에 처리합니다.
#
#   설계 원칙:
#     · 멱등성 — 이미 끝난 단계는 건너뜁니다. 중단 후 다시 실행해도 안전합니다.
#     · 사용자 권한 실행 — Homebrew 는 root 실행을 거부하므로 sudo 로 감싸지
#       않습니다. 권한이 필요한 단계(Rosetta)만 개별적으로 암호를 요청합니다.
#     · 파괴적 동작 없음 — 기존 세이브/설정은 절대 덮어쓰지 않습니다.
#
#   사용법:
#     ./install.sh              # 전체 설치 (대화형 확인 포함)
#     ./install.sh --yes        # 확인 없이 진행 (무인 설치)
#     ./install.sh --no-app     # GUI 앱 빌드 건너뛰기 (CLI 만 사용)
#     ./install.sh --check      # 설치 상태만 점검하고 종료
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

# --------------------------------------------------------------------- 출력
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

# ============================================================ 사전 점검
printf '%s╔════════════════════════════════════════════════════════════╗%s\n' "$c_bold" "$c_rst"
printf '%s║   팰월드 전용 서버 설치 프로그램  (macOS / Apple Silicon)  ║%s\n' "$c_bold" "$c_rst"
printf '%s╚════════════════════════════════════════════════════════════╝%s\n' "$c_bold" "$c_rst"

[[ "$(uname -s)" == "Darwin" ]] || die "macOS 전용입니다."

# --- python3 실행 가능 여부 (Command Line Tools) -----------------------------
# 새 맥에서는 /usr/bin/python3 파일이 '존재'하지만 실행하면 개발자 도구 설치
# 대화상자만 띄우고 실패하는 스텁입니다. 그래서 command -v 로는 판별할 수 없고
# 실제로 실행해 봐야 합니다.
# RCON 클라이언트(config.sh), 상태 조회, 설정 편집이 모두 python3 에 의존하므로
# 이게 없으면 설치를 진행해도 핵심 기능이 동작하지 않습니다.
if ! python3 -c 'pass' >/dev/null 2>&1; then
  printf '\n%s✘ Command Line Tools 가 필요합니다%s\n\n' "$c_red" "$c_rst"
  printf '  python3 를 실행할 수 없습니다. 이 도구 모음은 RCON 안전 종료·상태 조회·\n'
  printf '  설정 편집에 python3 를 사용합니다.\n\n'
  printf '  아래를 실행해 설치를 마친 뒤 다시 시도하세요 (대화상자가 뜹니다):\n\n'
  printf '    xcode-select --install\n\n'
  exit 1
fi

source ./config.sh

# 라벨을 '표시 폭' 기준으로 정렬해 출력합니다.
# printf 의 %-18s 는 바이트 기준이라 한글(3바이트/2칸)이 섞이면 어긋납니다.
kv() {
  python3 -c '
import sys, unicodedata
label, value, width = sys.argv[1], sys.argv[2], 16
disp = sum(2 if unicodedata.east_asian_width(c) in ("W", "F") else 1 for c in label)
print("  " + label + " " * max(1, width - disp) + value)
' "$1" "$2"
}

# 설치 상태 점검 결과를 모아 출력 (--check 및 최종 요약 공용)
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

# 실행 권한 부여. config.local.sh 는 비밀번호를 담고 있어 600 을 유지해야 하므로
# 제외합니다 (`chmod +x ./*.sh` 로 싸잡으면 700/711 이 되어 의도한 권한이 깨집니다).
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

# ============================================================ 5. 개인 설정
step 5 "개인 설정 생성"
if [[ -f config.local.sh ]]; then
  skip "config.local.sh"
else
  # RCON 비밀번호는 안전 종료(세이브 유실 방지)의 핵심이라 반드시 만들어 둡니다.
  PW="$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c 24)"
  cat > config.local.sh <<EOF
#!/usr/bin/env bash
# 개인 설정 — config.sh 의 기본값을 덮어씁니다. 버전 관리에 올리지 마세요.

# install.sh 가 감지한 Wine 경로
WINE_BIN="${WINE_BIN}"

# RCON — 안전 종료 / 접속자 조회 / 자동 재시작 조건에 사용합니다.
# PalWorldSettings.ini 의 AdminPassword 와 반드시 같아야 합니다.
RCON_PASSWORD="${PW}"
EOF
  chmod 600 config.local.sh
  ok "config.local.sh 생성 (권한 600)"
  note "생성된 RCON 비밀번호: $PW"
fi

# ============================================================ 6. 서버 본체
step 6 "팰월드 서버 설치"
if [[ -f "$PAL_EXE_SHIPPING" ]]; then
  skip "서버 본체 ($(du -sh "$PAL_ROOT" 2>/dev/null | cut -f1))"
else
  note "약 5.6GB 를 내려받습니다. 회선에 따라 10~30분 걸릴 수 있습니다."
  confirm "지금 다운로드할까요?" || die "서버 본체 없이는 사용할 수 없습니다."
  ./install_update.sh || die "서버 설치 실패"
fi

# --- RCON 설정을 ini 에 반영 (기존 값이 비어 있을 때만) ---
source ./config.sh   # 방금 만든 config.local.sh 를 반영
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

# ============================================================ 7. GUI 앱
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

# ============================================================ 완료
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
