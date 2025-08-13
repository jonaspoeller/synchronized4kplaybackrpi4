#!/bin/bash
# ==================================================================================
# Uninstallation Script for the Synchronized Video Playback System
# Version: 1.0
#
# This script cleanly reverts all changes made by the setup script.
# It removes the application, services, and resets boot configurations.
# System dependencies like VLC or Python are NOT uninstalled.
#
# Run with: sudo bash uninstall_video_sync.sh
# ==================================================================================
set -e
echo "================================================="
echo "Uninstalling the Synchronized Video Playback System"
echo "================================================="

# --- 1. Stop and remove the Systemd service ---
echo ""
echo "--- Stopping and removing Systemd service... ---"
if systemctl list-units --full -all | grep -q 'video-sync.service'; then
    systemctl stop video-sync.service || true
    systemctl disable video-sync.service || true
    rm -f /etc/systemd/system/video-sync.service
    echo "Service 'video-sync.service' removed."
else
    echo "Service 'video-sync.service' not found, skipping."
fi
systemctl daemon-reload

# --- 2. Delete application files and helpers ---
echo ""
echo "--- Deleting application directory and helper scripts... ---"
rm -rf /opt/video-sync
rm -f /usr/local/bin/video-sync-*
echo "Application files and helper scripts removed."

# --- 3. Revert system configuration ---
echo ""
echo "--- Reverting system configuration to defaults... ---"
echo "Re-enabling the console login service..."
systemctl enable getty@tty1.service
echo "Setting boot target back to graphical desktop..."
systemctl set-default graphical.target
echo "Removing kernel parameters from /boot/firmware/cmdline.txt..."
sed -i 's/ quiet//g; s/ loglevel=[0-9]*//g; s/ consoleblank=[0-9]*//g; s/ splash//g; s/ vt.global_cursor_default=[0-9]*//g; s/ logo.nologo//g' /boot/firmware/cmdline.txt
sed -i 's/console=tty3/console=tty1/g' /boot/firmware/cmdline.txt
echo "Removing entries from /boot/firmware/config.txt..."
sed -i '/# --- Video Sync Setup ---/,/# --- Ende Video Sync Setup ---/d' /boot/firmware/config.txt
sed -i -e :a -e '/^\n*$/{$d;N;};/\n$/ba' /boot/firmware/config.txt

echo ""
echo "================================================"
echo "      Uninstallation complete!"
echo "================================================"
echo ""
echo "A reboot is now required to apply all changes."
echo "The system will automatically reboot in 10 seconds..."
sleep 10
reboot
