#!/usr/bin/env bash
# Captures a snapshot of system state right before shutdown/reboot.
# Called by rpi-shutdown-capture.service ExecStop so it runs during the
# systemd shutdown sequence, before the root filesystem becomes read-only.
#
# Output goes to /var/log/rpi-monitor/shutdown-<timestamp>.log

LOG_DIR="/var/log/rpi-monitor"
OUTFILE="${LOG_DIR}/shutdown-$(date '+%Y-%m-%dT%H:%M:%S').log"

mkdir -p "$LOG_DIR"

vcgencmd_safe() {
  vcgencmd "$@" 2>/dev/null || echo "unavailable"
}

decode_throttle() {
  local raw="$1"
  local val
  val=$(( raw ))

  local flags=()
  (( val & 0x1     )) && flags+=("UNDER_VOLTAGE_NOW")
  (( val & 0x2     )) && flags+=("ARM_FREQ_CAPPED_NOW")
  (( val & 0x4     )) && flags+=("THROTTLED_NOW")
  (( val & 0x8     )) && flags+=("SOFT_TEMP_LIMIT_NOW")
  (( val & 0x10000 )) && flags+=("under_voltage_occurred")
  (( val & 0x20000 )) && flags+=("arm_freq_capped_occurred")
  (( val & 0x40000 )) && flags+=("throttling_occurred")
  (( val & 0x80000 )) && flags+=("soft_temp_limit_occurred")

  if [[ ${#flags[@]} -eq 0 ]]; then
    echo "OK"
  else
    local IFS="|"
    echo "${flags[*]}"
  fi
}

{
  echo "════════════════════════════════════════════"
  echo "  SHUTDOWN CAPTURE  $(date '+%Y-%m-%dT%H:%M:%S')"
  echo "════════════════════════════════════════════"

  echo ""
  echo "── System ───────────────────────────────────"
  echo "  hostname   : $(hostname)"
  echo "  uptime     : $(uptime)"
  echo "  who        : $(who | tr '\n' ';')"

  echo ""
  echo "── Memory ───────────────────────────────────"
  free -h

  echo ""
  echo "── CPU frequency ────────────────────────────"
  for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
    [[ -r "$f" ]] || continue
    core="${f#/sys/devices/system/cpu/}"
    core="${core%%/*}"
    printf "  %-6s: %d MHz\n" "$core" "$(( $(cat "$f") / 1000 ))"
  done

  echo ""
  echo "── Thermal zones ────────────────────────────"
  for zone_dir in /sys/class/thermal/thermal_zone*; do
    [[ -r "${zone_dir}/temp" ]] || continue
    type=$(cat "${zone_dir}/type" 2>/dev/null || basename "$zone_dir")
    temp_raw=$(cat "${zone_dir}/temp")
    temp_c=$(awk "BEGIN {printf \"%.1f\", ${temp_raw}/1000}")
    printf "  %-20s: %s°C\n" "$type" "$temp_c"
  done

  echo ""
  echo "── vcgencmd ──────────────────────────────────"
  echo "  temp       : $(vcgencmd_safe measure_temp)"

  raw_throttle=$(vcgencmd_safe get_throttled)
  throttle_hex="${raw_throttle#*=}"
  if [[ "$throttle_hex" == "unavailable" ]]; then
    throttle_flags="unavailable"
  else
    throttle_flags=$(decode_throttle "$throttle_hex")
  fi
  echo "  throttled  : ${raw_throttle}  →  ${throttle_flags}"

  for rail in core sdram_c sdram_i sdram_p; do
    printf "  volts_%-8s: %s\n" "$rail" "$(vcgencmd_safe measure_volts "$rail")"
  done

  echo ""
  echo "── Top processes (CPU) ───────────────────────"
  ps aux --sort=-%cpu | head -11

  echo ""
  echo "── Disk usage ────────────────────────────────"
  df -h

  echo ""
  echo "── Last 50 kernel messages ───────────────────"
  dmesg --time-format iso 2>/dev/null | tail -50 || dmesg | tail -50

  echo ""
  echo "── Kernel messages: thermal/power/voltage ────"
  dmesg --time-format iso 2>/dev/null \
    | grep -iE "(thermal|throttl|over.temp|under.volt|voltage|power|reboot|panic|oom|killed|segfault)" \
    || echo "  (none found)"

  echo ""
  echo "── journald: last 30 errors ──────────────────"
  journalctl -p err -n 30 --no-pager 2>/dev/null || echo "  (journalctl unavailable)"

  echo ""
  echo "════════════════════════════════════════════"
  echo "  END OF SHUTDOWN CAPTURE"
  echo "════════════════════════════════════════════"

} > "$OUTFILE" 2>&1

# Sync to ensure the file is flushed before the filesystem is remounted r/o.
sync
