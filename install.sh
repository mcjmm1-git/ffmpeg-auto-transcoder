#!/usr/bin/env bash

###############################################################################
# FFmpeg Auto Transcoder
# Installer
###############################################################################

set -e

VERSION="1.1.0"

DEFAULT_INSTALL_DIR="/opt/ffmpeg-auto-transcoder"

###############################################################################
# VARIABLES
###############################################################################

INSTALL_DIR=""
MEDIA_DIR=""
REAL_USER=""
TMDB_API_KEY=""
OMDB_API_KEY=""

###############################################################################
# FUNCTIONS
###############################################################################

check_root() {

    if [[ $EUID -ne 0 ]]; then
        echo
        echo "This installer must be run with sudo."
        echo
        echo "Run:"
        echo
        echo "sudo ./install.sh"
        echo
        exit 1
    fi

}

detect_user() {

    REAL_USER="${SUDO_USER:-$(logname)}"

}

detect_package_manager() {

    if command -v apt >/dev/null 2>&1; then
        PKG_MANAGER="apt"

    elif command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"

    elif command -v pacman >/dev/null 2>&1; then
        PKG_MANAGER="pacman"

    elif command -v zypper >/dev/null 2>&1; then
        PKG_MANAGER="zypper"

    else
        echo
        echo "No supported package manager found."
        exit 1
    fi

}

check_nvidia() {

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        echo
        echo "ERROR: No NVIDIA GPU detected."
        echo
        echo "FFmpeg Auto Transcoder requires NVIDIA NVENC."
        echo
        exit 1
    fi

}

check_dependencies() {

    local dependencies=(
        rsync
    )

    for program in "${dependencies[@]}"; do

        if ! command -v "$program" >/dev/null 2>&1; then
            echo
            echo "ERROR: $program is not installed."
            echo
            exit 1
        fi

    done

}

install_package() {

    local PACKAGE="$1"

    case "$PKG_MANAGER" in

        apt)
            apt install -y "$PACKAGE"
            ;;

        dnf)
            dnf install -y "$PACKAGE"
            ;;

        pacman)
            pacman -Sy --noconfirm "$PACKAGE"
            ;;

        zypper)
            zypper install -y "$PACKAGE"
            ;;

    esac

    if ! command -v "$PACKAGE" >/dev/null 2>&1; then
        echo
        echo "ERROR: Failed to install '$PACKAGE'."
        exit 1
    fi

}

install_dependencies() {

    echo
    echo "[1/7] Installing dependencies..."
    echo

    local REQUIRED=(
        rsync
        ffmpeg
        jq
        curl
        bc
        ttyd
    )

    for PACKAGE in "${REQUIRED[@]}"; do

        if command -v "$PACKAGE" >/dev/null 2>&1; then
            echo "✔ $PACKAGE"
            continue
        fi

        echo "Installing $PACKAGE..."

        install_package "$PACKAGE"

    done

}

ask_install_directory() {

    while true; do

        echo
        read -rp "Installation directory [/opt/ffmpeg-auto-transcoder]: " INSTALL_DIR

        if [[ -z "$INSTALL_DIR" ]]; then
            INSTALL_DIR="/opt/ffmpeg-auto-transcoder"
        fi

        break

    done

}

ask_media_directory() {

    while true; do

        echo
        echo "Example: /mnt/dd2"
        echo

        read -rp "Media library path: " MEDIA_DIR

        if [[ -z "$MEDIA_DIR" ]]; then
            echo
            echo "Please enter a valid path."
            continue
        fi

        if [[ ! -d "$MEDIA_DIR" ]]; then

            echo
            echo "Directory does not exist."
            echo

            read -rp "Create it? [Y/n]: " REPLY

            if [[ "$REPLY" =~ ^[Nn]$ ]]; then
                continue
            fi

            mkdir -p "$MEDIA_DIR" || {
                echo
                echo "Failed to create the directory."
                continue
            }

        else

            echo
            echo "Media library found:"
            echo "  $MEDIA_DIR"
            echo

            read -rp "Use this media library? [Y/n]: " REPLY

            if [[ "$REPLY" =~ ^[Nn]$ ]]; then
                continue
            fi

        fi

        echo
        echo "Creating directory structure..."
        echo

        mkdir -p \
            "$MEDIA_DIR/incoming" \
            "$MEDIA_DIR/processing" \
            "$MEDIA_DIR/library" \
            "$MEDIA_DIR/completed" \
            "$MEDIA_DIR/failed" \
            "$MEDIA_DIR/logs" \
            "$MEDIA_DIR/temp"

        break

    done

}

ask_api_keys()
{
    echo
    echo "TMDb and OMDb API keys"
    echo
    echo "Leave a field empty if you want to configure it later."
    echo

    read -rp "TMDb API key: " TMDB_API_KEY
    read -rp "OMDb API key: " OMDB_API_KEY
}

show_summary() {

    clear

    echo "==============================================="
    echo " FFmpeg Auto Transcoder Installer"
    echo "==============================================="
    echo
    echo "Version      : $VERSION"
    echo
    echo "User         : $REAL_USER"
    echo
    echo "Installation : $INSTALL_DIR"
    echo
    echo "Media library: $MEDIA_DIR"
    echo

}

check_ffmpeg_nvenc() {

    if ! ffmpeg -hide_banner -encoders | grep -q "hevc_nvenc"; then
        echo
        echo "ERROR: Your FFmpeg installation does not include the HEVC NVENC encoder."
        echo "Please install a version of FFmpeg with NVIDIA NVENC support."
        echo
        exit 1
    fi

}

copy_project() {

    echo
    echo "[2/7] Copying project files..."
    echo

    if [[ -d "$INSTALL_DIR" ]]; then

        echo
        echo "The installation directory already exists."

        read -rp "Overwrite it? [y/N]: " REPLY

        if [[ "$REPLY" =~ ^[Nn]$ || -z "$REPLY" ]]; then
            echo
            echo "Installation cancelled."
            exit 0
        fi

        rm -rf "$INSTALL_DIR"

    fi

    if ! command -v rsync >/dev/null 2>&1; then
        echo
        echo "ERROR: rsync is not installed."
        echo
        echo "Please install it and try again."
        exit 1
    fi

    mkdir -p "$INSTALL_DIR"

    rsync -a \
        --exclude=".git" \
        --exclude=".github" \
        --exclude=".gitignore" \
        --exclude="*.bak" \
        --exclude="install.sh" \
        ./ "$INSTALL_DIR"

    chmod +x \
        "$INSTALL_DIR/transcoder.sh" \
        "$INSTALL_DIR/monitor.sh" \
        "$INSTALL_DIR/monitor-web.sh" \
        "$INSTALL_DIR/lib/tmdb.sh" \
        "$INSTALL_DIR/lib/omdb.sh"

    chown -R "$REAL_USER":"$REAL_USER" "$MEDIA_DIR"

}

generate_config() {

    echo
    echo "[3/7] Generating configuration..."
    echo

    mkdir -p /etc/ffmpeg-auto-transcoder

    sed \
        -e "s|__MEDIA_DIR__|$MEDIA_DIR|g" \
        -e "s|YOUR_TMDB_API_KEY|$TMDB_API_KEY|g" \
        -e "s|YOUR_OMDB_API_KEY|$OMDB_API_KEY|g" \
        "$INSTALL_DIR/templates/config.sh.template" \
        > "/etc/ffmpeg-auto-transcoder/config.sh"

    rm -f "$INSTALL_DIR/templates/config.sh.template"
}

save_install_info() {

    echo
    echo "[4/7] Saving installation information..."
    echo

    mkdir -p /etc/ffmpeg-auto-transcoder

    cat > /etc/ffmpeg-auto-transcoder/install.conf <<EOF
INSTALL_DIR="$INSTALL_DIR"
MEDIA_DIR="$MEDIA_DIR"
REAL_USER="$REAL_USER"
VERSION="$VERSION"
EOF

}

generate_services() {

    echo
    echo "[5/7] Generating systemd services..."
    echo

    sed \
        -e "s|__USER__|$REAL_USER|g" \
        -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
        "$INSTALL_DIR/templates/transcoder.service.template" \
        > /etc/systemd/system/transcoder.service

    sed \
        -e "s|__USER__|$REAL_USER|g" \
        -e "s|__INSTALL_DIR__|$INSTALL_DIR|g" \
        "$INSTALL_DIR/templates/ffmpeg-monitor.service.template" \
        > /etc/systemd/system/ffmpeg-monitor.service

}

install_services() {

    echo
    echo "[6/7] Installing services..."
    echo

    systemctl daemon-reload

    systemctl enable transcoder.service
    systemctl enable ffmpeg-monitor.service

}

start_services() {

    echo
    echo "[7/7] Starting services..."
    echo

    systemctl restart transcoder.service
    systemctl restart ffmpeg-monitor.service

}

finish() {

echo
echo "==============================================="
echo " Installation completed successfully"
echo "==============================================="
echo

echo "Installation directory:"
echo "  $INSTALL_DIR"
echo

echo "Media library:"
echo "  $MEDIA_DIR"
echo

echo "Service status:"
echo
echo "  sudo systemctl status transcoder.service"
echo

echo "Web monitor:"
echo
echo "  http://SERVER_IP:9001"
echo

echo "⚠ IMPORTANT"
echo
echo "Edit the following file:"
echo
echo "  /etc/ffmpeg-auto-transcoder/config.sh"
echo
echo "and enter your API keys:"
echo
echo "  • TMDB_API_KEY"
echo "  • OMDB_API_KEY"
echo
echo "Without these keys, the application"
echo "will not be able to identify and"
echo "organize your movies correctly."
echo

echo "Enjoy! 😊"
echo

}

###############################################################################
# MAIN
###############################################################################

check_root

detect_user

detect_package_manager

check_nvidia

check_dependencies

ask_install_directory

ask_media_directory

ask_api_keys

show_summary

read -rp "Continue with the installation? [Y/n]: " REPLY

if [[ "$REPLY" =~ ^[Nn]$ ]]; then
    echo
    echo "Installation cancelled."
    exit 0
fi

install_dependencies

check_ffmpeg_nvenc

copy_project

generate_config

save_install_info

generate_services

install_services

start_services

finish
