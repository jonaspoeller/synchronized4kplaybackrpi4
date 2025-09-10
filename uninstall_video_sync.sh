#!/bin/bash
# ==================================================================================
# Deinstallations-Skript für das Synchronized Video Playback System
# Version: Final
# ==================================================================================
set -e
echo "================================================="
echo "Deinstallation des Synchronized Video Playback Systems"
echo "================================================="
echo ""
echo "--- Stoppe und entferne den Systemd-Dienst... ---"
systemctl stop video-sync.service || true
systemctl disable video-sync.service || true
rm -f /etc/systemd/system/video-sync.service
systemctl daemon-reload
echo "Dienst 'video-sync.service' entfernt."
echo ""
echo "--- Lösche Anwendungsverzeichnis und Helfer-Skripte... ---"
rm -rf /opt/video-sync
rm -f /usr/local/bin/video-sync-*
echo "Anwendungsdateien und Helfer-Skripte entfernt."
echo ""
echo "--- Setze Systemkonfiguration zurück... ---"
systemctl enable getty@tty1.service
systemctl set-default graphical.target
sed -i 's/ quiet//g; s/ loglevel=[0-9]*//g; s/ consoleblank=[0-9]*//g; s/ splash//g; s/ vt.global_cursor_default=[0-9]*//g; s/ logo.nologo//g' /boot/firmware/cmdline.txt
sed -i 's/console=tty3/console=tty1/g' /boot/firmware/cmdline.txt
sed -i '/# --- Video Sync Setup ---/,/# --- Ende Video Sync Setup ---/d' /boot/firmware/config.txt
echo ""
echo "================================================"
echo "      Deinstallation abgeschlossen!"
echo "================================================"
echo "EIN NEUSTART IST JETZT ZWINGEND ERFORDERLICH."
echo "Befehl: sudo reboot"
echo ""
