#!/usr/bin/env bash
# ==============================================================================
# status.sh - 서버 상태 점검
#   PID / CPU / RAM / 가동시간 / UDP 8211 바인딩 / 접속자 / 세이브 크기 / 백업 현황
#
#   사용법:
#     ./status.sh            # 상태 요약
#     ./status.sh --watch    # 5초 간격 실시간 갱신
#     ./status.sh --log      # 서버 로그 tail
# ==============================================================================
set -uo pipefail   # 상태 조회는 일부 실패해도 계속 진행해야 하므로 -e 제외
cd "$(dirname "${BASH_SOURCE[0]}")"
source ./config.sh

# ---------------------------------------------------------------- JSON 출력
# GUI 앱 등 기계 소비자용. 사람용 출력은 색코드가 섞여 파싱이 취약하므로 분리합니다.
emit_json() {
  # --no-rcon: 접속자 조회를 생략합니다. RCON 호출은 bash+python3 기동 때문에
  # 약 260ms 가 들어 이 스크립트 전체 시간의 대부분을 차지하는데,
  # GUI 앱은 접속자를 네이티브 RCON(약 34ms)으로 직접 조회하므로 중복입니다.
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

  # 접속자 목록 (RCON 이 살아있을 때만)
  player_count=0; players_json="[]"
  if [[ "$skip_rcon" != "--no-rcon" && -n "$RCON_PASSWORD" && -n "$pid" && "$rcon_up" == "true" ]]; then
    local raw; raw="$(rcon_cmd "ShowPlayers" 2>/dev/null || true)"
    if [[ -n "$raw" ]]; then
      players_json="$(printf '%s\n' "$raw" | tail -n +2 | awk -F, '
        NF>1 && $1 != "" {
          gsub(/"/, "", $1)
          printf "%s\"%s\"", (n++ ? "," : ""), $1
        } END { }' )"
      players_json="[${players_json}]"
      player_count="$(printf '%s\n' "$raw" | tail -n +2 | grep -c . )"
    fi
  fi

  save_bytes=0
  [[ -d "$SAVEGAMES_DIR" ]] && save_bytes="$(du -sk "$SAVEGAMES_DIR" 2>/dev/null | cut -f1)" && save_bytes=$(( save_bytes * 1024 ))

  world_json="$(ls -1 "$SAVEGAMES_DIR" 2>/dev/null | awk '{printf "%s\"%s\"", (n++ ? "," : ""), $0}')"
  world_json="[${world_json}]"

  latest_backup="$(ls -1t "$BACKUP_DIR"/palworld_backup_*.tar.gz 2>/dev/null | head -n1 || true)"
  backup_count="$(ls -1 "$BACKUP_DIR"/palworld_backup_*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"

  # 설치된 빌드 번호. 매니페스트를 읽을 뿐이라 네트워크를 타지 않습니다.
  # 최신 버전과의 비교는 비용이 커서 update_check.sh 가 따로 담당합니다.
  local installed_build=""
  local manifest="$PAL_ROOT/steamapps/appmanifest_${STEAM_APPID}.acf"
  [[ -f "$manifest" ]] && installed_build="$(awk '/"buildid"/ {gsub(/"/,"",$2); print $2; exit}' "$manifest" 2>/dev/null)"

  printf '{'
  printf '"running":%s,'      "$([[ -n "$pid" ]] && echo true || echo false)"
  printf '"pid":%s,'          "${pid:-0}"
  printf '"cpuPercent":%s,'   "${cpu:-0}"
  printf '"memoryMB":%s,'     "$rss_mb"
  printf '"uptime":"%s",'     "${etime:-}"
  printf '"portBound":%s,'    "$port_bound"
  printf '"rconListening":%s,' "$rcon_up"
  printf '"playerCount":%s,'  "${player_count:-0}"
  printf '"players":%s,'      "$players_json"
  printf '"saveBytes":%s,'    "${save_bytes:-0}"
  printf '"worlds":%s,'       "$world_json"
  printf '"latestBackup":"%s",' "$(basename "${latest_backup:-}" 2>/dev/null)"
  printf '"backupCount":%s,'  "${backup_count:-0}"
  printf '"gamePort":%s,'     "$GAME_PORT"
  printf '"rconPort":%s,'     "$RCON_PORT"
  # 접속 주소. 공인 IP 는 외부 요청이 나가므로 여기 포함하지 않습니다
  # (--public-ip 로 명시적으로 조회하세요).
  printf '"lanIP":"%s",'      "$(lan_ip || true)"
  printf '"localHostname":"%s",' "$(local_hostname || true)"
  printf '"installedBuild":"%s",' "$installed_build"
  printf '"rconConfigured":%s' "$([[ -n "$RCON_PASSWORD" ]] && echo true || echo false)"
  printf '}\n'
}

case "${1:-}" in
  --json) emit_json "${2:-}"; exit 0 ;;
  --address|--ip)
    # 지인들에게 알려 줄 접속 주소를 한눈에.
    info "접속 주소"
    ip="$(lan_ip || true)"; host="$(local_hostname || true)"
    [[ -n "$ip"   ]] && printf '  같은 공유기 안 : %s%s:%s%s\n' "$_c_grn" "$ip" "$GAME_PORT" "$_c_reset"
    [[ -n "$host" ]] && printf '  같은 공유기 안 : %s%s:%s%s  (IP 가 바뀌어도 유지됨)\n' \
                        "$_c_grn" "$host" "$GAME_PORT" "$_c_reset"
    # 진행 표시는 터미널일 때만. 파이프/로그로 넘어가면 \r 이 지워지지 않아
    # 출력이 지저분해집니다.
    if [[ -t 1 ]]; then printf '  외부(인터넷)   : 공인 IP 조회 중...'; fi
    pub="$(public_ip || true)"
    if [[ -t 1 ]]; then printf '\r%*s\r' 60 ''; fi
    if [[ -n "$pub" ]]; then
      printf '  외부(인터넷)   : %s%s:%s%s\n' "$_c_grn" "$pub" "$GAME_PORT" "$_c_reset"
      printf '                   %s공유기에서 UDP %s 포트포워딩이 되어 있어야 합니다%s\n' \
             "$_c_dim" "$GAME_PORT" "$_c_reset"
    else
      printf '  외부(인터넷)   : 공인 IP 조회 실패 (네트워크 확인)          \n'
    fi
    exit 0 ;;
  --watch)
    command -v watch >/dev/null 2>&1 \
      && exec watch -n5 --color "$PWD/status.sh" \
      || while :; do clear; "$0"; sleep 5; done ;;
  --log)
    [[ -f "$SERVER_LOG" ]] || die "로그 파일이 없습니다: $SERVER_LOG"
    exec tail -f "$SERVER_LOG" ;;
  "") ;;
  *) die "알 수 없는 옵션: $1 (--watch | --log | --address | --json)" ;;
esac

hr() { printf '%s\n' "════════════════════════════════════════════════════════════"; }
row() { printf '  %-16s %s\n' "$1" "$2"; }

hr
printf '  Palworld Dedicated Server — 상태 (%s)\n' "$(date '+%Y-%m-%d %H:%M:%S')"
hr

# ------------------------------------------------------------------ 프로세스
pid="$(server_pid || true)"
orphan=""
if [[ -z "$pid" ]]; then
  orphan="$(server_pid_by_name || true)"
fi

if [[ -n "$pid" ]]; then
  printf '%s ● 실행 중%s\n' "$_c_grn" "$_c_reset"
elif [[ -n "$orphan" ]]; then
  printf '%s ● 실행 중 (PID 파일 불일치)%s\n' "$_c_ylw" "$_c_reset"
  pid="$orphan"
else
  printf '%s ● 정지됨%s\n' "$_c_red" "$_c_reset"
fi
echo

if [[ -n "$pid" ]]; then
  # ps 로 CPU%, RSS(KB), 경과시간, 시작시각을 한 번에 조회
  read -r p_cpu p_rss p_etime p_start <<<"$(ps -o %cpu=,rss=,etime=,lstart= -p "$pid" 2>/dev/null | awk '{printf "%s %s %s %s", $1, $2, $3, substr($0, index($0,$4))}')"

  row "PID"        "$pid"
  row "CPU 점유율"  "${p_cpu:-?} %"

  # RSS 는 KB 단위 → MB/GB 로 환산 (메모리 누수 추적의 핵심 지표)
  if [[ -n "${p_rss:-}" ]]; then
    rss_mb=$(( p_rss / 1024 ))
    if (( rss_mb >= 1024 )); then
      row "메모리(RSS)" "$(awk -v m="$rss_mb" 'BEGIN{printf "%.2f GB (%d MB)", m/1024, m}')"
    else
      row "메모리(RSS)" "${rss_mb} MB"
    fi
    # 팰월드는 장시간 가동 시 RSS 가 계속 증가하는 경향이 있습니다.
    if (( rss_mb >= 12288 )); then
      printf '  %s⚠ 메모리 사용량이 12GB 를 넘었습니다. 재시작을 권장합니다.%s\n' "$_c_red" "$_c_reset"
    elif (( rss_mb >= 8192 )); then
      printf '  %s⚠ 메모리 사용량 8GB 초과 — 누수 진행 중일 수 있습니다.%s\n' "$_c_ylw" "$_c_reset"
    fi
  fi

  row "가동 시간"   "${p_etime:-?}"
  row "시작 시각"   "${p_start:-?}"

  # 설치된 빌드 (최신 여부는 ./update_check.sh 가 판정)
  _mf="$PAL_ROOT/steamapps/appmanifest_${STEAM_APPID}.acf"
  if [[ -f "$_mf" ]]; then
    row "설치 빌드" "$(awk '/"buildid"/ {gsub(/"/,"",$2); print $2; exit}' "$_mf")"
  fi

  # Wine 은 자식 프로세스를 여럿 만듭니다. 전체 합계도 같이 봅니다.
  total_rss="$(ps -axo rss=,command= 2>/dev/null | grep -E 'PalServer|wineserver' | grep -v grep | awk '{s+=$1} END {print int(s/1024)}')"
  [[ -n "$total_rss" && "$total_rss" != "0" ]] && row "Wine 전체 RAM" "${total_rss} MB"
else
  row "PID"        "-"
fi

echo
# ------------------------------------------------------------------ 포트 상태
if lsof -nP -iUDP:"$GAME_PORT" >/dev/null 2>&1; then
  printf '  %s✔%s UDP %s  바인딩됨 (게임 포트)\n' "$_c_grn" "$_c_reset" "$GAME_PORT"
  lsof -nP -iUDP:"$GAME_PORT" 2>/dev/null | awk 'NR>1 {printf "      %s (PID %s)\n", $1, $2}' | sort -u
else
  printf '  %s✘%s UDP %s  바인딩 안 됨 — 외부 접속 불가\n' "$_c_red" "$_c_reset" "$GAME_PORT"
fi

if lsof -nP -iTCP:"$RCON_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  printf '  %s✔%s TCP %s  RCON 대기 중\n' "$_c_grn" "$_c_reset" "$RCON_PORT"
else
  printf '  %s·%s TCP %s  RCON 비활성 (PalWorldSettings.ini 의 RCONEnabled 확인)\n' "$_c_dim" "$_c_reset" "$RCON_PORT"
fi

# 접속 주소 — 지인들에게 그대로 불러 줄 수 있게 표시합니다.
# 공인 IP 는 외부 요청이 나가므로 여기서는 조회하지 않습니다 (./status.sh --address).
_lan="$(lan_ip || true)"; _host="$(local_hostname || true)"
if [[ -n "$_lan" || -n "$_host" ]]; then
  echo
  [[ -n "$_lan"  ]] && row "접속 주소" "$_lan:$GAME_PORT"
  [[ -n "$_host" ]] && row ""         "$_host:$GAME_PORT"
  printf '      %s외부 접속 주소는 ./status.sh --address%s\n' "$_c_dim" "$_c_reset"
fi

# ------------------------------------------------------- RCON 으로 접속자 조회
if [[ -n "$RCON_PASSWORD" ]] && [[ -n "$pid" ]]; then
  echo
  players="$(rcon_cmd "ShowPlayers" 2>/dev/null || true)"
  if [[ -n "$players" ]]; then
    # 첫 줄은 CSV 헤더(name,playeruid,steamid)
    n=$(( $(printf '%s\n' "$players" | grep -c . ) - 1 ))
    (( n < 0 )) && n=0
    row "접속자 수" "$n 명"
    printf '%s\n' "$players" | tail -n +2 | awk -F, 'NF>1 {printf "      %s\n", $1}'
  fi
fi

echo
hr
# ------------------------------------------------------------ 세이브 / 백업
if [[ -d "$SAVEGAMES_DIR" ]]; then
  row "세이브 경로" "$SAVEGAMES_DIR"
  row "세이브 크기" "$(du -sh "$SAVEGAMES_DIR" 2>/dev/null | cut -f1)"
  ls -1 "$SAVEGAMES_DIR" 2>/dev/null | while read -r w; do
    printf '      월드 %s (최종수정 %s)\n' "$w" \
      "$(stat -f '%Sm' -t '%Y-%m-%d %H:%M' "$SAVEGAMES_DIR/$w" 2>/dev/null)"
  done
else
  row "세이브 경로" "없음 (미기동 상태)"
fi

latest_backup="$(ls -1t "$BACKUP_DIR"/palworld_backup_*.tar.gz 2>/dev/null | head -n1 || true)"
if [[ -n "$latest_backup" ]]; then
  cnt="$(ls -1 "$BACKUP_DIR"/palworld_backup_*.tar.gz 2>/dev/null | wc -l | tr -d ' ')"
  row "최근 백업" "$(basename "$latest_backup") ($(du -h "$latest_backup" | cut -f1))"
  row "백업 개수" "${cnt}개"
else
  row "최근 백업" "없음 — ./backup_save.sh 실행 권장"
fi

# ------------------------------------------------------------------ 로그 꼬리
if [[ -f "$SERVER_LOG" ]]; then
  echo
  printf '  %s최근 로그 5줄%s (전체: ./status.sh --log)\n' "$_c_dim" "$_c_reset"
  tail -n 5 "$SERVER_LOG" 2>/dev/null | sed 's/^/      /'
fi
hr
