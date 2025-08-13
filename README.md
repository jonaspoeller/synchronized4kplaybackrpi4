# Synchronized 4K HEVC Video Playback for Raspberry Pi

A robust, self-healing system for playing perfectly synchronized, seamless video loops across multiple Raspberry Pi 4 devices. Designed for video walls, art installations, and any application requiring flawless multi-screen playback without a central, expensive video controller.

This project is the result of an intensive, iterative development and debugging process, resulting in a highly reliable, "set it and forget it" solution.

---

## Key Features

- **Perfectly Synchronized Playback:** Starts and loops all screens with millisecond accuracy.
- **Seamless Looping:** Videos loop without any black screen, flicker, or HDMI resync issues by resetting the media stream without releasing the display controller.
- **Rock-Solid Reliability:** The system is designed to be "unbreakable".
  - **Authoritative Master:** The Master node dictates the entire state, ensuring no ambiguity.
  - **Proactive Slaves:** Slaves boot into a prepared, "warm" standby state, ensuring they are instantly ready for a start command, even when joining a running system.
- **Completely Headless Operation:**
  - **Silent Boot:** All Raspberry Pi boot text, logos, and cursors are suppressed for a professional, appliance-like startup.
  - **Console Disabled:** The login prompt on the attached display is permanently disabled, preventing any on-screen text.
- **Fully Automated Setup:** A single, intelligent script handles system updates, dependency installation, boot configuration, and service creation from a fresh Raspberry Pi OS install.
- **Fine-Grained Tuning:** Each device (including the master) has its own local start delay parameter, allowing for precise compensation for different display latencies (e.g., slow TVs vs. fast monitors).
- **Optimized for Raspberry Pi 4:** Utilizes the 64-bit OS, hardware-accelerated HEVC decoding (`v4l2m2m`), and direct-to-display video rendering (`drm_vout`) for maximum performance.

---

## How It Works

The system uses a Master-Slave architecture where one Raspberry Pi acts as the "conductor" (Master) and all others act as the "orchestra" (Slaves).

- **Communication:** The Master sends commands as UDP broadcast packets on the local network. Slaves listen for these commands.
- **Synchronization Logic:**
  - **Authoritative Start Sequence:** Upon starting, the Master follows a strict, unskippable sequence to guarantee a perfect cold start:
    1. It broadcasts a `stop` command to reset any "zombie" slaves from a previous session.
    2. It broadcasts a `load` command, instructing all slaves to load the video and pause on the first frame.
    3. It waits for a generous, configurable `initial_prepare_time` (e.g., 10 seconds) to guarantee every single slave is ready.
    4. Finally, it begins the playback loop by sending a `prepare_play` command with a precise start time in the near future.
  - **Seamless Looping:** Instead of stopping the player (which causes HDMI flicker), the Master and Slaves simply reset the media stream (`set_media()`) at the end of a loop. This resets the video pipeline internally without releasing the display controller, ensuring a seamless transition.
  - **Slave Reliability:** A Slave's life cycle is simple and robust:
    1. On boot, it displays a black image to hide the console.
    2. It immediately and proactively loads the main video, plays it for a fraction of a second, and pauses on the first frame. It is now in a "warm," ready state.
    3. It listens for commands. If it loses the Master's signal for more than 5 seconds, a watchdog automatically returns it to the safe black-screen state, ready for a clean start when the Master reappears.

---

## Prerequisites

- 2 or more Raspberry Pi 4 devices.
- A fresh installation of **Raspberry Pi OS (64-bit) Bookworm** on each SD card.
- A stable, wired (Ethernet) network connection is highly recommended.
- Each Pi must be configured with a **fixed IP address** (either set manually or via DHCP reservation in your router).
- Your video file, named **`video.mp4`**, must be placed in the `/home/pi/` directory on **every** Pi.

---

## Installation

The setup process is fully automated by a single script.

1. **Configure Fixed IPs:** Before running the script, ensure every Pi has its unique, fixed IP address configured and is connected to the network.
2. **Download the Setup Script:** On each Pi, run:

   ```bash
   wget https://raw.githubusercontent.com/jonaspoeller/synchronized4kplaybackrpi4/main/setup_video_sync.sh
   ```

3. **Run the Setup Script:**  
   ```bash
   sudo bash setup_video_sync.sh
   ```

4. **Follow the Prompts:** The script will ask you for:
   - The IP address of the current device.
   - The role of the device (Master or Slave).
   - The IP address of the Master (if configuring a Slave).

5. **Automatic Reboot:** The script will automatically reboot the Pi after the installation is complete.

After the reboot, the system is fully operational and will start automatically.
---

## Configuration

### Master Configuration

Path: `/opt/video-sync/sync_config.ini` on the Master

```ini
[network]
master_ip = 192.168.1.10
broadcast_ip = 192.168.1.255
sync_port = 5555

[video]
file_path = /home/pi/video.mp4
loop_delay = 0.5
start_delay = 0.0
initial_prepare_time = 10
```

- **file_path:** Absolute path to your video file. Must be identical on all devices.
- **loop_delay:** Pause in seconds between the end of one video loop and the start of the next.
- **start_delay:** Local start time offset in seconds for the Master only.
- **initial_prepare_time:** Waiting period in seconds after the Master boots before starting playback.

---

### Slave Configuration

Path: `/opt/video-sync/sync_config.ini` on a Slave

```ini
[network]
master_ip = 192.168.1.10
slave_ip = 192.168.1.11
broadcast_ip = 192.168.1.255
sync_port = 5555

[video]
file_path = /home/pi/video.mp4
start_delay = 0.0
```

- **file_path:** Absolute path to your video file. Must be identical on all devices.
- **start_delay:** Local start time offset for this specific Slave.

---

## Usage & Management

```bash
video-sync-start    # Start the service
video-sync-stop     # Stop the service
video-sync-status   # Check the service status
video-sync-logs     # View live logs
```

---

## Uninstallation

```bash
sudo bash uninstall_video_sync.sh
```

The script will clean up all files and services and reboot the Pi back into the standard graphical desktop environment.

---

## License

This project is licensed under the MIT License. See the LICENSE file for details.

© [2025] [Jonas Pöller]
