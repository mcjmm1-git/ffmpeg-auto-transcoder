#!/usr/bin/env bash

# Configuration loader.
# Loads the system configuration file when available.
# Docker deployments fall back to environment variables.

CONFIG_FILE="/etc/ffmpeg-auto-transcoder/config.sh"

# Load the system configuration if available.
# Docker deployments typically rely on environment variables instead.
if [[ -f "$CONFIG_FILE" ]]; then
    source "$CONFIG_FILE"
fi

###############################################################################
# ENVIRONMENT VARIABLE OVERRIDES
# (used by Docker Compose when no config file is present)
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
# DIRECTORIES
###############################################################################

INCOMING="$MEDIA_DIR/incoming"
PROCESSING="$MEDIA_DIR/processing"
LIBRARY="$MEDIA_DIR/library"
COMPLETED="$MEDIA_DIR/completed"
FAILED="$MEDIA_DIR/failed"
LOGS="$MEDIA_DIR/logs"
TEMP="$MEDIA_DIR/temp"
