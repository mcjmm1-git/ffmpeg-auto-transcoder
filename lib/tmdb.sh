#!/usr/bin/env bash

tmdb_imdb_id() {

    local TMDB_ID="$1"

    curl -s \
        "https://api.themoviedb.org/3/movie/${TMDB_ID}/external_ids?api_key=${TMDB_API_KEY}"
}

###############################################################################
# NORMALIZAR NOMBRE
###############################################################################

normalizar_nombre()
{
    local FILE="$1"

    TITLE=$(basename "$FILE")
    TITLE="${TITLE%.*}"

    # Extraer año si existe
    YEAR=$(printf '%s\n' "$TITLE" |
        grep -oE '\((18|19|20)[0-9]{2}\)' |
        tr -d '()')

    # Eliminar únicamente el año entre paréntesis
    TITLE=$(printf '%s\n' "$TITLE" |
        sed -E 's/\((18|19|20)[0-9]{2}\)//g')

    # Eliminar etiquetas entre corchetes
    TITLE=$(printf '%s\n' "$TITLE" |
        sed -E 's/\[[^]]+\]//g')

    # Sustituir puntos por espacios
    TITLE=$(printf '%s\n' "$TITLE" |
        tr '.' ' ')

    # Eliminar etiquetas típicas de ripeos
    TITLE=$(printf '%s\n' "$TITLE" |
        awk '
        {
            IGNORECASE=1

            gsub(/\<2160p\>/,"")
            gsub(/\<1080p\>/,"")
            gsub(/\<720p\>/,"")
            gsub(/\<480p\>/,"")

            gsub(/\<x264\>/,"")
            gsub(/\<x265\>/,"")
            gsub(/\<h264\>/,"")
            gsub(/\<h265\>/,"")

            gsub(/\<hevc\>/,"")
            gsub(/\<bluray\>/,"")
            gsub(/\<bdrip\>/,"")
            gsub(/\<brrip\>/,"")
            gsub(/\<web-dl\>/,"")
            gsub(/\<webrip\>/,"")
            gsub(/\<hdrip\>/,"")
            gsub(/\<dvdrip\>/,"")
            gsub(/\<remux\>/,"")
            gsub(/\<hdr10\>/,"")
            gsub(/\<dv\>/,"")

            gsub(/\<aac\>/,"")
            gsub(/\<ac3\>/,"")
            gsub(/\<dts\>/,"")
            gsub(/\<truehd\>/,"")
            gsub(/\<atmos\>/,"")

            print
        }')

    # Limpiar espacios
    TITLE=$(printf '%s\n' "$TITLE" |
        sed 's/[[:space:]][[:space:]]*/ /g' |
        sed 's/^ *//;s/ *$//')
}

###############################################################################
# BUSCAR EN TMDB
###############################################################################

tmdb_search()
{
    local FILE="$1"

    normalizar_nombre "$FILE"

echo "TMDb -> Título : $TITLE" >&2
echo "TMDb -> Año    : ${YEAR:-N/D}" >&2

    if [[ -n "$YEAR" ]]
    then
        curl -s \
            --get \
            --data-urlencode "api_key=${TMDB_API_KEY}" \
            --data-urlencode "language=es-ES" \
            --data-urlencode "query=${TITLE}" \
            --data-urlencode "year=${YEAR}" \
            "https://api.themoviedb.org/3/search/movie"
    else
        curl -s \
            --get \
            --data-urlencode "api_key=${TMDB_API_KEY}" \
            --data-urlencode "language=es-ES" \
            --data-urlencode "query=${TITLE}" \
            "https://api.themoviedb.org/3/search/movie"
    fi
}


