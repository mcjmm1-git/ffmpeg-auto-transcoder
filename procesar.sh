#!/usr/bin/env bash

#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/config.sh"
source "$SCRIPT_DIR/lib/tmdb.sh"
source "$SCRIPT_DIR/lib/omdb.sh"

###############################################################################
# COMPROBAR CONFIGURACIÓN
###############################################################################

if [[ -z "$MEDIA_DIR" || "$MEDIA_DIR" == "/CAMBIAR/ESTA/RUTA" ]]; then
    echo
    echo "ERROR: Debe configurar MEDIA_DIR en config.sh"
    echo
    exit 1
fi

set -Eeuo pipefail
IFS=$'\n\t'
export LC_NUMERIC=C

###############################################################################
# CONFIGURACIÓN
###############################################################################
INPUT="$ENTRADA"
OUTPUT="$PROCESADAS"
JELLYFIN_DIR="$JELLYFIN"
LOGDIR="$LOGS"
DONEDIR="$TERMINADAS"
ERRDIR="$ERRORES"

mkdir -p "$OUTPUT" "$JELLYFIN_DIR" "$LOGDIR" "$DONEDIR" "$ERRDIR"

LOGFILE="${LOGDIR}/procesar_$(date +%F_%H-%M-%S).log"


TARGET_TOTAL_BPS=$(awk \
    -v gb="$TARGET_GB" \
    -v min="$TARGET_MIN" \
    'BEGIN{printf "%.0f", (gb*1024*1024*1024*8)/(min*60)}')


###############################################################################
# FUNCIONES
###############################################################################
log() {
    printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$LOGFILE"
}

error() {
    log "ERROR: $*"
    exit 1
}

require_program() {
    command -v "$1" >/dev/null 2>&1 || error "No existe el programa '$1'"
}

###############################################################################
# COMPROBACIONES
###############################################################################
require_program ffprobe
require_program ffmpeg
require_program jq
require_program bc

[[ -d "$INPUT" ]] || error "No existe el directorio de entrada $INPUT"

for DIR in "$INPUT" "$OUTPUT" "$DONEDIR" "$ERRDIR" "$LOGDIR"; do
    [[ -w "$DIR" ]] || error "Sin permiso de escritura en $DIR"
done

###############################################################################
# BUSCAR PELÍCULAS
###############################################################################

PROGRESS_FILE="${LOGDIR}/ffmpeg.progress"
EXTRA_FILE="${LOGDIR}/ffmpeg.extra"

while true
do
    mapfile -d '' MOVIES < <(
        find "$INPUT" -type f \( \
            -iname "*.mkv" -o \
            -iname "*.mp4" -o \
            -iname "*.avi" -o \
            -iname "*.m2ts" -o \
            -iname "*.ts" \
        \) -print0 | sort -z
    )

    if (( ${#MOVIES[@]} == 0 )); then

        cat > "$EXTRA_FILE" <<EOF
ESTADO=esperando
EOF

        : > "$PROGRESS_FILE"

        sleep 5
        continue
    fi

###############################################################################
# PROCESAR
###############################################################################
    for FILE in "${MOVIES[@]}"
    do
        [[ -f "$FILE" ]] || continue

        BASENAME=$(basename "$FILE")
        NAME="${BASENAME%.*}"
        OUTFILE="${OUTPUT}/${NAME}.mkv"

    log "==============================================================="
    log "Archivo: $BASENAME"
    log "==============================================================="

    # Intentar llamadas a APIs externas de forma segura
    TITLE="Desconocido"; YEAR=""; VOTE="0"; ID="0"; IMDB_ID=""
    if command -v tmdb_search >/dev/null 2>&1; then
        TMDB_JSON=$(tmdb_search "$FILE" || echo "{}")

if ! jq empty >/dev/null 2>&1 <<<"$TMDB_JSON"; then
    log "ERROR: TMDb ha devuelto un JSON no válido"
    log "$TMDB_JSON"
    TMDB_JSON='{}'
fi
        TITLE=$(jq -r '.results[0].title // "Desconocido"' <<<"$TMDB_JSON")
        YEAR=$(jq -r '.results[0].release_date // ""' <<<"$TMDB_JSON" | cut -d- -f1)
        VOTE=$(jq -r '.results[0].vote_average // 0' <<<"$TMDB_JSON")
        ID=$(jq -r '.results[0].id // 0' <<<"$TMDB_JSON")

        if command -v tmdb_imdb_id >/dev/null 2>&1; then
            EXTERNAL=$(tmdb_imdb_id "$ID" || echo "{}")

if ! jq empty >/dev/null 2>&1 <<<"$EXTERNAL"; then
    log "ERROR: TMDb external_ids ha devuelto un JSON no válido"
    log "$EXTERNAL"
    EXTERNAL='{}'
fi
            IMDB_ID=$(jq -r '.imdb_id // ""' <<<"$EXTERNAL")
        fi
    fi

    echo -e "\nTMDb\n------------------------------------------------"
    printf "%-20s %s\n" "Título:" "$TITLE"
    printf "%-20s %s\n" "Año:" "$YEAR"
    printf "%-20s %s\n" "Puntuación:" "$VOTE"
    printf "%-20s %s\n" "ID:" "$ID"

    IMDB="-"; IMDB_RATING="-"; METASCORE="-"; DIRECTOR="-"
    if [[ -n "$IMDB_ID" ]] && command -v omdb_search >/dev/null 2>&1; then
        OMDB_JSON=$(omdb_search "$IMDB_ID" || echo "{}")

if ! jq empty >/dev/null 2>&1 <<<"$OMDB_JSON"; then
    log "ERROR: OMDb ha devuelto un JSON no válido"
    log "$OMDB_JSON"
    OMDB_JSON='{}'
fi
        IMDB=$(jq -r '.imdbID // "-"' <<<"$OMDB_JSON")
        IMDB_RATING=$(jq -r '.imdbRating // "-"' <<<"$OMDB_JSON")
        METASCORE=$(jq -r '.Metascore // "-"' <<<"$OMDB_JSON")
        DIRECTOR=$(jq -r '.Director // "-"' <<<"$OMDB_JSON")
    fi

    echo -e "\nOMDb\n------------------------------------------------"
    printf "%-20s %s\n" "IMDb:" "$IMDB"
    printf "%-20s %s\n" "Rating:" "$IMDB_RATING"
    printf "%-20s %s\n" "Metascore:" "$METASCORE"
    printf "%-20s %s\n" "Director:" "$DIRECTOR"
    printf "%-20s %s\n" "IMDb ID:" "$IMDB_ID"
    # Lectura de ffprobe con verificación de errores
    JSON=$(ffprobe -v quiet -print_format json -show_format -show_streams "$FILE" || echo "")
    if [[ -z "$JSON" ]]; then
        log "ERROR: ffprobe no pudo leer el archivo $BASENAME. Saltando..."
        mv "$FILE" "$ERRDIR/"
        continue
    fi

    # CORRECCIÓN JQ: Extraer el objeto de vídeo de forma aislada, omitiendo imágenes incrustadas (covers)
    VIDEO=$(jq '[.streams[] | select(.codec_type=="video" and (.disposition.attached_pic != 1))] | .[0] // empty' <<<"$JSON" 2>/dev/null || echo "")
    if [[ -z "$VIDEO" ]]; then
        log "ERROR: No se encontró pista de vídeo en $BASENAME. Saltando..."
        mv "$FILE" "$ERRDIR/"
        continue
    fi

    WIDTH=$(jq -r '.width // 0' <<<"$VIDEO")
    HEIGHT=$(jq -r '.height // 0' <<<"$VIDEO")
    [[ "$WIDTH" =~ ^[0-9]+$ ]] || WIDTH=0
    [[ "$HEIGHT" =~ ^[0-9]+$ ]] || HEIGHT=0
    CODEC=$(jq -r '.codec_name // "unknown"' <<<"$VIDEO")
    PIXFMT=$(jq -r '.pix_fmt // "yuv420p"' <<<"$VIDEO")
    FPS=$(jq -r '.avg_frame_rate // "0/0"' <<<"$VIDEO")

    FPS_REAL=$(awk -F/ '{if($2==0) print 0; else printf "%.3f",$1/$2}' <<<"$FPS")
    COLOR_TRANSFER=$(jq -r '.color_transfer // ""' <<<"$VIDEO")
    COLOR_PRIMARIES=$(jq -r '.color_primaries // ""' <<<"$VIDEO")

    HDR="NO"
    if [[ "$COLOR_TRANSFER" == "smpte2084" || "$COLOR_TRANSFER" == "arib-std-b67" || "$COLOR_PRIMARIES" == "bt2020" ]]; then
        HDR="SI"
    fi

    DV="NO"
    if jq -e '.side_data_list[]? | tostring | test("DOVI";"i")' <<<"$VIDEO" >/dev/null 2>&1; then
        DV="SI"
    fi

    DURATION=$(jq -r '.format.duration // 0' <<<"$JSON")
    [[ "$DURATION" =~ ^[0-9.]+$ ]] || DURATION=0
    DURATION_INT=$(awk -v d="$DURATION" 'BEGIN{printf "%.0f", d}')
    SIZE=$(jq -r '.format.size // 0' <<<"$JSON")
    [[ "$SIZE" =~ ^[0-9]+$ ]] || SIZE=0
    BITRATE=$(jq -r '.format.bit_rate // 0' <<<"$JSON")
    [[ "$BITRATE" =~ ^[0-9]+$ ]] || BITRATE=0

    if [[ "$BITRATE" == "0" && "$DURATION_INT" -gt 0 ]]; then
        BITRATE=$(awk -v s="$SIZE" -v d="$DURATION_INT" 'BEGIN{printf "%.0f",(s*8)/d}')
    fi

    DURATION_HMS=$(printf "%02d:%02d:%02d" \
        $((DURATION_INT/3600)) \
        $(((DURATION_INT%3600)/60)) \
        $((DURATION_INT%60)))

    if (( WIDTH >= 3800 )); then RESOLUTION="4K"
    elif (( WIDTH >= 2500 )); then RESOLUTION="1440p"
    elif (( WIDTH >= 1900 )); then RESOLUTION="1080p"
    elif (( WIDTH >= 1200 )); then RESOLUTION="720p"
    else RESOLUTION="SD"; fi

    echo -e "\nVídeo\n------------------------------------------------"
    printf "%-20s %s\n" "Codec:" "$CODEC"
    printf "%-20s %s\n" "Resolución:" "${WIDTH}x${HEIGHT} (${RESOLUTION})"
    printf "%-20s %s\n" "Pixel Format:" "$PIXFMT"
    printf "%-20s %s\n" "FPS:" "$FPS_REAL"
    printf "%-20s %s\n" "HDR:" "$HDR"
    printf "%-20s %s\n" "Dolby Vision:" "$DV"
    printf "%-20s %s\n" "Duración:" "$DURATION_HMS"
    printf "%-20s %.2f GB\n" "Tamaño:" "$(awk -v s="$SIZE" 'BEGIN{print s/1024/1024/1024}')"
    printf "%-20s %.2f Mbps\n" "Bitrate:" "$(awk -v b="$BITRATE" 'BEGIN{print b/1000000}')"

    echo -e "\nAudio\n------------------------------------------------"
    jq -r '.streams[] | select(.codec_type=="audio") | "\(.index)|\(.tags.language // "und")|\(.codec_name)|\(.channels)"' <<<"$JSON" |
    while IFS="|" read -r IDX LANG ACODEC CH; do
        printf "Pista %-3s %-8s %-12s %s canales\n" "$IDX" "$LANG" "$ACODEC" "$CH"
    done

    echo -e "\nSubtítulos\n------------------------------------------------"
    jq -r '.streams[] | select(.codec_type=="subtitle") | "\(.index)|\(.tags.language // "und")|\(.codec_name)"' <<<"$JSON" |
    while IFS="|" read -r IDX LANG SCODEC; do
        printf "Pista %-3s %-8s %s\n" "$IDX" "$LANG" "$SCODEC"
    done
    echo

    ###########################################################################
    # CONFIGURACIÓN DE FFMPEG Y CÁLCULO DE BITRATE OBJETIVO
    ###########################################################################
    log "Calculando bitrate dinámico para el reescalado..."
    
    # Calcular bitrate basándose en la duración real del archivo actual
    if (( DURATION_INT > 0 )); then
        CALC_VIDEO_BPS=$(awk -v total="$TARGET_TOTAL_BPS" -v dest_t="$TARGET_MIN" -v real_t="$DURATION_INT" 'BEGIN{printf "%.0f", (total * (dest_t * 60)) / real_t}')
    else
        CALC_VIDEO_BPS=$MIN_VIDEO_BPS
    fi

    # Asegurar que el bitrate nunca sea inferior al umbral mínimo crítico de 4K
    if (( CALC_VIDEO_BPS < MIN_VIDEO_BPS )); then
        CALC_VIDEO_BPS=$MIN_VIDEO_BPS
    fi
    
    log "Bitrate asignado para la pista de vídeo: $(awk -v b="$CALC_VIDEO_BPS" 'BEGIN{printf "%.2f", b/1000000}') Mbps"

    # Preparar el pixel format de salida y espacio de color para NVENC
    ENC_PIX_FMT="yuv420p"
    FFMPEG_EXTRA_FLAGS=()

    if [[ "$HDR" == "SI" || "$PIXFMT" == *"10"* ]]; then
        # NVENC requiere p010le para trabajar flujos de 10 bits de forma nativa por hardware
        ENC_PIX_FMT="p010le"
        if [[ "$COLOR_TRANSFER" == "smpte2084" ]]; then
            FFMPEG_EXTRA_FLAGS+=(-color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc)
        fi
    fi

START_EPOCH=$(date +%s)

    log "Iniciando transcodificación por GPU..."

###############################################################################
# Reiniciar fichero de progreso
###############################################################################

lanzar_ffmpeg() {

    ffmpeg -y -v error \
        -hwaccel cuda \
        -hwaccel_output_format cuda \
        -i "$FILE" \
        -progress "$PROGRESS_FILE" \
        -vf "$FILTRO" \
        -c:v hevc_nvenc \
        -preset p4 \
        -tune hq \
        -rc vbr \
        -b:v "$CALC_VIDEO_BPS" \
        -maxrate:v $((CALC_VIDEO_BPS * 2)) \
        -bufsize:v $((CALC_VIDEO_BPS * 4)) \
        "${FFMPEG_EXTRA_FLAGS[@]}" \
        -c:a copy \
        -c:s copy \
        "$OUTFILE" < /dev/null &

    FFMPEG_PID=$!
}

    # Variables de control de tiempo y velocidad (5 minutos = 300 segundos)
# Variables de control de avance real
limite_tiempo=300          # 5 minutos sin avanzar
ultimo_frame=0
ultimo_movimiento=$SECONDS 
CANCELADO_TESTIGO="${LOGDIR}/ffmpeg_cancelado_${NAME}.tmp"
rm -f "$CANCELADO_TESTIGO"

# Forzamos la creación del archivo limpio para despertar al panel izquierdo
PROGRESS_FILE="${LOGDIR}/ffmpeg.progress"

rm -f "$PROGRESS_FILE"
: > "$PROGRESS_FILE"

# Archivo auxiliar para el monitor (NO lo toca FFmpeg)
EXTRA_FILE="${LOGDIR}/ffmpeg.extra"
: > "$EXTRA_FILE"

GPU_FILTER="scale_cuda=w=${TARGET_W}:h=${TARGET_H}:force_original_aspect_ratio=decrease:interp_algo=lanczos"

CPU_FILTER="scale=w=${TARGET_W}:h=${TARGET_H}:force_original_aspect_ratio=decrease:flags=lanczos,pad=w=${TARGET_W}:h=${TARGET_H}:x=(ow-iw)/2:y=(oh-ih)/2"

FILTRO="$GPU_FILTER"

for intento in 1 2; do

    if (( intento == 1 )); then
        FILTRO="$GPU_FILTER"
        log "Intentando filtros GPU..."
    else
        FILTRO="$CPU_FILTER"
        log "GPU incompatible. Reintentando con pad CPU..."
        rm -f "$OUTFILE"
        echo "progress=continue" > "$PROGRESS_FILE"
    fi

    lanzar_ffmpeg

    # Monitorizamos el archivo de progreso mientras FFmpeg esté vivo
        while kill -0 $FFMPEG_PID 2>/dev/null; do
        sleep 2 # Intervalo de comprobación

        if [[ -f "$PROGRESS_FILE" ]]; then
            # 1. CAPTURA Y ANEXO DEL USO DEL ENCODER (NVIDIA NVENC)
            encoder_usage=$(nvidia-smi --query-gpu=utilization.encoder --format=csv,noheader,nounits -i 0 2>/dev/null | tr -d '[:space:]' || echo "0")
# Leer FPS real
linea_fps=$(grep "^fps=" "$PROGRESS_FILE" | tail -1 || true)

# Leer Q real
linea_q=$(grep "^stream_0_0_q=" "$PROGRESS_FILE" | tail -1 || true)

[[ "$linea_fps" =~ fps=([0-9.]+) ]] \
    && current_fps="${BASH_REMATCH[1]}" \
    || current_fps="0"

[[ "$linea_q" =~ stream_0_0_q=([0-9.-]+) ]] \
    && current_q="${BASH_REMATCH[1]}" \
    || current_q="0.0"

PID=$FFMPEG_PID

echo "DEBUG FFMPEG_PID=[$FFMPEG_PID]"
echo "DEBUG PID=[$PID]"

# Escribir archivo auxiliar para el monitor
cat > "$EXTRA_FILE" <<EOF
encoder_usage=${encoder_usage}
current_q=${current_q}
START_EPOCH=${START_EPOCH}
CURRENT_FILE="${BASENAME}"
TITULO="${TITLE}"
RAW_DUR=${DURATION_INT}
PID=${FFMPEG_PID}
ESTADO=codificando
EOF

# 2. COMPROBAR SI FFMPEG SIGUE AVANZANDO

linea_frame=$(grep "^frame=" "$PROGRESS_FILE" | tail -1 || true)

if [[ "$linea_frame" =~ frame=([0-9]+) ]]; then
    frame_actual="${BASH_REMATCH[1]}"

    echo "frame=$frame_actual  ultimo=$ultimo_frame"

    if (( frame_actual > ultimo_frame )); then
        ultimo_frame=$frame_actual
        ultimo_movimiento=$SECONDS
    fi
fi

# Si no ha avanzado en 10 minutos, se considera bloqueado
if (( SECONDS - ultimo_movimiento >= limite_tiempo )); then
    echo "==============================================================="
    echo "ALERTA: FFmpeg lleva 10 minutos sin avanzar."
    echo "Cancelando proceso..."
    echo "==============================================================="
    touch "$CANCELADO_TESTIGO"
    kill -9 $FFMPEG_PID 2>/dev/null || true
    break
fi
        fi
    done
    wait $FFMPEG_PID
    FFMPEG_EXIT=$?

    if (( FFMPEG_EXIT == 0 )); then
        break
    fi
done

# Verificamos cómo terminó el proceso
if [[ -f "$CANCELADO_TESTIGO" ]]; then
    log "TIMEOUT: FFmpeg detenido por falta de avance en $BASENAME"
    rm -f "$CANCELADO_TESTIGO"
    rm -f "$OUTFILE" "$PROGRESS_FILE" "$EXTRA_FILE"
    mv "$FILE" "$ERRDIR/"
    continue

elif (( FFMPEG_EXIT != 0 )); then
    log "ERROR: Han fallado los dos intentos de transcodificación (GPU y CPU)."
    rm -f "$OUTFILE" "$PROGRESS_FILE" "$EXTRA_FILE"
    mv "$FILE" "$ERRDIR/"
    continue

elif [[ ! -s "$OUTFILE" ]]; then
    log "ERROR: El archivo de salida no existe o está vacío."
    rm -f "$OUTFILE" "$PROGRESS_FILE" "$EXTRA_FILE"
    mv "$FILE" "$ERRDIR/"
    continue

else
    log "Transcodificación completada con éxito."
    rm -f "$PROGRESS_FILE" "$EXTRA_FILE"

    # Publicar la película terminada en Jellyfin
    if mv "$OUTFILE" "$JELLYFIN_DIR/"; then
        log "Película movida a Jellyfin: $JELLYFIN_DIR/$NAME.mkv"
        mv "$FILE" "$DONEDIR/"
    else
        log "ERROR: No se pudo mover la película a Jellyfin."
        rm -f "$OUTFILE"
        mv "$FILE" "$ERRDIR/"
    fi
fi
done

log "Lote terminado. Esperando nuevas películas..."

sleep 5

done

