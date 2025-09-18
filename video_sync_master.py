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
        self.player.play()
        time.sleep(0.2)
        self.player.pause()
        self.player.set_position(0)

    def play_video(self):
        self.player.play()
        self.is_playing = True

    def start(self):
        print("--- Video Sync Master ---")
        if not self.load_video(): self.stop(); return

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

                print("Video ended. Resetting for loop.")
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
