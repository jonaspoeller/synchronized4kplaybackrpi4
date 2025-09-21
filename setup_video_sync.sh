#!/bin/bash
# ==================================================================================
# Automated Setup for Synchronized Video Playback on Raspberry Pi 4 (v2 - Hardened)
# ==================================================================================

set -e

# --- System Check ---
if [ "$EUID" -ne 0 ]; then echo "ERROR: Please run as root (sudo)."; exit 1; fi
if ! uname -a | grep -q 'aarch64'; then echo "ERROR: This script requires a 64-bit (aarch64) Raspberry Pi OS."; exit 1; fi

# --- Interactive User Input ---
echo "================================================="
echo " Interactive Setup for Video Sync System"
echo "================================================="
echo ""
echo "--- Network Configuration ---"
# GEÄNDERT: Abfrage im CIDR-Format für korrekte Broadcast-Berechnung
read -p "Enter the static IP address and subnet for this device (e.g., 192.168.1.10/24): " device_ip_cidr
read -p "Enter the sync port for this group (e.g., 5555): " sync_port

# --- NEU: Robuste Broadcast-IP-Berechnung ---
IP=$(echo $device_ip_cidr | cut -d/ -f1)
CIDR=$(echo $device_ip_cidr | cut -d/ -f2)
if ! [[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || ! [[ "$CIDR" =~ ^[0-9]+$ ]] || [ "$CIDR" -gt 32 ]; then
    echo "ERROR: Invalid IP address or CIDR format."
    exit 1
fi
IFS=. read -r i1 i2 i3 i4 <<< "$IP"
ip_int=$(( (i1 << 24) + (i2 << 16) + (i3 << 8) + i4 ))
mask_int=$(( 0xFFFFFFFF << (32 - CIDR) ))
bcast_int=$(( (ip_int & mask_int) | ~mask_int & 0xFFFFFFFF ))
BROADCAST_IP="$(( (bcast_int >> 24) & 0xFF )).$(( (bcast_int >> 16) & 0xFF )).$(( (bcast_int >> 8) & 0xFF )).$(( bcast_int & 0xFF ))"
echo "Calculated Broadcast IP: $BROADCAST_IP"
# --- Ende der Broadcast-Berechnung ---

echo ""
echo "--- Role Configuration ---"
echo "1) Master Node (controls playback)"
echo "2) Slave Node (controlled by Master)"
read -p "Select role [1-2]: " node_type

if [ "$node_type" == "2" ]; then
    read -p "Enter the Master's IP address: " master_ip
else
    node_type="1"
    master_ip=$IP
fi
echo ""

# --- System & Dependencies ---
echo "--- Performing full system upgrade (this may take a while)... ---"
apt-get update && apt-get full-upgrade -y

echo "--- Installing dependencies and setting permissions... ---"
apt-get install -y vlc python3-pip python3-vlc ffmpeg
usmod -a -G render,video,audio pi
loginctl enable-linger pi

# --- System Configuration for Silent Boot ---
echo "--- Configuring system for silent boot... ---"
systemctl set-default multi-user.target
systemctl disable getty@tty1.service

# --- Configure Graphics for Raspberry Pi 4 ---
echo "Applying graphics settings for Raspberry Pi 4..."
V3D_OVERLAY_LINE="dtoverlay=vc4-kms-v3d-pi4,cma-512"

echo "--- Configuring /boot/firmware/config.txt... ---"
sed -i '/# --- Video Sync Setup ---/,/# --- End Video Sync Setup ---/d' /boot/firmware/config.txt
cat >> /boot/firmware/config.txt << EOF

# --- Video Sync Setup ---
${V3D_OVERLAY_LINE}
dtoverlay=rpivid-v4l2
disable_overscan=1
hdmi_group=1
hdmi_mode=16
# --- End Video Sync Setup ---
EOF

echo "--- Configuring kernel parameters for silent boot... ---"
sed -i 's/ quiet//g; s/ loglevel=[0-9]*//g; s/ consoleblank=[0-9]*//g; s/ splash//g; s/ vt.global_cursor_default=[0-9]*//g; s/ logo.nologo//g' /boot/firmware/cmdline.txt
sed -i 's/console=tty1/console=tty3/g' /boot/firmware/cmdline.txt
sed -i '1 s/$/ quiet loglevel=0 vt.global_cursor_default=0 logo.nologo/' /boot/firmware/cmdline.txt

# --- Application Installation ---
INSTALL_DIR="/opt/video-sync"
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

# KORREKTUR: black.png wird jetzt immer erstellt, vor der Rollen-Auswahl
echo "--- Creating black image for standby... ---"
ffmpeg -f lavfi -i color:c=black:s=1920x1080:d=1 -vframes 1 /opt/video-sync/black.png -y >/dev/null 2>&1

if [ "$node_type" == "1" ]; then
    # --- MASTER SETUP ---
    echo "--- Creating Master configuration for port $sync_port... ---"
    cat > sync_config.ini << EOF
[network]
master_ip = $master_ip
broadcast_ip = $BROADCAST_IP
sync_port = $sync_port
[video]
file_path = /home/pi/video.mp4
loop_delay = 0.5
EOF
    echo "--- Installing Master script... ---"
    # Der Python-Code für den Master wird hier eingefügt (siehe separates Skript unten)
    cp /pfad/zu/ihrem/video_sync_master.py $INSTALL_DIR/video_sync_master.py
    chmod +x video_sync_master.py
    PYTHON_EXEC_PATH=$INSTALL_DIR/video_sync_master.py
else
    # --- SLAVE SETUP ---
    echo "--- Creating Slave configuration for port $sync_port... ---"
    cat > sync_config.ini << EOF
[network]
master_ip = $master_ip
sync_port = $sync_port
EOF
    echo "--- Installing Slave script... ---"
    # Der Python-Code für den Slave wird hier eingefügt (siehe separates Skript unten)
    cp /pfad/zu/ihrem/video_sync_slave.py $INSTALL_DIR/video_sync_slave.py
    chmod +x video_sync_slave.py
    PYTHON_EXEC_PATH=$INSTALL_DIR/video_sync_slave.py
fi

# --- Systemd Service ---
echo "--- Installing systemd service... ---"
cat > /etc/systemd/system/video-sync.service << EOF
[Unit]
Description=Video Sync Service ($(if [ "$node_type" == "1" ]; then echo "Master"; else echo "Slave"; fi) on Port $sync_port)
After=network-online.target
[Service]
Type=simple
User=pi
WorkingDirectory=$INSTALL_DIR
ExecStartPre=/bin/sleep 5
Environment="XDG_RUNTIME_DIR=/run/user/1000"
ExecStart=/usr/bin/python3 $PYTHON_EXEC_PATH
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

# --- Helper Scripts & Finalize ---
echo "--- Installing helper scripts... ---"
cat > /usr/local/bin/video-sync-start << EOF
#!/bin/bash
sudo systemctl start video-sync.service
EOF
chmod +x /usr/local/bin/video-sync-start

cat > /usr/local/bin/video-sync-stop << EOF
#!/bin/bash
sudo systemctl stop video-sync.service
EOF
chmod +x /usr/local/bin/video-sync-stop

cat > /usr/local/bin/video-sync-status << EOF
#!/bin/bash
sudo systemctl status video-sync.service
EOF
chmod +x /usr/local/bin/video-sync-status

cat > /usr/local/bin/video-sync-logs << EOF
#!/bin/bash
sudo journalctl -u video-sync.service -f
EOF
chmod +x /usr/local/bin/video-sync-logs

echo "--- Finalizing installation... ---"
systemctl daemon-reload
systemctl enable video-sync.service
echo ""
echo "================================================"
echo "      Installation complete!"
echo "================================================"
echo "Helper commands (video-sync-start, video-sync-stop, etc.) are now available."
echo "The system will reboot in 10 seconds to apply all changes."
sleep 10
reboot
