#!/usr/bin/env bash
# ==============================================================================
# config.sh - Shared settings and helpers for every script
#   Loaded via `source config.sh`; not meant to be run on its own.
#   For personal settings, create config.local.sh instead of editing this file.
# ==============================================================================
# Everything here exists to be read by the scripts that source this file, so the
# linter cannot see the uses and reports every definition as dead.
# (Careful: a comment line starting with the linter's name is parsed as a
# directive, so that word must not begin a line here.)
# shellcheck disable=SC2034

# ------------------------------------------------------------------ Paths
PAL_ROOT="${PAL_ROOT:-$HOME/PalworldServer}"        # where the server itself lives
STEAMCMD_DIR="${STEAMCMD_DIR:-$HOME/steamcmd}"      # steamcmd install location
BACKUP_DIR="${BACKUP_DIR:-$HOME/palworld_backups}"  # backup archives
LOG_DIR="${LOG_DIR:-$PAL_ROOT/logs}"                # server and script logs
RUN_DIR="${RUN_DIR:-$PAL_ROOT/run}"                 # runtime state (PID file, caches)

PID_FILE="$RUN_DIR/palserver.pid"
SERVER_LOG="$LOG_DIR/palserver.log"
OPS_LOG="$LOG_DIR/operations.log"

# ------------------------------------------------------- Wine / Rosetta
# Wine executable. Point this at whichever compatibility layer you installed:
#   Wine (Homebrew cask):   /usr/local/bin/wine64  or  /opt/homebrew/bin/wine
#   CrossOver:              /Applications/CrossOver.app/Contents/SharedSupport/CrossOver/bin/wine
#   Game Porting Toolkit:   `brew --prefix game-porting-toolkit`/bin/wine64
WINE_BIN="${WINE_BIN:-}"        # empty means detect_wine() searches for it below
export WINEPREFIX="${WINEPREFIX:-$HOME/.palworld_wine}"
export WINEARCH="${WINEARCH:-win64}"                 # PalServer is 64-bit only
export WINEDEBUG="${WINEDEBUG:--all}"                # silence Wine debug spam
export WINEDLLOVERRIDES="${WINEDLLOVERRIDES:-mscoree=d;mshtml=d}"  # no Mono/Gecko prompts

# ------------------------------------------------------------- Server options
STEAM_APPID="2394010"           # Palworld Dedicated Server
GAME_PORT="${GAME_PORT:-8211}"  # UDP; this is what you port-forward
QUERY_PORT="${QUERY_PORT:-27015}"
RCON_PORT="${RCON_PORT:-25575}"
MAX_PLAYERS="${MAX_PLAYERS:-32}"

# PalServer.exe is only a launcher shim, and tracking its child through Wine is
# unreliable. Running the real server binary directly makes PID handling and clean
# shutdown far more dependable.
#   1 = run PalServer-Win64-Shipping.exe directly (recommended)
#   0 = go through the PalServer.exe launcher
USE_SHIPPING_EXE="${USE_SHIPPING_EXE:-1}"

# Server arguments, including UE5 dedicated-server threading flags.
SERVER_ARGS=(
  "-port=${GAME_PORT}"
  "-publicport=${GAME_PORT}"
  "-queryport=${QUERY_PORT}"
  "-players=${MAX_PLAYERS}"
  "-useperfthreads"
  "-NoAsyncLoadingThread"
  "-UseMultithreadForDS"
  "-NoSound"           # a dedicated server needs no audio; avoids Wine's audio stack
)

# ------------------------------------------------------------------ RCON
# Used for safe shutdown (flush the save, then stop).
# Requires RCONEnabled=True and an AdminPassword in PalWorldSettings.ini.
RCON_HOST="${RCON_HOST:-127.0.0.1}"
RCON_PASSWORD="${RCON_PASSWORD:-}"       # set this in config.local.sh
RCON_SHUTDOWN_DELAY="${RCON_SHUTDOWN_DELAY:-30}"   # seconds of shutdown warning

# ------------------------------------------------------------------ Backup policy
BACKUP_RETENTION_DAYS="${BACKUP_RETENTION_DAYS:-14}"  # delete backups older than this
BACKUP_RETENTION_MIN="${BACKUP_RETENTION_MIN:-10}"    # but always keep at least this many

# Housekeeping for the files nothing else cleans up. backup_save.sh applies these
# on every run, since it is the one script that goes round on a schedule.
PRERESTORE_RETENTION_MIN="${PRERESTORE_RETENTION_MIN:-3}"  # pre-restore snapshots to keep
INI_BACKUP_KEEP="${INI_BACKUP_KEEP:-10}"                   # PalWorldSettings.ini.bak_* to keep

# --------------------------------------------------- Derived paths (do not edit)
PAL_EXE_LAUNCHER="$PAL_ROOT/PalServer.exe"
PAL_EXE_SHIPPING="$PAL_ROOT/Pal/Binaries/Win64/PalServer-Win64-Shipping.exe"
SAVED_DIR="$PAL_ROOT/Pal/Saved"
SAVEGAMES_DIR="$SAVED_DIR/SaveGames/0"
CONFIG_DIR="$SAVED_DIR/Config/WindowsServer"
SETTINGS_INI="$CONFIG_DIR/PalWorldSettings.ini"
DEFAULT_SETTINGS_INI="$PAL_ROOT/DefaultPalWorldSettings.ini"

# ============================================================== Shared helpers

_c_reset=$'\033[0m'; _c_red=$'\033[31m'; _c_grn=$'\033[32m'
_c_ylw=$'\033[33m';  _c_blu=$'\033[34m'; _c_dim=$'\033[2m'

log()   { printf '%s[%s]%s %s\n' "$_c_dim" "$(date '+%Y-%m-%d %H:%M:%S')" "$_c_reset" "$*"; }
info()  { printf '%s==>%s %s\n'  "$_c_blu" "$_c_reset" "$*"; }
ok()    { printf '%s ✔%s  %s\n'  "$_c_grn" "$_c_reset" "$*"; }
warn()  { printf '%s ⚠%s  %s\n'  "$_c_ylw" "$_c_reset" "$*" >&2; }
die()   { printf '%s ✘%s  %s\n'  "$_c_red" "$_c_reset" "$*" >&2; exit 1; }

# Also record to a file for non-interactive runs such as cron
audit() {
  mkdir -p "$LOG_DIR"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$OPS_LOG"
  trim_log "$OPS_LOG"
}

ensure_dirs() { mkdir -p "$PAL_ROOT" "$BACKUP_DIR" "$LOG_DIR" "$RUN_DIR"; }

# --- Append-only log trimming ------------------------------------------------
# operations.log, auto_restart.log and cron.log are appended to forever, so on a
# long-lived server they grow without limit. Rotating them on a schedule needs a
# scheduler; keeping the tail is enough for logs nobody reads in full.
LOG_MAX_BYTES="${LOG_MAX_BYTES:-2097152}"   # 2 MB
LOG_KEEP_LINES="${LOG_KEEP_LINES:-2000}"
trim_log() {
  local f="$1" size
  [[ -f "$f" ]] || return 0
  size="$(stat -f %z "$f" 2>/dev/null || echo 0)"
  [[ "$size" -gt "$LOG_MAX_BYTES" ]] || return 0
  # Rewrite in place rather than mv'ing a new file over it. cron and tee hold
  # these logs open with O_APPEND for the length of a run; replacing the file
  # would leave them writing to an unlinked inode and lose the rest of that run.
  if tail -n "$LOG_KEEP_LINES" "$f" > "$f.trim" 2>/dev/null; then
    cat "$f.trim" > "$f" && rm -f "$f.trim"
  fi
}

# --- Single-writer lock ------------------------------------------------------
# Start, stop, backup, restore and update all move the same save files around,
# and there are three ways to trigger them at once (the app, cron and a
# terminal). macOS ships no flock(1), so the lock is a symlink.
#
# Why a symlink and not a lock directory: `ln -s` is atomic *and* publishes its
# payload in the same step. A directory would have to be created first and
# stamped with its owner second, leaving a window where the lock exists with no
# owner — and a second process arriving in that window cannot tell "just taken"
# from "left behind by a crash". The link's target text carries the owner from
# the instant it exists. (The target names no real file; it is pure payload.)
#
# The owner token is "PID|process-start-time|label". The start time is what makes
# stale detection trustworthy: a bare `kill -0` on a recycled PID reports a lock
# as live forever, which would block every backup until an unrelated process
# happened to exit.
#
# Re-entrant across scripts: auto_restart.sh calls backup/stop/start, and each
# would otherwise deadlock on the lock its own parent holds. The holder exports
# PAL_LOCK_HELD, so child scripts see it and skip straight through.
LOCK_LINK="${LOCK_LINK:-$RUN_DIR/ops.lock}"
LOCK_WAIT="${LOCK_WAIT:-300}"          # seconds to wait for a busy lock

# Process start time, as ps reports it. Empty for a PID that no longer exists.
_proc_started() { ps -o lstart= -p "$1" 2>/dev/null | tr -s ' '; }

release_lock() {
  # Only the process that took the lock may drop it.
  [[ "${PAL_LOCK_HELD:-}" == "$$" ]] || return 0
  rm -f "$LOCK_LINK"
  unset PAL_LOCK_HELD
}

# Usage: acquire_lock "backup"   (dies if another operation holds it too long)
acquire_lock() {
  local label="${1:-operation}" waited=0 spins=0 token owner rest owner_pid owner_start owner_label
  [[ -n "${PAL_LOCK_HELD:-}" ]] && return 0     # inherited from the parent script

  mkdir -p "$RUN_DIR"
  token="$$|$(_proc_started $$)|$label"

  while ! ln -s "$token" "$LOCK_LINK" 2>/dev/null; do
    owner="$(readlink "$LOCK_LINK" 2>/dev/null || true)"
    owner_pid="${owner%%|*}"
    rest="${owner#*|}"; owner_start="${rest%|*}"; owner_label="${owner##*|}"

    if [[ -n "$owner" ]] \
       && { [[ ! "$owner_pid" =~ ^[0-9]+$ ]] || [[ "$(_proc_started "$owner_pid")" != "$owner_start" ]]; }; then
      # The owner is gone, or its PID now belongs to something else.
      warn "Clearing a stale lock left by ${owner_label:-a previous run}"
      rm -f "$LOCK_LINK"
    elif [[ -n "$owner" ]]; then
      [[ $waited -eq 0 ]] && info "Waiting for '${owner_label}' (PID $owner_pid) to finish..."
      [[ $waited -ge $LOCK_WAIT ]] && die "'${owner_label}' (PID $owner_pid) has held the lock for ${LOCK_WAIT}s.
    Wait for it, or remove the lock by hand: rm -f '$LOCK_LINK'"
      sleep 2; waited=$((waited + 2))     # counts real seconds, so the message above is true
    fi
    # Falling through without sleeping is the fast path: either the lock was
    # released between ln and readlink, or a stale one was just cleared. Both
    # should retry at once — but a retry that never settles must still end.
    spins=$((spins + 1))
    [[ $spins -gt 1000 ]] && die "Gave up taking the lock after $spins attempts."
  done

  export PAL_LOCK_HELD="$$"
  # A bare `trap release_lock INT` would drop the lock and then carry on running
  # unlocked, so the signal traps exit as well.
  trap release_lock EXIT
  trap 'release_lock; exit 130' INT
  trap 'release_lock; exit 143' TERM
}

# --- Connection addresses ----------------------------------------------------
# LAN IP. Hard-coding en0 misses wired/wireless setups, so ask the routing table
# which interface the default route actually uses.
lan_ip() {
  local iface ip
  iface="$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')"
  if [[ -n "$iface" ]]; then
    ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
    [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
  fi
  # Fallback: first interface that has an IPv4 address
  for iface in $(ifconfig -l 2>/dev/null); do
    ip="$(ipconfig getifaddr "$iface" 2>/dev/null)"
    [[ -n "$ip" ]] && { printf '%s' "$ip"; return 0; }
  done
  return 1
}

# mDNS hostname (.local). Survives DHCP address changes on the same network, so it
# is a steadier thing to hand out than a raw IP.
local_hostname() {
  local h
  h="$(scutil --get LocalHostName 2>/dev/null)"
  [[ -n "$h" ]] && printf '%s.local' "$h"
}

# Public IP. Calls an external service, so it is never fetched automatically —
# only on explicit request.
public_ip() {
  curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null
}

# --- Wine discovery ----------------------------------------------------------
detect_wine() {
  if [[ -n "$WINE_BIN" ]]; then
    [[ -x "$WINE_BIN" ]] || die "WINE_BIN is not executable: $WINE_BIN"
    return 0
  fi
  # Notes on the search order:
  #  - gcenx/wine's game-porting-toolkit cask links wine64 into brew's bin.
  #  - Apple's official GPTK formula installs under the Rosetta x86_64 brew
  #    (/usr/local), not the arm64 one (/opt/homebrew), so it needs its own entry.
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
  detect_wine || die "Wine not found. Run ./setup.sh first, or set WINE_BIN in config.local.sh."
}

# --- Server process state ----------------------------------------------------
# Check that the PID file points at a PalServer process that is actually alive
server_pid() {
  [[ -f "$PID_FILE" ]] || return 1
  local pid; pid="$(cat "$PID_FILE" 2>/dev/null)"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

# Fallback lookup by process name when the PID file is missing or stale
server_pid_by_name() {
  pgrep -f 'PalServer-Win64-Shipping\.exe|PalServer\.exe' 2>/dev/null | head -n1
}

is_running() { server_pid >/dev/null 2>&1; }

# --- RCON client (Source RCON protocol, plain python3) -----------------------
# Usage: rcon_cmd "Save"  /  rcon_cmd "Shutdown 30 restarting"
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
            raise ConnectionError("RCON connection closed early")
        buf += chunk
    return buf

def recv_up_to(sock, n, settle=0.35):
    """Read up to n bytes, returning whatever arrived if the rest never comes.

    [Palworld server bug] When the response body contains non-ASCII text the server
    declares a length larger than what it actually sends (Info: declared 74, sent 58).
    Waiting for the declared length means waiting for bytes that never arrive, ending
    in a timeout — a player with a non-ASCII nickname trips this via ShowPlayers.

    Mis-declared responses still carry the packet terminator (00 00), so reading stops
    there. `settle` is the safety net for when even the terminator never shows up.
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
            break                     # terminator reached; declared length is irrelevant
        if len(buf) < n:
            sock.settimeout(settle)   # no terminator yet: wait only briefly for more
    return buf

def read_packet(sock, timeout=8):
    # Restore the timeout recv_up_to lowered, so it doesn't leak into the next packet.
    sock.settimeout(timeout)
    size = struct.unpack("<i", recv_exact(sock, 4))[0]
    data = recv_up_to(sock, size)
    if len(data) < 8:
        raise ConnectionError(f"RCON response too short ({len(data)} bytes)")
    req_id, typ = struct.unpack("<ii", data[:8])
    # Lengths can be wrong, so strip trailing nulls by scanning rather than by count.
    return req_id, typ, data[8:].rstrip(b"\x00").decode("utf-8", "replace")

try:
    with socket.create_connection((host, port), timeout=8) as s:
        s.settimeout(8)
        s.sendall(pack(1, SERVERDATA_AUTH, pw))
        rid, _, _ = read_packet(s)
        if rid == -1:
            print("RCON auth failed: check AdminPassword", file=sys.stderr)
            sys.exit(4)
        s.sendall(pack(2, SERVERDATA_EXECCOMMAND, cmd))
        _, _, body = read_packet(s)
        if body.strip():
            print(body.strip())
except Exception as e:
    print(f"RCON error: {e}", file=sys.stderr)
    sys.exit(5)
PY
}

# --- Load local overrides (personal settings, kept out of git) ---------------
_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ -f "$_here/config.local.sh" ]]; then
  source "$_here/config.local.sh"
fi

# This file must end with exit status 0: under `set -e`, a sourced file returning
# non-zero would abort the calling script immediately.
:
