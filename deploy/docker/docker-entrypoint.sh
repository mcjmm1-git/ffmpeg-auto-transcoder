#!/usr/bin/env bash

set -e

###############################################################################
# MEDIA ROOTS
###############################################################################

if [[ -n "${MEDIA_DIRS:-}" ]]; then
    IFS=':' read -r -a MEDIA_ROOTS <<< "$MEDIA_DIRS"
else
    MEDIA_ROOTS=("${MEDIA_DIR:-/media}")
fi

if [[ -n "${OUTPUT_MEDIA_DIRS:-}" ]]; then
    IFS=':' read -r -a OUTPUT_ROOTS <<< "$OUTPUT_MEDIA_DIRS"
else
    OUTPUT_ROOTS=("${MEDIA_ROOTS[@]}")
fi

###############################################################################
# INPUT, ORIGINALS AND SHARED STATE
###############################################################################

for MEDIA_ROOT in "${MEDIA_ROOTS[@]}"; do

    [[ -n "$MEDIA_ROOT" ]] || continue

    mkdir -p \
        "$MEDIA_ROOT/incoming" \
        "$MEDIA_ROOT/completed" \
        "$MEDIA_ROOT/failed" \
        "$MEDIA_ROOT/logs" \
        "$MEDIA_ROOT/temp"

done

###############################################################################
# TRANSCODING OUTPUTS
###############################################################################

for OUTPUT_ROOT in "${OUTPUT_ROOTS[@]}"; do

    [[ -n "$OUTPUT_ROOT" ]] || continue

    mkdir -p \
        "$OUTPUT_ROOT/processing" \
        "$OUTPUT_ROOT/library/films" \
        "$OUTPUT_ROOT/library/series"

done

###############################################################################
# START CONTAINER COMMAND
###############################################################################

exec "$@"
