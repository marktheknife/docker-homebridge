#!/usr/bin/env bash
# Installs the rpi-monitor and rpi-shutdown-capture services on a Raspberry Pi.
#
# Usage:  ./rpi-monitor-install.sh <pi-host> [ssh-user]
#         ./rpi-monitor-install.sh raspberrypi.local
#         ./rpi-monitor-install.sh 192.168.1.42 pi
#
# Requires: ssh access with sudo on the target host.

set -euo pipefail

PI_HOST="${1:?Usage: $0 <pi-host> [ssh-user]}"
SSH_USER="${2:-$(whoami)}"
SSH="${SSH_USER}@${PI_HOST}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

info()  { echo "[install] $*"; }
fatal() { echo "[ERROR]   $*" >&2; exit 1; }

command -v ssh  >/dev/null || fatal "ssh not found"
command -v scp  >/dev/null || fatal "scp not found"

info "Copying scripts to ${SSH}:/tmp/ ..."
scp "${SCRIPT_DIR}/rpi-monitor.sh" \
    "${SCRIPT_DIR}/rpi-shutdown-capture.sh" \
    "${SSH}:/tmp/"

info "Installing binaries and systemd units ..."
# shellcheck disable=SC2087
ssh -tt "$SSH" bash <<'REMOTE'
set -euo pipefail

sudo install -m 755 /tmp/rpi-monitor.sh          /usr/local/bin/rpi-monitor.sh
sudo install -m 755 /tmp/rpi-shutdown-capture.sh  /usr/local/bin/rpi-shutdown-capture.sh

sudo mkdir -p /var/log/rpi-monitor

# Write the monitor service
sudo tee /etc/systemd/system/rpi-monitor.service > /dev/null <<'EOF'
[Unit]
Description=Raspberry Pi system health monitor
After=multi-user.target
Wants=multi-user.target

[Service]
Type=simple
ExecStart=/usr/local/bin/rpi-monitor.sh 30
Restart=always
RestartSec=5
StandardOutput=journal
StandardError=journal
SyslogIdentifier=rpi-monitor

[Install]
WantedBy=multi-user.target
EOF

# Write the shutdown-capture service
sudo tee /etc/systemd/system/rpi-shutdown-capture.service > /dev/null <<'EOF'
[Unit]
Description=Capture Raspberry Pi system state immediately before shutdown
DefaultDependencies=no
Before=shutdown.target reboot.target halt.target
Requires=local-fs.target
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStop=/usr/local/bin/rpi-shutdown-capture.sh

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now rpi-monitor.service
sudo systemctl enable rpi-shutdown-capture.service

echo "Status of rpi-monitor:"
sudo systemctl status rpi-monitor.service --no-pager || true
REMOTE

info "Done. Logs will appear in /var/log/rpi-monitor/ on the Pi."
info "To tail the live log:  ssh ${SSH} 'tail -f /var/log/rpi-monitor/rpi-monitor-\$(date +%Y-%m-%d).log'"
info "Shutdown snapshots are saved as /var/log/rpi-monitor/shutdown-<timestamp>.log"
