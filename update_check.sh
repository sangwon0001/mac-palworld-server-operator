#!/usr/bin/env bash
# ==============================================================================
# update_check.sh - Compare the installed version against Steam's latest
#
#   The installed buildid is read straight from steamapps/appmanifest_2394010.acf;
#   the latest buildid comes from `steamcmd +app_info_print`.
#
#   [Design note] The latest-version lookup takes about 6 seconds and calls out to
#   Steam, so it must not ride along with the app's 3-second status poll. Therefore
#     · the result is cached (1 hour by default), and
#     · a warm cache never touches the network.
#   Official steamcmd is used rather than a third-party API to avoid adding a
#   dependency.
#
#   Usage:
#     ./update_check.sh              # human-readable
#     ./update_check.sh --json       # machine-readable (used by the app)
#     ./update_check.sh --force      # ignore the cache and look up again
#     ./update_check.sh --cached     # cache/manifest only, no network (instant)
# ==============================================================================
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

CACHE_TTL="${UPDATE_CACHE_TTL:-3600}"      # seconds
CACHE_FILE="$RUN_DIR/update_check.cache"

MODE="text"; FORCE=0; CACHED_ONLY=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --json)   MODE="json"; shift ;;
    --force)  FORCE=1; shift ;;
    --cached) CACHED_ONLY=1; shift ;;
    -h|--help) sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "알 수 없는 옵션: $1 (--json | --force | --cached)" ;;
  esac
done

mkdir -p "$RUN_DIR"

# ------------------------------------------------------- Installed build (instant)
installed=""
manifest="$PAL_ROOT/steamapps/appmanifest_${STEAM_APPID}.acf"
if [[ -f "$manifest" ]]; then
  installed="$(awk '/"buildid"/ {gsub(/"/,"",$2); print $2; exit}' "$manifest" 2>/dev/null)"
  installed_at="$(awk '/"LastUpdated"/ {gsub(/"/,"",$2); print $2; exit}' "$manifest" 2>/dev/null)"
fi

# ------------------------------------------------------------ Cached latest build
latest=""; checked_at=0
if [[ -f "$CACHE_FILE" ]]; then
  # Format: <buildid> <checked-at epoch>
  read -r latest checked_at < "$CACHE_FILE" 2>/dev/null || true
  [[ "$checked_at" =~ ^[0-9]+$ ]] || checked_at=0
fi

now="$(date +%s)"
age=$(( now - checked_at ))
fresh=0
[[ -n "$latest" && $age -lt $CACHE_TTL ]] && fresh=1

# ---------------------------------------------------------- Refresh if needed
if [[ $CACHED_ONLY -eq 0 ]] && { [[ $FORCE -eq 1 ]] || [[ $fresh -eq 0 ]]; }; then
  if [[ -x "$STEAMCMD_DIR/steamcmd.sh" ]]; then
    STEAMCMD="$STEAMCMD_DIR/steamcmd.sh"
  else
    STEAMCMD="$(command -v steamcmd 2>/dev/null || true)"
  fi

  if [[ -n "$STEAMCMD" ]]; then
    [[ "$MODE" == "text" ]] && info "Steam 에서 최신 버전 조회 중 (약 6초)..."
    # Pull just the public branch's buildid out of app_info_print.
    fetched="$("$STEAMCMD" +login anonymous +app_info_print "$STEAM_APPID" +quit 2>/dev/null \
      | awk '/"branches"/{b=1} b&&/"public"/{p=1} p&&/"buildid"/{gsub(/"/,"",$2); print $2; exit}')"
    if [[ "$fetched" =~ ^[0-9]+$ ]]; then
      latest="$fetched"; checked_at="$now"; age=0; fresh=1
      printf '%s %s\n' "$latest" "$checked_at" > "$CACHE_FILE"
    fi
  fi
fi

# ------------------------------------------------------------------ Verdict
#   up-to-date / update-available / unknown
state="unknown"
if [[ -n "$installed" && -n "$latest" ]]; then
  if [[ "$installed" == "$latest" ]]; then state="up-to-date"; else state="update-available"; fi
fi

if [[ "$MODE" == "json" ]]; then
  printf '{"installedBuild":"%s","latestBuild":"%s","state":"%s","checkedAt":%s,"cacheAgeSeconds":%s,"installedAt":%s}\n' \
    "$installed" "$latest" "$state" "${checked_at:-0}" "$age" "${installed_at:-0}"
  exit 0
fi

# ------------------------------------------------------------------ Human output
fmt_time() { [[ "${1:-0}" -gt 0 ]] && date -r "$1" '+%Y-%m-%d %H:%M' || echo "-"; }

printf '  %-14s %s\n' "설치된 빌드" "${installed:-알 수 없음}"
printf '  %-14s %s\n' "설치 시각"   "$(fmt_time "${installed_at:-0}")"
printf '  %-14s %s\n' "최신 빌드"   "${latest:-조회 실패}"
printf '  %-14s %s\n' "조회 시각"   "$(fmt_time "${checked_at:-0}")"
echo
case "$state" in
  up-to-date)
    ok "최신 버전입니다." ;;
  update-available)
    warn "업데이트가 있습니다: $installed → $latest"
    printf '    ./auto_restart.sh --update    (백업 → 안전 종료 → 업데이트 → 재기동)\n'
    printf '    ./install_update.sh           (서버가 꺼져 있을 때 업데이트만)\n' ;;
  *)
    warn "판정할 수 없습니다. 서버가 설치되어 있는지, 네트워크가 되는지 확인하세요." ;;
esac
