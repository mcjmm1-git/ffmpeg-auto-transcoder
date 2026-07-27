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
# MEDIA ROOTS
###############################################################################

MEDIA_DIRS="${MEDIA_DIRS:-${MEDIA_DIR:-/media}}"

IFS=':' read -r -a MEDIA_ROOTS <<< "$MEDIA_DIRS"

if (( ${#MEDIA_ROOTS[@]} == 0 )) ||
   [[ -z "${MEDIA_ROOTS[0]:-}" ]]
then
    MEDIA_ROOTS=("/media")
fi

# The first media root stores input files, originals, logs and monitor state.
MEDIA_DIR="${MEDIA_ROOTS[0]}"

OUTPUT_MEDIA_DIRS="${OUTPUT_MEDIA_DIRS:-$MEDIA_DIR}"

IFS=':' read -r -a OUTPUT_ROOTS <<< "$OUTPUT_MEDIA_DIRS"

if (( ${#OUTPUT_ROOTS[@]} == 0 )) ||
   [[ -z "${OUTPUT_ROOTS[0]:-}" ]]
then
    OUTPUT_ROOTS=("$MEDIA_DIR")
fi

###############################################################################
# TRANSCODING SETTINGS
###############################################################################

TARGET_GB="${TARGET_GB:-20}"
TARGET_MIN="${TARGET_MIN:-150}"
MIN_VIDEO_BPS="${MIN_VIDEO_BPS:-8000000}"

TARGET_W="${TARGET_W:-3840}"
TARGET_H="${TARGET_H:-2160}"

MIN_FREE_GB="${MIN_FREE_GB:-50}"
OUTPUT_SPACE_MARGIN_GB="${OUTPUT_SPACE_MARGIN_GB:-5}"

TMDB_API_KEY="${TMDB_API_KEY:-}"
OMDB_API_KEY="${OMDB_API_KEY:-}"

###############################################################################
# INPUT AND SHARED DIRECTORIES
###############################################################################

INCOMING="$MEDIA_DIR/incoming"
COMPLETED="$MEDIA_DIR/completed"
FAILED="$MEDIA_DIR/failed"
LOGS="$MEDIA_DIR/logs"
TEMP="$MEDIA_DIR/temp"

###############################################################################
# DEFAULT OUTPUT DIRECTORIES
#
# transcoder.sh overrides these for every job after selecting an output disk.
###############################################################################

PROCESSING="${OUTPUT_ROOTS[0]}/processing"
LIBRARY="${OUTPUT_ROOTS[0]}/library"
FILMS="$LIBRARY/films"
SERIES="$LIBRARY/series"
