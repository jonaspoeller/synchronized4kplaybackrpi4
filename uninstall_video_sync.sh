#!/bin/bash
# ==================================================================================
# Uninstaller for the Synchronized Video Playback System
# ==================================================================================

set -e

# --- System Check ---
if [ "$EUID" -ne 0 ]; then echo "ERROR: Please run as root (sudo)."; exit 1; fi

echo "================================================="
echo " Uninstalling the Synchronized Video Playback System"
echo "================================================="
echo ""

# --- Stop and remove the systemd service ---
echo "--- Stopping and removing the systemd service... ---"
systemctl stop video-sync.service || true
systemctl disable video-sync.service || true
rm -f /etc/systemd/system/video-sync.service
systemctl daemon-reload
echo "Service 'video-sync.service' removed."
echo ""

# --- Delete helper scripts ---
echo "--- Deleting helper scripts... ---"
rm -f /usr/local/bin/video-sync-*
echo "Helper scripts removed."
echo ""

# --- Delete application directory ---
echo "--- Deleting application directory... ---"
rm -rf /opt/video-sync
echo "Application directory '/opt/video-sync' removed."
echo ""

# --- Revert system configuration ---
echo "--- Reverting system configuration... ---"
# Restore graphical boot and login prompt
systemctl enable getty@tty1.service
systemctl set-default graphical.target
echo "Graphical boot restored."

# Revert kernel parameters
sed -i 's/ quiet//g; s/ loglevel=0//g; s/ vt.global_cursor_default=0//g; s/ logo.nologo//g' /boot/firmware/cmdline.txt
sed -i 's/console=tty3/console=tty1/g' /boot/firmware/cmdline.txt
echo "Kernel parameters in 'cmdline.txt' reverted."

# Revert graphics configuration
sed -i '/# --- Video Sync Setup ---/,/# --- End Video Sync Setup ---/d' /boot/firmware/config.txt
echo "Custom settings in 'config.txt' removed."
echo ""

echo "================================================"
echo "      Uninstallation complete!"
echo "================================================"
echo "A REBOOT IS NOW REQUIRED to apply all changes."
echo "Command: sudo reboot"
echo ""
