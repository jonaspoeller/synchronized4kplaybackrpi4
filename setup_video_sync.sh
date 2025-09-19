#!/bin/bash
# ==================================================================================
# Automated Setup for Synchronized Video Playback on Raspberry Pi 4
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
read -p "Enter the static IP address for this device: " device_ip
read -p "Enter the sync port for this group (e.g., 5555): " sync_port
echo ""
echo "--- Role Configuration ---"
echo "1) Master Node (controls playback)"
echo "2) Slave Node (controlled by Master)"
read -p "Select role [1-2]: " node_type

if [ "$node_type" == "2" ]; then
    read -p "Enter the Master's IP address: " master_ip
else
    node_type="1"
    master_ip=$device_ip
fi
echo ""

# --- System & Dependencies ---
echo "--- Performing full system upgrade (this may take a while)... ---"
apt-get update && apt-get full-upgrade -y

echo "--- Installing dependencies and setting permissions... ---"
apt-get install -y vlc python3-pip python3-vlc ffmpeg
usermod -a -G render,video,audio pi
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

if [ "$node_type" == "1" ]; then
    # --- MASTER SETUP ---
    echo "--- Creating Master configuration for port $sync_port... ---"
    cat > sync_config.ini << EOF
[network]
master_ip = $master_ip
broadcast_ip = $(echo $device_ip | cut -d. -f1-3).255
sync_port = $sync_port
[video]
file_path = /home/pi/video.mp4
loop_delay = 0.5
EOF
    echo "--- Installing Master script... ---"
    cat > video_sync_master.py << 'MASTER_SCRIPT'
#!/usr/bin/env python3
import vlc, socket, time, json, configparser, os
class VideoSyncMasterPlayer:
    def __init__(self, config_file='sync_config.ini'):
        self.config = configparser.ConfigParser()
        self.config.read(config_file)
        self.broadcast_ip = self.config.get('network', 'broadcast_ip')
        self.sync_port = self.config.getint('network', 'sync_port')
        self.master_ip = self.config.get('network', 'master_ip')
        self.video_path = self.config.get('video', 'file_path')
        self.loop_delay = self.config.getfloat('video', 'loop_delay', fallback=0.5)
        vlc_args = ['--no-xlib', '--quiet', '--fullscreen', '--no-video-title-show', '--no-osd', '--avcodec-hw=drm', '--codec=hevc_v4l2m2m,hevc', '--vout=drm_vout']
        self.instance = vlc.Instance(' '.join(vlc_args))
        self.player = self.instance.media_player_new()
        self.media = None
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.is_playing = False
        self.running = True
    def send_broadcast(self, message):
        message['master_ip'] = self.master_ip
        self.sock.sendto(json.dumps(message).encode('utf-8'), (self.broadcast_ip, self.sync_port))
        print(f"Command '{message.get('command')}' sent.")
    def load_video(self):
        if not os.path.exists(self.video_path): return False
        self.media = self.instance.media_new(self.video_path)
        return True
    def prepare_player(self):
        self.player.set_media(self.media)
        self.player.video_set_scale(0)
        self.player.play()
        time.sleep(0.2)
        self.player.pause()
        self.player.set_position(0)
    def play_video(self):
        self.player.play()
        self.is_playing = True
    def start(self):
        print("="*20, "Video Sync Master", "="*20)
        if not self.load_video(): self.stop(); return
        self.player.set_media(self.black_media); self.player.play()
        self.send_broadcast({'command': 'stop'}); time.sleep(0.2)
        self.send_broadcast({'command': 'load', 'data': {'video_path': self.video_path}}); time.sleep(0.2)
        self.prepare_player()
        self.send_broadcast({'command': 'prepare', 'data': {'video_path': self.video_path}}); time.sleep(0.2)
        self.play_video()
        self.send_broadcast({'command': 'play'})
        try:
            while self.running:
                while self.is_playing and self.running:
                    self.send_broadcast({'command': 'sync'})
                    time.sleep(1)
                    if self.player.get_state() == vlc.State.Ended:
                        self.is_playing = False
                if not self.running: break
                print("\n--- Video ended. Resetting for loop. ---")
                self.prepare_player()
                self.send_broadcast({'command': 'prepare', 'data': {'video_path': self.video_path}})
                time.sleep(self.loop_delay)
                self.play_video()
                self.send_broadcast({'command': 'play'})
        except KeyboardInterrupt:
            self.stop()
    def stop(self):
        self.running = False
        self.send_broadcast({'command': 'stop'})
        self.player.stop()
        self.sock.close()
        print("Master stopped.")
if __name__ == "__main__":
    master = VideoSyncMasterPlayer()
    master.start()
MASTER_SCRIPT
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
    echo "--- Creating black image for standby... ---"
    ffmpeg -f lavfi -i color:c=black:s=1920x1080:d=1 -vframes 1 /opt/video-sync/black.png -y >/dev/null 2>&1
    echo "--- Installing Slave script... ---"
    cat > video_sync_slave.py << 'SLAVE_SCRIPT'
#!/usr/bin/env python3
import vlc, socket, time, json, configparser, os, threading
class VideoSyncSlave:
    def __init__(self, config_file='sync_config.ini'):
        self.config = configparser.ConfigParser()
        self.config.read(config_file)
        self.master_ip = self.config.get('network', 'master_ip')
        self.sync_port = self.config.getint('network', 'sync_port')
        vlc_args = ['--no-xlib', '--quiet', '--fullscreen', '--no-video-title-show', '--no-osd', '--avcodec-hw=drm', '--codec=hevc_v4l2m2m,hevc', '--vout=drm_vout']
        self.instance = vlc.Instance(' '.join(vlc_args))
        self.player = self.instance.media_player_new()
        self.media = None
        self.black_media = self.instance.media_new('/opt/video-sync/black.png')
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(('', self.sync_port))
        self.running = True
        self.last_sync_time = time.time()
    def handle_command(self, message):
        if message.get('master_ip') != self.master_ip: return
        self.last_sync_time = time.time()
        command = message.get('command')
        if command == 'stop':
            self.player.set_media(self.black_media); self.player.play()
        elif command == 'load':
            video_path = message.get('data', {}).get('video_path')
            if video_path: self.media = self.instance.media_new(video_path)
        elif command == 'prepare':
            video_path = message.get('data', {}).get('video_path')
            if video_path and (not self.media or self.media.get_mrl() != video_path):
                self.media = self.instance.media_new(video_path)
            if self.media:
                self.player.set_media(self.media)
                self.player.video_set_scale(0)
                self.player.play()
                time.sleep(0.2)
                self.player.pause()
                self.player.set_position(0)
        elif command == 'play':
            self.player.play()
    def listen_for_commands(self):
        while self.running:
            try:
                data, _ = self.sock.recvfrom(1024)
                self.handle_command(json.loads(data.decode('utf-8')))
            except Exception: pass
    def master_watchdog(self):
        while self.running:
            time.sleep(2)
            if time.time() - self.last_sync_time > 5:
                print("Master signal lost! Reverting to standby (black screen).")
                self.player.set_media(self.black_media)
                self.player.play()
                self.last_sync_time = time.time()
    def start(self):
        print("="*20, "Video Sync Slave (Passive)", "="*20)
        self.player.set_media(self.black_media)
        self.player.play()
        print("Black screen displayed. Passively waiting for master's commands.")
        watchdog_thread = threading.Thread(target=self.master_watchdog, daemon=True)
        watchdog_thread.start()
        try:
            self.listen_for_commands()
        except KeyboardInterrupt:
            self.stop()
    def stop(self):
        self.running = False
        self.player.stop()
        self.sock.close()
        print("Slave stopped.")
if __name__ == "__main__":
    slave = VideoSyncSlave()
    slave.start()
SLAVE_SCRIPT
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
