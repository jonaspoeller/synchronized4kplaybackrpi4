#!/bin/bash
set -e
echo "--- Uninstalling Synchronized Video Playback System ---"

# --- Stop and remove service ---
echo "Stopping and removing Systemd service..."
systemctl stop video-sync.service || true
systemctl disable video-sync.service || true
rm -f /etc/systemd/system/video-sync.service
systemctl daemon-reload

# --- Delete application files ---
echo "Deleting application directory..."
rm -rf /opt/video-sync

# --- Revert system configuration ---
echo "Reverting system configuration..."
systemctl enable getty@tty1.service
systemctl set-default graphical.target
sed -i 's/ quiet//g; s/ loglevel=[0-9]*//g; s/ splash//g; s/ vt.global_cursor_default=[0-9]*//g; s/ logo.nologo//g' /boot/firmware/cmdline.txt
sed -i 's/console=tty3/console=tty1/g' /boot/firmware/cmdline.txt
sed -i '/# --- Video Sync Setup ---/,/# --- End Video Sync Setup ---/d' /boot/firmware/config.txt

echo ""
echo "--- Uninstallation complete! ---"
echo "A REBOOT IS NOW REQUIRED."
echo "Command: sudo reboot"
echo ""
