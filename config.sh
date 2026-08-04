#!/usr/bin/env bash
# ==============================================================================
# config.sh - 모든 스크립트가 공유하는 설정 및 공통 함수
#   다른 스크립트에서 `source config.sh` 로 불러 씁니다. 단독 실행하지 마세요.
#   개인 설정은 이 파일을 고치지 말고 config.local.sh 를 만들어 덮어쓰세요.
# ==============================================================================

# ------------------------------------------------------------------ 경로 설정
PAL_ROOT="${PAL_ROOT:-$HOME/PalworldServer}"        # 서버 본체 설치 위치
STEAMCMD_DIR="${STEAMCMD_DIR:-$HOME/steamcmd}"      # steamcmd 설치 위치
BACKUP_DIR="${BACKUP_DIR:-$HOME/palworld_backups}"  # 백업 tar.gz 보관 위치
LOG_DIR="${LOG_DIR:-$PAL_ROOT/logs}"                # 서버/스크립트 로그
RUN_DIR="${RUN_DIR:-$PAL_ROOT/run}"                 # PID 파일 등 런타임 상태

PID_FILE="$RUN_DIR/palserver.pid"
SERVER_LOG="$LOG_DIR/palserver.log"
OPS_LOG="$LOG_DIR/operations.log"

# ------------------------------------------------------- Wine / Rosetta 설정
# Wine 실행 파일. 설치한 호환 레이어에 맞춰 아래 중 하나로 지정하세요.
#   Wine (Homebrew cask):   /usr/local/bin/wine64  또는 /opt/homebrew/bin/wine
#   CrossOver:              /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine
#   Game Porting Toolkit:   `brew --prefix game-porting-toolkit`/bin/wine64
WINE_BIN="${WINE_BIN:-}"        # 비우면 아래 detect_wine() 이 자동 탐색
export WINEPREFIX="${WINEPREFIX:-$HOME/.palworld_wine}"
export WINEARCH="${WINEARCH:-win64}"                 # PalServer 는 64bit 전용
export WINEDEBUG="${WINEDEBUG:--all}"                # Wine 디버그 스팸 억제
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree=d;mshtml=d}"  # 모노/게코 팝업 차단

# ------------------------------------------------------------- 서버 실행 옵션
STEAM_APPID="2394010"           # Palworld Dedicated Server
GAME_PORT="${GAME_PORT:-8211}"  # UDP. 공유기 포트포워딩 대상
QUERY_PORT="${QUERY_PORT:-27015}"
RCON_PORT="${RCON_PORT:-25575}"
MAX_PLAYERS="${MAX_PLAYERS:-32}"

# PalServer.exe 는 런처 껍데기라 Wine 에서 자식 프로세스 추적이 어렵습니다.
# 실제 서버 바이너리를 직접 띄우는 쪽이 PID 관리/정상 종료에 훨씬 안정적입니다.
#   1 = PalServer-Win64-Shipping.exe 직접 실행 (권장)
#   0 = PalServer.exe 런처 경유
USE_SHIPPING_EXE="${USE_SHIPPING_EXE:-1}"

# 서버 실행 인자. UE5 서버 스레딩 최적화 플래그 포함.
SERVER_ARGS=(
  "-port=${GAME_PORT}"
  "-publicport=${GAME_PORT}"
  "-queryport=${QUERY_PORT}"
  "-players=${MAX_PLAYERS}"
  "-useperfthreads"
  "-NoAsyncLoadingThread"
  "-UseMultithreadForDS"
  "-NoSound"           # 데디 서버는 오디오 불필요. Wine 오디오 스택 회피
)

# ------------------------------------------------------------------ RCON 설정
# 안전 종료(세이브 플러시 후 종료)에 사용합니다.
# PalWorldSettings.ini 에서 RCONEnabled=True, AdminPassword 를 설정해야 동작합니다.
RCON_HOST="${RCON_HOST:-127.0.0.1}"
RCON_PASSWORD="${RCON_PASSWORD:-}"       # config.local.sh 에 넣으세요
RCON_SHUTDOWN_DELAY="${RCON_SHUTDOWN_DELAY:-30}"   # 종료 예고 초

# ------------------------------------------------------------------ 백업 정책
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"  # 이보다 오래된 백업 삭제
BACKUP_RETENTION_MIN="${BACKUP_RETENTION_MIN:-10}"    # 단 최소 이 개수는 보존

# --------------------------------------------------- 파생 경로 (수정 불필요)
PAL_EXE_LAUNCHER="$PAL_ROOT/PalServer.exe"
PAL_EXE_SHIPPING="$PAL_ROOT/Pal/Binaries/Win64/PalServer-Win64-Shipping.exe"
SAVED_DIR="$PAL_ROOT/Pal/Saved"
SAVEGAMES_DIR="$SAVED_DIR/SaveGames/0"
CONFIG_DIR="$SAVED_DIR/Config/WindowsServer"
SETTINGS_INI="$CONFIG_DIR/PalWorldSettings.ini"
DEFAULT_SETTINGS_INI="$PAL_ROOT/DefaultPalWorldSettings.ini"

# ============================================================== 공통 유틸 함수

_c_reset=$'\033[0m'; _c_red=$'\033[31m'; _c_grn=$'\033[32m'
_c_ylw=$'\033[33m';  _c_blu=$'\033[34m'; _c_dim=$'\033[2m'

log()   { printf '%s[%s]%s %s\n' "$_c_dim" "$(date '+%Y-%m-%d %H:%M:%S')" "$_c_reset" "$*"; }
info()  { printf '%s==>%s %s\n'  "$_c_blu" "$_c_reset" "$*"; }
ok()    { printf '%s ✔%s  %s\n'  "$_c_grn" "$_c_reset" "$*"; }
warn()  { printf '%s ⚠%s  %s\n'  "$_c_ylw" "$_c_reset" "$*" >&2; }
die()   { printf '%s ✘%s  %s\n'  "$_c_red" "$_c_reset" "$*" >&2; exit 1; }

# cron 등 비대화형 실행에서 파일에도 기록
audit() {
  mkdir -p "$LOG_DIR"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$OPS_LOG"
}

ensure_dirs() { mkdir -p "$PAL_ROOT" "$BACKUP_DIR" "$LOG_DIR" "$RUN_DIR"; }

# --- 접속 주소 ---------------------------------------------------------------
# 내부망 IP. en0 을 하드코딩하면 유선/무선 구성에 따라 빗나가므로,
# 기본 경로가 실제로 쓰는 인터페이스를 먼저 물어봅니다.
lan_ip() {
  local iface ip
  iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  if [[ -n "$iface" ]]; then
    ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
    [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
  fi
  # 폴백: IPv4 가 붙어 있는 첫 인터페이스
  for iface in $(ifconfig -l 2>/dev/null); do
    ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
    [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

# mDNS 호스트명(.local). DHCP 로 IP 가 바뀌어도 같은 망에서는 계속 통하므로
# 지인들에게 알려 주기에는 IP 보다 안정적입니다.
local_hostname() {
  local h
  h="$(scutil --get LocalHostName 2>/dev/null)"
  [[ -n "$h" ]] && printf '%s.local' "$h"
}

# 공인 IP. 외부 서비스에 요청이 나가므로 자동 조회하지 않고,
# 사용자가 명시적으로 요청할 때만 호출합니다.
public_ip() {
  curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null
}

# --- Wine 자동 탐색 -----------------------------------------------------------
detect_wine() {
  if [[ -n "$WINE_BIN" ]]; then
    [[ -x "$WINE_BIN" ]] || die "WINE_BIN 경로가 실행 가능하지 않습니다: $WINE_BIN"
    return 0
  fi
  # 탐색 순서 주의사항:
  #  - gcenx/wine 의 game-porting-toolkit cask 는 wine64 를 brew bin 에 링크합니다.
  #  - Apple 공식 GPTK formula 는 arm64 brew(/opt/homebrew) 가 아니라
  #    Rosetta 모드의 x86_64 brew(/usr/local) 에 설치되므로 경로를 따로 둡니다.
  local candidates=(
    "/Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine"
    "$(brew --prefix 2>/dev/null)/bin/wine64"
    "$(brew --prefix 2>/dev/null)/bin/wine"
    "/Applications/Game Porting Toolkit.app/Contents/Resources/wine/bin/wine64"
    "/usr/local/opt/game-porting-toolkit/bin/wine64"
    "/usr/local/bin/wine64"
    "/usr/local/bin/wine"
  )
  local c
  for c in "${candidates[@]}"; do
    [[ -n "$c" && -x "$c" ]] && { WINE_BIN="$c"; return 0; }
  done
  return 1
}

require_wine() {
  detect_wine || die "Wine 을 찾지 못했습니다. ./setup.sh 를 먼저 실행하거나 config.local.sh 에 WINE_BIN 을 지정하세요."
}

# --- 서버 프로세스 상태 -------------------------------------------------------
# PID 파일이 가리키는 프로세스가 실제로 살아있는 PalServer 인지 확인
server_pid() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

# PID 파일이 없거나 어긋났을 때를 대비한 이름 기반 탐색
server_pid_by_name() {
  pgrep -f 'PalServer-Win64-Shipping\.exe|PalServer\.exe' 2>/dev/null | head -n1
}

is_running() { server_pid >/dev/null 2>&1; }

# --- RCON 클라이언트 (Source RCON 프로토콜, 순수 python3) ---------------------
# 사용: rcon_cmd "Save"  /  rcon_cmd "Shutdown 30 restarting"
rcon_cmd() {
  local cmd="$1"
  [[ -n "$RCON_PASSWORD" ]] || return 2
  command -v python3 >/dev/null 2>&1 || return 3
  RCON_HOST="$RCON_HOST" RCON_PORT="$RCON_PORT" RCON_PASSWORD="$RCON_PASSWORD" \
  RCON_CMD="$cmd" python3 - <<'PY'
import os, socket, struct, sys

host = os.environ["RCON_HOST"]
port = int(os.environ["RCON_PORT"])
pw   = os.environ["RCON_PASSWORD"]
cmd  = os.environ["RCON_CMD"]

SERVERDATA_AUTH, SERVERDATA_EXECCOMMAND = 3, 2

def pack(req_id, typ, body):
    payload = struct.pack("<ii", req_id, typ) + body.encode("utf-8") + b"\x00\x00"
    return struct.pack("<i", len(payload)) + payload

def recv_exact(sock, n):
    buf = b""
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ConnectionError("RCON 연결이 조기에 끊겼습니다")
        buf += chunk
    return buf

def recv_up_to(sock, n, settle=0.35):
    """최대 n 바이트까지 읽되, 더 오지 않으면 받은 만큼만 반환.

    [팰월드 서버 버그 대응] 응답 본문에 비ASCII(한글 등)가 섞이면 서버가
    실제 전송량보다 큰 길이를 헤더에 적습니다 (Info: 선언 74 / 실제 58).
    선언 길이만큼 기다리면 오지 않는 바이트를 기다리다 타임아웃이 납니다.
    한글 닉네임 플레이어가 있으면 ShowPlayers 가 여기에 걸립니다.

    다행히 길이를 잘못 적은 응답도 패킷 종단(00 00)은 붙여 보내므로,
    종단을 만나면 즉시 끝냅니다. settle 은 종단조차 없을 때의 안전망입니다.
    """
    buf = b""
    while len(buf) < n:
        try:
            chunk = sock.recv(n - len(buf))
        except socket.timeout:
            break
        if not chunk:
            break
        buf += chunk
        if len(buf) >= 10 and buf.endswith(b"\x00\x00"):
            break                     # 패킷 종단 도달 — 선언 길이와 무관하게 완료
        if len(buf) < n:
            sock.settimeout(settle)   # 종단이 안 보이면 짧게만 더 기다립니다
    return buf

def read_packet(sock, timeout=8):
    # recv_up_to 가 낮춰 놓은 타임아웃이 다음 패킷까지 남지 않도록 되돌립니다.
    sock.settimeout(timeout)
    size = struct.unpack("<i", recv_exact(sock, 4))[0]
    data = recv_up_to(sock, size)
    if len(data) < 8:
        raise ConnectionError(f"RCON 응답이 너무 짧습니다 ({len(data)}바이트)")
    req_id, typ = struct.unpack("<ii", data[:8])
    # 길이가 어긋날 수 있으므로 끝의 널 바이트를 개수로 자르지 않고 훑어 냅니다.
    return req_id, typ, data[8:].rstrip(b"\x00").decode("utf-8", "replace")

try:
    with socket.create_connection((host, port), timeout=8) as s:
        s.settimeout(8)
        s.sendall(pack(1, SERVERDATA_AUTH, pw))
        rid, _, _ = read_packet(s)
        if rid == -1:
            print("RCON 인증 실패: AdminPassword 를 확인하세요", file=sys.stderr)
            sys.exit(4)
        s.sendall(pack(2, SERVERDATA_EXECCOMMAND, cmd))
        _, _, body = read_packet(s)
        if body.strip():
            print(body.strip())
except Exception as e:
    print(f"RCON 오류: {e}", file=sys.stderr)
    sys.exit(5)
PY
}

# --- 로컬 오버라이드 로드 (git 에 올리지 않는 개인 설정) ---------------------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_here/config.local.sh" ]]; then
  source "$_here/config.local.sh"
fi

# 이 파일의 마지막 종료 코드는 반드시 0 이어야 합니다.
# `set -e` 를 켠 스크립트에서 source 가 0 이 아닌 값을 반환하면 즉시 종료됩니다.
:
