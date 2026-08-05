#!/usr/bin/env bash
# ==============================================================================
# status.sh - Inspect server state
#   PID / CPU / RAM / uptime / UDP 8211 binding / players / save size / backups
#
#   Usage:
#     ./status.sh            # summary
#     ./status.sh --watch    # refresh every 5 seconds
#     ./status.sh --log      # tail the server log
#     ./status.sh --address  # show the addresses players should connect to
#     ./status.sh --json     # machine-readable (used by the app)
# ==============================================================================
set -uo pipefail   # no -e: a partial failure should not abort the whole report
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./config.sh

# ---------------------------------------------------------------- JSON output
# For machine consumers such as the GUI app. Kept separate from the human output,
# which carries colour codes and would be fragile to parse.

# Quote a string as JSON. Player nicknames, world folder names and backup labels
# are arbitrary text, and a single backslash in any of them used to produce
# invalid JSON — which the app cannot decode, so the whole status panel freezes
# rather than showing one odd name.
json_str() {
  local s="${1//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\t'/\\t}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\n'/\\n}"
  printf '"%s"' "$s"
}

# du -sk walks the whole save folder. The app polls every 3 seconds, so on a
# grown world that is a full directory scan several times a minute for a figure
# that changes at autosave speed. Cache it briefly.
SAVE_SIZE_TTL="${SAVE_SIZE_TTL:-30}"
cached_save_bytes() {
  local cache="$RUN_DIR/savesize.cache" age kb bytes
  [[ -d "$SAVEGAMES_DIR" ]] || { printf '0'; return 0; }
  if [[ -f "$cache" ]]; then
    age=$(( $(date +%s) - $(stat -f %m "$cache" 2>/dev/null || echo 0) ))
    if [[ $age -ge 0 && $age -lt $SAVE_SIZE_TTL ]]; then cat "$cache"; return 0; fi
  fi
  kb="$(du -sk "$SAVEGAMES_DIR" 2>/dev/null | cut -f1)"
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  bytes=$(( kb * 1024 ))
  mkdir -p "$RUN_DIR" && printf '%s' "$bytes" > "$cache" 2>/dev/null
  printf '%s' "$bytes"
}

emit_json() {
  # --no-rcon skips the player lookup. Going through bash+python3 costs about
  # 260ms — most of this script's runtime — and the GUI app already queries players
  # over native RCON (about 34ms), so it would be duplicated work.
  local skip_rcon="${1:-}"
  local pid cpu rss_kb rss_mb etime port_bound rcon_up players_json player_count
  local save_bytes world_json latest_backup backup_count

  pid="$(server_pid || server_pid_by_name || true)"
  if [[ -n "$pid" ]]; then
    cpu="$(ps -o %cpu= -p "$pid" 2>/dev/null | tr -d ' ')"
    rss_kb="$(ps -o rss= -p "$pid" 2>/dev/null | tr -d ' ')"
    etime="$(ps -o etime= -p "$pid" 2>/dev/null | tr -d ' ')"
  fi
  rss_mb=$(( ${rss_kb:-0} / 1024 ))

  lsof -nP -iUDP:"$GAME_PORT"                >/dev/null 2>&1 && port_bound=true || port_bound=false
  lsof -nP -iTCP:"$RCON_PORT" -sTCP:LISTEN   >/dev/null 2>&1 && rcon_up=true    || rcon_up=false

  # Player list (only when RCON is up)
  player_count=0; players_json="[]"
  if [[ "$skip_rcon" != "--no-rcon" && -n "$RCON_PASSWORD" && -n "$pid" && "$rcon_up" == "true" ]]; then
    local raw line name acc=""
    raw="$(rcon_cmd "ShowPlayers" 2>/dev/null || true)"
    if [[ -n "$raw" ]]; then
      # ShowPlayers is CSV with a header line; the name is the first field.
      while IFS= read -r line; do
        name="${line%%,*}"
        [[ -n "$name" ]] || continue
        [[ $player_count -gt 0 ]] && acc+=","
        acc+="$(json_str "$name")"
        player_count=$((player_count + 1))
      done < <(printf '%s\n' "$raw" | tail -n +2)
      players_json="[${acc}]"
    fi
  fi

  save_bytes="$(cached_save_bytes)"

  local world acc_w=""
  while IFS= read -r world; do
    [[ -n "$world" ]] || continue
    [[ -n "$acc_w" ]] && acc_w+=","
    acc_w+="$(json_str "$world")"
  done < <(ls -1 "$SAVEGAMES_DIR" 2>/dev/null || true)
  world_json="[${acc_w}]"

  latest_backup="$(ls -1t "$BACKUP_DIR"/palworld_backup_*.tar.gz 2>/dev/null | head -n1 || true)"
  backup_count="$(ls -1 "$BACKUP_DIR"/palworld_backup_*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"

  # Installed build number — just a manifest read, no network.
  # Comparing against the latest is expensive, so update_check.sh handles that.
  local installed_build=""
  local manifest="$PAL_ROOT/steamapps/appmanifest_${STEAM_APPID}.acf"
  [[ -f "$manifest" ]] && installed_build="$(awk '/"buildid"/ {gsub(/"/,"",$2); print $2; exit}' "$manifest" 2>/dev/null)"

  printf '{'
  printf '"running":%s,'      "$([[ -n "$pid" ]] && echo true || echo false)"
  printf '"pid":%s,'          "${pid:-0}"
  printf '"cpuPercent":%s,'   "${cpu:-0}"
  printf '"memoryMB":%s,'     "$rss_mb"
  printf '"uptime":%s,'       "$(json_str "${etime:-}")"
  printf '"portBound":%s,'    "$port_bound"
  printf '"rconListening":%s,' "$rcon_up"
  printf '"playerCount":%s,'  "${player_count:-0}"
  printf '"players":%s,'      "$players_json"
  printf '"saveBytes":%s,'    "${save_bytes:-0}"
  printf '"worlds":%s,'       "$world_json"
  printf '"latestBackup":%s,' "$(json_str "$(basename "${latest_backup:-}" 2>/dev/null)")"
  printf '"backupCount":%s,'  "${backup_count:-0}"
  # Where the backups actually live. BACKUP_DIR is overridable in
  # config.local.sh, and without this the app had no way to know — it guessed
  # ~/palworld_backups and showed an empty list next to a non-zero count.
  printf '"backupDir":%s,'    "$(json_str "$BACKUP_DIR")"
  printf '"gamePort":%s,'     "$GAME_PORT"
  printf '"rconPort":%s,'     "$RCON_PORT"
  # Connection addresses. The public IP is left out because it requires an
  # external request; ask for it explicitly instead.
  printf '"lanIP":%s,'        "$(json_str "$(lan_ip || true)")"
  printf '"localHostname":%s,' "$(json_str "$(local_hostname || true)")"
  printf '"installedBuild":%s,' "$(json_str "$installed_build")"
  printf '"rconConfigured":%s' "$([[ -n "$RCON_PASSWORD" ]] && echo true || echo false)"
  printf '}\n'
}

case "${1:-}" in
  --json) emit_json "${2:-}"; exit 0 ;;
  --address|--ip)
    # The addresses to hand out to players, in one place.
    info "Connection addresses"
    ip="$(lan_ip || true)"; host="$(local_hostname || true)"
    [[ -n "$ip"   ]] && printf '  Same network : %s%s:%s%s\n' "$_c_grn" "$ip" "$GAME_PORT" "$_c_reset"
    [[ -n "$host" ]] && printf '  Same network : %s%s:%s%s  (survives IP changes)\n' \
                        "$_c_grn" "$host" "$GAME_PORT" "$_c_reset"
    # Progress indicator only on a TTY: piped to a file, the \r never clears and
    # leaves the output messy.
    if [[ -t 1 ]]; then printf '  External     : looking up public IP...'; fi
    pub="$(public_ip || true)"
    if [[ -t 1 ]]; then printf '\r%*s\r' 60 ''; fi
    if [[ -n "$pub" ]]; then
      printf '  External     : %s%s:%s%s\n' "$_c_grn" "$pub" "$GAME_PORT" "$_c_reset"
      printf '                 %sRequires UDP %s port forwarding on your router%s\n' \
             "$_c_dim" "$GAME_PORT" "$_c_reset"
    else
      printf '  External     : public IP lookup failed (check the network)   \n'
    fi
    exit 0 ;;
  --watch)
    command -v watch >/dev/null 2>&1 \
      && exec watch -n5 --color "$PWD/status.sh" \
      || while :; do clear; "$0"; sleep 5; done ;;
  --log)
    [[ -f "$SERVER_LOG" ]] || die "No log file: $SERVER_LOG"
    exec tail -f "$SERVER_LOG" ;;
  "") ;;
  *) die "Unknown option: $1 (--watch | --log | --address | --json)" ;;
esac

hr() { printf '%s\n' "════════════════════════════════════════════════════════════"; }
row() { printf '  %-16s %s\n' "$1" "$2"; }

hr
printf '  Palworld Dedicated Server — status (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')"
hr

# ------------------------------------------------------------------ Process
pid="$(server_pid || true)"
orphan=""
if [[ -z "$pid" ]]; then
  orphan="$(server_pid_by_name || true)"
fi

if [[ -n "$pid" ]]; then
  printf '%s ● Running%s\n' "$_c_grn" "$_c_reset"
elif [[ -n "$orphan" ]]; then
  printf '%s ● Running (PID file mismatch)%s\n' "$_c_ylw" "$_c_reset"
  pid="$orphan"
else
  printf '%s ● Stopped%s\n' "$_c_red" "$_c_reset"
fi
echo

if [[ -n "$pid" ]]; then
  # One ps call for CPU%, RSS (KB), elapsed time and start time
  read -r p_cpu p_rss p_etime p_start <<<"$(ps -o %cpu=,rss=,etime=,lstart= -p "$pid" 2>/dev/null | awk '{printf "%s %s %s %s", $1, $2, $3, substr($0, index($0,$4))}')"

  row "PID"        "$pid"
  row "CPU"        "${p_cpu:-?} %"

  # RSS comes in KB; convert to MB/GB — the key signal for tracking leaks
  if [[ -n "${p_rss:-}" ]]; then
    rss_mb=$(( p_rss / 1024 ))
    if (( rss_mb >= 1024 )); then
      row "Memory (RSS)" "$(awk -v m="$rss_mb" 'BEGIN{printf "%.2f GB (%d MB)", m/1024, m}')"
    else
      row "Memory (RSS)" "${rss_mb} MB"
    fi
    # Palworld's RSS tends to climb steadily over long uptimes.
    if (( rss_mb >= 12288 )); then
      printf '  %s⚠ Memory is above 12GB. A restart is recommended.%s\n' "$_c_red" "$_c_reset"
    elif (( rss_mb >= 8192 )); then
      printf '  %s⚠ Memory is above 8GB — a leak may be under way.%s\n' "$_c_ylw" "$_c_reset"
    fi
  fi

  row "Uptime"     "${p_etime:-?}"
  row "Started"    "${p_start:-?}"

  # Installed build (./update_check.sh decides whether it is current)
  _mf="$PAL_ROOT/steamapps/appmanifest_${STEAM_APPID}.acf"
  if [[ -f "$_mf" ]]; then
    row "Build"      "$(awk '/"buildid"/ {gsub(/"/,"",$2); print $2; exit}' "$_mf")"
  fi

  # Wine spawns several child processes, so show the combined total too.
  total_rss="$(ps -axo rss=,command= 2>/dev/null | grep -E 'PalServer|wineserver' | grep -v grep | awk '{s+=$1} END {print int(s/1024)}')"
  [[ -n "$total_rss" && "$total_rss" != "0" ]] && row "Wine total RAM" "${total_rss} MB"
else
  row "PID"        "-"
fi

echo
# ------------------------------------------------------------------ Ports
if lsof -nP -iUDP:"$GAME_PORT" >/dev/null 2>&1; then
  printf '  %s✔%s UDP %s  bound (game port)\n' "$_c_grn" "$_c_reset" "$GAME_PORT"
  lsof -nP -iUDP:"$GAME_PORT" 2>/dev/null | awk 'NR>1 {printf "      %s (PID %s)\n", $1, $2}' | sort -u
else
  printf '  %s✘%s UDP %s  not bound — nobody can connect\n' "$_c_red" "$_c_reset" "$GAME_PORT"
fi

if lsof -nP -iTCP:"$RCON_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  printf '  %s✔%s TCP %s  RCON listening\n' "$_c_grn" "$_c_reset" "$RCON_PORT"
else
  printf '  %s·%s TCP %s  RCON off (check RCONEnabled in PalWorldSettings.ini)\n' "$_c_dim" "$_c_reset" "$RCON_PORT"
fi

# Connection addresses, in a form you can read out to friends directly.
# The public IP is not looked up here since it needs an external request
# (use ./status.sh --address).
_lan="$(lan_ip || true)"; _host="$(local_hostname || true)"
if [[ -n "$_lan" || -n "$_host" ]]; then
  echo
  [[ -n "$_lan"  ]] && row "Address"    "$_lan:$GAME_PORT"
  [[ -n "$_host" ]] && row ""         "$_host:$GAME_PORT"
  printf '      %sFor the external address: ./status.sh --address%s\n' "$_c_dim" "$_c_reset"
fi

# ------------------------------------------------------- Players via RCON
if [[ -n "$RCON_PASSWORD" ]] && [[ -n "$pid" ]]; then
  echo
  players="$(rcon_cmd "ShowPlayers" 2>/dev/null || true)"
  if [[ -n "$players" ]]; then
    # The first line is the CSV header (name,playeruid,steamid)
    n=$(( $(printf '%s\n' "$players" | grep -c . ) - 1 ))
    (( n < 0 )) && n=0
    row "Players"    "$n"
    printf '%s\n' "$players" | tail -n +2 | awk -F, 'NF>1 {printf "      %s\n", $1}'
  fi
fi

echo
hr
# ------------------------------------------------------------ Saves and backups
if [[ -d "$SAVEGAMES_DIR" ]]; then
  row "Save path"  "$SAVEGAMES_DIR"
  row "Save size"  "$(du -sh "$SAVEGAMES_DIR" 2>/dev/null | cut -f1)"
  ls -1 "$SAVEGAMES_DIR" 2>/dev/null | while read -r w; do
    printf '      World %s (modified %s)\n' "$w" \
      "$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$SAVEGAMES_DIR/$w" 2>/dev/null)"
  done
else
  row "Save path"  "none (never started)"
fi

latest_backup="$(ls -1t "$BACKUP_DIR"/palworld_backup_*.tar.gz 2>/dev/null | head -n1 || true)"
if [[ -n "$latest_backup" ]]; then
  cnt="$(ls -1 "$BACKUP_DIR"/palworld_backup_*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  row "Last backup" "$(basename "$latest_backup") ($(du -h "$latest_backup" | cut -f1))"
  row "Backups"    "${cnt}"
else
  row "Last backup" "none — run ./backup_save.sh"
fi

# ------------------------------------------------------------------ Log tail
if [[ -f "$SERVER_LOG" ]]; then
  echo
  printf '  %sLast 5 log lines%s (full log: ./status.sh --log)\n' "$_c_dim" "$_c_reset"
  tail -n 5 "$SERVER_LOG" 2>/dev/null | sed 's/^/      /'
fi
hr
