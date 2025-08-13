#!/usr/bin/env python3
# ==================================================================================
# Synchronized Video Playback - Slave Node
# Final Version
#
# This script receives commands from the Master to play a video in sync.
# It is self-healing and can recover from a master signal loss.
# ==================================================================================
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
        self.last_sync_time = time.time() # Update watchdog timer on any valid message
        
        command = message.get('command')
        data = message.get('data', {})
        
        if command == 'prepare_play':
            if not self.is_playing:
                # Ensure the main video is loaded, not the black screen
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
        """Monitors the master's heartbeat signal."""
        while self.running:
            time.sleep(2) # Check every 2 seconds
            if (time.time() - self.last_sync_time > 5) and (self.player.get_media() is not self.black_media):
                print("Master signal lost! Reverting to standby (black screen).")
                self.is_playing = False
                self.player.set_media(self.black_media)
                self.player.play()
                self.last_sync_time = time.time() # Reset timer to prevent loop

    def start(self):
        print("="*20, "Video Sync Slave", "="*20)
        if self.start_delay != 0: print(f"Local start delay: {self.start_delay}s")
        
        # 1. Immediately show a black screen to hide the console
        self.black_media = self.instance.media_new('/opt/video-sync/black.png')
        self.player.set_media(self.black_media)
        self.player.play()
        print("Black screen displayed.")
        
        # 2. Proactively prepare the main video to be in a "warm" ready state
        print("Proactively preparing player...")
        self.load_and_prepare(self.video_path)
        print("Slave is ready and listening for master commands.")
        
        # 3. Start all background tasks
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
