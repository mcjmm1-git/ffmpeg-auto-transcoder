#!/usr/bin/env bash

cd "$(dirname "$0")" || exit 1

PORT=9001

exec ttyd \
    -W \
    -i 0.0.0.0 \
    -p "$PORT" \
    -t 'theme={"background":"#282C34","foreground":"#E6EDF3"}' \
    bash -il -c "./monitor.sh"
