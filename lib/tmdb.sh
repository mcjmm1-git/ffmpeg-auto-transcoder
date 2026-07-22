#!/usr/bin/env bash

tmdb_imdb_id()
{
    local TMDB_ID="$1"

    curl -s \
        "https://api.themoviedb.org/3/movie/${TMDB_ID}/external_ids?api_key=${TMDB_API_KEY}"
}

###############################################################################
# NORMALIZE FILENAME
###############################################################################

normalize_filename()
{
    local FILE="$1"

    TITLE=$(basename "$FILE")
    TITLE="${TITLE%.*}"

    # Extract year if present: "(1952)" or "1952 Title"
    YEAR=""

    if [[ "$TITLE" =~ \(((18|19|20)[0-9]{2})\) ]]; then
        YEAR="${BASH_REMATCH[1]}"
    elif [[ "$TITLE" =~ ^((18|19|20)[0-9]{2})([[:space:]_.-]|$) ]]; then
        YEAR="${BASH_REMATCH[1]}"
    fi

    # Remove year in parentheses or at the beginning
    TITLE=$(printf '%s\n' "$TITLE" |
        sed -E \
            -e 's/\((18|19|20)[0-9]{2}\)//g' \
            -e 's/^(18|19|20)[0-9]{2}[[:space:]_.-]+//')

    # Remove tags enclosed in square brackets
    TITLE=$(printf '%s\n' "$TITLE" |
        sed -E 's/\[[^]]+\]//g')

    # Replace dots with spaces
    TITLE=$(printf '%s\n' "$TITLE" |
        tr '.' ' ')

    # Remove common release tags
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

    # Normalize whitespace
    TITLE=$(printf '%s\n' "$TITLE" |
        sed 's/[[:space:]][[:space:]]*/ /g' |
        sed 's/^ *//;s/ *$//')
}

###############################################################################
# SEARCH TMDB
###############################################################################

tmdb_search()
{
    local FILE="$1"

    normalize_filename "$FILE"

    echo "TMDb -> Title : $TITLE" >&2
    echo "TMDb -> Year  : ${YEAR:-N/A}" >&2

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
