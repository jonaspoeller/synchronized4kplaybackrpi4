#!/usr/bin/env python3
# ==================================================================================
# Synchronized Video Playback - Slave Node (FINALE, SCALE-FIX)
#
# LÖSUNG: Verwendet player.video_set_scale(0), um das Bild aggressiv
#         auf Vollbild zu zwingen.
# ==================================================================================
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
