Synchronized 4K HEVC Video Playback for Raspberry Pi
============================================

A system for synchronized, seamless looping video playback across multiple Raspberry Pi 4 devices. It is designed for 24/7 operation in environments like video walls or digital signage.

## Key Features

*   **State-Based Synchronization:** Ensures precise playback timing across all devices.
*   **Master-Failure Recovery:** A watchdog on each slave reverts to a safe black screen if the master signal is lost.
*   **Automatic Late-Joiner Integration:** Newly started slaves are automatically integrated into the next playback loop.
*   **Optimized for Raspberry Pi 4:** Delivers hardware-accelerated playback of 4K/60fps 8-bit HEVC video via `v4l2m2m` and `drm_vout`.
*   **Headless Operation:** Provides a silent boot process and runs as a background `systemd` service.
*   **Multi-Group Support:** Allows multiple independent playback groups to operate on the same network via selectable ports.
*   **Automated Setup:** An interactive script handles all system configuration and dependency installation.

---

## How It Works

The system uses a Master-Slave architecture where one Raspberry Pi acts as the "conductor" (Master) and all others act as the "orchestra" (Slaves).

1.  **Architecture:** The system uses a Master-Slave model. A single Master node controls multiple Slave nodes via UDP broadcast packets. Communication is unidirectional from Master to Slaves.

2.  **Synchronization:** The Master enforces synchronization by broadcasting a strict command sequence (`stop` -> `load` -> `prepare` -> `play`) at the beginning of each loop.

3.  **Reliability:** Slaves are passive receivers that execute commands. The watchdog mechanism ensures a predictable state during a master outage. The looping command sequence allows for automatic recovery and integration of slaves.

---

## Prerequisites

-   2 or more Raspberry Pi 4 devices.

-   A fresh installation of Raspberry Pi OS (64-bit) Bookworm on each SD card.

-   A stable, wired (Ethernet) network connection.

-   Each Pi must have a unique, fixed IP address.

-   The video file, named `video.mp4`, must be located in `/home/pi/` on every device.

---

## Installation

The installation is a step-by-step process. The following must be performed on **every** Pi (both Master and Slaves). The setup will do a full apt upgrade and reboot afterwards. 

#### Step 1: Prepare the System

Before running the installer, each device must be properly configured.

1.  **Set a Static IP Address:** A static IP is essential for system stability. This can be done via the command line using `nmcli`.
    *   First, find your connection name (usually `"Wired connection 1"`):
        ```bash
        nmcli connection show
        ```
    *   Use the following command to set the static IP, gateway, and DNS. **Replace the example values with your network's settings.**
        ```bash
        sudo nmcli c mod "Wired connection 1" ipv4.method manual \
        ipv4.addresses 10.0.0.220/24 \
        ipv4.gateway 10.0.0.1 \
        ipv4.dns "8.8.8.8,1.1.1.1"
        ```
    *   Apply the changes by restarting the connection:
        ```bash
        sudo nmcli c down "Wired connection 1"; sudo nmcli c up "Wired connection 1"
        ```
        A reboot will also apply the settings. Verify the new IP with `ip a`.

2.  **Place the Video File:** Copy your video file to the home directory of each Pi. The system expects the file at this exact location:
    `/home/pi/video.mp4`

#### Step 2: Run the Automated Installer

Once the static IP is set and the video file is in place, run the automated setup script.

Connect to each Pi via SSH and execute the following command:
```bash
wget -O - https://raw.githubusercontent.com/jonaspoeller/synchronized4kplaybackrpi4/refs/heads/main/setup_video_sync.sh | sudo bash
```
#### Step 3: Follow the Interactive Prompts

The script will guide you through the final configuration by asking for:
*   The static IP address of the current device.
*   The network port for this sync group (e.g., `5555`).
*   The role of the device (Master or Slave).
*   The IP address of the Master (if configuring a Slave).


The device will reboot automatically upon completion. After the reboot, the system is fully configured and will start playback automatically.

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
```

- **loop_delay:** Pause in seconds between the end of one video loop and the start of the next.

---

### Slave Configuration

Path: `/opt/video-sync/sync_config.ini` on a Slave

```ini
[network]
master_ip = 192.168.1.10
sync_port = 5555
```

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
wget -O - https://github.com/jonaspoeller/synchronized4kplaybackrpi4/releases/latest/download/uninstall.sh | sudo bash
```

The script will clean up all files and services and reboot the Pi back into the standard graphical desktop environment.

---

## License

This project is licensed under the MIT License. See the LICENSE file for details.

© [2025] [Jonas Pöller]
