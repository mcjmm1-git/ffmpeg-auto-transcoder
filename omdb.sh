#!/usr/bin/env bash

omdb_search() {

    local IMDB_ID="$1"

    curl -s \
        --get \
        --data-urlencode "apikey=${OMDB_API_KEY}" \
        --data-urlencode "i=${IMDB_ID}" \
        "https://www.omdbapi.com/"
}
