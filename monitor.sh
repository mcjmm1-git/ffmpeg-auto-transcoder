#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/tmdb.sh"
source "$SCRIPT_DIR/lib/theme.sh"

###############################################################################
# MONITOR
###############################################################################

set -Euo pipefail

trap 'echo "ERROR: line $LINENO: $BASH_COMMAND"' ERR

export LC_NUMERIC=C

###############################################################################
# ZONA HORARIA LOCAL
###############################################################################

configure_monitor_timezone()
{
    local configured_tz="${TIMEZONE:-${TZ:-}}"
    local detected_tz=""

    # Native installations normally provide TIMEZONE through config.sh.
    # Docker deployments normally provide TZ through docker-compose.yml.
    if [[ -z "$configured_tz" ]] && command -v timedatectl >/dev/null 2>&1; then
        detected_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || true)
    fi

    if [[ -z "$configured_tz" && -n "$detected_tz" ]]; then
        configured_tz="$detected_tz"
    fi

    if [[ -z "$configured_tz" && -r /etc/timezone ]]; then
        configured_tz=$(head -n1 /etc/timezone 2>/dev/null || true)
    fi

    if [[ -z "$configured_tz" && -L /etc/localtime ]]; then
        detected_tz=$(readlink -f /etc/localtime 2>/dev/null || true)
        detected_tz=${detected_tz#*/usr/share/zoneinfo/}

        if [[ -n "$detected_tz" && "$detected_tz" != /etc/localtime ]]; then
            configured_tz="$detected_tz"
        fi
    fi

    if [[ -n "$configured_tz" ]]; then
        MONITOR_TIMEZONE="$configured_tz"
    elif [[ -e /etc/localtime ]]; then
        MONITOR_TIMEZONE=":/etc/localtime"
    else
        MONITOR_TIMEZONE="UTC"
    fi

    export TZ="$MONITOR_TIMEZONE"
}

configure_monitor_timezone

# Accent colours. CYAN is used for normal progress; the remaining colours
# continue to come from lib/theme.sh. The fallback keeps the monitor working
# with older versions of that file.
: "${CYAN:=$'\e[36m'}"
: "${LIGHT_CYAN:=$'\e[96m'}"
: "${RESET:=$'\e[0m'}"
: "${BLUE:=$'\e[34m'}"

###############################################################################
# CONFIGURATION
###############################################################################

PROGRESS_FILE="$LOGS/ffmpeg.progress"
EXTRA_FILE="$LOGS/ffmpeg.extra"

REFRESH=2

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
    GPU_USAGE=${GPU_USAGE:-0}
    GPU_ENCODER=${GPU_ENCODER:-0}
    GPU_DECODER=${GPU_DECODER:-0}

    # Normal progress uses a lighter cyan. Red is reserved for real warnings.
    BAR_COLOR=$LIGHT_CYAN

    GPU_COLOR=$GREEN
    ENC_COLOR=$GREEN
    DEC_COLOR=$GREEN
    TEMP_COLOR=$GREEN

    (( GPU_USAGE >= 85 )) && GPU_COLOR=$YELLOW
    (( GPU_USAGE >= 95 )) && GPU_COLOR=$RED

    (( GPU_ENCODER >= 85 )) && ENC_COLOR=$YELLOW
    (( GPU_ENCODER >= 95 )) && ENC_COLOR=$RED

    (( GPU_DECODER >= 85 )) && DEC_COLOR=$YELLOW
    (( GPU_DECODER >= 95 )) && DEC_COLOR=$RED

    (( GPU_TEMP >= 65 )) && TEMP_COLOR=$YELLOW
    (( GPU_TEMP >= 80 )) && TEMP_COLOR=$RED

    return 0
}


###############################################################################
# STATUS
###############################################################################

update_status()
{
    if [[ ! -f "$PROGRESS_FILE" ]]; then
        DISPLAY_STATUS="Esperando a FFmpeg"
        STATUS_COLOR=$YELLOW

    elif [[ "$STATUS" == "end" ]]; then
        DISPLAY_STATUS="Finalizando"
        STATUS_COLOR=$GREEN

    elif (( FRAME == 0 )); then
        DISPLAY_STATUS="Esperando primeros fotogramas"
        STATUS_COLOR=$YELLOW

    else
        DISPLAY_STATUS="Codificando"
        STATUS_COLOR=$CYAN
    fi
}


###############################################################################
# PROGRESS BAR
###############################################################################

create_progress_bar()
{
    local progress=$1
    local width=${2:-50}

    progress=$(printf "%.0f" "$progress")

    (( progress > 100 )) && progress=100
    (( progress < 0 )) && progress=0

    local filled=$((progress * width / 100))
    local empty=$((width - filled))

    local bar=""
    local i

    for ((i=0; i<filled; i++)); do
        bar+="█"
    done

    for ((i=0; i<empty; i++)); do
        bar+="░"
    done

    printf "%s" "$bar"
}

###############################################################################
# TEXT HELPERS
###############################################################################

truncate_text()
{
    local text=${1:-}
    local width=${2:-20}

    (( width < 1 )) && width=1

    if (( ${#text} <= width )); then
        printf "%s" "$text"
    elif (( width <= 1 )); then
        printf "…"
    else
        printf "%s…" "${text:0:width-1}"
    fi
}

safe_percent()
{
    local value=${1:-0}

    [[ "$value" =~ ^[0-9]+([.][0-9]+)?$ ]] || value=0
    printf "%.0f" "$value"
}


###############################################################################
# SCREEN OUTPUT
###############################################################################

# Clear the complete current row before drawing it. This prevents remnants
# when a section becomes shorter or moves between refreshes.
clear_current_line()
{
    printf '\r\e[2K'
}

ui_title()
{
    local text=${1:-}

    clear_current_line
    printf "%b%s%b\n" "$BLUE" "$text" "$RESET"
    horizontal_rule
}

ui_section()
{
    local text=${1:-}

    horizontal_rule
    clear_current_line
    printf "%b%s%b\n" "$BLUE" "$text" "$RESET"
}

###############################################################################
# ALIGNED OUTPUT
###############################################################################

# All values begin at this absolute terminal column. Using a cursor column
# avoids UTF-8 labels such as "Película" shifting the following value.
UI_VALUE_COLUMN=16
UI_LABEL_WIDTH=$((UI_VALUE_COLUMN - 1))
UI_PERCENT_WIDTH=8

print_aligned_label()
{
    local label=${1:-}

    clear_current_line
    printf "%s:" "$label"
    printf '\e[%dG' "$UI_VALUE_COLUMN"
}

aligned_field()
{
    local label=${1:-}
    local value=${2:-}
    local color=${3:-}

    print_aligned_label "$label"

    if [[ -n "$color" ]]; then
        printf "%b%s%b" "$color" "$value" "$RESET"
    else
        printf "%s" "$value"
    fi

    printf '\e[K\n'
}

aligned_progress_field()
{
    local label=${1:-}
    local bar=${2:-}
    local percent=${3:-0}
    local color=${4:-$CYAN}
    local percent_text

    percent_text=$(printf "%.2f %%" "$percent")

    print_aligned_label "$label"
    printf "%b%s %*s%b" \
        "$color" \
        "$bar" \
        "$UI_PERCENT_WIDTH" \
        "$percent_text" \
        "$RESET"
    printf '\e[K\n'
}

blank_line()
{
    clear_current_line
    printf '\n'
}

horizontal_rule()
{
    local cols
    local i

    cols=$(terminal_width)
    (( cols < 1 )) && cols=1

    clear_current_line
    printf "%b" "$BLUE"
    for ((i=0; i<cols; i++)); do
        printf "─"
    done
    printf "%b\n" "$RESET"
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

    GPU_NAME="No disponible"
    GPU_USAGE=0
    GPU_ENCODER=0
    GPU_DECODER=0
    GPU_TEMP=0
    GPU_MEM_USED=0
    GPU_MEM_TOTAL=0
    GPU_POWER=0

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

    GPU_USAGE=$(safe_percent "$GPU_USAGE")
    GPU_ENCODER=$(safe_percent "$GPU_ENCODER")
    GPU_DECODER=$(safe_percent "$GPU_DECODER")
    GPU_TEMP=$(safe_percent "$GPU_TEMP")
}


get_pid()
{
    PID=$(pgrep -x ffmpeg 2>/dev/null | head -n1 || true)

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
        ETA=$(awk \
            -v r="$REMAINING" \
            -v s="$s" \
            'BEGIN { if (s > 0) printf "%.0f", r/s; else print 0 }')
    fi
}


###############################################################################
# FINISH TIME
###############################################################################

finish_time()
{
    FINISH_TIME=$(TZ="$MONITOR_TIMEZONE" date -d "+${ETA} seconds" +"%H:%M:%S")
}

###############################################################################
# READ EXTRA
###############################################################################

read_extra()
{
    ENCODER_USAGE=0
    CURRENT_Q="0.0"
    START_EPOCH=0

    CURRENT_FILE="Esperando..."
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
    printf '\e[H'

    local bar
    local gpu_bar
    local enc_bar
    local dec_bar
    local cols
    local bar_width
    local meter_width=28
    local title_width
    local display_title
    local display_file

    cols=$(terminal_width)
    (( cols < 42 )) && cols=42

    title_width=$((cols - UI_LABEL_WIDTH))
    (( title_width < 12 )) && title_width=12

    display_title=$(truncate_text "${TITLE:-Sin título}" "$title_width")
    display_file=$(truncate_text "${CURRENT_FILE:-Sin archivo}" "$title_width")

    ui_title "🎬  FFmpeg Auto Transcoder"

    aligned_field "Estado" "● $DISPLAY_STATUS" "$STATUS_COLOR"
    aligned_field "Película" "$display_title"
    aligned_field "Archivo" "$display_file"

    ui_section "⚙ PROGRESO"

    bar_width=$((cols - UI_LABEL_WIDTH - UI_PERCENT_WIDTH - 1))
    (( bar_width < 8 )) && bar_width=8

    bar=$(create_progress_bar "$PROGRESS_INT" "$bar_width")
    aligned_progress_field "Progreso" "$bar" "$PERCENT" "$BAR_COLOR"

    aligned_field "Tiempo" \
        "$(seconds_to_hms "$PROCESSED_SECONDS") / $(seconds_to_hms "$RAW_DUR")"

    aligned_field "Restante" \
        "$(seconds_to_hms "$ETA")   ·   Finaliza $FINISH_TIME"

    aligned_field "Rendimiento" \
        "${FPS} FPS   ·   ${SPEED}   ·   Transcurrido ${ELAPSED_HMS}"

    ui_section "📋 COLA"
    draw_queue

    ui_section "🎮 GPU"

    aligned_field "Modelo" "$(truncate_text "$GPU_NAME" "$title_width")"
    blank_line

    gpu_bar=$(create_progress_bar "$GPU_USAGE" "$meter_width")
    enc_bar=$(create_progress_bar "$GPU_ENCODER" "$meter_width")
    dec_bar=$(create_progress_bar "$GPU_DECODER" "$meter_width")

    aligned_progress_field "GPU" "$gpu_bar" "$GPU_USAGE" "$GPU_COLOR"
    blank_line

    aligned_progress_field \
        "Codificador" "$enc_bar" "$GPU_ENCODER" "$ENC_COLOR"
    blank_line

    aligned_progress_field \
        "Decodificador" "$dec_bar" "$GPU_DECODER" "$DEC_COLOR"
    blank_line

    aligned_field "Memoria" \
        "${GPU_MEM_USED} / ${GPU_MEM_TOTAL} MB"

    aligned_field "Temperatura" \
        "${GPU_TEMP} ºC   ·   ${GPU_POWER} W" \
        "$TEMP_COLOR"

    blank_line
    horizontal_rule
    printf '\e[J'
}


draw_queue()
{
    local file
    local display_name
    local prefix
    local available
    local cols

    local files
    local total=0
    local shown=0
    local max_shown=4
    local hidden_movies=0
    local hidden_episodes=0
    local summary=""
    local part=""

    local current_title="${TITLE:-}"
    local current_year="${YEAR:-}"
    local current_file="${CURRENT_FILE:-}"
    local current_media_type="${MEDIA_TYPE:-movie}"
    local current_season_number="${SEASON_NUMBER:-}"
    local current_episode_number="${EPISODE_NUMBER:-}"
    local episode_code=""

    cols=$(terminal_width)
    (( cols < 42 )) && cols=42

    ###########################################################################
    # Only source files still waiting in incoming belong to the queue.
    #
    # Files in an output disk's processing directory are either:
    #   - the output currently being written by FFmpeg, or
    #   - an incomplete leftover from an interrupted job.
    #
    # Neither case is a pending queue item, so processing is intentionally not
    # scanned here. transcoder.sh removes interrupted partial outputs on clean
    # shutdown and again at startup after an unclean stop or power loss.
    ###########################################################################

    mapfile -t files < <(
        find "$INCOMING" -maxdepth 1 -type f 2>/dev/null | sort
    )

    for file in "${files[@]}"; do

        # The source of the active job remains in incoming until the encode has
        # completed successfully. Do not display it a second time in the queue.
        if [[ -n "$current_file" &&
              "$(basename "$file")" == "$current_file" ]]
        then
            continue
        fi

        TITLE=""
        YEAR=""
        MEDIA_TYPE="movie"
        SEASON_NUMBER=""
        EPISODE_NUMBER=""
        normalize_filename "$file"

        ((total += 1))

        if (( shown >= max_shown )); then
            if [[ "${MEDIA_TYPE:-movie}" == "episode" ]]; then
                ((hidden_episodes += 1))
            else
                ((hidden_movies += 1))
            fi
            continue
        fi

        ((shown += 1))

        display_name="${TITLE:-Desconocida}"

        if [[ -n "${YEAR:-}" ]]; then
            display_name+=" (${YEAR:-})"
        fi

        if [[ "${MEDIA_TYPE:-movie}" == "episode" &&
              "${SEASON_NUMBER:-}" =~ ^[0-9]+$ &&
              "${EPISODE_NUMBER:-}" =~ ^[0-9]+$ ]]
        then
            episode_code=$(printf 'S%02dE%02d' \
                "$SEASON_NUMBER" \
                "$EPISODE_NUMBER")
            display_name+=" ${episode_code}"
        fi

        prefix=$(printf "%d.       " "$shown")
        available=$((cols - ${#prefix}))
        (( available < 6 )) && available=6

        clear_current_line
        printf "%s%s\n" \
            "$prefix" \
            "$(truncate_text "$display_name" "$available")"

    done

    if (( total == 0 )); then
        clear_current_line
        printf '%s\n' "No hay archivos pendientes."

    elif (( hidden_movies > 0 || hidden_episodes > 0 )); then
        if (( hidden_movies == 1 )); then
            summary="1 película"
        elif (( hidden_movies > 1 )); then
            summary="${hidden_movies} películas"
        fi

        if (( hidden_episodes == 1 )); then
            part="1 capítulo de serie"
        elif (( hidden_episodes > 1 )); then
            part="${hidden_episodes} capítulos de serie"
        else
            part=""
        fi

        if [[ -n "$summary" && -n "$part" ]]; then
            summary+=" y ${part}"
        elif [[ -n "$part" ]]; then
            summary="$part"
        fi

        clear_current_line
        printf '…y %s más\n' "$summary"
    fi

    TITLE="${current_title:-}"
    YEAR="${current_year:-}"
    MEDIA_TYPE="${current_media_type:-movie}"
    SEASON_NUMBER="${current_season_number:-}"
    EPISODE_NUMBER="${current_episode_number:-}"
}
###############################################################################
# IDLE SCREEN
###############################################################################

draw_idle_screen()
{
    printf '\e[H'

    ui_title "🎬  FFmpeg Auto Transcoder"

    ui_section "⏸ EN ESPERA"
    aligned_field "Estado" "● Esperando nuevas películas..." "$YELLOW"

    ui_section "📋 COLA"
    draw_queue

    blank_line
    horizontal_rule
    printf '\e[J'
}


###############################################################################
# SERVICE STOPPED
###############################################################################

draw_service_stopped()
{
    printf '\e[H'

    ui_title "🎬  FFmpeg Auto Transcoder"

    ui_section "⛔ SERVICIO"
    aligned_field \
        "Estado" \
        "● El servicio de transcodificación está detenido" \
        "$RED"

    blank_line
    clear_current_line
    printf '%s\n' "Para iniciarlo:"
    blank_line
    clear_current_line
    printf '%s\n' "docker compose up -d ffmpeg-auto-transcoder"
    blank_line
    horizontal_rule
    printf '\e[J'
}


transcoder_is_running()
{
    if command -v systemctl >/dev/null 2>&1 &&
       systemctl list-unit-files transcoder.service >/dev/null 2>&1
    then
        systemctl is-active --quiet transcoder.service
    else
        pgrep -f '[t]ranscoder.sh' >/dev/null 2>&1
    fi
}
###############################################################################
# MAIN LOOP
###############################################################################

trap 'printf "\e[?1049l\e[?25h"' EXIT

printf '\e[?1049h'
printf '\e[?25l'
printf '\e[2J\e[H'

while true
do
    if ! transcoder_is_running; then
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
    get_pid
    calculate_eta
    finish_time
    calculate_elapsed_time
    calculate_colors
    update_status
    draw_screen

    sleep "$REFRESH"
done

