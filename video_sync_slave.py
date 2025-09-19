#!/usr/bin/env python3
# ==================================================================================
# Synchronized Video Playback - Slave Node
# ==================================================================================
import vlc
import socket
import time
import json
import configparser
import os
import threading

class VideoSyncSlave:
    def __init__(self, config_file='sync_config.ini'):
        self.config = configparser.ConfigParser()
        self.config.read(config_file)

        # Network configuration
        self.master_ip = self.config.get('network', 'master_ip')
        self.sync_port = self.config.getint('network', 'sync_port')

        # VLC instance with hardware acceleration arguments
        vlc_args = [
            '--no-xlib',
            '--quiet',
            '--fullscreen',
            '--no-video-title-show',
            '--no-osd',
            '--avcodec-hw=drm',
            '--codec=hevc_v4l2m2m,hevc',
            '--vout=drm_vout'
        ]
        
        self.instance = vlc.Instance(' '.join(vlc_args))
        self.player = self.instance.media_player_new()
        self.media = None
        self.black_media = self.instance.media_new('/opt/video-sync/black.png')
        
        # Network socket to listen for master commands
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.sock.bind(('', self.sync_port))
        
        self.running = True
        self.last_sync_time = time.time()

    def handle_command(self, message):
        # Ignore commands from other masters on the network
        if message.get('master_ip') != self.master_ip:
            return
        
        # Reset watchdog timer on any valid command
        self.last_sync_time = time.time()
        
        command = message.get('command')
        
        if command == 'stop':
            self.player.set_media(self.black_media)
            self.player.play()

        elif command == 'load':
            video_path = message.get('data', {}).get('video_path')
            if video_path:
                self.media = self.instance.media_new(video_path)

        elif command == 'prepare':
            video_path = message.get('data', {}).get('video_path')
            # Load media if it's not loaded or if the path has changed.
            if video_path and (not self.media or self.media.get_mrl() != video_path):
                self.media = self.instance.media_new(video_path)
            
            if self.media:
                # Pre-buffer the video to the first frame and pause.
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
                # Silently ignore malformed packets or other errors
                pass

    def master_watchdog(self):
        """Monitors for the master's heartbeat signal and reverts to a black screen on timeout."""
        while self.running:
            time.sleep(2)
            if time.time() - self.last_sync_time > 5:
                print("Master signal lost. Reverting to standby (black screen).")
                self.player.set_media(self.black_media)
                self.player.play()
                # Reset timer to prevent repeated messages
                self.last_sync_time = time.time()

    def start(self):
        print("="*20, "Video Sync Slave", "="*20)
        # Start with a black screen and wait for commands
        self.player.set_media(self.black_media)
        self.player.play()
        print("Waiting for master commands...")
        
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
