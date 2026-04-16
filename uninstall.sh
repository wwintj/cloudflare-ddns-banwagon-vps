#!/usr/bin/env bash
set -euo pipefail

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
    echo "Please run as root (sudo ./uninstall.sh)"
    exit 1
fi

echo "Stopping and disabling systemd timer..."
systemctl stop cf-ddns.timer || true
systemctl disable cf-ddns.timer || true
systemctl stop cf-ddns.service || true

echo "Removing systemd unit files..."
rm -f /etc/systemd/system/cf-ddns.service
rm -f /etc/systemd/system/cf-ddns.timer
systemctl daemon-reload

echo "Removing binary..."
rm -f /usr/local/bin/cf-ddns-update

echo "Removing configuration and cache directories..."
rm -rf /etc/cf-ddns
rm -rf /var/lib/cf-ddns

echo "Uninstall complete."
