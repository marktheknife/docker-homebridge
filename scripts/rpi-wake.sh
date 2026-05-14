#!/usr/bin/env bash
# Sends a Wake-on-LAN magic packet to a Raspberry Pi (or any WoL-enabled host).
# Run this on any machine on the same network as the Pi.
#
# Usage: ./rpi-wake.sh <MAC-address> [broadcast-address]
#
# Examples:
#   ./rpi-wake.sh d8:3a:dd:12:34:56
#   ./rpi-wake.sh d8:3a:dd:12:34:56 192.168.1.255
#
# If you saved the MAC in a file called .rpi-mac next to this script, you can
# just run:  ./rpi-wake.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MAC_FILE="${SCRIPT_DIR}/.rpi-mac"

# ── Resolve MAC ───────────────────────────────────────────────────────────────

if [[ $# -ge 1 ]]; then
  MAC="$1"
elif [[ -f "$MAC_FILE" ]]; then
  MAC="$(cat "$MAC_FILE" | tr -d '[:space:]')"
  echo "Using saved MAC: ${MAC}"
else
  echo "Usage: $0 <MAC-address> [broadcast-address]" >&2
  echo "  or save the MAC to ${MAC_FILE}" >&2
  exit 1
fi

BROADCAST="${2:-255.255.255.255}"

# Normalise: strip separators, uppercase
MAC_CLEAN="${MAC//:/}"
MAC_CLEAN="${MAC_CLEAN//-/}"
MAC_CLEAN="${MAC_CLEAN^^}"

if [[ ${#MAC_CLEAN} -ne 12 ]]; then
  echo "Error: '${MAC}' does not look like a valid MAC address." >&2
  exit 1
fi

# ── Send magic packet ─────────────────────────────────────────────────────────
# Try wakeonlan first (common on Linux/macOS), then fall back to Python,
# then fall back to a raw nc approach.

send_python() {
  python3 - <<PYEOF
import socket, sys

mac  = "${MAC_CLEAN}"
dest = "${BROADCAST}"

payload = bytes.fromhex("FF" * 6 + mac * 16)
with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as s:
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    s.connect((dest, 9))
    s.send(payload)
print(f"Magic packet sent to {mac} via {dest}:9")
PYEOF
}

if command -v wakeonlan &>/dev/null; then
  wakeonlan -i "$BROADCAST" "$MAC"
  echo "Magic packet sent via wakeonlan."
elif command -v python3 &>/dev/null; then
  send_python
else
  echo "Error: neither 'wakeonlan' nor 'python3' found." >&2
  echo "Install one: sudo apt install wakeonlan  OR  brew install wakeonlan" >&2
  exit 1
fi

echo "Sent WoL magic packet to ${MAC} (broadcast: ${BROADCAST})"
echo "The Pi should boot within 10–20 seconds if it was in halted state."
