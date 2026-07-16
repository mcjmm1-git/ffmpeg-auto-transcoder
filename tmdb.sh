#!/usr/bin/env bash

tmdb_imdb_id() {

    local TMDB_ID="$1"

    curl -s \
        "https://api.themoviedb.org/3/movie/${TMDB_ID}/external_ids?api_key=${TMDB_API_KEY}"
}

tmdb_search() {

    local FILE="$1"

    local NAME
    NAME=$(basename "$FILE")

    NAME="${NAME%.*}"

    NAME=$(echo "$NAME" \
        | sed -E 's/\[[^]]+\]//g' \
        | sed -E 's/\([^)]*\)//g' \
        | sed -E 's/\b(2160p|1080p|720p|480p|x264|x265|h264|h265|HEVC|BluRay|WEBRip|WEB-DL|HDR|DV|REMUX|AAC|DTS|TRUEHD|ATMOS)\b//Ig' \
        | tr '.' ' ' \
        | sed 's/  */ /g' \
        | sed 's/^ *//;s/ *$//')

NAME=$(echo "$NAME" | sed -E 's/[[:space:]]+(18|19|20)[0-9]{2}$//')

    curl -s \
        --get \
        --data-urlencode "api_key=${TMDB_API_KEY}" \
        --data-urlencode "language=es-ES" \
        --data-urlencode "query=${NAME}" \
        "https://api.themoviedb.org/3/search/movie"
}
