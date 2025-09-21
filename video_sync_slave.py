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
        # VERBESSERUNG: Hält die ID der aktuellen Master-Instanz fest
        self.current_sequence_id = None

    def handle_command(self, message):
        # Ignoriere Befehle von einer fremden Master-IP
        if message.get('master_ip') != self.master_ip: return
        
        # VERBESSERUNG: Sequenz-Management zur Erkennung von Master-Neustarts
        incoming_sequence_id = message.get('sequence_id')
        if not incoming_sequence_id: return # Ignoriere Befehle ohne Sequenz-ID

        # Wenn der Master neu gestartet hat (höhere ID), folge dem neuen Master
        if self.current_sequence_id is None or incoming_sequence_id > self.current_sequence_id:
            print(f"Detected new Master sequence. Following ID: {incoming_sequence_id}")
            self.current_sequence_id = incoming_sequence_id
        # Ignoriere veraltete Befehle von einer vorherigen Master-Instanz
        elif incoming_sequence_id < self.current_sequence_id:
            print(f"Ignoring old command from sequence {incoming_sequence_id}")
            return

        self.last_sync_time = time.time()
        command = message.get('command')
        
        if command == 'stop':
            self.player.set_media(self.black_media); self.player.play()
        elif command == 'load':
            video_path = message.get('data', {}).get('video_path')
            if video_path: self.media = self.instance.media_new(video_path)
        elif command == 'prepare':
            video_path = message.get('data', {}).get('video_path')
            # Der originale Code war hier bereits sicher, keine Änderung nötig
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
            except Exception as e:
                print(f"Error processing command: {e}")
                pass

    def master_watchdog(self):
        while self.running:
            time.sleep(2)
            if time.time() - self.last_sync_time > 5:
                print("Master signal lost! Reverting to standby (black screen).")
                self.player.set_media(self.black_media)
                self.player.play()
                # Reset, um auf einen neuen Master oder den alten zu warten
                self.last_sync_time = time.time()
                self.current_sequence_id = None 

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
