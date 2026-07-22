#!/usr/bin/env bash

set -e

###############################################################################
# CREATE REQUIRED MEDIA DIRECTORIES
###############################################################################

MEDIA_ROOT="${MEDIA_DIR:-/media}"

mkdir -p \
    "$MEDIA_ROOT/incoming" \
    "$MEDIA_ROOT/processing" \
    "$MEDIA_ROOT/library" \
    "$MEDIA_ROOT/completed" \
    "$MEDIA_ROOT/failed" \
    "$MEDIA_ROOT/logs" \
    "$MEDIA_ROOT/temp"

###############################################################################
# START CONTAINER COMMAND
###############################################################################

exec "$@"
