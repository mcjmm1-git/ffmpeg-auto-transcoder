#!/usr/bin/env bash

###############################################################################
# FFmpeg Auto Transcoder
# Theme
###############################################################################

# Reset
RST='\e[0m'

# Styles
BOLD='\e[1m'
DIM='\e[2m'

# Colors
WHITE='\e[97m'
BLACK='\e[30m'

BLUE='\e[38;5;33m'
CYAN='\e[38;5;31m'
GREEN='\e[38;5;46m'
YELLOW='\e[38;5;220m'
ORANGE='\e[38;5;208m'
RED='\e[38;5;196m'
MAGENTA='\e[38;5;141m'

GRAY='\e[38;5;245m'
LIGHTGRAY='\e[38;5;250m'

###############################################################################
# Printing helpers
###############################################################################

title()
{
    separator
    printf "%b%b%s%b\n" "$BOLD" "$BLUE" "$*" "$RST"
    separator
}

section()
{
    echo
    separator
    printf "%b%b%s%b\n" "$BOLD" "$BLUE" "$*" "$RST"
}

label()
{
    printf "${GRAY}%s${RST}" "$1"
}

value()
{
    printf "${WHITE}%s${RST}" "$1"
}

field()
{
    local name=$1
    local content=$2
    local content_color=${3:-$WHITE}
    local width=${4:-12}

    printf "%b%-*s%b %b%s%b\n" \
        "$GRAY" \
        "$width" \
        "${name}:" \
        "$RST" \
        "$content_color" \
        "$content" \
        "$RST"
}

progress_field()
{
    local name=$1
    local bar=$2
    local percent=$3
    local bar_color=$4
    local label_width=${5:-12}
    local percent_width=${6:-8}

    printf "%b%-*s%b %b%s%b %*.2f %%\n" \
        "$GRAY" \
        "$label_width" \
        "${name}:" \
        "$RST" \
        "$bar_color" \
        "$bar" \
        "$RST" \
        "$((percent_width - 2))" \
        "$percent"
}

ok()
{
    printf "${GREEN}%s${RST}" "$1"
}

warn()
{
    printf "${YELLOW}%s${RST}" "$1"
}

error()
{
    printf "${RED}%s${RST}" "$1"
}

accent()
{
    printf "${MAGENTA}%s${RST}" "$1"
}

separator()
{
    local cols

    cols=$(tput cols 2>/dev/null || true)

    if [[ ! "$cols" =~ ^[0-9]+$ ]]; then
        cols=80
    fi

    # Reservamos una columna para evitar el salto automático.
    (( cols > 1 )) && cols=$((cols - 1))

    printf "%b" "$BLUE"
    printf '━%.0s' $(seq 1 "$cols")
    printf "%b\n" "$RST"
}

terminal_width()
{
    local cols

    cols=$(tput cols 2>/dev/null || true)

    if [[ ! "$cols" =~ ^[0-9]+$ ]]; then
        cols=80
    fi

    # Reservamos una columna para evitar el salto automático.
    (( cols > 1 )) && cols=$((cols - 1))

    printf "%d" "$cols"
}

