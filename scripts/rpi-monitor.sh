#!/usr/bin/env bash
# Periodic system-health logger for Raspberry Pi 5.
# Designed to help diagnose unexpected shutdowns by logging temperature,
# throttle flags, voltage, CPU frequency, memory, and kernel warnings.
#
# Usage: rpi-monitor.sh [interval_seconds]  (default: 30)
#
# Logs rotate daily; LOG_KEEP_DAYS controls retention.

set -euo pipefail

INTERVAL="${1:-30}"
LOG_DIR="/var/log/rpi-monitor"
LOG_KEEP_DAYS=14

mkdir -p "$LOG_DIR"

# ── Helpers ──────────────────────────────────────────────────────────────────

log_file() {
  echo "${LOG_DIR}/rpi-monitor-$(date +%Y-%m-%d).log"
}

rotate_logs() {
  find "$LOG_DIR" -name "rpi-monitor-*.log" -mtime +"$LOG_KEEP_DAYS" -delete 2>/dev/null || true
}

# Decode the vcgencmd get_throttled bitmask into human-readable flags.
decode_throttle() {
  local raw="$1"
  local val
  val=$(( raw ))   # handles "throttled=0x50005" if passed as hex string

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

vcgencmd_safe() {
  vcgencmd "$@" 2>/dev/null || echo "unavailable"
}

# ── Single sample ─────────────────────────────────────────────────────────────

collect() {
  local ts
  ts="$(date '+%Y-%m-%dT%H:%M:%S')"
  local out
  out="$(log_file)"

  {
    echo "──────────────────────────────────────────── ${ts}"

    # Uptime / load
    echo "  uptime     : $(uptime -p 2>/dev/null || uptime)"
    echo "  load_avg   : $(cut -d' ' -f1-3 /proc/loadavg)"

    # Memory
    local mem_total mem_avail mem_used_pct
    mem_total=$(awk '/^MemTotal/  {print $2}' /proc/meminfo)
    mem_avail=$(awk '/^MemAvailable/ {print $2}' /proc/meminfo)
    mem_used_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))
    printf "  memory     : %d MiB total, %d MiB avail (%d%% used)\n" \
      "$(( mem_total / 1024 ))" "$(( mem_avail / 1024 ))" "$mem_used_pct"

    # CPU frequencies (all cores)
    local freqs=()
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq; do
      [[ -r "$f" ]] && freqs+=("$(( $(cat "$f") / 1000 ))MHz")
    done
    if [[ ${#freqs[@]} -gt 0 ]]; then
      echo "  cpu_freq   : ${freqs[*]}"
    fi

    # Thermal zones
    for zone_dir in /sys/class/thermal/thermal_zone*; do
      [[ -r "${zone_dir}/temp" ]] || continue
      local type temp_raw temp_c
      type=$(cat "${zone_dir}/type" 2>/dev/null || basename "$zone_dir")
      temp_raw=$(cat "${zone_dir}/temp")
      temp_c=$(awk "BEGIN {printf \"%.1f\", ${temp_raw}/1000}")
      printf "  %-10s : %s°C\n" "$type" "$temp_c"
    done

    # vcgencmd: temp, throttle, voltages
    local raw_temp
    raw_temp=$(vcgencmd_safe measure_temp)
    echo "  vcgencmd_t : ${raw_temp}"

    local raw_throttle throttle_hex throttle_flags
    raw_throttle=$(vcgencmd_safe get_throttled)
    # raw_throttle looks like "throttled=0x50005"
    throttle_hex="${raw_throttle#*=}"
    if [[ "$throttle_hex" == "unavailable" ]]; then
      throttle_flags="unavailable"
    else
      throttle_flags=$(decode_throttle "$throttle_hex")
    fi
    echo "  throttled  : ${raw_throttle}  →  ${throttle_flags}"

    for rail in core sdram_c sdram_i sdram_p; do
      local v
      v=$(vcgencmd_safe measure_volts "$rail")
      printf "  volts_%-8s: %s\n" "$rail" "$v"
    done

    # Recent kernel messages that mention thermal, power, or voltage issues
    local dmesg_hits
    dmesg_hits=$(dmesg --time-format iso 2>/dev/null \
      | grep -iE "(thermal|throttl|over.temp|under.volt|voltage|power|reboot|panic|oom|killed)" \
      | tail -5 \
      || true)
    if [[ -n "$dmesg_hits" ]]; then
      echo "  dmesg_warn :"
      while IFS= read -r line; do
        echo "    $line"
      done <<< "$dmesg_hits"
    else
      echo "  dmesg_warn : (none)"
    fi

  } >> "$out"
}

# ── Main loop ─────────────────────────────────────────────────────────────────

echo "rpi-monitor started (interval=${INTERVAL}s, log_dir=${LOG_DIR})" \
  >> "$(log_file)"

rotate_logs

while true; do
  collect
  rotate_logs
  sleep "$INTERVAL"
done
