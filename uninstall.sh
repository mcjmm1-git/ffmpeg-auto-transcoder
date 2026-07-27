#!/usr/bin/env bash

###############################################################################
# FFmpeg Auto Transcoder
# UNINSTALLER
###############################################################################

set -e

CONFIG_FILE="/etc/ffmpeg-auto-transcoder/install.conf"

if [[ ! -f "$CONFIG_FILE" ]]; then
    echo
    echo "Installation information was not found."
    echo "Unable to continue with the uninstallation."
    echo
    exit 1
fi

source "$CONFIG_FILE"

###############################################################################
# VARIABLES
###############################################################################

SERVICES=(
    transcoder.service
    ffmpeg-monitor.service
)

PROGRAM_REMOVED=false
CONFIG_REMOVED=false
MEDIA_REMOVED=false

###############################################################################
# FUNCTIONS
###############################################################################

check_root()
{
    if [[ $EUID -ne 0 ]]; then
        echo
        echo "This uninstaller must be run with sudo."
        echo
        echo "sudo ./uninstall.sh"
        echo
        exit 1
    fi
}

stop_services()
{
    echo
    echo "[1/7] Stopping services..."
    echo

    for SERVICE in "${SERVICES[@]}"; do

        if systemctl is-active --quiet "$SERVICE"; then
            systemctl stop "$SERVICE"
            echo "✔ $SERVICE stopped"
        else
            echo "- $SERVICE is already stopped"
        fi

    done
}

kill_monitor_processes()
{
    echo
    echo "Stopping remaining monitor processes..."
    echo

    pkill -TERM -f "ttyd.*monitor.sh" 2>/dev/null || true
    pkill -TERM -f "bash -il -c ./monitor.sh" 2>/dev/null || true
    pkill -TERM -f "/monitor.sh" 2>/dev/null || true

    sleep 1

    pkill -KILL -f "ttyd.*monitor.sh" 2>/dev/null || true
    pkill -KILL -f "bash -il -c ./monitor.sh" 2>/dev/null || true
    pkill -KILL -f "/monitor.sh" 2>/dev/null || true

    echo "✔ Remaining monitor processes terminated"
}

disable_services()
{
    echo
    echo "[2/7] Disabling services..."
    echo

    for SERVICE in "${SERVICES[@]}"; do

        if systemctl is-enabled --quiet "$SERVICE" 2>/dev/null; then
            systemctl disable "$SERVICE" >/dev/null
            echo "✔ $SERVICE disabled"
        else
            echo "- $SERVICE is already disabled"
        fi

    done
}

###############################################################################
# REMOVE SERVICE FILES
###############################################################################

remove_service_files()
{
    echo
    echo "[3/7] Removing service files..."
    echo

    for SERVICE in "${SERVICES[@]}"; do

        SERVICE_FILE="/etc/systemd/system/$SERVICE"

        if [[ -f "$SERVICE_FILE" ]]; then
            rm -f "$SERVICE_FILE"
            echo "✔ $SERVICE_FILE"
        else
            echo "- $SERVICE_FILE does not exist"
        fi

    done
}

###############################################################################
# RELOAD SYSTEMD
###############################################################################

reload_systemd()
{
    echo
    echo "[4/7] Reloading systemd..."
    echo

    systemctl daemon-reload
    systemctl reset-failed

    echo "✔ systemd reloaded"
}

###############################################################################
# REMOVE PROGRAM
###############################################################################

remove_program()
{
    echo
    echo "[5/7] Removing program..."
    echo

    if [[ -d "$INSTALL_DIR" ]]; then
        rm -rf "$INSTALL_DIR"
        echo "✔ $INSTALL_DIR removed"
        PROGRAM_REMOVED=true
    else
        echo "- $INSTALL_DIR does not exist"
    fi
}

###############################################################################
# REMOVE CONFIGURATION
###############################################################################

remove_configuration()
{
    echo
    echo "[6/7] Removing configuration..."
    echo

    read -rp "Do you also want to remove the configuration? [y/N]: " REPLY

    if [[ "$REPLY" =~ ^[Yy]$ ]]; then

        if [[ -d "/etc/ffmpeg-auto-transcoder" ]]; then
            rm -rf /etc/ffmpeg-auto-transcoder
            echo "✔ Configuration removed"
            CONFIG_REMOVED=true
        else
            echo "- Configuration directory does not exist"
        fi

    else

        echo "✔ Configuration preserved"

    fi
}

###############################################################################
# REMOVE MEDIA LIBRARY
###############################################################################

remove_media_directory()
{
    echo
    echo "[7/7] Removing media library..."
    echo

    read -rp "Do you also want to remove the media library? [y/N]: " REPLY

    if [[ "$REPLY" =~ ^[Yy]$ ]]; then

        if [[ -d "$MEDIA_DIR" ]]; then
            rm -rf "$MEDIA_DIR"
            echo "✔ Media library removed"
            MEDIA_REMOVED=true
        else
            echo "- Media library does not exist"
        fi

    else

        echo "✔ Media library preserved"

    fi
}

###############################################################################
# FINISH
###############################################################################

finish()
{
    echo
    echo "==============================================="
    echo " Uninstallation completed successfully"
    echo "==============================================="
    echo

    if $PROGRAM_REMOVED; then
        echo "✔ Program removed"
    else
        echo "• Program preserved"
    fi

    if $CONFIG_REMOVED; then
        echo "✔ Configuration removed"
    else
        echo "✔ Configuration preserved"
    fi

    if $MEDIA_REMOVED; then
        echo "✔ Media library removed"
    else
        echo "✔ Media library preserved"
    fi

    echo
    echo "Media library:"
    echo "  $MEDIA_DIR"
}

###############################################################################
# MAIN
###############################################################################

check_root
stop_services
kill_monitor_processes
disable_services
remove_service_files
reload_systemd
remove_program
remove_configuration
remove_media_directory
finish
