#!/usr/bin/env bash

###############################################################################
# FFmpeg Auto Transcoder
# Web Monitor
###############################################################################

cd "$(dirname "$0")" || exit 1

PORT=9001

exec ttyd \
    -W \
    -i 0.0.0.0 \
    -p "$PORT" \
    bash -il -c "./monitor.sh"
