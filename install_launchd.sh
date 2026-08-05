#!/usr/bin/env bash
# ==============================================================================
# install_launchd.sh - Schedule backups and restarts with launchd (macOS native)
#
#   Does the same job as install_cron.sh, the way macOS actually wants it done.
#   Pick one or the other, never both — two schedulers means two backups of the
#   same save and two restarts fighting each other.
#
#   Why prefer this over cron:
#     · No Full Disk Access step. cron is confined by TCC, so its jobs cannot
#       reach your home directory until you add /usr/sbin/cron by hand in System
#       Settings; miss it and the jobs fail silently. A LaunchAgent runs inside
#       your own login session and needs no such grant.
#     · Missed runs are made up. If the Mac is asleep at 05:00, launchd runs the
#       job when it wakes; cron simply skips it.
#     · cron on macOS is deprecated, and has been "for compatibility only" for
#       years.
#
#   The trade-off, honestly: LaunchAgents run in your GUI login session, so
#   nothing fires while nobody is logged in. If this Mac reboots unattended, set
#   it to log in automatically, or use install_cron.sh instead.
#
#   Usage:
#     ./install_launchd.sh --show      # print the jobs that would be installed
#     ./install_launchd.sh --install   # write the agents and load them
#     ./install_launchd.sh --remove    # unload and delete them
#     ./install_launchd.sh --status    # what is loaded right now
# ==============================================================================
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")" || exit 1
source ./config.sh

DIR="$PWD"
AGENT_DIR="$HOME/Library/LaunchAgents"
LABEL_PREFIX="local.palworld"
GUI="gui/$(id -u)"
LAUNCHD_LOG="$LOG_DIR/launchd.log"

# The three jobs, matching install_cron.sh exactly:
#   <label suffix>|<hour, empty for hourly>|<minute>|<script and arguments>
# The hourly backup sits at :30 for the same reason it does in cron — see that
# script's header.
JOBS=(
  "backup||30|backup_save.sh"
  "restart|5|0|auto_restart.sh"
  "restart-if-over|6|0|auto_restart.sh --if-over 8192 --if-empty"
)

# Paths and arguments go inside XML, and a home directory containing & or < would
# otherwise produce a plist launchd refuses to parse.
xml_escape() {
  local s="${1//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  printf '%s' "$s"
}

plist_for() {
  local suffix="$1" hour="$2" minute="$3" argv="$4"
  local label="$LABEL_PREFIX.$suffix" arg

  printf '<?xml version="1.0" encoding="UTF-8"?>\n'
  printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
  printf '<plist version="1.0">\n<dict>\n'
  printf '  <key>Label</key><string>%s</string>\n' "$label"

  printf '  <key>ProgramArguments</key>\n  <array>\n'
  printf '    <string>/bin/bash</string>\n'
  # The first field is the script; the rest are its arguments. Splitting on
  # whitespace is the point here — the JOBS table holds a command line.
  local first=1
  # shellcheck disable=SC2086
  for arg in $argv; do
    if [[ $first -eq 1 ]]; then
      printf '    <string>%s</string>\n' "$(xml_escape "$DIR/$arg")"; first=0
    else
      printf '    <string>%s</string>\n' "$(xml_escape "$arg")"
    fi
  done
  printf '  </array>\n'

  printf '  <key>WorkingDirectory</key><string>%s</string>\n' "$(xml_escape "$DIR")"

  # A LaunchAgent inherits almost nothing, so spell out the PATH the scripts need
  # for tar, lsof, python3 and wine — the same list cron gets.
  printf '  <key>EnvironmentVariables</key>\n  <dict>\n'
  printf '    <key>PATH</key><string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>\n'
  printf '  </dict>\n'

  printf '  <key>StandardOutPath</key><string>%s</string>\n' "$(xml_escape "$LAUNCHD_LOG")"
  printf '  <key>StandardErrorPath</key><string>%s</string>\n' "$(xml_escape "$LAUNCHD_LOG")"

  # No Hour key means "every hour at this minute".
  printf '  <key>StartCalendarInterval</key>\n  <dict>\n'
  [[ -n "$hour" ]] && printf '    <key>Hour</key><integer>%s</integer>\n' "$hour"
  printf '    <key>Minute</key><integer>%s</integer>\n' "$minute"
  printf '  </dict>\n'

  printf '</dict>\n</plist>\n'
}

describe() {
  local hour="$1" minute="$2"
  if [[ -z "$hour" ]]; then printf 'every hour at :%02d' "$minute"
  else printf 'daily at %02d:%02d' "$hour" "$minute"; fi
}

cron_is_installed() {
  crontab -l 2>/dev/null | grep -qF "palworld-server cron"
}

loaded_labels() {
  local suffix
  for job in "${JOBS[@]}"; do
    IFS='|' read -r suffix _ _ _ <<<"$job"
    launchctl print "$GUI/$LABEL_PREFIX.$suffix" >/dev/null 2>&1 && printf '%s\n' "$LABEL_PREFIX.$suffix"
  done
}

case "${1:-}" in

  --show)
    for job in "${JOBS[@]}"; do
      IFS='|' read -r suffix hour minute argv <<<"$job"
      printf '%s─── %s.%s  (%s) ───%s\n' "$_c_dim" "$LABEL_PREFIX" "$suffix" "$(describe "$hour" "$minute")" "$_c_reset"
      plist_for "$suffix" "$hour" "$minute" "$argv"
      printf '\n'
    done
    info "Files would be written to $AGENT_DIR/"
    ;;

  --install)
    ensure_dirs
    # Running both schedulers would double every backup and every restart.
    if cron_is_installed; then
      die "The cron schedule is already installed. Remove it first:
    ./install_cron.sh --remove
    Running cron and launchd together would back up and restart twice over."
    fi

    mkdir -p "$AGENT_DIR"
    for job in "${JOBS[@]}"; do
      IFS='|' read -r suffix hour minute argv <<<"$job"
      label="$LABEL_PREFIX.$suffix"
      plist="$AGENT_DIR/$label.plist"

      # bootout first so re-running this is an update rather than an error.
      launchctl bootout "$GUI/$label" 2>/dev/null || true
      plist_for "$suffix" "$hour" "$minute" "$argv" > "$plist"
      plutil -lint "$plist" >/dev/null || die "Generated an invalid plist: $plist"
      launchctl bootstrap "$GUI" "$plist" \
        || die "launchctl refused to load $label ($plist)."
      ok "$label — $(describe "$hour" "$minute")"
    done

    echo
    ok "Scheduled through launchd. No Full Disk Access step is needed."
    info "Log: $LAUNCHD_LOG"
    printf '    %sJobs run while you are logged in. For a Mac that reboots unattended,%s\n' "$_c_dim" "$_c_reset"
    printf '    %senable automatic login, or use ./install_cron.sh instead.%s\n' "$_c_dim" "$_c_reset"
    audit "launchd schedule installed"
    ;;

  --remove)
    removed=0
    for job in "${JOBS[@]}"; do
      IFS='|' read -r suffix _ _ _ <<<"$job"
      label="$LABEL_PREFIX.$suffix"
      launchctl bootout "$GUI/$label" 2>/dev/null && removed=$((removed + 1)) || true
      rm -f "$AGENT_DIR/$label.plist"
    done
    if [[ $removed -gt 0 ]]; then
      ok "Removed ${removed} launchd jobs"
      audit "launchd schedule removed"
    else
      info "Nothing was loaded. Any leftover files have been deleted."
    fi
    ;;

  --status)
    info "launchd jobs"
    found=0
    for job in "${JOBS[@]}"; do
      IFS='|' read -r suffix hour minute _ <<<"$job"
      label="$LABEL_PREFIX.$suffix"
      if launchctl print "$GUI/$label" >/dev/null 2>&1; then
        found=1
        printf '  %s✔%s %-32s %s\n' "$_c_grn" "$_c_reset" "$label" "$(describe "$hour" "$minute")"
      else
        printf '  %s·%s %-32s not loaded\n' "$_c_dim" "$_c_reset" "$label"
      fi
    done
    [[ $found -eq 1 ]] || info "Install with: ./install_launchd.sh --install"
    if cron_is_installed; then
      echo
      warn "The cron schedule is ALSO installed — every job would run twice."
      printf '    Keep one: ./install_cron.sh --remove   or   ./install_launchd.sh --remove\n'
    fi
    ;;

  -h|--help) sed -n '2,/^# ===/p' "$0" | sed 's/^# \{0,1\}//' ;;

  *)
    die "Usage: ./install_launchd.sh --show | --install | --remove | --status"
    ;;
esac
