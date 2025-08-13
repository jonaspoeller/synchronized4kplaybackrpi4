#!/bin/bash
# ==================================================================================
# Automated Setup for Synchronized 4K HEVC Video Playback
# Version: 1.0
#
# This script configures a Raspberry Pi (4 or newer) as a Master or Slave node
# for a synchronized video wall system. It handles system updates, kernel parameters
# for a completely silent boot, application installation, and service creation.
#
# PREREQUISITE: A fresh installation of Raspberry Pi OS (64-bit).
#
# Run with: sudo bash setup_video_sync.sh
# ==================================================================================

set -e
echo "================================================="
echo "Setup for Synchronized 4K Video Playback (v1.0)"
echo "================================================="

# --- 1. System Check ---
if [ "$EUID" -ne 0 ]; then echo "ERROR: Please run this script as root (use sudo)."; exit 1; fi
if ! uname -a | grep -q 'aarch64'; then echo "ERROR: This script is designed for a 64-bit (aarch64) Raspberry Pi OS only."; exit 1; fi

# --- 2. User Input ---
echo ""
echo "--- Network Configuration (Manual) ---"
echo "Please ensure this device has a fixed IP address (static or via DHCP reservation)."
read -p "Enter the IP address for this device: " device_ip
broadcast_ip=$(echo $device_ip | cut -d. -f1-3).255
sync_port=5555
echo "-> Broadcast address will be set to '$broadcast_ip'."
echo "-> Sync port will be set to '$sync_port'."
echo ""
echo "--- Node Role Configuration ---"
echo "1) Master Node (controls playback and plays video itself)"
echo "2) Slave Node (is controlled by the master)"
read -p "Select the node type [1-2]: " node_type
if [ "$node_type" == "2" ]; then read -p "Enter the Master Node's IP address: " master_ip; else master_ip=$device_ip; fi

# --- 3. System Update ---
echo ""
echo "--- Performing full system update (this may take a while)... ---"
apt-get update
apt-get full-upgrade -y

# --- 4. Install Dependencies & Set Permissions ---
echo ""
echo "--- Installing dependencies and setting permissions... ---"
apt-get install -y vlc python3-pip python3-vlc ffmpeg
usermod -a -G render,video,audio pi
loginctl enable-linger pi

# --- 5. Configure for Silent Boot ---
echo ""
echo "--- Configuring system for a completely silent boot... ---"
echo "Setting default boot target to console..."
systemctl set-default multi-user.target
echo "Disabling console login prompt service (getty@tty1)..."
systemctl disable getty@tty1.service
echo "Configuring /boot/firmware/config.txt..."
sed -i '/# --- Video Sync Setup ---/,/# --- Ende Video Sync Setup ---/d' /boot/firmware/config.txt
cat >> /boot/firmware/config.txt << EOF

# --- Video Sync Setup ---
disable_splash=1
dtoverlay=vc4-kms-v3d-pi4,cma-512
dtoverlay=rpivid-v4l2
# --- Ende Video Sync Setup ---
EOF
echo "Configuring kernel parameters for the quietest possible boot..."
sed -i 's/ quiet//g; s/ loglevel=[0-9]*//g; s/ consoleblank=[0-9]*//g; s/ splash//g; s/ vt.global_cursor_default=[0-9]*//g; s/ logo.nologo//g' /boot/firmware/cmdline.txt
sed -i 's/console=tty1/console=tty3/g' /boot/firmware/cmdline.txt
sed -i '1 s/$/ quiet loglevel=0 vt.global_cursor_default=0 logo.nologo/' /boot/firmware/cmdline.txt

# --- 6. Install Application ---
INSTALL_DIR="/opt/video-sync"
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

if [ "$node_type" == "1" ]; then
    # --- MASTER SETUP ---
    echo "--- Creating Master configuration... ---"
    cat > sync_config.ini << EOF
[network]
master_ip = $master_ip
broadcast_ip = $broadcast_ip
sync_port = $sync_port
[video]
file_path = /home/pi/video.mp4
loop_delay = 0.5
start_delay = 0.0
initial_prepare_time = 10
EOF
    echo "--- Installing Master script... ---"
    cat > video_sync_master.py << 'MASTER_SCRIPT'
#!/usr/bin/env python3
import vlc, socket, time, json, threading, configparser, os
from datetime import datetime
class VideoSyncMasterPlayer:
    def __init__(self, config_file='sync_config.ini'):
        self.config = configparser.ConfigParser()
        self.config.read(config_file)
        self.broadcast_ip = self.config.get('network', 'broadcast_ip')
        self.sync_port = self.config.getint('network', 'sync_port')
        self.master_ip = self.config.get('network', 'master_ip')
        self.video_path = self.config.get('video', 'file_path')
        self.loop_delay = self.config.getfloat('video', 'loop_delay', fallback=0.5)
        self.start_delay = self.config.getfloat('video', 'start_delay', fallback=0.0)
        self.initial_prepare_time = self.config.getfloat('video', 'initial_prepare_time', fallback=7.0)
        vlc_args = ['--no-xlib', '--quiet', '--fullscreen', '--no-video-title-show', '--no-osd', '--avcodec-hw=drm', '--codec=hevc_v4l2m2m,hevc', '--vout=drm_vout', '--network-caching=1000', '--file-caching=2000', '--clock-jitter=0', '--clock-synchro=0']
        self.instance = vlc.Instance(' '.join(vlc_args))
        if self.instance is None: raise RuntimeError("VLC instance could not be created.")
        self.player = self.instance.media_player_new()
        self.media = None
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.is_playing = False
        self.running = True
    def send_broadcast(self, message):
        message['master_ip'] = self.master_ip
        try:
            for _ in range(3):
                self.sock.sendto(json.dumps(message).encode('utf-8'), (self.broadcast_ip, self.sync_port))
                time.sleep(0.05)
        except Exception as e: print(f"Broadcast error: {e}")
    def load_video(self):
        if not os.path.exists(self.video_path):
            print(f"ERROR: Video file not found: {self.video_path}")
            return False
        print(f"Loading video: {self.video_path}"); self.media = self.instance.media_new(self.video_path); self.player.set_media(self.media)
        print("Pre-buffering video..."); self.player.play(); time.sleep(0.2); self.player.pause(); self.player.set_position(0)
        print("Video is ready.")
        return True
    def start_playback_loop(self):
        while self.running:
            print("\n--- Starting new playback loop ---")
            sync_time = time.time() + 1.5
            print(f"Sending 'prepare_play' for slave sync time: {sync_time}")
            self.send_broadcast({'command': 'prepare_play', 'data': {'sync_time': sync_time}})
            time.sleep(max(0, sync_time - time.time()))
            if self.start_delay != 0:
                print(f"Applying local master delay: {self.start_delay}s")
                time.sleep(self.start_delay)
            self.player.play()
            self.is_playing = True
            print(f"Master playback started at {datetime.now().strftime('%H:%M:%S.%f')[:-3]}")
            while self.is_playing and self.running:
                time.sleep(1)
                self.send_broadcast({'command': 'sync'}) # Watchdog heartbeat
                if self.player.get_state() == vlc.State.Ended:
                    self.is_playing = False
            if not self.running: break
            print("Video ended. Resetting for seamless loop.")
            self.player.set_media(self.media)
            self.player.pause()
            self.send_broadcast({'command': 'reset'})
            print(f"Loop delay: waiting {self.loop_delay}s...")
            time.sleep(self.loop_delay)
    def start(self):
        print("="*20, "Video Sync Master", "="*20)
        if not self.load_video(): self.stop(); return
        print("\nPhase 1: Preparing all nodes for synchronized start...")
        self.send_broadcast({'command': 'load', 'data': {'video_path': self.video_path}})
        print(f"Phase 2: Waiting {self.initial_prepare_time}s to ensure all slaves are ready...")
        time.sleep(self.initial_prepare_time)
        print("\n--- All nodes should be ready. Starting playback loop. ---")
        try: self.start_playback_loop()
        except KeyboardInterrupt: print("\nShutting down...")
        finally: self.stop()
    def stop(self):
        print("Stopping playback and sending stop signal.")
        self.running = False; self.is_playing = False
        self.send_broadcast({'command': 'stop'})
        self.player.stop(); self.sock.close()
        print("Master stopped.")
if __name__ == "__main__":
    master = VideoSyncMasterPlayer()
    master.start()
MASTER_SCRIPT
    chmod +x video_sync_master.py
    PYTHON_EXEC_PATH=$INSTALL_DIR/video_sync_master.py
else
    # --- SLAVE SETUP ---
    echo "--- Creating Slave configuration... ---"
    cat > sync_config.ini << EOF
[network]
master_ip = $master_ip
slave_ip = $device_ip
broadcast_ip = $broadcast_ip
sync_port = $sync_port
[video]
file_path = /home/pi/video.mp4
start_delay = 0.0
EOF
    echo "--- Creating black image for startup... ---"
    ffmpeg -f lavfi -i color=c=black:s=1920x1080:d=1 -vframes 1 /opt/video-sync/black.png -y >/dev/null 2>&1
    
    echo "--- Installing Slave script... ---"
    cat > video_sync_slave.py << 'SLAVE_SCRIPT'
#!/usr/bin/env python3
import vlc, socket, time, json, threading, configparser, os
from datetime import datetime
class VideoSyncSlave:
    def __init__(self, config_file='sync_config.ini'):
        self.config = configparser.ConfigParser()
        self.config.read(config_file)
        self.slave_ip = self.config.get('network', 'slave_ip')
        self.sync_port = self.config.getint('network', 'sync_port')
        self.master_ip = self.config.get('network', 'master_ip')
        self.video_path = self.config.get('video', 'file_path')
        self.start_delay = self.config.getfloat('video', 'start_delay', fallback=0.0)
        vlc_args = ['--no-xlib', '--quiet', '--fullscreen', '--no-video-title-show', '--no-osd', '--avcodec-hw=drm', '--codec=hevc_v4l2m2m,hevc', '--vout=drm_vout', '--network-caching=1000', '--file-caching=2000', '--clock-jitter=0', '--clock-synchro=0']
        self.instance = vlc.Instance(' '.join(vlc_args))
        if self.instance is None: raise RuntimeError("VLC instance could not be created.")
        self.player = self.instance.media_player_new()
        self.media = None
        self.black_media = None
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(('', self.sync_port))
        self.is_playing = False
        self.running = True
        self.last_sync_time = time.time()
    def load_and_prepare(self, video_path=None):
        if video_path: self.video_path = video_path
        if not os.path.exists(self.video_path): return False
        self.media = self.instance.media_new(self.video_path)
        self.player.set_media(self.media)
        print("Video loaded. Pausing on first frame.")
        self.player.play(); time.sleep(0.2); self.player.pause(); self.player.set_position(0)
        return True
    def handle_sync_message(self, message):
        if message.get('master_ip') != self.master_ip: return
        self.last_sync_time = time.time()
        command = message.get('command')
        data = message.get('data', {})
        if command == 'prepare_play':
            if not self.is_playing:
                if self.player.get_media() is not self.media:
                    self.player.set_media(self.media)
                    self.player.pause()
                sync_time = data.get('sync_time')
                if sync_time:
                    delay_until_sync = sync_time - time.time()
                    total_delay = delay_until_sync + self.start_delay
                    print(f"Waiting {total_delay:.3f}s for synchronized start.")
                    if total_delay > 0: threading.Timer(total_delay, self.start_playback).start()
                    else: self.start_playback()
        elif command == 'reset':
            print("Resetting for seamless loop.")
            self.player.set_media(self.media)
            self.player.pause()
            self.is_playing = False
        elif command == 'load':
             self.load_and_prepare(data.get('video_path', self.video_path))
        elif command == 'stop':
            self.player.stop()
            self.is_playing = False
    def start_playback(self):
        self.player.play(); self.is_playing = True
        self.last_sync_time = time.time()
        print(f"Playback started at {datetime.now().strftime('%H:%M:%S.%f')[:-3]}")
    def listen_for_sync(self):
        print(f"Listening for commands from master {self.master_ip}...")
        self.sock.settimeout(1.0)
        while self.running:
            try:
                data, addr = self.sock.recvfrom(1024)
                threading.Thread(target=self.handle_sync_message, args=(json.loads(data.decode('utf-8')),), daemon=True).start()
            except socket.timeout: continue
            except Exception: pass
    def _player_monitor(self):
        while self.running:
            time.sleep(0.2)
            if self.is_playing and self.player.get_state() in (vlc.State.Ended, vlc.State.Error):
                print("Own player state is 'Ended/Error'. Resetting playing status.")
                self.is_playing = False
    def _master_watchdog(self):
        while self.running:
            time.sleep(2)
            if (time.time() - self.last_sync_time > 5) and (self.player.get_media() is not self.black_media):
                print("Master signal lost! Reverting to standby (black screen).")
                self.is_playing = False
                self.player.set_media(self.black_media)
                self.player.play()
                self.last_sync_time = time.time()
    def start(self):
        print("="*20, "Video Sync Slave", "="*20)
        if self.start_delay != 0: print(f"Local start delay: {self.start_delay}s")
        self.black_media = self.instance.media_new('/opt/video-sync/black.png')
        self.player.set_media(self.black_media)
        self.player.play()
        print("Black screen displayed.")
        print("Proactively preparing player...")
        self.load_and_prepare(self.video_path)
        print("Slave is ready and listening for master commands.")
        threading.Thread(target=self.listen_for_sync, daemon=True).start()
        threading.Thread(target=self._player_monitor, daemon=True).start()
        threading.Thread(target=self._master_watchdog, daemon=True).start()
        try:
            while self.running: time.sleep(1)
        except KeyboardInterrupt: pass
        finally: self.stop()
    def stop(self):
        self.running = False; self.is_playing = False; self.player.stop(); self.sock.close()
        print("Slave stopped.")
if __name__ == "__main__":
    VideoSyncSlave().start()
SLAVE_SCRIPT
    chmod +x video_sync_slave.py
    PYTHON_EXEC_PATH=$INSTALL_DIR/video_sync_slave.py
fi

# 7. Create Systemd Service
echo "--- Installing Systemd service... ---"
cat > /etc/systemd/system/video-sync.service << EOF
[Unit]
Description=Video Sync Service ($(if [ "$node_type" == "1" ]; then echo "Master"; else echo "Slave"; fi))
After=network-online.target
[Service]
Type=simple
User=pi
WorkingDirectory=$INSTALL_DIR
$(if [ "$node_type" == "1" ]; then
    echo "ExecStartPre=/bin/sleep 10"
else
    echo "ExecStartPre=/bin/sleep 5"
fi)
Environment="XDG_RUNTIME_DIR=/run/user/1000"
ExecStart=/usr/bin/python3 $PYTHON_EXEC_PATH
Restart=always
RestartSec=5
[Install]
WantedBy=multi-user.target
EOF

# 8. Create Helper Scripts & Finalize
echo "--- Creating helper scripts... ---"
cat > /usr/local/bin/video-sync-start << EOF
#!/bin/bash
sudo systemctl start video-sync.service
EOF
chmod +x /usr/local/bin/video-sync-start
cp /usr/local/bin/video-sync-start /usr/local/bin/video-sync-stop
sed -i 's/start/stop/' /usr/local/bin/video-sync-stop
cp /usr/local/bin/video-sync-start /usr/local/bin/video-sync-status
sed -i 's/start/status/' /usr/local/bin/video-sync-status
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
echo ""
echo "All configurations have been applied."
echo "The system will automatically reboot in 10 seconds to activate all changes."
echo "After the reboot, please place your video file at /home/pi/video.mp4"
echo ""
sleep 10
reboot
