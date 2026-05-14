#!/usr/bin/env bash
# Configures Wake-on-LAN on a Raspberry Pi 5.
# Run this ON THE PI (or via the install script).
#
# What it does:
#   1. Enables WoL on eth0 immediately.
#   2. Installs a systemd service so the WoL setting survives reboots.
#   3. Prints the MAC address you need for rpi-wake.sh.
#
# Usage: sudo bash rpi-wol-setup.sh [interface]  (default: eth0)

set -euo pipefail

IFACE="${1:-eth0}"

info()  { echo "[wol-setup] $*"; }
fatal() { echo "[ERROR] $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fatal "Run as root: sudo bash $0"

# ── Check interface exists ───────────────────────────────────────────────────

if ! ip link show "$IFACE" &>/dev/null; then
  fatal "Interface '$IFACE' not found. Available: $(ip -o link show | awk -F': ' '{print $2}' | tr '\n' ' ')"
fi

# ── Install ethtool if needed ────────────────────────────────────────────────

if ! command -v ethtool &>/dev/null; then
  info "ethtool not found — installing..."
  apt-get install -y ethtool
fi

# ── Enable WoL now ───────────────────────────────────────────────────────────

info "Enabling Wake-on-LAN (magic packet) on ${IFACE}..."
ethtool -s "$IFACE" wol g

current=$(ethtool "$IFACE" | grep -i "wake-on" || true)
info "ethtool reports: ${current}"

# ── Get MAC address ──────────────────────────────────────────────────────────

MAC=$(cat "/sys/class/net/${IFACE}/address")
info "MAC address: ${MAC}"

# ── Make WoL persistent via systemd ─────────────────────────────────────────
# ethtool WoL settings reset on each boot, so we install a lightweight service.

SERVICE=/etc/systemd/system/wol-enable.service

cat > "$SERVICE" <<EOF
[Unit]
Description=Enable Wake-on-LAN on ${IFACE}
After=network.target

[Service]
Type=oneshot
ExecStart=/sbin/ethtool -s ${IFACE} wol g
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now wol-enable.service
info "Installed and started wol-enable.service"

# ── EEPROM note ──────────────────────────────────────────────────────────────
# On Pi 5, WoL works in halted state without EEPROM changes.
# If the Pi is fully powered off (e.g. after a hard thermal cut), you need
# the physical J2 button — WoL cannot wake a Pi with no standby power.

echo ""
echo "══════════════════════════════════════════════════"
echo "  Wake-on-LAN configured for ${IFACE}"
echo "  MAC address: ${MAC}"
echo ""
echo "  To wake from another machine on the same network:"
echo "    ./rpi-wake.sh ${MAC}"
echo ""
echo "  NOTE: WoL only works if the Pi is in HALTED state"
echo "  (clean OS shutdown, ethernet still powered)."
echo "  For a hard power cut, use the J2 physical button."
echo "══════════════════════════════════════════════════"
