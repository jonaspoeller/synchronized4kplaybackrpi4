#!/bin/bash
# ==================================================================================
# Automated Setup for Synchronized 4K HEVC Video Playback
# Version: Final (mit Overscan-Fix)
#
# Dieses Skript ist für die unbeaufsichtigte Ausführung konzipiert.
# ==================================================================================

set -e

# --- 1. Parameter auswerten ---
while getopts "t:i:m:" opt; do
  case $opt in
    t) node_type_str="$OPTARG"
    ;;
    i) device_ip="$OPTARG"
    ;;
    m) master_ip="$OPTARG"
    ;;
    \?) echo "Ungültige Option: -$OPTARG" >&2; exit 1
    ;;
  esac
done

# --- 2. Validierung der Parameter ---
if [ "$EUID" -ne 0 ]; then echo "FEHLER: Bitte als root (sudo) ausführen."; exit 1; fi
if ! uname -a | grep -q 'aarch64'; then echo "FEHLER: Dieses Skript ist nur für ein 64-bit (aarch64) Raspberry Pi OS vorgesehen."; exit 1; fi
if [ -z "$node_type_str" ] || [ -z "$device_ip" ]; then echo "FEHLER: Parameter fehlen."; exit 1; fi

if [ "$node_type_str" == "master" ]; then node_type="1"; master_ip=$device_ip;
elif [ "$node_type_str" == "slave" ]; then node_type="2"; if [ -z "$master_ip" ]; then echo "FEHLER: Slave benötigt eine Master-IP (-m)."; exit 1; fi
else echo "FEHLER: Ungültiger Rollentyp '$node_type_str'."; exit 1; fi

# 3. System Update
echo "--- Führe vollständiges System-Update durch (dies kann dauern)... ---"
apt-get update && apt-get full-upgrade -y

# 4. Installiere Abhängigkeiten & setze Berechtigungen
echo "--- Installiere Abhängigkeiten und setze Berechtigungen... ---"
apt-get install -y vlc python3-pip python3-vlc ffmpeg
usermod -a -G render,video,audio pi
loginctl enable-linger pi

# 5. Konfiguriere für stillen Bootvorgang & korrekte Videoausgabe
echo "--- Konfiguriere System für einen absolut stillen Bootvorgang... ---"
systemctl set-default multi-user.target
systemctl disable getty@tty1.service

echo "--- Konfiguriere /boot/firmware/config.txt für robuste Videoausgabe... ---"
sed -i '/# --- Video Sync Setup ---/,/# --- Ende Video Sync Setup ---/d' /boot/firmware/config.txt
cat >> /boot/firmware/config.txt << EOF

# --- Video Sync Setup ---
# Grundkonfiguration für Hardware-Beschleunigung
disable_splash=1
dtoverlay=vc4-kms-v3d-pi4,cma-512
dtoverlay=rpivid-v4l2

# HDMI-Modus explizit erzwingen, um Overscan-Probleme zu vermeiden
disable_overscan=1    # Deaktiviert die Overscan-Korrektur des Pi
hdmi_group=1          # CEA-Modus (für Fernseher)
hdmi_mode=16          # 1080p @ 60Hz. Für 4K@60Hz wäre es hdmi_mode=97
# --- Ende Video Sync Setup ---
EOF

echo "--- Konfiguriere Kernel-Parameter für den leisestmöglichen Boot... ---"
sed -i 's/ quiet//g; s/ loglevel=[0-9]*//g; s/ consoleblank=[0-9]*//g; s/ splash//g; s/ vt.global_cursor_default=[0-9]*//g; s/ logo.nologo//g' /boot/firmware/cmdline.txt
sed -i 's/console=tty1/console=tty3/g' /boot/firmware/cmdline.txt
sed -i '1 s/$/ quiet loglevel=0 vt.global_cursor_default=0 logo.nologo/' /boot/firmware/cmdline.txt

# 6. Installiere Anwendung
INSTALL_DIR="/opt/video-sync"
mkdir -p $INSTALL_DIR
cd $INSTALL_DIR

if [ "$node_type" == "1" ]; then
    # --- MASTER SETUP ---
    echo "--- Erstelle Master-Konfiguration... ---"
    cat > sync_config.ini << EOF
[network]
master_ip = $master_ip
broadcast_ip = $(echo $device_ip | cut -d. -f1-3).255
sync_port = 5555
[video]
file_path = /home/pi/video.mp4
loop_delay = 0.5
EOF
    echo "--- Installiere Master-Skript... ---"
    cat > video_sync_master.py << 'MASTER_SCRIPT'
#!/usr/bin/env python3
import vlc, socket, time, json, configparser, os
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
        vlc_args = ['--no-xlib', '--quiet', '--fullscreen', '--no-video-title-show', '--no-osd', '--avcodec-hw=drm', '--codec=hevc_v4l2m2m,hevc', '--vout=drm_vout']
        self.instance = vlc.Instance(' '.join(vlc_args))
        self.player = self.instance.media_player_new()
        self.media = None
        self.black_media = self.instance.media_new('/opt/video-sync/black.png')
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
        self.send_broadcast({'command': 'prepare'}); time.sleep(0.2)
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
                self.send_broadcast({'command': 'prepare'})
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
    echo "--- Erstelle Slave-Konfiguration... ---"
    cat > sync_config.ini << EOF
[network]
master_ip = $master_ip
sync_port = 5555
EOF
    echo "--- Erstelle schwarzes Bild für den Start... ---"
    ffmpeg -f lavfi -i color=c=black:s=1920x1080:d=1 -vframes 1 /opt/video-sync/black.png -y >/dev/null 2>&1
    echo "--- Installiere Slave-Skript... ---"
    cat > video_sync_slave.py << 'SLAVE_SCRIPT'
#!/usr/bin/env python3
import vlc, socket, time, json, configparser, os
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
    def handle_command(self, message):
        if message.get('master_ip') != self.master_ip: return
        command = message.get('command')
        if command == 'stop':
            self.player.set_media(self.black_media)
            self.player.play()
        elif command == 'load':
            video_path = message.get('data', {}).get('video_path')
            if video_path and (not self.media or self.media.get_mrl() != video_path):
                self.media = self.instance.media_new(video_path)
        elif command == 'prepare':
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
            except Exception:
                pass
    def start(self):
        self.player.set_media(self.black_media)
        self.player.play()
        try:
            self.listen_for_commands()
        except KeyboardInterrupt:
            self.stop()
    def stop(self):
        self.running = False
        self.player.stop()
        self.sock.close()
if __name__ == "__main__":
    slave = VideoSyncSlave()
    slave.start()
SLAVE_SCRIPT
    chmod +x video_sync_slave.py
    PYTHON_EXEC_PATH=$INSTALL_DIR/video_sync_slave.py
fi

# 7. Erstelle Systemd-Dienst
echo "--- Installiere Systemd-Dienst... ---"
cat > /etc/systemd/system/video-sync.service << EOF
[Unit]
Description=Video Sync Service ($(if [ "$node_type" == "1" ]; then echo "Master"; else echo "Slave"; fi))
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

# 8. Finalisieren
echo "--- Schließe Installation ab... ---"
systemctl daemon-reload
systemctl enable video-sync.service
echo ""
echo "================================================"
echo "      Installation abgeschlossen!"
echo "================================================"
echo "Das System wird in 10 Sekunden automatisch neu gestartet, um alle Änderungen zu aktivieren."
sleep 10
reboot
