#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source /etc/ffmpeg-auto-transcoder/config.sh

###############################################################################
# MONITOR
###############################################################################

set -Eeuo pipefail

export LC_NUMERIC=C

###############################################################################
# CONFIGURATION
###############################################################################

PROGRESS_FILE="$LOGS/ffmpeg.progress"
EXTRA_FILE="$LOGS/ffmpeg.extra"

REFRESH=2

###############################################################################
# COLORS
###############################################################################

RESET="\e[0m"

BOLD="\e[1m"

RED="\e[31m"
GREEN="\e[32m"
YELLOW="\e[33m"
BLUE="\e[34m"
MAGENTA="\e[35m"
CYAN="\e[36m"
GRAY="\e[90m"

LINE="────────────────────────────────────────────────────────────────────────────"

###############################################################################
# SECONDS → HH:MM:SS
###############################################################################

seconds_to_hms()
{
    local seconds=${1:-0}

    (( seconds < 0 )) && seconds=0

    printf "%02d:%02d:%02d" \
        $((seconds/3600)) \
        $(((seconds%3600)/60)) \
        $((seconds%60))
}

###############################################################################
# ELAPSED TIME
###############################################################################

calculate_elapsed_time()
{
    if (( START_EPOCH == 0 ))
    then
        ELAPSED=0
    else
        ELAPSED=$(( $(date +%s)-START_EPOCH ))
    fi

    (( ELAPSED < 0 )) && ELAPSED=0

    ELAPSED_HMS=$(seconds_to_hms "$ELAPSED")
}

###############################################################################
# DYNAMIC COLORS
###############################################################################

calculate_colors()
{
    GPU_TEMP=${GPU_TEMP:-0}

    BAR_COLOR=$GREEN

    if (( PROGRESS_INT < 25 ))
    then
        BAR_COLOR=$RED

    elif (( PROGRESS_INT < 75 ))
    then
        BAR_COLOR=$YELLOW
    fi

    TEMP_COLOR=$GREEN

    if (( GPU_TEMP >= 60 ))
    then
        TEMP_COLOR=$YELLOW
    fi

    if (( GPU_TEMP >= 75 ))
    then
        TEMP_COLOR=$RED
    fi
}

###############################################################################
# STATUS
###############################################################################

update_status()
{
    if [[ ! -f "$PROGRESS_FILE" ]]; then

        DISPLAY_STATUS="Waiting for FFmpeg"

    elif [[ "$STATUS" == "end" ]]; then

        DISPLAY_STATUS="Finishing"

    elif (( FRAME == 0 )); then

        DISPLAY_STATUS="Waiting for first frames"

    else

        DISPLAY_STATUS="Encoding"

    fi
}

###############################################################################
# PROGRESS BAR
###############################################################################

create_progress_bar()
{
    local progress=$1

    progress=$(printf "%.0f" "$progress")

    (( progress > 100 )) && progress=100
    (( progress < 0 )) && progress=0

    local filled=$((progress/2))
    local empty=$((50-filled))

    local bar=""

    for ((i=0;i<filled;i++))
    do
        bar+="█"
    done

    for ((i=0;i<empty;i++))
    do
        bar+="░"
    done

    printf "%s" "$bar"
}

###############################################################################
# READ PROGRESS
###############################################################################

read_progress()
{
    FRAME=0
    FPS=0
    SPEED="0x"

    OUT_US=0
    STATUS=""

    if [[ ! -f "$PROGRESS_FILE" ]]
    then
        STATUS="waiting"
        return
    fi

    while IFS="=" read -r key value
    do
        case "$key" in

            frame)
                FRAME="$value"
                ;;

            fps)
                FPS="$value"
                ;;

            speed)
                SPEED="$value"
                ;;

            out_time_us)
                [[ "$value" =~ ^[0-9]+$ ]] && OUT_US="$value"
                ;;

            progress)
                STATUS="$value"
                ;;

        esac

    done < "$PROGRESS_FILE"

    PROCESSED_SECONDS=$((OUT_US/1000000))
}

###############################################################################
# CALCULATE PROGRESS
###############################################################################

calculate_progress()
{
    PERCENT=0
    REMAINING=0

    if (( RAW_DUR > 0 ))
    then

        PERCENT=$(awk \
            -v a="$PROCESSED_SECONDS" \
            -v b="$RAW_DUR" \
            'BEGIN{printf "%.2f",(a/b)*100}')

        (( PROCESSED_SECONDS > RAW_DUR )) && \
            PROCESSED_SECONDS=$RAW_DUR

        REMAINING=$((RAW_DUR-PROCESSED_SECONDS))

    fi

    PROGRESS_INT=$(printf "%.0f" "$PERCENT")

    if (( PROGRESS_INT > 100 )); then
        PROGRESS_INT=100
    fi

    if (( PROGRESS_INT < 0 )); then
        PROGRESS_INT=0
    fi
}

###############################################################################
# GPU
###############################################################################

read_gpu()
{
    local data

    data=$(nvidia-smi \
        --query-gpu=name,\
utilization.gpu,\
utilization.encoder,\
utilization.decoder,\
temperature.gpu,\
memory.used,\
memory.total,\
power.draw \
        --format=csv,noheader,nounits 2>/dev/null || true)

    [[ -z "$data" ]] && return

    IFS=',' read \
        GPU_NAME \
        GPU_USAGE \
        GPU_ENCODER \
        GPU_DECODER \
        GPU_TEMP \
        GPU_MEM_USED \
        GPU_MEM_TOTAL \
        GPU_POWER <<< "$data"

    GPU_NAME=$(echo "$GPU_NAME" | xargs)
    GPU_USAGE=$(echo "$GPU_USAGE" | xargs)
    GPU_ENCODER=$(echo "$GPU_ENCODER" | xargs)
    GPU_DECODER=$(echo "$GPU_DECODER" | xargs)
    GPU_TEMP=$(echo "$GPU_TEMP" | xargs)
    GPU_MEM_USED=$(echo "$GPU_MEM_USED" | xargs)
    GPU_MEM_TOTAL=$(echo "$GPU_MEM_TOTAL" | xargs)
    GPU_POWER=$(echo "$GPU_POWER" | xargs)
}

get_pid()
{
    PID=$(pgrep -x ffmpeg | head -n1)

    if [[ -z "$PID" ]]; then
        PID="---"
    fi
}

###############################################################################
# ETA
###############################################################################

calculate_eta()
{
    local s

    s=$(echo "$SPEED" | tr -d x)

    ETA=0

    if [[ "$s" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        if (( $(echo "$s > 0" | bc -l) )); then
            ETA=$(awk \
                -v r="$REMAINING" \
                -v s="$s" \
                'BEGIN{printf "%.0f", r/s}')
        fi
    fi
}

###############################################################################
# FINISH TIME
###############################################################################

finish_time()
{
    FINISH_TIME=$(date -d "+${ETA} seconds" +"%H:%M:%S")
}

###############################################################################
# READ EXTRA
###############################################################################

read_extra()
{
    ENCODER_USAGE=0
    CURRENT_Q="0.0"
    START_EPOCH=0

    CURRENT_FILE="Waiting..."
    TITLE=""
    RAW_DUR=0
    PID="-"

    STATUS_TEXT="waiting"

    if [[ -f "$EXTRA_FILE" ]]; then
        source "$EXTRA_FILE"
    fi
}

###############################################################################
# SCREEN
###############################################################################

draw_screen()
{
    clear

    local bar

    bar=$(create_progress_bar "$PROGRESS_INT")

    echo -e "${BLUE}${BOLD}"
    echo "══════════════════════════════════════════════════════════════════════════════"
    echo "                           MONITOR"
    echo "══════════════════════════════════════════════════════════════════════════════"
    echo -e "${RESET}"

    echo

    printf "%-18s %s\n" "File:" "$CURRENT_FILE"
    printf "%-18s %s\n" "Title:" "$TITLE"
    printf "%-18s %s\n" "Duration:" "$(seconds_to_hms "$RAW_DUR")"

    echo
    echo "$LINE"

    echo
    echo -e "${BOLD}PROGRESS${RESET}"
    echo

    printf "%-18s %s / %s\n" \
        "Time:" \
        "$(seconds_to_hms "$PROCESSED_SECONDS")" \
        "$(seconds_to_hms "$RAW_DUR")"

    printf "%-18s %.2f %%\n" \
        "Progress:" \
        "$PERCENT"

    printf "%-18s [%b%s%b]\n" \
        "Bar:" \
        "$BAR_COLOR" \
        "$bar" \
        "$RESET"

    echo
    echo "$LINE"

    echo
    echo -e "${BOLD}PERFORMANCE${RESET}"
    echo

    printf "%-18s %s\n" "FPS:" "$FPS"
    printf "%-18s %s\n" "Speed:" "$SPEED"
    printf "%-18s %s\n" "Q:" "$CURRENT_Q"

    echo
    echo "$LINE"

    echo
    echo -e "${BOLD}GPU${RESET}"
    echo

    printf "%-18s %s\n" "Model:" "$GPU_NAME"
    printf "%-18s %s %%\n" "GPU:" "$GPU_USAGE"
    printf "%-18s %s %%\n" "Encoder:" "$GPU_ENCODER"
    printf "%-18s %s %%\n" "Decoder:" "$GPU_DECODER"

    printf "%-18s %s / %s MB\n" \
        "VRAM:" \
        "$GPU_MEM_USED" \
        "$GPU_MEM_TOTAL"

    printf "%-18s %b%s ºC%b\n" \
        "Temperature:" \
        "$TEMP_COLOR" \
        "$GPU_TEMP" \
        "$RESET"

    printf "%-18s %s W\n" \
        "Power:" \
        "$GPU_POWER"

    echo
    echo "$LINE"

    echo
    echo -e "${BOLD}TIMING${RESET}"
    echo

    printf "%-18s %s\n" \
        "Elapsed:" \
        "$ELAPSED_HMS"

    printf "%-18s %s\n" \
        "Remaining:" \
        "$(seconds_to_hms "$REMAINING")"

    printf "%-18s %s\n" \
        "ETA:" \
        "$(seconds_to_hms "$ETA")"

    printf "%-18s %s\n" \
        "Finish:" \
        "$FINISH_TIME"

    echo
    echo "$LINE"

    echo
    echo -e "${BOLD}STATUS${RESET}"
    echo

    printf "%-18s %b●%b %s\n" \
        "Status:" \
        "$GREEN" \
        "$RESET" \
        "$STATUS_TEXT"

    printf "%-18s %s\n" \
        "PID:" \
        "$PID"

    echo
}

###############################################################################
# IDLE SCREEN
###############################################################################

draw_idle_screen()
{
    clear

    echo -e "${BLUE}${BOLD}"
    echo "══════════════════════════════════════════════════════════════════════════════"
    echo "                           MONITOR"
    echo "══════════════════════════════════════════════════════════════════════════════"
    echo -e "${RESET}"

    echo
    echo -e "${YELLOW}●${RESET} No encoding job is currently running."
    echo
    echo "Waiting for new movies..."
    echo
}

###############################################################################
# SERVICE STOPPED
###############################################################################

draw_service_stopped()
{
    clear

    echo -e "${RED}${BOLD}"
    echo "══════════════════════════════════════════════════════════════════════════════"
    echo "                           MONITOR"
    echo "══════════════════════════════════════════════════════════════════════════════"
    echo -e "${RESET}"

    echo
    echo -e "${RED}●${RESET} The transcoding service is stopped."
    echo
    echo "Start it with:"
    echo
    echo "sudo systemctl start transcoder.service"
    echo
}

###############################################################################
# MAIN LOOP
###############################################################################

while true
do
    if ! systemctl is-active --quiet transcoder.service; then
        draw_service_stopped
        sleep "$REFRESH"
        continue
    fi

    read_extra

    if [[ "$STATUS_TEXT" == "waiting" ]]; then
        draw_idle_screen
        sleep "$REFRESH"
        continue
    fi

    read_progress
    calculate_progress
    read_gpu
    calculate_eta
    finish_time
    calculate_elapsed_time
    calculate_colors
    update_status
    draw_screen

    sleep "$REFRESH"
done
