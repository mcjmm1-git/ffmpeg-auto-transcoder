#!/usr/bin/env bash

###############################################################################
# EXTERNAL IDS
###############################################################################

tmdb_imdb_id()
{
    local TMDB_ID="${1:-}"

    [[ "$TMDB_ID" =~ ^[1-9][0-9]*$ ]] || {
        printf '%s\n' '{}'
        return 0
    }

    if [[ "${MEDIA_TYPE:-movie}" == "episode" ]]; then

        [[ "${SEASON_NUMBER:-}" =~ ^[0-9]+$ &&
           "${EPISODE_NUMBER:-}" =~ ^[0-9]+$ ]] || {
            printf '%s\n' '{}'
            return 0
        }

        curl -fsS \
            --connect-timeout 10 \
            --max-time 30 \
            --retry 2 \
            --retry-delay 1 \
            --get \
            --data-urlencode "api_key=${TMDB_API_KEY}" \
            "https://api.themoviedb.org/3/tv/${TMDB_ID}/season/${SEASON_NUMBER}/episode/${EPISODE_NUMBER}/external_ids"

    else

        curl -fsS \
            --connect-timeout 10 \
            --max-time 30 \
            --retry 2 \
            --retry-delay 1 \
            --get \
            --data-urlencode "api_key=${TMDB_API_KEY}" \
            "https://api.themoviedb.org/3/movie/${TMDB_ID}/external_ids"
    fi
}
###############################################################################
# DETECT MEDIA TYPE
###############################################################################

detect_media_type()
{
    local FILE="$1"
    local NAME

    NAME=$(basename "$FILE")
    NAME="${NAME%.*}"

    MEDIA_TYPE="movie"
    SEASON_NUMBER=""
    EPISODE_NUMBER=""

    # Compact Spanish chapter numbering. "Cap" must be a complete token
    # followed directly by the compact number (optionally through separators),
    # or the full word "Capitulo/Capítulo". This prevents movie titles such as
    # "Capitán Veneno - 1943" from being mistaken for season 19, episode 43.
    #
    # Silo [HDTV 720p][Cap.302] -> season 3, episode 02
    # Series Capitulo 1203.mkv   -> season 12, episode 03
    local COMPACT_CODE=""

    if [[ "$NAME" =~ (^|[^[:alnum:]])[Cc]ap([.]|[[:space:]_-])*([0-9]{3,4})([^0-9]|$) ]]; then
        COMPACT_CODE="${BASH_REMATCH[3]}"
    elif [[ "$NAME" =~ (^|[^[:alnum:]])[Cc]apitulo[[:space:]._:-]*([0-9]{3,4})([^0-9]|$) ]]; then
        COMPACT_CODE="${BASH_REMATCH[2]}"
    elif [[ "$NAME" =~ (^|[^[:alnum:]])[Cc]apítulo[[:space:]._:-]*([0-9]{3,4})([^0-9]|$) ]]; then
        COMPACT_CODE="${BASH_REMATCH[2]}"
    fi

    if [[ -n "$COMPACT_CODE" ]]; then
        local SEASON_DIGITS="${COMPACT_CODE:0:${#COMPACT_CODE}-2}"
        local EPISODE_DIGITS="${COMPACT_CODE: -2}"

        MEDIA_TYPE="episode"
        SEASON_NUMBER=$((10#$SEASON_DIGITS))
        EPISODE_NUMBER=$((10#$EPISODE_DIGITS))
        return
    fi

    # Common SxxExxx forms, allowing separators and "Ep":
    # Series.Name.S01E03.mkv
    # Series Name S01.E03.mp4
    # Series-Name-S01-E03.avi
    # Series Name S1 Ep3.mkv
    if [[ "$NAME" =~ [Ss]([0-9]{1,2})[[:space:]._-]*[Ee][Pp]?[[:space:]._-]*([0-9]{1,3}) ]]; then
        MEDIA_TYPE="episode"
        SEASON_NUMBER=$((10#${BASH_REMATCH[1]}))
        EPISODE_NUMBER=$((10#${BASH_REMATCH[2]}))
        return
    fi

    # Common 1x03 forms, also allowing separators around the x.
    if [[ "$NAME" =~ ([0-9]{1,2})[[:space:]._-]*[xX][[:space:]._-]*([0-9]{1,3}) ]]; then
        MEDIA_TYPE="episode"
        SEASON_NUMBER=$((10#${BASH_REMATCH[1]}))
        EPISODE_NUMBER=$((10#${BASH_REMATCH[2]}))
        return
    fi

    # Long English/Spanish forms.
    if [[ "$NAME" =~ [Ss]eason[[:space:]._-]*([0-9]{1,2})[[:space:]._-]*[Ee]pisode[[:space:]._-]*([0-9]{1,3}) ]]; then
        MEDIA_TYPE="episode"
        SEASON_NUMBER=$((10#${BASH_REMATCH[1]}))
        EPISODE_NUMBER=$((10#${BASH_REMATCH[2]}))
        return
    fi

    if [[ "$NAME" =~ [Tt]emporada[[:space:]._-]*([0-9]{1,2})[[:space:]._-]*[Ee]pisodio[[:space:]._-]*([0-9]{1,3}) ]]; then
        MEDIA_TYPE="episode"
        SEASON_NUMBER=$((10#${BASH_REMATCH[1]}))
        EPISODE_NUMBER=$((10#${BASH_REMATCH[2]}))
    fi
}

###############################################################################
# NORMALIZE FILENAME
###############################################################################

normalize_filename()
{
    local FILE="$1"
    local METADATA_WORDS
    local PRIMARY_TITLE=""
    local RELEASE_CUT_TAGS
    local TITLE_AFTER_YEAR=""
    local TITLE_BEFORE_YEAR=""
    local YEAR_MATCH=""

    detect_media_type "$FILE"

    TITLE=$(basename "$FILE")
    TITLE="${TITLE%.*}"

    YEAR=""

    # Extract the last plausible release year from the filename. Using the last
    # one preserves titles that contain a year or number, for example:
    #   1984 (1984)
    #   2001: A Space Odyssey (1968)
    #   Blade Runner 2049 (2017)
    # It also supports forms such as:
    #   Movie (1953)
    #   Movie (Director, 1953)
    #   Movie (Director.1953)
    #   (1953) Movie
    #   Movie [1953]
    YEAR_MATCH=$(
        printf '%s\n' "$TITLE" |
            awk '
                {
                    for (position = 1; position <= length($0) - 3; position++) {
                        candidate = substr($0, position, 4)
                        before = position == 1 ? "" : substr($0, position - 1, 1)
                        after = position + 4 > length($0) ? "" : substr($0, position + 4, 1)

                        if (candidate ~ /^(18|19|20)[0-9]{2}$/ &&
                            (before == "" || before ~ /[[:space:][:punct:]]/) &&
                            (after == "" || after ~ /[[:space:][:punct:]]/)) {
                            last_year = candidate
                        }
                    }
                }
                END {
                    if (last_year != "") {
                        print last_year
                    }
                }
            '
    )

    if [[ -n "$YEAR_MATCH" ]]; then
        YEAR="$YEAR_MATCH"
    fi

    # For movies, a release year is normally the boundary between the actual
    # title and uploader, director, cast, duration and release metadata. Prefer
    # the text before the final year. If the filename starts with the year, use
    # the text after it instead.
    if [[ "$MEDIA_TYPE" == "movie" && -n "$YEAR" ]]; then
        TITLE_BEFORE_YEAR="${TITLE%$YEAR*}"
        TITLE_AFTER_YEAR="${TITLE##*$YEAR}"

        PRIMARY_TITLE=$(printf '%s\n' "$TITLE_BEFORE_YEAR" |
            tr '._' '  ' |
            sed -E \
                -e 's/[[:space:]_.-]*\([^()]*$//' \
                -e 's/[[:space:]_.-]*\[[^][]*$//' \
                -e ':remove_trailing_block' \
                -e 's/[[:space:]_.-]*\([^()]*\)[[:space:]_.-]*$//; t remove_trailing_block' \
                -e 's/[[:space:]_.-]*\[[^][]*\][[:space:]_.-]*$//; t remove_trailing_block' \
                -e 's/^[[:space:]_.-]+//' \
                -e 's/[[:space:]_.-]+$//' \
                -e 's/[[:space:]]+/ /g')

        if [[ "$PRIMARY_TITLE" =~ [[:alnum:]] ]]; then
            TITLE="$PRIMARY_TITLE"
        else
            TITLE="$TITLE_AFTER_YEAR"
        fi
    fi

    # Remove season/episode code and everything following it.
    if [[ "$MEDIA_TYPE" == "episode" ]]; then
        TITLE=$(printf '%s
' "$TITLE" |
            sed -E \
                -e 's/[Ss][0-9]{1,2}[[:space:]._-]*[Ee][Pp]?[[:space:]._-]*[0-9]{1,3}.*$//' \
                -e 's/[0-9]{1,2}[[:space:]._-]*[xX][[:space:]._-]*[0-9]{1,3}.*$//' \
                -e 's/[Ss]eason[[:space:]._-]*[0-9]{1,2}[[:space:]._-]*[Ee]pisode[[:space:]._-]*[0-9]{1,3}.*$//' \
                -e 's/[Tt]emporada[[:space:]._-]*[0-9]{1,2}[[:space:]._-]*[Ee]pisodio[[:space:]._-]*[0-9]{1,3}.*$//' \
                -e 's/\[[Cc]ap[^]]*[0-9]{3,4}[^]]*\].*$//' \
                -e 's/[[:space:]_.-]*[Cc]ap[^0-9]*[0-9]{3,4}.*$//')
    fi

    # Remove bracketed blocks. They are normally alternate titles, quality,
    # language or release tags. The main title before the block is preferred
    # for the first TMDb query.
    TITLE=$(printf '%s
' "$TITLE" |
        sed -E 's/\[[^]]+\]//g')

    # Remove parenthesized blocks that contain the detected year. This strips
    # director/year metadata such as "(George Cukor.1953)" without leaving the
    # director attached to the title.
    if [[ -n "$YEAR" ]]; then
        TITLE=$(printf '%s
' "$TITLE" |
            sed -E "s/\([^)]*${YEAR}[^)]*\)//g")
    fi

    # With no release year, use only conservative structural clues. A trailing
    # dash followed exclusively by language/subtitle labels is metadata. If the
    # remaining final dot introduces three or more comma-separated cast names,
    # discard that cast suffix as well. Dotted release names without this cast
    # pattern are left untouched and continue through the normal separator pass.
    if [[ "$MEDIA_TYPE" == "movie" && -z "$YEAR" ]]; then
        local LANGUAGE_WORDS
        local CAST_PREFIX
        local CAST_SUFFIX
        local CAST_COMMAS

        LANGUAGE_WORDS='spanishsubs?|englishsubs?|spanish|castellano|english|latino|dual|multi|esp|eng|subs?|subtitles?|subbed|dubbed'
        TITLE=$(printf '%s\n' "$TITLE" |
            sed -E "s/[[:space:]]*[-–—]+[[:space:]]*(${LANGUAGE_WORDS})([[:space:]_.-]+(${LANGUAGE_WORDS}))*[[:space:]]*$//I")

        CAST_PREFIX="${TITLE%.*}"
        CAST_SUFFIX="${TITLE##*.}"
        CAST_COMMAS="${CAST_SUFFIX//[^,]/}"

        if [[ "$CAST_PREFIX" != "$TITLE" && ${#CAST_COMMAS} -ge 2 ]]; then
            TITLE="$CAST_PREFIX"
        fi
    fi

    # Replace common filename separators with spaces.
    TITLE=$(printf '%s
' "$TITLE" |
        tr '._' '  ')

    # Remove parenthesized release/language metadata while preserving genuine
    # alternate titles.
    METADATA_WORDS='subs?|subtitles?|subbed|dubbed|spanish|castellano|english|latino|dual|multi|esp|eng|aac|ac3|eac3|dts|truehd|atmos'
    TITLE=$(printf '%s
' "$TITLE" |
        sed -E "s/\([^)]*(${METADATA_WORDS})[^)]*\)//Ig")

    # Once a real release marker is reached, everything after it is technical
    # metadata or a release-group name.
    RELEASE_CUT_TAGS='4320p|2160p|1440p|1080p|720p|480p|xvid|x264|x265|h264|h265|hevc|avc|blu-ray|bluray|bdrip|brrip|web-dl|webdl|webrip|hdrip|dvd-rip|dvdrip|remux|hdr10|hdr|dolby[[:space:]]+vision'
    TITLE=$(printf '%s
' "$TITLE" |
        sed -E "s/(^|[[:space:]_-])(${RELEASE_CUT_TAGS})([[:space:]_-]|$).*$//I")

    # Remove a trailing site/domain credit. Do not strip generic "by NAME" or
    # "por NAME" suffixes here: both can be part of a genuine movie title
    # (for example "Stand by Me" or "La vida por delante"). When a release
    # year is present, the title boundary logic above has already discarded the
    # uploader section safely.
    TITLE=$(printf '%s
' "$TITLE" |
        sed -E \
            -e 's/[[:space:]]*\([^)]*\.(com|org|net|es)\)[[:space:]]*$//I')

    # Remove a bare year left outside brackets/parentheses.
    if [[ -n "$YEAR" && "$TITLE" != "$YEAR" ]]; then
        TITLE=$(printf '%s
' "$TITLE" |
            sed -E "s/(^|[[:space:]_.-])${YEAR}([[:space:]_.-]|$)/ /g")
    fi

    # Normalize punctuation and whitespace left by cleanup.
    TITLE=$(printf '%s
' "$TITLE" |
        sed -E \
            -e 's/[[:space:]]*[-–—]+[[:space:]]*/ - /g' \
            -e 's/^[[:space:]_.-]*[])]+[[:space:]_.-]*//' \
            -e 's/[[:space:]_-]+$//' \
            -e 's/^[[:space:]_-]+//' \
            -e 's/[[:space:]]+/ /g' \
            -e 's/^ //' \
            -e 's/ $//')

    [[ -n "$TITLE" ]] || TITLE="Unknown"
}

###############################################################################
# SEARCH MOVIE
###############################################################################

tmdb_search_movie()
{
    local RESPONSE

    if [[ -n "$YEAR" ]]; then
        RESPONSE=$(
            curl -fsS \
            --connect-timeout 10 \
            --max-time 30 \
            --retry 2 \
            --retry-delay 1 \
                --get \
                --data-urlencode "api_key=${TMDB_API_KEY}" \
                --data-urlencode "language=es-ES" \
                --data-urlencode "query=${TITLE}" \
                --data-urlencode "year=${YEAR}" \
                "https://api.themoviedb.org/3/search/movie"
        )
    else
        RESPONSE=$(
            curl -fsS \
            --connect-timeout 10 \
            --max-time 30 \
            --retry 2 \
            --retry-delay 1 \
                --get \
                --data-urlencode "api_key=${TMDB_API_KEY}" \
                --data-urlencode "language=es-ES" \
                --data-urlencode "query=${TITLE}" \
                "https://api.themoviedb.org/3/search/movie"
        )
    fi

    if [[ -n "$YEAR" ]] &&
       jq -e '(.results // []) | length == 0' >/dev/null 2>&1 <<< "$RESPONSE"
    then
        RESPONSE=$(
            curl -fsS \
                --connect-timeout 10 \
                --max-time 30 \
                --retry 2 \
                --retry-delay 1 \
                --get \
                --data-urlencode "api_key=${TMDB_API_KEY}" \
                --data-urlencode "language=es-ES" \
                --data-urlencode "query=${TITLE}" \
                "https://api.themoviedb.org/3/search/movie"
        )
    fi

    printf '%s\n' "$RESPONSE"
}

###############################################################################
# SEARCH TV SERIES
###############################################################################

###############################################################################
# SEARCH TV SERIES AND EPISODE
###############################################################################

tmdb_search_tv()
{
    local SEARCH_RESPONSE
    local SERIES_ID
    local SERIES_NAME
    local SERIES_DATE
    local EPISODE_RESPONSE
    local EPISODE_NAME
    local EPISODE_DATE
    local DISPLAY_TITLE

    # Search for the TV series.
    if [[ -n "$YEAR" ]]; then
        SEARCH_RESPONSE=$(
            curl -fsS \
            --connect-timeout 10 \
            --max-time 30 \
            --retry 2 \
            --retry-delay 1 \
                --get \
                --data-urlencode "api_key=${TMDB_API_KEY}" \
                --data-urlencode "language=es-ES" \
                --data-urlencode "query=${TITLE}" \
                --data-urlencode "first_air_date_year=${YEAR}" \
                "https://api.themoviedb.org/3/search/tv"
        )
    else
        SEARCH_RESPONSE=$(
            curl -fsS \
            --connect-timeout 10 \
            --max-time 30 \
            --retry 2 \
            --retry-delay 1 \
                --get \
                --data-urlencode "api_key=${TMDB_API_KEY}" \
                --data-urlencode "language=es-ES" \
                --data-urlencode "query=${TITLE}" \
                "https://api.themoviedb.org/3/search/tv"
        )
    fi

    SERIES_ID=$(jq -r '.results[0].id // empty' <<< "$SEARCH_RESPONSE")
    SERIES_NAME=$(jq -r '.results[0].name // empty' <<< "$SEARCH_RESPONSE")
    SERIES_DATE=$(jq -r '.results[0].first_air_date // empty' <<< "$SEARCH_RESPONSE")

    # No series found.
    if [[ -z "$SERIES_ID" ]]; then
        echo "TMDb -> TV series not found: $TITLE" >&2
        printf '%s\n' '{"page":1,"results":[],"total_pages":0,"total_results":0}'
        return 0
    fi

    echo "TMDb -> Series ID    : $SERIES_ID" >&2
    echo "TMDb -> Series name  : $SERIES_NAME" >&2

    # Get the specific episode information.
    EPISODE_RESPONSE=$(
        curl -fsS \
            --connect-timeout 10 \
            --max-time 30 \
            --retry 2 \
            --retry-delay 1 \
            --get \
            --data-urlencode "api_key=${TMDB_API_KEY}" \
            --data-urlencode "language=es-ES" \
            "https://api.themoviedb.org/3/tv/${SERIES_ID}/season/${SEASON_NUMBER}/episode/${EPISODE_NUMBER}"
    )

    EPISODE_NAME=$(jq -r '.name // empty' <<< "$EPISODE_RESPONSE")
    EPISODE_DATE=$(jq -r '.air_date // empty' <<< "$EPISODE_RESPONSE")

    if [[ -n "$EPISODE_NAME" ]]; then
        DISPLAY_TITLE=$(printf '%s - S%02dE%02d - %s' \
            "$SERIES_NAME" \
            "$SEASON_NUMBER" \
            "$EPISODE_NUMBER" \
            "$EPISODE_NAME")
    else
        DISPLAY_TITLE=$(printf '%s - S%02dE%02d' \
            "$SERIES_NAME" \
            "$SEASON_NUMBER" \
            "$EPISODE_NUMBER")
    fi

    echo "TMDb -> Episode name : ${EPISODE_NAME:-N/A}" >&2
    echo "TMDb -> Display title: $DISPLAY_TITLE" >&2

    # Return a movie-compatible structure so the existing transcoder
    # can continue reading .results[0].title and .release_date.
    jq -n \
        --argjson id "$SERIES_ID" \
        --arg title "$DISPLAY_TITLE" \
        --arg original_title "$SERIES_NAME" \
        --arg release_date "${EPISODE_DATE:-$SERIES_DATE}" \
        --arg overview "$(jq -r '.overview // empty' <<< "$EPISODE_RESPONSE")" \
        --arg poster_path "$(jq -r '.still_path // empty' <<< "$EPISODE_RESPONSE")" \
        --argjson vote_average "$(jq -r '.vote_average // 0' <<< "$EPISODE_RESPONSE")" \
        --argjson episode_id "$(jq -r '.id // 0' <<< "$EPISODE_RESPONSE")" \
        --arg series_name "$SERIES_NAME" \
        --arg episode_name "$EPISODE_NAME" \
        --argjson season "$SEASON_NUMBER" \
        --argjson episode "$EPISODE_NUMBER" \
        '{
            page: 1,
            results: [
                {
                    id: $id,
                    title: $title,
                    original_title: $original_title,
                    release_date: $release_date,
                    overview: $overview,
                    poster_path: $poster_path,
                    vote_average: $vote_average,
                    episode_id: $episode_id,
                    media_type: "episode",
                    series_name: $series_name,
                    episode_name: $episode_name,
                    season_number: $season,
                    episode_number: $episode
                }
            ],
            total_pages: 1,
            total_results: 1
        }'
}

###############################################################################
# EPISODE DETAILS
###############################################################################

tmdb_episode_details()
{
    local SERIES_ID="$1"
    local SEASON="$2"
    local EPISODE="$3"

    curl -fsS \
            --connect-timeout 10 \
            --max-time 30 \
            --retry 2 \
            --retry-delay 1 \
        --get \
        --data-urlencode "api_key=${TMDB_API_KEY}" \
        --data-urlencode "language=es-ES" \
        "https://api.themoviedb.org/3/tv/${SERIES_ID}/season/${SEASON}/episode/${EPISODE}"
}

###############################################################################
# SEARCH TMDB
###############################################################################

tmdb_search()
{
    local FILE="$1"

    normalize_filename "$FILE"

    echo "TMDb -> Type    : ${MEDIA_TYPE}" >&2
    echo "TMDb -> Title   : ${TITLE}" >&2
    echo "TMDb -> Year    : ${YEAR:-N/A}" >&2

    if [[ "$MEDIA_TYPE" == "episode" ]]; then
        echo "TMDb -> Season  : ${SEASON_NUMBER}" >&2
        echo "TMDb -> Episode : ${EPISODE_NUMBER}" >&2

        tmdb_search_tv
    else
        tmdb_search_movie
    fi
}
