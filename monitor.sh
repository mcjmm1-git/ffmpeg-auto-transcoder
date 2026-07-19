#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source /etc/ffmpeg-auto-transcoder/config.sh

###############################################################################
# MONITOR
###############################################################################

set -Eeuo pipefail

export LC_NUMERIC=C

###############################################################################
# CONFIGURACIÓN
###############################################################################

PROGRESS_FILE="$LOGS/ffmpeg.progress"
EXTRA_FILE="$LOGS/ffmpeg.extra"

REFRESH=2


###############################################################################
# COLORES
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

LINEA="────────────────────────────────────────────────────────────────────────────"

###############################################################################
# SEGUNDOS → HH:MM:SS
###############################################################################

segundos_hms()
{
    local s=${1:-0}

    (( s < 0 )) && s=0

    printf "%02d:%02d:%02d" \
        $((s/3600)) \
        $(((s%3600)/60)) \
        $((s%60))
}

###############################################################################
# TIEMPO TRANSCURRIDO
###############################################################################

tiempo_transcurrido()
{
    if (( START_EPOCH == 0 ))
    then
        ELAPSED=0
    else
        ELAPSED=$(( $(date +%s)-START_EPOCH ))
    fi

    (( ELAPSED < 0 )) && ELAPSED=0

    ELAPSED_HMS=$(segundos_hms "$ELAPSED")
}

###############################################################################
# COLORES DINÁMICOS
###############################################################################

calcular_colores()
{
GPU_TEMP=${GPU_TEMP:-0}

    BAR_COLOR=$GREEN

    if (( PORCENTAJE_INT < 25 ))
    then
        BAR_COLOR=$RED

    elif (( PORCENTAJE_INT < 75 ))
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
# ESTADO
###############################################################################

estado()
{
    if [[ ! -f "$PROGRESS_FILE" ]]; then

        ESTADO="Esperando FFmpeg"

    elif [[ "$STATUS" == "end" ]]; then

        ESTADO="Finalizando"

    elif (( FRAME == 0 )); then

        ESTADO="Esperando primeros fotogramas"

    else

        ESTADO="Codificando correctamente"

    fi
}
###############################################################################
# BARRA DE PROGRESO
###############################################################################

crear_barra()
{
    local porcentaje=$1

porcentaje=$(printf "%.0f" "$porcentaje")

    (( porcentaje > 100 )) && porcentaje=100
    (( porcentaje < 0 )) && porcentaje=0

    local llenos=$((porcentaje/2))
    local vacios=$((50-llenos))

    local barra=""

    for ((i=0;i<llenos;i++))
    do
        barra+="█"
    done

    for ((i=0;i<vacios;i++))
    do
        barra+="░"
    done

    printf "%s" "$barra"
}


###############################################################################
# LEER PROGRESS
###############################################################################

leer_progress()
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

    SEGUNDOS_PROCESADOS=$((OUT_US/1000000))
}

###############################################################################
# CALCULAR PROGRESO
###############################################################################

calcular_progreso()
{
    PORCENTAJE=0
    RESTANTE=0

    if (( RAW_DUR > 0 ))
    then

        PORCENTAJE=$(awk \
            -v a="$SEGUNDOS_PROCESADOS" \
            -v b="$RAW_DUR" \
            'BEGIN{printf "%.2f",(a/b)*100}')

        (( SEGUNDOS_PROCESADOS > RAW_DUR )) && \
            SEGUNDOS_PROCESADOS=$RAW_DUR

        RESTANTE=$((RAW_DUR-SEGUNDOS_PROCESADOS))

    fi

    PORCENTAJE_INT=$(printf "%.0f" "$PORCENTAJE")
if (( PORCENTAJE_INT > 100 )); then
    PORCENTAJE_INT=100
fi

if (( PORCENTAJE_INT < 0 )); then
    PORCENTAJE_INT=0
fi
}

###############################################################################
# GPU
###############################################################################

leer_gpu()
{
    local datos

datos=$(nvidia-smi \
    --query-gpu=name,\
utilization.gpu,\
utilization.encoder,\
utilization.decoder,\
temperature.gpu,\
memory.used,\
memory.total,\
power.draw \
    --format=csv,noheader,nounits 2>/dev/null || true)

[[ -z "$datos" ]] && return

    IFS=',' read \
        GPU_NAME \
        GPU_USAGE \
        GPU_ENCODER \
        GPU_DECODER \
        GPU_TEMP \
        GPU_MEM_USED \
        GPU_MEM_TOTAL \
        GPU_POWER <<< "$datos"

    GPU_NAME=$(echo "$GPU_NAME" | xargs)
    GPU_USAGE=$(echo "$GPU_USAGE" | xargs)
    GPU_ENCODER=$(echo "$GPU_ENCODER" | xargs)
    GPU_DECODER=$(echo "$GPU_DECODER" | xargs)
    GPU_TEMP=$(echo "$GPU_TEMP" | xargs)
    GPU_MEM_USED=$(echo "$GPU_MEM_USED" | xargs)
    GPU_MEM_TOTAL=$(echo "$GPU_MEM_TOTAL" | xargs)
    GPU_POWER=$(echo "$GPU_POWER" | xargs)
}

obtener_pid()
{
    PID=$(pgrep -x ffmpeg | head -n1)

    if [[ -z "$PID" ]]; then
        PID="---"
    fi
}

###############################################################################
# ETA
###############################################################################

calcular_eta()
{
    local s

    s=$(echo "$SPEED" | tr -d x)

    ETA=0

    if [[ "$s" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        if (( $(echo "$s > 0" | bc -l) )); then
            ETA=$(awk \
                -v r="$RESTANTE" \
                -v s="$s" \
                'BEGIN{printf "%.0f", r/s}')
        fi
    fi
}

###############################################################################
# HORA FINAL
###############################################################################

hora_finalizacion()
{
    FIN=$(date -d "+${ETA} seconds" +"%H:%M:%S")
}



###############################################################################
# LEER EXTRA
###############################################################################

###############################################################################
# LEER EXTRA
###############################################################################

leer_extra()
{
    encoder_usage=0
    current_q="0.0"
    START_EPOCH=0

    CURRENT_FILE="Esperando..."
    TITULO=""
    RAW_DUR=0
    PID="-"

    ESTADO="esperando"

    if [[ -f "$EXTRA_FILE" ]]; then
        source "$EXTRA_FILE"
    fi
}
###############################################################################
# PANTALLA
###############################################################################

pintar()
{
    clear

    local barra

    barra=$(crear_barra "$PORCENTAJE_INT")

    echo -e "${BLUE}${BOLD}"
    echo "══════════════════════════════════════════════════════════════════════════════"
    echo "                           MONITOR"
    echo "══════════════════════════════════════════════════════════════════════════════"
    echo -e "${RESET}"

    echo

    printf "%-18s %s\n" "Archivo:" "$CURRENT_FILE"
    printf "%-18s %s\n" "Título:" "$TITULO"
    printf "%-18s %s\n" "Duración:" "$(segundos_hms "$RAW_DUR")"

    echo
    echo "$LINEA"

    echo
    echo -e "${BOLD}PROGRESO${RESET}"
    echo

    printf "%-18s %s / %s\n" \
        "Tiempo:" \
        "$(segundos_hms "$SEGUNDOS_PROCESADOS")" \
        "$(segundos_hms "$RAW_DUR")"

    printf "%-18s %.2f %%\n" \
        "Porcentaje:" \
        "$PORCENTAJE"

    printf "%-18s [%b%s%b]\n" \
    "Avance:" \
    "$BAR_COLOR" \
    "$barra" \
    "$RESET"

    echo
    echo "$LINEA"

    echo
    echo -e "${BOLD}RENDIMIENTO${RESET}"
    echo

    printf "%-18s %s\n" "FPS:" "$FPS"
    printf "%-18s %s\n" "Speed:" "$SPEED"
    printf "%-18s %s\n" "Q:" "$current_q"

    echo
    echo "$LINEA"

    echo
    echo -e "${BOLD}GPU${RESET}"
    echo

    printf "%-18s %s\n" "Modelo:" "$GPU_NAME"
    printf "%-18s %s %%\n" "GPU:" "$GPU_USAGE"
    printf "%-18s %s %%\n" "Encoder:" "$GPU_ENCODER"
    printf "%-18s %s %%\n" "Decoder:" "$GPU_DECODER"

    printf "%-18s %s / %s MB\n" \
        "VRAM:" \
        "$GPU_MEM_USED" \
        "$GPU_MEM_TOTAL"

    printf "%-18s %b%s ºC%b\n" \
    "Temperatura:" \
    "$TEMP_COLOR" \
    "$GPU_TEMP" \
    "$RESET"

    printf "%-18s %s W\n" \
        "Potencia:" \
        "$GPU_POWER"

    echo
    echo "$LINEA"

    echo
    echo -e "${BOLD}TIEMPOS${RESET}"
    echo

printf "%-18s %s\n" \
    "Codificando:" \
    "$ELAPSED_HMS"

    printf "%-18s %s\n" \
        "Restante:" \
        "$(segundos_hms "$RESTANTE")"

    printf "%-18s %s\n" \
        "ETA:" \
        "$(segundos_hms "$ETA")"

    printf "%-18s %s\n" \
        "Finaliza:" \
        "$FIN"

    echo

echo
echo "$LINEA"

echo

echo -e "${BOLD}ESTADO${RESET}"

echo

printf "%-18s %b●%b %s\n" \
    "Estado:" \
    "$GREEN" \
    "$RESET" \
    "$ESTADO"

printf "%-18s %s\n" \
    "PID:" \
    "$PID"

echo

}

pintar_sin_proceso()
{
    clear

    echo -e "${BLUE}${BOLD}"
    echo "══════════════════════════════════════════════════════════════════════════════"
    echo "                           MONITOR"
    echo "══════════════════════════════════════════════════════════════════════════════"
    echo -e "${RESET}"

    echo
    echo -e "${YELLOW}●${RESET} No hay ninguna codificación en curso."
    echo
    echo "Esperando una nueva película..."
    echo
}

###############################################################################
# SERVICIO DETENIDO
###############################################################################

pintar_servicio_parado()
{
    clear

    echo -e "${RED}${BOLD}"
    echo "══════════════════════════════════════════════════════════════════════════════"
    echo "                           MONITOR"
    echo "══════════════════════════════════════════════════════════════════════════════"
    echo -e "${RESET}"

    echo
    echo -e "${RED}●${RESET} El servicio procesar.service está detenido."
    echo
    echo "Arráncalo con:"
    echo
    echo "sudo systemctl start procesar.service"
    echo
}

###############################################################################
# PROGRAMA PRINCIPAL
###############################################################################

while true
do
    if ! systemctl is-active --quiet procesar.service; then
        pintar_servicio_parado
        sleep "$REFRESH"
        continue
    fi

    leer_extra

    if [[ "$ESTADO" == "esperando" ]]; then
        pintar_sin_proceso
        sleep "$REFRESH"
        continue
    fi

    leer_progress
    calcular_progreso
    leer_gpu
    calcular_eta
    hora_finalizacion
    tiempo_transcurrido
    calcular_colores
    estado
    pintar

    sleep "$REFRESH"
done


