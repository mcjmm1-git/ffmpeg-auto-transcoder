#!/usr/bin/env bash

omdb_search()
{
    local IMDB_ID="${1:-}"

    if [[ -z "${OMDB_API_KEY:-}" ]]; then
        printf '%s\n' '{"Response":"False","Error":"OMDb API key is not configured."}'
        return 0
    fi

    if [[ ! "$IMDB_ID" =~ ^tt[0-9]+$ ]]; then
        printf '%s\n' '{"Response":"False","Error":"Invalid IMDb ID."}'
        return 0
    fi

    curl -fsS \
        --connect-timeout 10 \
        --max-time 30 \
        --retry 2 \
        --retry-delay 1 \
        --get \
        --data-urlencode "apikey=${OMDB_API_KEY}" \
        --data-urlencode "i=${IMDB_ID}" \
        "https://www.omdbapi.com/"
}
