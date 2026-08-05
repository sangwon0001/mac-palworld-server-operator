#!/usr/bin/env bash
# ==============================================================================
# tests/safety_tests.sh - Regression tests for the parts that can lose data
#
#   uninstall.sh deletes save games and backups, and the run lock is what keeps
#   two operations off the same files. Both were verified by hand once; this
#   keeps them verified. A later edit that quietly widens what gets deleted is
#   exactly the kind of change nobody notices until it is someone's world.
#
#   Everything runs against throwaway directories under a temp folder. No test
#   touches a real install: PAL_ROOT, BACKUP_DIR, WINEPREFIX, STEAMCMD_DIR and
#   APP_PATH are all pointed elsewhere.
#
#   Usage: ./tests/safety_tests.sh
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1
REPO="$PWD"

PASS=0; FAIL=0
c_grn=$'\033[32m'; c_red=$'\033[31m'; c_rst=$'\033[0m'

# Prefixed names on purpose: this file sources config.sh further down, which
# defines ok() and warn() of its own. Plain names were silently replaced, and the
# checks after that point stopped being counted.
t_ok()    { printf '  %s✔%s %s\n' "$c_grn" "$c_rst" "$1"; PASS=$((PASS + 1)); }
t_fail()  { printf '  %s✘%s %s\n' "$c_red" "$c_rst" "$1"; FAIL=$((FAIL + 1)); }
t_group() { printf '\n%s\n' "$1"; }

# check "<description>" <condition-as-command...>
check() { local msg="$1"; shift; if "$@"; then t_ok "$msg"; else t_fail "$msg"; fi; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/palworld-tests.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# A sandbox that looks like a real install, rebuilt fresh for each test.
new_sandbox() {
  local sb="$TMP/sb.$RANDOM"
  rm -rf "$sb"
  mkdir -p "$sb/PalworldServer/Pal/Saved/SaveGames/0/WORLD" "$sb/backups" "$sb/wine"
  echo save    > "$sb/PalworldServer/Pal/Saved/SaveGames/0/WORLD/Level.sav"
  echo archive > "$sb/backups/palworld_backup_20260101_000000.tar.gz"
  echo snap    > "$sb/backups/prerestore_20260101_000000.tar.gz"
  echo notours > "$sb/backups/somebody_elses_file.txt"
  printf '%s' "$sb"
}

# Run uninstall.sh against a sandbox. Extra args after the sandbox are passed on.
uninstall_in() {
  local sb="$1"; shift
  env PAL_ROOT="$sb/PalworldServer" BACKUP_DIR="$sb/backups" WINEPREFIX="$sb/wine" \
      STEAMCMD_DIR="$sb/steamcmd" APP_PATH="$sb/App.app" \
      LOCK_LINK="$sb/ops.lock" \
      "$REPO/uninstall.sh" "$@" </dev/null 2>&1
}

# The backup-deletion confirmation is read from /dev/tty on purpose, so a pipe
# cannot reach it — and without a terminal the script declines, which means the
# deletion path is never exercised at all. Anything that tests what --backups
# actually deletes has to run under a real terminal.
run_with_tty() {
  local cmd="$1" typed="$2"
  python3 - "$cmd" "$typed" <<'PY'
import os, pty, select, sys, time
cmd, typed = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execv("/bin/bash", ["/bin/bash", "-c", cmd])
    os._exit(1)
time.sleep(0.5)
os.write(fd, typed.encode())
out, deadline = b"", time.time() + 30
while time.time() < deadline:
    r, _, _ = select.select([fd], [], [], 0.3)
    if r:
        try:
            chunk = os.read(fd, 4096)
        except OSError:
            break
        if not chunk:
            break
        out += chunk
    else:
        try:
            if os.waitpid(pid, os.WNOHANG)[0]:
                break
        except ChildProcessError:
            break
sys.stdout.write(out.decode(errors="replace"))
PY
}

# The command run_with_tty executes, for a given sandbox.
uninstall_cmd() {
  local sb="$1"; shift
  printf 'cd %q && env PAL_ROOT=%q BACKUP_DIR=%q WINEPREFIX=%q LOCK_LINK=%q %q %s' \
    "$REPO" "$sb/PalworldServer" "$sb/backups" "$sb/wine" "$sb/ops.lock" \
    "$REPO/uninstall.sh" "$*"
}

# ---------------------------------------------------------------- uninstall.sh
t_group "uninstall.sh — what it must never delete"

sb="$(new_sandbox)"
uninstall_in "$sb" >/dev/null
check "report mode deletes nothing" test -f "$sb/PalworldServer/Pal/Saved/SaveGames/0/WORLD/Level.sav"

sb="$(new_sandbox)"
printf 'n\n' | env PAL_ROOT="$sb/PalworldServer" BACKUP_DIR="$sb/backups" \
  WINEPREFIX="$sb/wine" LOCK_LINK="$sb/ops.lock" "$REPO/uninstall.sh" --server >/dev/null 2>&1
check "answering 'n' deletes nothing" test -d "$sb/PalworldServer"

sb="$(new_sandbox)"
uninstall_in "$sb" --server >/dev/null    # stdin is /dev/null: EOF must cancel
check "no answer at all cancels" test -d "$sb/PalworldServer"

# The whole point of --backups being separate from --all.
sb="$(new_sandbox)"
uninstall_in "$sb" --all --yes >/dev/null
check "--all leaves the backups alone" test -f "$sb/backups/palworld_backup_20260101_000000.tar.gz"

sb="$(new_sandbox)"
uninstall_in "$sb" --backups --yes >/dev/null   # no tty, so it must decline
check "no terminal means backups are kept" test -f "$sb/backups/palworld_backup_20260101_000000.tar.gz"

# The one that matters: with a terminal and the word typed, --backups must take
# this toolkit's archives and nothing else. BACKUP_DIR is a user setting, and
# pointing it at a folder that already holds other things must not cost them.
sb="$(new_sandbox)"
run_with_tty "$(uninstall_cmd "$sb" --backups --yes)" 'DELETE
' >/dev/null 2>&1
check "DELETE removes our backup archive"      test ! -f "$sb/backups/palworld_backup_20260101_000000.tar.gz"
check "DELETE removes our pre-restore archive" test ! -f "$sb/backups/prerestore_20260101_000000.tar.gz"
check "unrelated files are never in scope"     test -f "$sb/backups/somebody_elses_file.txt"
check "a folder with other files is kept"      test -d "$sb/backups"

# And the wrong word keeps everything, terminal or not.
sb="$(new_sandbox)"
run_with_tty "$(uninstall_cmd "$sb" --backups --yes)" 'delete
' >/dev/null 2>&1
check "the wrong word keeps the archives" test -f "$sb/backups/palworld_backup_20260101_000000.tar.gz"

# PAL_ROOT pointed somewhere that is not a server.
sb="$(new_sandbox)"
mkdir -p "$sb/documents"; echo tax > "$sb/documents/return.pdf"
env PAL_ROOT="$sb/documents" BACKUP_DIR="$sb/backups" WINEPREFIX="$sb/wine" \
    LOCK_LINK="$sb/ops.lock" "$REPO/uninstall.sh" --server --yes </dev/null >/dev/null 2>&1
check "a folder that is not a server is refused" test -f "$sb/documents/return.pdf"

# Overlapping server and backup folders, both nesting directions.
sb="$(new_sandbox)"
mkdir -p "$sb/PalworldServer/inner-backups"
echo a > "$sb/PalworldServer/inner-backups/palworld_backup_20260101_000000.tar.gz"
env PAL_ROOT="$sb/PalworldServer" BACKUP_DIR="$sb/PalworldServer/inner-backups" \
    WINEPREFIX="$sb/wine" LOCK_LINK="$sb/ops.lock" \
    "$REPO/uninstall.sh" --server --yes </dev/null >/dev/null 2>&1
check "backups inside the server folder blocks --server" \
      test -f "$sb/PalworldServer/inner-backups/palworld_backup_20260101_000000.tar.gz"

sb="$(new_sandbox)"
mkdir -p "$sb/backups/PalworldServer/Pal"
env PAL_ROOT="$sb/backups/PalworldServer" BACKUP_DIR="$sb/backups" \
    WINEPREFIX="$sb/wine" LOCK_LINK="$sb/ops.lock" \
    "$REPO/uninstall.sh" --backups --yes </dev/null >/dev/null 2>&1
check "server inside the backup folder blocks --backups" test -d "$sb/backups/PalworldServer/Pal"

# A custom Wine prefix may be shared with other applications.
sb="$(new_sandbox)"
uninstall_in "$sb" --server --yes --no-final-backup >/dev/null
check "a custom Wine prefix survives --server" test -d "$sb/wine"
check "the server folder itself is removed"     test ! -d "$sb/PalworldServer"

# A final backup that cannot be written must stop the deletion.
sb="$(new_sandbox)"
mkdir -p "$sb/readonly"; chmod 500 "$sb/readonly"
env PAL_ROOT="$sb/PalworldServer" BACKUP_DIR="$sb/readonly/backups" WINEPREFIX="$sb/wine" \
    LOCK_LINK="$sb/ops.lock" "$REPO/uninstall.sh" --server --yes </dev/null >/dev/null 2>&1
check "a failed final backup stops the deletion" test -d "$sb/PalworldServer/Pal"
chmod 700 "$sb/readonly"

# ---------------------------------------------------------------- the run lock
t_group "config.sh — the run lock"

# shellcheck source=/dev/null
LOCK_LINK="$TMP/lock.test" source "$REPO/config.sh"

log="$TMP/critical.log"; : > "$log"
for i in 1 2 3 4 5 6 7 8; do
  ( LOCK_LINK="$TMP/lock.test" bash -c '
      set -euo pipefail
      source "'"$REPO"'/config.sh"
      acquire_lock "worker"
      printf "IN %s\n" '"$i"' >> "'"$log"'"
      sleep 0.15
      printf "OUT %s\n" '"$i"' >> "'"$log"'"' ) &
done >/dev/null 2>&1
wait

overlaps="$(python3 - "$log" <<'PY'
import sys
lines = [l.split() for l in open(sys.argv[1]) if l.strip()]
bad = sum(1 for a, b in zip(lines[::2], lines[1::2])
          if a[0] != "IN" or b[0] != "OUT" or a[1] != b[1])
print(bad if len(lines) == 16 else "wrong-count")
PY
)"
check "eight contenders never overlap in the critical section" test "$overlaps" = "0"

# A lock whose owner died must not block the next run forever.
ln -sf "999999|Mon Jan  1 00:00:00 2020|ghost" "$TMP/lock.test"
LOCK_LINK="$TMP/lock.test" bash -c 'source "'"$REPO"'/config.sh"; acquire_lock "after-dead"' >/dev/null 2>&1
check "a dead owner's lock is cleared" test ! -e "$TMP/lock.test"

# A live PID that is not the original owner (macOS recycles PIDs) is also stale.
sleep 60 & live=$!
ln -sf "$live|Mon Jan  1 00:00:00 2020|impostor" "$TMP/lock.test"
LOCK_LINK="$TMP/lock.test" bash -c 'source "'"$REPO"'/config.sh"; acquire_lock "after-reuse"' >/dev/null 2>&1
check "a recycled PID does not look like a live owner" test ! -e "$TMP/lock.test"
kill "$live" 2>/dev/null

# ------------------------------------------------------------------ status.sh
t_group "status.sh — the JSON the app depends on"

json_ok() {
  local dir="$1"
  BACKUP_DIR="$dir" PAL_ROOT="$TMP/nothing-here" "$REPO/status.sh" --json --no-rcon 2>/dev/null \
    | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null
}
check "valid for an ordinary path"        json_ok "$TMP/backups"
check "valid with a control character"    json_ok "$(printf '%s' "$TMP/a"; printf '\014'; printf 'b')"
check "valid with a non-UTF-8 byte"       json_ok "$(printf '%s' "$TMP/a"; printf '\200'; printf 'b')"
check "valid with Korean and Japanese"    json_ok "$TMP/백업_バックアップ"

# ------------------------------------------------------------------ Result
printf '\n%s%d passed, %d failed%s\n' \
  "$([[ $FAIL -eq 0 ]] && printf '%s' "$c_grn" || printf '%s' "$c_red")" \
  "$PASS" "$FAIL" "$c_rst"
[[ $FAIL -eq 0 ]]
