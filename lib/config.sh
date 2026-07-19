#!/usr/bin/env bash

CONFIG_FILE="/etc/ffmpeg-auto-transcoder/config.sh"

if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

###############################################################################
# CONFIGURACIÓN DESDE VARIABLES DE ENTORNO (Docker)
###############################################################################

MEDIA_DIR="${MEDIA_DIR:-/media}"

TARGET_GB="${TARGET_GB:-20}"
TARGET_MIN="${TARGET_MIN:-150}"
MIN_VIDEO_BPS="${MIN_VIDEO_BPS:-8000000}"

TARGET_W="${TARGET_W:-3840}"
TARGET_H="${TARGET_H:-2160}"

TMDB_API_KEY="${TMDB_API_KEY:-}"
OMDB_API_KEY="${OMDB_API_KEY:-}"

###############################################################################
# DIRECTORIOS
###############################################################################

INCOMING="$MEDIA_DIR/incoming"
PROCESSING="$MEDIA_DIR/processing"
LIBRARY="$MEDIA_DIR/library"
COMPLETED="$MEDIA_DIR/completed"
FAILED="$MEDIA_DIR/failed"
LOGS="$MEDIA_DIR/logs"
TEMP="$MEDIA_DIR/temp"
