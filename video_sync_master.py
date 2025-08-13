#!/usr/bin/env python3
# ==================================================================================
# Synchronized Video Playback - Master Node
# Version: 1.0
#
# This script acts as the central controller and also plays the video.
# It dictates the playback state for all slave nodes on the network.
# ==================================================================================
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
            # Send each command three times to ensure delivery, especially on network startup
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
        try:
            self.start_playback_loop()
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
