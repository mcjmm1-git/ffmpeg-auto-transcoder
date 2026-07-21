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
    -t titleFixed="FFmpeg Auto Transcoder — Monitor" \
    -t fontSize=15 \
    -t lineHeight=1.20 \
    -t cursorStyle=bar \
    -t cursorBlink=true \
    -t scrollback=3000 \
    -t 'fontFamily=Consolas, "Cascadia Mono", "DejaVu Sans Mono", monospace' \
    -t 'theme={
        "background":"#f7fbff",
        "foreground":"#101820",
        "cursor":"#075fa8",
        "cursorAccent":"#ffffff",
        "selectionBackground":"#9bcfff",
        "black":"#101820",
        "red":"#b00020",
        "green":"#087a19",
        "yellow":"#735c00",
        "blue":"#003f91",
        "magenta":"#69369a",
        "cyan":"#006f78",
        "white":"#566574",
        "brightBlack":"#465563",
        "brightRed":"#d3212d",
        "brightGreen":"#13932d",
        "brightYellow":"#927400",
        "brightBlue":"#126bc5",
        "brightMagenta":"#854eb4",
        "brightCyan":"#008c98",
        "brightWhite":"#101820"
    }' \
    bash -il -c "./monitor.sh"
