<h1 align="center">
  FFmpeg Auto Transcoder
</h1>

<p align="center">
  Automated movie and TV episode transcoding for <b>Linux servers</b> and <b>NAS systems</b>, powered by <b>FFmpeg</b> and <b>NVIDIA NVENC</b>.
</p>

<p align="center">

![License](https://img.shields.io/badge/license-MIT-green)
![Linux](https://img.shields.io/badge/Linux-Server-orange)
![Docker](https://img.shields.io/badge/Docker-Compose-2496ED)
![NAS](https://img.shields.io/badge/NAS-Ready-blueviolet)
![NVIDIA](https://img.shields.io/badge/NVIDIA-NVENC-76B900)
![FFmpeg](https://img.shields.io/badge/FFmpeg-HEVC-blue)

</p>

<p align="center">
  Designed for unattended use alongside <b>Jellyfin</b>, <b>Plex</b>, <b>Emby</b>, and other self-hosted media servers.
</p>

<p align="center">
  <img src="docs/images/monitor.png" width="800">
</p>


---

# Built for Linux Servers and NAS

**FFmpeg Auto Transcoder** is a background service for home servers, media servers, NAS devices, and Linux virtual machines.

It continuously watches a single input queue, identifies movies and TV episodes through **TMDb** and **OMDb**, analyzes them with **FFprobe**, and transcodes them to **H.265 / HEVC** using **NVIDIA NVENC** hardware acceleration.

The project is designed to run without a desktop environment. Once installed, new media can be added through a network share, SFTP, SMB, NFS, or any other method that writes files into the `incoming` directory.

The storage model is intentionally simple:

- One media root.
- One incoming queue.
- One processing directory.
- One final library.
- One set of logs and recovery directories.

This makes it suitable for a single-disk server, a NAS shared folder, or a storage pool mounted as one filesystem.

---

# Main Features

- Automatic discovery and processing of new media files.
- Movie and TV episode detection.
- Support for common episode patterns such as `S01E03`, `1x03`, and `Cap.302`.
- Automatic metadata lookup through TMDb and OMDb.
- NVIDIA NVENC hardware-accelerated H.265 / HEVC encoding.
- Automatic media analysis with FFprobe.
- Configurable output size, minimum bitrate, and resolution.
- Preservation of audio and subtitle streams.
- Real-time terminal monitor available through a web browser.
- GPU, encoder, decoder, VRAM, temperature, and power monitoring.
- Queue display with separate movie and episode counts.
- Automatic recovery from stalled FFmpeg processes.
- Native systemd installation for Linux servers.
- Docker Compose deployment for Linux and compatible NAS systems.
- Detailed logs and failed-file recovery.

---

# Typical Use Cases

## Home Media Server

Run the transcoder alongside Jellyfin, Plex, or Emby. Copy new media into `incoming` and let the service process it unattended.

## NAS with Docker Compose

Use a NAS that supports Docker Compose, NVIDIA GPU access, and bind-mounted shared folders. The project uses one host media path mounted inside the containers as `/media`.

## Dedicated Linux Transcoding Server

Install the project as a native systemd service on Ubuntu Server, Debian, Linux Mint, or another compatible Linux distribution.

## Virtual Machine or Container Host

Run it inside a Linux VM or container host with access to an NVIDIA GPU and the media filesystem.

---

# Requirements

## Hardware

- A supported NVIDIA GPU with NVENC.
- Sufficient free disk space for the source and temporary output files.
- A local or mounted filesystem available to the transcoder.

## Native Linux Installation

The installer uses the following tools:

- Bash
- FFmpeg and FFprobe
- NVIDIA drivers and `nvidia-smi`
- `jq`
- `curl`
- `bc`
- `ttyd`
- `rsync`
- systemd

## Docker Compose Installation

The Docker deployment requires:

- Docker Engine
- Docker Compose
- NVIDIA drivers on the host
- NVIDIA Container Toolkit
- A NAS or Linux host capable of exposing the NVIDIA GPU to containers

> Not every NAS supports NVIDIA GPU passthrough. Check your NAS platform before using the Docker deployment.

---

# Storage Layout

The application manages one media root:

```text
MEDIA_DIR/
├── incoming/
├── processing/
├── library/
├── completed/
├── failed/
├── logs/
└── temp/
```

Directory purpose:

| Directory | Purpose |
|---|---|
| `incoming` | Files waiting to be processed |
| `processing` | Temporary transcoding output |
| `library` | Final transcoded media |
| `completed` | Original files processed successfully |
| `failed` | Original files that could not be processed |
| `logs` | Transcoder logs and monitor status files |
| `temp` | Temporary application data |

The project does not require separate input and output disks. A single disk, NAS share, or mounted storage pool can provide the complete `MEDIA_DIR` structure.

---

# Processing Workflow

```text
incoming
   │
   ▼
metadata detection
TMDb / OMDb
   │
   ▼
media analysis
FFprobe
   │
   ▼
processing
FFmpeg + NVIDIA NVENC
   │
   ├── success ──► library + completed
   │
   └── failure ──► failed
```

For every supported file placed in `incoming`, the application:

1. Detects whether it is a movie or TV episode.
2. Cleans and normalizes the filename.
3. Looks up metadata through TMDb and OMDb.
4. Analyzes video, audio, subtitle, HDR, and Dolby Vision information.
5. Calculates the target bitrate.
6. Transcodes the video with NVIDIA NVENC.
7. Copies audio and subtitle streams when supported.
8. Moves the final file into `library`.
9. Moves the original into `completed`.
10. Moves the original into `failed` if processing cannot be completed.

---

# Installation

Choose one deployment method. Do not run the native and Docker deployments against the same media directory at the same time.

## Option A: Docker Compose

Docker Compose is usually the easiest option for NAS systems and container-based Linux servers.

Clone the repository:

```bash
git clone https://github.com/mcjmm1-git/ffmpeg-auto-transcoder.git
cd ffmpeg-auto-transcoder/deploy/docker
```

Edit the Compose configuration:

```bash
nano docker-compose.yml
```

Configure at least:

- Host media directory.
- User ID and group ID.
- TMDb API key.
- OMDb API key.
- Time zone (`x-time-zone` at the top of `docker-compose.yml`).
- Target resolution and bitrate settings.

Validate the configuration:

```bash
docker compose config
```

Build and start the services:

```bash
docker compose up -d --build --remove-orphans
```

Check the containers:

```bash
docker compose ps
```

Follow the transcoder logs:

```bash
docker compose logs -f ffmpeg-auto-transcoder
```

Follow the monitor logs:

```bash
docker compose logs -f ffmpeg-monitor
```

Open the web monitor:

```text
http://SERVER_IP:9002
```

Stop the deployment:

```bash
docker compose down --remove-orphans
```

Rebuild after changing project files:

```bash
docker compose up -d --build --force-recreate --remove-orphans
```

## Option B: Native Linux Service

Use the native installer for a dedicated Linux server with systemd.

Clone the repository:

```bash
git clone https://github.com/mcjmm1-git/ffmpeg-auto-transcoder.git
cd ffmpeg-auto-transcoder
```

Make the management scripts executable:

```bash
chmod +x install.sh uninstall.sh
```

Run the installer:

```bash
sudo ./install.sh
```

The installer asks for the application time zone and suggests the server's current zone as the default. The selected value is stored in `/etc/ffmpeg-auto-transcoder/config.sh`; it does not change the server's system-wide time zone.

Edit the configuration:

```bash
sudo nano /etc/ffmpeg-auto-transcoder/config.sh
```

The native configuration includes:

```bash
TIMEZONE="Europe/Madrid"
export TZ="$TIMEZONE"
```

Restart the transcoder after changing the configuration:

```bash
sudo systemctl restart transcoder.service
```

Check service status:

```bash
sudo systemctl status transcoder.service
sudo systemctl status ffmpeg-monitor.service
```

Follow the transcoder log:

```bash
sudo journalctl -u transcoder.service -f
```

Open the native web monitor:

```text
http://SERVER_IP:9001
```

Uninstall the native deployment:

```bash
sudo ./uninstall.sh
```

---

# Docker and NAS Configuration

Docker configuration is stored in:

```text
deploy/docker/docker-compose.yml
```

Set the time zone once near the top of the file:

```yaml
x-time-zone: &time_zone "Europe/Madrid"
```

The same value is passed to both the transcoder and monitor containers as `TZ`, keeping log timestamps and finish-time estimates consistent. Use an IANA zone such as `Europe/Madrid`, `America/New_York`, or `UTC`.

The Docker services share one media mount:

```yaml
volumes:
  - "/path/on/your/server:/media:rw"
```

A typical NAS path might be:

```text
/volume1/media-transcoder
/mnt/user/media-transcoder
/mnt/pool1/media-transcoder
```

Use a path appropriate for your own server or NAS platform.

## File Permissions

The transcoder and monitor must be able to read and write the mounted media directory.

For Docker, configure the container user with the correct host UID and GID. You can check them on Linux with:

```bash
id
```

For a NAS, ensure the selected account has read and write permission on the shared folder.

## Network Shares

`MEDIA_DIR` may be located on a mounted SMB or NFS share, but transcoding performance and reliability depend on network throughput and mount stability.

For best results, keep `processing` on fast local or directly attached storage whenever possible.

---

# Configuration

## Native Installation

```text
/etc/ffmpeg-auto-transcoder/config.sh
```

## Docker Compose

```text
deploy/docker/docker-compose.yml
```

Common settings include:

- Media root path.
- Target output size.
- Reference duration used for bitrate calculation.
- Minimum video bitrate.
- Target width and height.
- TMDb API key.
- OMDb API key.
- Container UID and GID.
- Time zone.
- Monitor port.

---

# TMDb and OMDb

Metadata lookup uses two external services:

- TMDb identifies movies, TV series, seasons, and episodes.
- OMDb provides IMDb rating, Metascore, director, and related IMDb data when available.

Create personal API keys:

- TMDb: https://www.themoviedb.org/settings/api
- OMDb: https://www.omdbapi.com/apikey.aspx

The application can still transcode without valid API keys, but automatic identification and metadata enrichment will be unavailable.

Do not commit API keys to GitHub. Store them only in your local configuration or Docker environment.

---

# Supported Media Names

Movie examples:

```text
Alien (1979).mkv
1979 Alien.mkv
Blade.Runner.1982.1080p.BluRay.mkv
```

Episode examples:

```text
Silo.S03E02.mkv
Silo.3x02.mkv
Silo [HDTV 720p][Cap.302].mkv
```

The filename parser removes common release tags such as resolution, codec, source, HDR, audio, and language labels before searching TMDb.

Clear names and explicit years or episode numbers produce the most reliable metadata matches.

---

# Web Monitor

The included terminal monitor is exposed through `ttyd`, allowing it to be viewed from a browser on another computer.

During an active transcode it displays:

- Current status.
- Detected title and source filename.
- Progress bar and percentage.
- Processed time, duration, and ETA.
- Expected completion time.
- FPS and encoding speed.
- Up to four queued files.
- Remaining movie and episode counts.
- NVIDIA GPU model.
- GPU, encoder, and decoder utilization.
- VRAM usage.
- GPU temperature and power draw.

The monitor automatically switches to an idle view when no file is being processed.

## Native Linux

```text
http://SERVER_IP:9001
```

## Docker Compose

```text
http://SERVER_IP:9002
```

Only expose the monitor port to trusted networks. The monitor is intended for local server and home-network use.

---

# Logs and Maintenance

Application logs are stored in:

```text
MEDIA_DIR/logs/
```

## Native Linux

```bash
sudo systemctl status transcoder.service
sudo systemctl restart transcoder.service
sudo journalctl -u transcoder.service -f
```

## Docker Compose

```bash
docker compose ps
docker compose logs -f ffmpeg-auto-transcoder
docker compose restart
```

---

# Updating

## Native Linux

From the repository directory:

```bash
git pull
sudo ./install.sh
```

The installer updates the application while preserving the existing configuration and media directory.

## Docker Compose

From the repository root:

```bash
git pull
cd deploy/docker
docker compose up -d --build --force-recreate --remove-orphans
```

---

# Troubleshooting

## NVIDIA GPU Is Not Available

Check the host:

```bash
nvidia-smi
```

For Docker, also verify that the NVIDIA Container Toolkit is installed and that the container can access the GPU.

## Permission Denied

Confirm that the service user or container UID/GID can write to every directory under `MEDIA_DIR`.

## Metadata Is Not Found

Check that:

- API keys are valid.
- The server has internet access.
- The filename contains a clear title.
- Movies include a year when possible.
- Episodes include a season and episode number.

## File Remains in `failed`

Inspect the latest log in `MEDIA_DIR/logs/` or follow the systemd/Docker logs for the exact FFmpeg error.

---

# Project Structure

```text
ffmpeg-auto-transcoder/
├── transcoder.sh
├── monitor.sh
├── monitor-web.sh
├── install.sh
├── uninstall.sh
├── lib/
│   ├── config.sh
│   ├── omdb.sh
│   ├── theme.sh
│   └── tmdb.sh
├── templates/
├── deploy/
│   └── docker/
└── README.md
```

---

# Security Notes

- Never commit TMDb or OMDb API keys.
- Do not expose the monitor directly to the public internet.
- Use firewall rules or a trusted reverse proxy when remote access is required.
- Run containers with a non-root UID and GID whenever possible.
- Keep Docker, FFmpeg, NVIDIA drivers, and the host operating system updated.

---

# Contributing

Bug reports, documentation improvements, and pull requests are welcome.

When reporting a problem, include:

- Installation method: native or Docker.
- Linux distribution or NAS platform.
- GPU model and driver version.
- FFmpeg version.
- Relevant log output with API keys and private paths removed.

---

# Roadmap

Possible future improvements include:

- Additional transcoding profiles.
- More metadata providers.
- Improved episode and filename detection.
- Expanded monitoring and statistics.
- Additional Docker and NAS documentation.
- Optional notifications when jobs complete or fail.

---

# Acknowledgements

This project is built on the work of:

- FFmpeg
- NVIDIA NVENC
- The Movie Database (TMDb)
- OMDb API
- ttyd

---

# License

This project is released under the **MIT License**.

You are free to use, modify, and distribute it in accordance with the license terms.

---

<p align="center">
  Built for unattended transcoding on Linux servers and NAS systems.
</p>
