#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/config.sh"
source "$SCRIPT_DIR/lib/tmdb.sh"
source "$SCRIPT_DIR/lib/omdb.sh"

###############################################################################
# CHECK CONFIGURATION
###############################################################################

if [[ -z "$MEDIA_DIR" || "$MEDIA_DIR" == "/CHANGE/THIS/PATH" ]]; then
    echo
    echo "ERROR: Please configure MEDIA_DIR in config.sh"
    echo
    exit 1
fi

set -Eeuo pipefail
IFS=$'\n\t'
export LC_NUMERIC=C

###############################################################################
# CONFIGURATION
###############################################################################

mkdir -p \
    "$INCOMING" \
    "$COMPLETED" \
    "$FAILED" \
    "$FAILED/metadata-review" \
    "$LOGS" \
    "$TEMP"

for OUTPUT_ROOT in "${OUTPUT_ROOTS[@]}"; do

    [[ -n "$OUTPUT_ROOT" ]] || continue

    mkdir -p \
        "$OUTPUT_ROOT/processing" \
        "$OUTPUT_ROOT/library/films" \
        "$OUTPUT_ROOT/library/series"

done

LOGFILE="${LOGS}/transcoder_$(date +%F_%H-%M-%S).log"

TARGET_TOTAL_BPS=$(awk \
    -v gb="$TARGET_GB" \
    -v min="$TARGET_MIN" \
    'BEGIN{printf "%.0f", (gb*1024*1024*1024*8)/(min*60)}')

ESTIMATED_OUTPUT_GB=$(awk \
    -v target="$TARGET_GB" \
    -v margin="$OUTPUT_SPACE_MARGIN_GB" \
    'BEGIN { printf "%.2f", target + margin }')

# Runtime state used for safe Docker shutdown and interrupted-job cleanup.
FFMPEG_PID=""
OUTFILE=""
JOB_ACTIVE=false
SHUTTING_DOWN=false

###############################################################################
# FUNCTIONS
###############################################################################

log()
{
    printf '[%(%F %T)T] %s\n' -1 "$*" | tee -a "$LOGFILE"
}

error()
{
    log "ERROR: $*"
    exit 1
}

require_program()
{
    command -v "$1" >/dev/null 2>&1 || error "Program '$1' not found"
}

# Make a TMDb title safe as one Linux path component. Jellyfin accepts Unicode,
# spaces and punctuation, but a slash would create an unintended subdirectory.
sanitize_path_component()
{
    local value="${1:-}"

    value=$(printf '%s' "$value" |
        sed -E \
            -e 's#[/\\]+# - #g' \
            -e 's/[?*"<>|]//g' \
            -e 's/:/ - /g' \
            -e 's/[[:cntrl:]]/ /g' \
            -e 's/[[:space:]]+/ /g' \
            -e 's/[[:space:]]+-[[:space:]]+-[[:space:]]+/ - /g' \
            -e 's/^[ .-]+//' \
            -e 's/[ .-]+$//')

    # Leave enough room for year, provider ID and episode information.
    value=$(printf '%s' "$value" | awk '{ print substr($0, 1, 180) }')

    [[ -n "$value" ]] || value="Unknown"
    printf '%s\n' "$value"
}

# Normalize two titles for conservative matching. This only affects confidence
# checking; the final name always comes from TMDb in Spanish.
normalize_title_for_match()
{
    local value="${1:-}"

    printf '%s' "$value" |
        sed -E \
            -e 's/[ÁÀÄÂÃáàäâã]/a/g' \
            -e 's/[ÉÈËÊéèëê]/e/g' \
            -e 's/[ÍÌÏÎíìïî]/i/g' \
            -e 's/[ÓÒÖÔÕóòöôõ]/o/g' \
            -e 's/[ÚÙÜÛúùüû]/u/g' \
            -e 's/[Ññ]/n/g' \
            -e 's/[Çç]/c/g' |
        tr '[:upper:]' '[:lower:]' |
        sed -E \
            -e 's/&/ y /g' \
            -e 's/[^[:alnum:]]+/ /g' \
            -e 's/[[:space:]]+/ /g' \
            -e 's/^ //' \
            -e 's/ $//'
}

# Return a score from 0.0000 to 1.0000. Exact/contained titles score very high;
# otherwise a Dice token-overlap score is used.
title_similarity()
{
    local left right

    left=$(normalize_title_for_match "${1:-}")
    right=$(normalize_title_for_match "${2:-}")

    if [[ -z "$left" || -z "$right" ]]; then
        printf '0.0000\n'
        return 0
    fi

    if [[ "$left" == "$right" ]]; then
        printf '1.0000\n'
        return 0
    fi

    if [[ ${#left} -ge 4 && ${#right} -ge 4 ]] &&
       { [[ " $left " == *" $right "* ]] ||
         [[ " $right " == *" $left "* ]]; }
    then
        printf '0.9800\n'
        return 0
    fi

    awk -v a="$left" -v b="$right" '
        BEGIN {
            na = split(a, aa, " ")
            nb = split(b, bb, " ")

            for (i = 1; i <= na; i++) {
                if (length(aa[i]) > 1) A[aa[i]] = 1
            }
            for (i = 1; i <= nb; i++) {
                if (length(bb[i]) > 1) B[bb[i]] = 1
            }

            ca = cb = common = 0
            for (word in A) {
                ca++
                if (word in B) common++
            }
            for (word in B) cb++

            if (ca + cb == 0) {
                print "0.0000"
            } else {
                printf "%.4f\n", (2 * common) / (ca + cb)
            }
        }'
}

best_title_similarity()
{
    local query="${1:-}"
    local title="${2:-}"
    local original_title="${3:-}"
    local first second

    first=$(title_similarity "$query" "$title")
    second=$(title_similarity "$query" "$original_title")

    awk -v a="$first" -v b="$second" \
        'BEGIN { printf "%.4f\n", (a > b ? a : b) }'
}

metadata_match_is_confident()
{
    local score="${1:-0}"
    local expected_year="${2:-}"
    local result_year="${3:-}"

    if [[ -n "$expected_year" && -n "$result_year" ]]; then
        local difference=$((10#$expected_year - 10#$result_year))
        (( difference < 0 )) && difference=$((-difference))

        # Festival, theatrical and regional release years can differ by one.
        (( difference <= 1 )) || return 1

        awk -v score="$score" 'BEGIN { exit !(score >= 0.50) }'
    else
        # With no year available, require a substantially stronger title match.
        awk -v score="$score" 'BEGIN { exit !(score >= 0.72) }'
    fi
}

# Choose the strongest movie candidate instead of blindly accepting results[0].
# The selected JSON object receives a private _match_score field.
select_best_movie_result()
{
    local response="$1"
    local query_title="$2"
    local query_year="${3:-}"

    local count index candidate
    local candidate_title candidate_original candidate_date candidate_year
    local similarity rank
    local best_json="{}"
    local best_rank="-999"
    local best_similarity="0"

    count=$(jq -r '(.results // []) | length' <<< "$response" 2>/dev/null || echo 0)
    [[ "$count" =~ ^[0-9]+$ ]] || count=0
    (( count > 10 )) && count=10

    for ((index=0; index<count; index++)); do
        candidate=$(jq -c ".results[$index] // {}" <<< "$response")
        candidate_title=$(jq -r '.title // empty' <<< "$candidate")
        candidate_original=$(jq -r '.original_title // empty' <<< "$candidate")
        candidate_date=$(jq -r '.release_date // empty' <<< "$candidate")
        candidate_year="${candidate_date%%-*}"

        similarity=$(best_title_similarity \
            "$query_title" \
            "$candidate_title" \
            "$candidate_original")

        rank=$(awk \
            -v similarity="$similarity" \
            -v query_year="$query_year" \
            -v candidate_year="$candidate_year" '
                BEGIN {
                    score = similarity
                    if (query_year ~ /^[0-9]{4}$/ && candidate_year ~ /^[0-9]{4}$/) {
                        difference = query_year - candidate_year
                        if (difference < 0) difference = -difference
                        if (difference == 0) score += 0.25
                        else if (difference == 1) score += 0.10
                        else score -= 0.50
                    }
                    printf "%.4f\n", score
                }')

        if awk -v current="$rank" -v best="$best_rank" \
            'BEGIN { exit !(current > best) }'
        then
            best_json="$candidate"
            best_rank="$rank"
            best_similarity="$similarity"
        fi
    done

    jq -c \
        --argjson match_score "$best_similarity" \
        '. + {_match_score: $match_score}' <<< "$best_json"
}

# TMDb's episode wrapper contains the episode air year. Ask the TV endpoint for
# the actual series start year so the Jellyfin series folder is stable.
tmdb_series_start_year()
{
    local series_id="${1:-}"
    local response

    [[ "$series_id" =~ ^[1-9][0-9]*$ ]] || return 0

    response=$(curl -fsS \
        --connect-timeout 10 \
        --max-time 30 \
        --retry 2 \
        --retry-delay 1 \
        --get \
        --data-urlencode "api_key=${TMDB_API_KEY}" \
        --data-urlencode "language=es-ES" \
        "https://api.themoviedb.org/3/tv/${series_id}" 2>/dev/null || echo '{}')

    jq -r '.first_air_date // empty' <<< "$response" | cut -d- -f1
}

# Move a source without ever overwriting a file already present in the target.
move_source_without_overwrite()
{
    local source_file="$1"
    local target_dir="$2"
    local base stem extension target counter=1

    mkdir -p -- "$target_dir" || return 1

    base=$(basename "$source_file")
    target="$target_dir/$base"

    if [[ -e "$target" ]]; then
        if [[ "$base" == *.* ]]; then
            stem="${base%.*}"
            extension=".${base##*.}"
        else
            stem="$base"
            extension=""
        fi

        target="$target_dir/${stem}_$(date +%Y%m%d_%H%M%S)${extension}"
        while [[ -e "$target" ]]; do
            target="$target_dir/${stem}_$(date +%Y%m%d_%H%M%S)_${counter}${extension}"
            ((counter += 1))
        done
    fi

    mv -- "$source_file" "$target" || return 1
    printf '%s\n' "$target"
}

move_to_metadata_review()
{
    local source_file="$1"
    local reason="$2"
    local moved_path

    log "METADATA REVIEW: $reason"
    log "Source: $source_file"

    if moved_path=$(move_source_without_overwrite \
        "$source_file" \
        "$FAILED/metadata-review")
    then
        log "Moved for manual review: $moved_path"
    else
        log "ERROR: Could not move the source to metadata-review."
    fi
}

select_output_root()
{
    local estimated_gb="${1:-$ESTIMATED_OUTPUT_GB}"
    local minimum_gb="${MIN_FREE_GB:-50}"

    local estimated_kb
    local minimum_kb

    local root
    local free_kb
    local remaining_kb

    local selected_root=""
    local selected_free_kb=-1

    estimated_kb=$(awk \
        -v gb="$estimated_gb" \
        'BEGIN { printf "%.0f", gb * 1024 * 1024 }')

    minimum_kb=$(awk \
        -v gb="$minimum_gb" \
        'BEGIN { printf "%.0f", gb * 1024 * 1024 }')

    for root in "${OUTPUT_ROOTS[@]}"; do

        [[ -n "$root" ]] || continue
        [[ -d "$root" ]] || continue
        [[ -w "$root" ]] || continue

        free_kb=$(df -Pk -- "$root" 2>/dev/null |
            awk 'END { print $4 }')

        [[ "$free_kb" =~ ^[0-9]+$ ]] || continue

        remaining_kb=$((free_kb - estimated_kb))

        # The estimated output must fit while preserving MIN_FREE_GB.
        if (( remaining_kb < minimum_kb )); then
            continue
        fi

        # Among valid disks, choose the one with the most available space.
        if (( free_kb > selected_free_kb )); then
            selected_root="$root"
            selected_free_kb=$free_kb
        fi

    done

    [[ -n "$selected_root" ]] || return 1

    printf '%s\n' "$selected_root"
}

cleanup_stale_processing_files()
{
    local root
    local file

    for root in "${OUTPUT_ROOTS[@]}"; do

        [[ -n "$root" ]] || continue
        [[ -d "$root/processing" ]] || continue

        while IFS= read -r -d '' file; do
            log "Removing stale incomplete output from a previous interruption: $file"

            if ! rm -f -- "$file"; then
                log "WARNING: Could not remove stale incomplete output: $file"
            fi
        done < <(
            find "$root/processing" \
                -maxdepth 1 \
                -type f \
                -print0 2>/dev/null
        )

    done
}

stop_active_ffmpeg()
{
    local attempt

    if [[ -z "${FFMPEG_PID:-}" ]] ||
       ! kill -0 "$FFMPEG_PID" 2>/dev/null
    then
        return 0
    fi

    log "Stopping FFmpeg process $FFMPEG_PID..."
    kill -TERM "$FFMPEG_PID" 2>/dev/null || true

    # Docker normally gives the container ten seconds before SIGKILL. Wait up
    # to five seconds for FFmpeg, then force it down so cleanup can still run.
    for ((attempt=0; attempt<20; attempt++)); do
        kill -0 "$FFMPEG_PID" 2>/dev/null || break
        sleep 0.25
    done

    if kill -0 "$FFMPEG_PID" 2>/dev/null; then
        log "FFmpeg did not stop in time; sending SIGKILL."
        kill -KILL "$FFMPEG_PID" 2>/dev/null || true
    fi

    wait "$FFMPEG_PID" 2>/dev/null || true
}

remove_current_partial_output()
{
    if [[ "${JOB_ACTIVE:-false}" == true &&
          -n "${OUTFILE:-}" &&
          -f "$OUTFILE" ]]
    then
        log "Removing incomplete output: $OUTFILE"
        rm -f -- "$OUTFILE" || \
            log "WARNING: Could not remove incomplete output: $OUTFILE"
    fi
}

clear_monitor_state()
{
    [[ -n "${PROGRESS_FILE:-}" ]] && rm -f -- "$PROGRESS_FILE"
    [[ -n "${EXTRA_FILE:-}" ]] && rm -f -- "$EXTRA_FILE"
    [[ -n "${FFMPEG_ERROR_FILE:-}" ]] && rm -f -- "$FFMPEG_ERROR_FILE"
}

reset_job_state()
{
    JOB_ACTIVE=false
    FFMPEG_PID=""
    OUTFILE=""
}

shutdown_transcoder()
{
    if [[ "${SHUTTING_DOWN:-false}" == true ]]; then
        return 0
    fi

    SHUTTING_DOWN=true
    log "Shutdown requested. Cleaning up the active job safely..."

    stop_active_ffmpeg
    remove_current_partial_output
    clear_monitor_state
    reset_job_state

    log "Shutdown cleanup completed. The source file remains in incoming."
    exit 0
}

###############################################################################
# CHECK DEPENDENCIES
###############################################################################

require_program ffprobe
require_program ffmpeg
require_program jq
require_program curl

[[ -n "${TMDB_API_KEY:-}" ]] || \
    error "TMDB_API_KEY is not configured; safe Jellyfin naming requires TMDb."

if [[ -z "${OMDB_API_KEY:-}" ]]; then
    log "WARNING: OMDB_API_KEY is not configured. IMDb ratings and director metadata will be skipped."
fi

[[ -d "$INCOMING" ]] || error "Incoming directory not found: $INCOMING"

for DIR in \
    "$INCOMING" \
    "$COMPLETED" \
    "$FAILED" \
    "$LOGS" \
    "$TEMP"
do
    [[ -w "$DIR" ]] || error "Write permission denied: $DIR"
done

VALID_OUTPUT_ROOTS=0

for OUTPUT_ROOT in "${OUTPUT_ROOTS[@]}"; do

    [[ -n "$OUTPUT_ROOT" ]] || continue

    if [[ -w "$OUTPUT_ROOT/processing" &&
          -w "$OUTPUT_ROOT/library/films" &&
          -w "$OUTPUT_ROOT/library/series" ]]
    then
        ((VALID_OUTPUT_ROOTS += 1))
    else
        log "WARNING: Output disk is unavailable or not writable: $OUTPUT_ROOT"
    fi

done

(( VALID_OUTPUT_ROOTS > 0 )) || error "No writable output media directory is available"

# Docker Compose sends SIGTERM during `docker compose down`. Handle it so the
# active partial output is removed while the untouched source stays in incoming.
trap shutdown_transcoder INT TERM HUP

# A trap cannot run after SIGKILL, a host crash or a power loss. Remove any
# incomplete outputs left in processing before accepting new work.
cleanup_stale_processing_files

###############################################################################
# SEARCH FOR MOVIES
###############################################################################

PROGRESS_FILE="${LOGS}/ffmpeg.progress"
EXTRA_FILE="${LOGS}/ffmpeg.extra"
FFMPEG_ERROR_FILE="${LOGS}/ffmpeg.error"

while true
do
    mapfile -d '' MOVIES < <(
        find "$INCOMING" -type f \( \
            -iname "*.mkv" -o \
            -iname "*.mp4" -o \
            -iname "*.avi" -o \
            -iname "*.m2ts" -o \
            -iname "*.ts" \
        \) -print0 | sort -z
    )

    if (( ${#MOVIES[@]} == 0 )); then

        cat > "$EXTRA_FILE" <<EOF
STATUS=waiting
EOF

        : > "$PROGRESS_FILE"

        sleep 5
        continue
    fi

###############################################################################
# PROCESS MOVIES
###############################################################################

OUTPUT_BLOCKED=false

for FILE in "${MOVIES[@]}"
do
    [[ -f "$FILE" ]] || continue

    BASENAME=$(basename "$FILE")
    NAME="${BASENAME%.*}"

    # Query external APIs safely
    TITLE="Unknown"
    YEAR=""
    VOTE="0"
    ID="0"
    IMDB_ID=""
    MEDIA_TYPE="movie"
    SEASON_NUMBER=""
    EPISODE_NUMBER=""

    # Keep normalized fallback metadata in the current shell. tmdb_search is
    # executed inside command substitution, so variables changed there do not
    # propagate back to this process.
    normalize_filename "$FILE"
    FALLBACK_TITLE="${TITLE:-$NAME}"
    FALLBACK_YEAR="${YEAR:-}"

    if ! OUTPUT_ROOT=$(select_output_root "$ESTIMATED_OUTPUT_GB"); then

        log "No output disk can preserve ${MIN_FREE_GB} GB of free space."
        log "The file remains in incoming: $BASENAME"

        cat > "$EXTRA_FILE" <<EOF
STATUS=waiting
STATUS_TEXT=waiting
CURRENT_FILE="Waiting for output disk space"
EOF

        OUTPUT_BLOCKED=true
        break

    fi

    PROCESSING="$OUTPUT_ROOT/processing"
    LIBRARY="$OUTPUT_ROOT/library"
    FILMS="$LIBRARY/films"
    SERIES="$LIBRARY/series"

    # The temporary output keeps the original basename. The final Jellyfin path
    # is built only after TMDb has returned a confident match.
    OUTFILE="$PROCESSING/$NAME.mkv"
    FINAL_FILE=""
    DESTINATION_DIR=""
    MEDIA_LABEL="Movie"

    log "==============================================================="
    log "File: $BASENAME"
    log "Detected media type: $MEDIA_TYPE"
    log "Normalized title: $FALLBACK_TITLE"
    log "Filename year: ${FALLBACK_YEAR:-N/A}"
    log "Output disk: $OUTPUT_ROOT"
    log "==============================================================="

    METADATA_OK=false
    MATCH_SCORE="0"
    MATCH_OBJECT='{}'
    TMDB_RESPONSE='{}'
    ORIGINAL_TITLE=""
    SERIES_NAME=""
    SERIES_YEAR=""
    EPISODE_NAME=""

    if command -v tmdb_search >/dev/null 2>&1; then

        TMDB_RESPONSE=$(tmdb_search "$FILE" || echo "{}")

        if ! jq empty >/dev/null 2>&1 <<<"$TMDB_RESPONSE"; then
            log "ERROR: TMDb returned an invalid JSON response"
            TMDB_RESPONSE='{}'
        fi

        if jq -e '.success == false or (.status_code? != null)' >/dev/null 2>&1 <<<"$TMDB_RESPONSE"; then
            log "WARNING: TMDb API error: $(jq -r '.status_message // "Unknown error"' <<<"$TMDB_RESPONSE")"
            TMDB_RESPONSE='{}'
        fi

        if [[ "$MEDIA_TYPE" == "episode" ]]; then
            MATCH_OBJECT=$(jq -c '.results[0] // {}' <<<"$TMDB_RESPONSE")
        else
            MATCH_OBJECT=$(select_best_movie_result \
                "$TMDB_RESPONSE" \
                "$FALLBACK_TITLE" \
                "$FALLBACK_YEAR")
        fi

        ID=$(jq -r '.id // 0' <<<"$MATCH_OBJECT")
        TITLE=$(jq -r '.title // empty' <<<"$MATCH_OBJECT")
        ORIGINAL_TITLE=$(jq -r '.original_title // empty' <<<"$MATCH_OBJECT")
        VOTE=$(jq -r '.vote_average // 0' <<<"$MATCH_OBJECT")

        if [[ "$MEDIA_TYPE" == "episode" ]]; then
            SERIES_NAME=$(jq -r '.series_name // .original_title // empty' <<<"$MATCH_OBJECT")
            EPISODE_NAME=$(jq -r '.episode_name // empty' <<<"$MATCH_OBJECT")
            SEASON_NUMBER=$(jq -r '.season_number // empty' <<<"$MATCH_OBJECT")
            EPISODE_NUMBER=$(jq -r '.episode_number // empty' <<<"$MATCH_OBJECT")
            SERIES_YEAR=$(tmdb_series_start_year "$ID")
            YEAR="$SERIES_YEAR"
            MATCH_SCORE=$(best_title_similarity \
                "$FALLBACK_TITLE" \
                "$SERIES_NAME" \
                "$ORIGINAL_TITLE")
        else
            YEAR=$(jq -r '.release_date // empty' <<<"$MATCH_OBJECT" | cut -d- -f1)
            MATCH_SCORE=$(jq -r '._match_score // 0' <<<"$MATCH_OBJECT")
        fi

        if [[ "$ID" =~ ^[1-9][0-9]*$ &&
              -n "$TITLE" ]] &&
           metadata_match_is_confident \
                "$MATCH_SCORE" \
                "$FALLBACK_YEAR" \
                "$YEAR"
        then
            METADATA_OK=true
        fi
    fi

    if [[ "$METADATA_OK" != true ]]; then
        move_to_metadata_review \
            "$FILE" \
            "TMDb match missing or uncertain (title='$FALLBACK_TITLE', year='${FALLBACK_YEAR:-N/A}', score=$MATCH_SCORE)."
        continue
    fi

    # Build the future Jellyfin layout. Existing library files are never scanned,
    # renamed or moved by this script.
    if [[ "$MEDIA_TYPE" == "episode" ]]; then
        if [[ ! "$SEASON_NUMBER" =~ ^[0-9]+$ ||
              ! "$EPISODE_NUMBER" =~ ^[0-9]+$ ||
              -z "$SERIES_NAME" ]]
        then
            move_to_metadata_review \
                "$FILE" \
                "TMDb did not return complete series/episode information."
            continue
        fi

        SAFE_SERIES_NAME=$(sanitize_path_component "$SERIES_NAME")
        SAFE_EPISODE_NAME=$(sanitize_path_component "$EPISODE_NAME")

        SERIES_FOLDER="$SAFE_SERIES_NAME"
        [[ -n "$SERIES_YEAR" ]] && SERIES_FOLDER+=" ($SERIES_YEAR)"
        SERIES_FOLDER+=" [tmdbid-$ID]"

        SEASON_FOLDER=$(printf 'Season %02d' "$SEASON_NUMBER")
        EPISODE_BASE=$(printf '%s S%02dE%02d' \
            "$SAFE_SERIES_NAME" \
            "$SEASON_NUMBER" \
            "$EPISODE_NUMBER")

        if [[ -n "$EPISODE_NAME" ]]; then
            EPISODE_BASE+=" - $SAFE_EPISODE_NAME"
        fi

        DESTINATION_DIR="$SERIES/$SERIES_FOLDER/$SEASON_FOLDER"
        FINAL_FILE="$DESTINATION_DIR/$EPISODE_BASE.mkv"
        MEDIA_LABEL="Episode"
    else
        if [[ ! "$YEAR" =~ ^[0-9]{4}$ ]]; then
            move_to_metadata_review \
                "$FILE" \
                "TMDb matched the movie but did not return a valid release year."
            continue
        fi

        SAFE_TITLE=$(sanitize_path_component "$TITLE")
        MOVIE_BASE="$SAFE_TITLE ($YEAR) [tmdbid-$ID]"
        DESTINATION_DIR="$FILMS/$MOVIE_BASE"
        FINAL_FILE="$DESTINATION_DIR/$MOVIE_BASE.mkv"
        MEDIA_LABEL="Movie"
    fi

    if [[ -e "$FINAL_FILE" ]]; then
        move_to_metadata_review \
            "$FILE" \
            "The Jellyfin destination already exists: $FINAL_FILE"
        continue
    fi

    log "TMDb match: $TITLE"
    log "TMDb ID: $ID"
    log "Match score: $MATCH_SCORE"
    log "Jellyfin destination: $FINAL_FILE"

    if [[ "$ID" =~ ^[1-9][0-9]*$ ]] &&
       command -v tmdb_imdb_id >/dev/null 2>&1
    then

        EXTERNAL_IDS=$(tmdb_imdb_id "$ID" || echo "{}")

        if ! jq empty >/dev/null 2>&1 <<<"$EXTERNAL_IDS"; then
            log "ERROR: TMDb external_ids returned an invalid JSON response"
            EXTERNAL_IDS='{}'
        fi

        IMDB_ID=$(jq -r '.imdb_id // ""' <<<"$EXTERNAL_IDS")
    fi

    echo -e "\nTMDb\n------------------------------------------------"
    printf "%-20s %s\n" "Title:" "$TITLE"
    printf "%-20s %s\n" "Year:" "$YEAR"
    printf "%-20s %s\n" "Rating:" "$VOTE"
    printf "%-20s %s\n" "ID:" "$ID"

    IMDB="-"
    IMDB_RATING="-"
    METASCORE="-"
    DIRECTOR="-"

    if [[ -n "$IMDB_ID" ]] && command -v omdb_search >/dev/null 2>&1; then

        OMDB_RESPONSE=$(omdb_search "$IMDB_ID" || echo "{}")

        if ! jq empty >/dev/null 2>&1 <<<"$OMDB_RESPONSE"; then
            log "ERROR: OMDb returned an invalid JSON response"
            log "$OMDB_RESPONSE"
            OMDB_RESPONSE='{}'
        elif jq -e '.Response == "False"' >/dev/null 2>&1 <<<"$OMDB_RESPONSE"; then
            log "WARNING: OMDb: $(jq -r '.Error // "Unknown error"' <<<"$OMDB_RESPONSE")"
            OMDB_RESPONSE='{}'
        fi

        IMDB=$(jq -r '.imdbID // "-"' <<<"$OMDB_RESPONSE")
        IMDB_RATING=$(jq -r '.imdbRating // "-"' <<<"$OMDB_RESPONSE")
        METASCORE=$(jq -r '.Metascore // "-"' <<<"$OMDB_RESPONSE")
        DIRECTOR=$(jq -r '.Director // "-"' <<<"$OMDB_RESPONSE")
    fi

    echo -e "\nOMDb\n------------------------------------------------"
    printf "%-20s %s\n" "IMDb:" "$IMDB"
    printf "%-20s %s\n" "Rating:" "$IMDB_RATING"
    printf "%-20s %s\n" "Metascore:" "$METASCORE"
    printf "%-20s %s\n" "Director:" "$DIRECTOR"
    printf "%-20s %s\n" "IMDb ID:" "$IMDB_ID"

    # Read ffprobe output and verify it completed successfully
    MEDIA_INFO=$(ffprobe -v quiet -print_format json -show_format -show_streams "$FILE" || echo "")

    if [[ -z "$MEDIA_INFO" ]]; then
        log "ERROR: ffprobe could not read $BASENAME. Skipping..."
        move_source_without_overwrite "$FILE" "$FAILED" >/dev/null || true
        continue
    fi

    # Extract the primary video stream, ignoring embedded cover images
    VIDEO_STREAM=$(jq '[.streams[] | select(.codec_type=="video" and (.disposition.attached_pic != 1))] | .[0] // empty' <<<"$MEDIA_INFO" 2>/dev/null || echo "")

    if [[ -z "$VIDEO_STREAM" ]]; then
        log "ERROR: No video stream found in $BASENAME. Skipping..."
        move_source_without_overwrite "$FILE" "$FAILED" >/dev/null || true
        continue
    fi

    WIDTH=$(jq -r '.width // 0' <<<"$VIDEO_STREAM")
    HEIGHT=$(jq -r '.height // 0' <<<"$VIDEO_STREAM")
    [[ "$WIDTH" =~ ^[0-9]+$ ]] || WIDTH=0
    [[ "$HEIGHT" =~ ^[0-9]+$ ]] || HEIGHT=0

    CODEC=$(jq -r '.codec_name // "unknown"' <<<"$VIDEO_STREAM")
    PIXFMT=$(jq -r '.pix_fmt // "yuv420p"' <<<"$VIDEO_STREAM")
    FPS=$(jq -r '.avg_frame_rate // "0/0"' <<<"$VIDEO_STREAM")

    FPS_REAL=$(awk -F/ '{if($2==0) print 0; else printf "%.3f",$1/$2}' <<<"$FPS")

    COLOR_TRANSFER=$(jq -r '.color_transfer // ""' <<<"$VIDEO_STREAM")
    COLOR_PRIMARIES=$(jq -r '.color_primaries // ""' <<<"$VIDEO_STREAM")

    HDR="NO"
    if [[ "$COLOR_TRANSFER" == "smpte2084" || "$COLOR_TRANSFER" == "arib-std-b67" || "$COLOR_PRIMARIES" == "bt2020" ]]; then
        HDR="YES"
    fi

    DV="NO"
    if jq -e '.side_data_list[]? | tostring | test("DOVI";"i")' <<<"$VIDEO_STREAM" >/dev/null 2>&1; then
        DV="YES"
    fi

    DURATION=$(jq -r '.format.duration // 0' <<<"$MEDIA_INFO")
    [[ "$DURATION" =~ ^[0-9.]+$ ]] || DURATION=0

    DURATION_INT=$(awk -v d="$DURATION" 'BEGIN{printf "%.0f", d}')

    SIZE=$(jq -r '.format.size // 0' <<<"$MEDIA_INFO")
    [[ "$SIZE" =~ ^[0-9]+$ ]] || SIZE=0

    BITRATE=$(jq -r '.format.bit_rate // 0' <<<"$MEDIA_INFO")
    [[ "$BITRATE" =~ ^[0-9]+$ ]] || BITRATE=0

    if [[ "$BITRATE" == "0" && "$DURATION_INT" -gt 0 ]]; then
        BITRATE=$(awk -v s="$SIZE" -v d="$DURATION_INT" 'BEGIN{printf "%.0f",(s*8)/d}')
    fi

    DURATION_HMS=$(printf "%02d:%02d:%02d" \
        $((DURATION_INT/3600)) \
        $(((DURATION_INT%3600)/60)) \
        $((DURATION_INT%60)))

    if (( WIDTH >= 3800 )); then
        RESOLUTION="4K"
    elif (( WIDTH >= 2500 )); then
        RESOLUTION="1440p"
    elif (( WIDTH >= 1900 )); then
        RESOLUTION="1080p"
    elif (( WIDTH >= 1200 )); then
        RESOLUTION="720p"
    else
        RESOLUTION="SD"
    fi

    echo -e "\nVideo\n------------------------------------------------"
    printf "%-20s %s\n" "Codec:" "$CODEC"
    printf "%-20s %s\n" "Resolution:" "${WIDTH}x${HEIGHT} (${RESOLUTION})"
    printf "%-20s %s\n" "Pixel Format:" "$PIXFMT"
    printf "%-20s %s\n" "FPS:" "$FPS_REAL"
    printf "%-20s %s\n" "HDR:" "$HDR"
    printf "%-20s %s\n" "Dolby Vision:" "$DV"
    printf "%-20s %s\n" "Duration:" "$DURATION_HMS"
    printf "%-20s %.2f GB\n" "Size:" "$(awk -v s="$SIZE" 'BEGIN{print s/1024/1024/1024}')"
    printf "%-20s %.2f Mbps\n" "Bitrate:" "$(awk -v b="$BITRATE" 'BEGIN{print b/1000000}')"

    echo -e "\nAudio\n------------------------------------------------"

    jq -r '.streams[] | select(.codec_type=="audio") | "\(.index)|\(.tags.language // "und")|\(.codec_name)|\(.channels)"' <<<"$MEDIA_INFO" |
    while IFS="|" read -r IDX LANG ACODEC CH; do
        printf "Track %-3s %-8s %-12s %s channels\n" "$IDX" "$LANG" "$ACODEC" "$CH"
    done

    echo -e "\nSubtitles\n------------------------------------------------"

    jq -r '.streams[] | select(.codec_type=="subtitle") | "\(.index)|\(.tags.language // "und")|\(.codec_name)"' <<<"$MEDIA_INFO" |
    while IFS="|" read -r IDX LANG SCODEC; do
        printf "Track %-3s %-8s %s\n" "$IDX" "$LANG" "$SCODEC"
    done

    echo

###############################################################################
# FFMPEG CONFIGURATION
###############################################################################

log "Calculating dynamic target bitrate..."

# Calculate target bitrate based on the actual video duration
if (( DURATION_INT > 0 )); then
    CALC_VIDEO_BPS=$(awk \
        -v total="$TARGET_TOTAL_BPS" \
        -v dest_t="$TARGET_MIN" \
        -v real_t="$DURATION_INT" \
        'BEGIN{printf "%.0f", (total * (dest_t * 60)) / real_t}')
else
    CALC_VIDEO_BPS=$MIN_VIDEO_BPS
fi

# Never go below the minimum bitrate allowed for 4K content
if (( CALC_VIDEO_BPS < MIN_VIDEO_BPS )); then
    CALC_VIDEO_BPS=$MIN_VIDEO_BPS
fi

log "Target video bitrate: $(awk -v b="$CALC_VIDEO_BPS" 'BEGIN{printf "%.2f", b/1000000}') Mbps"

# Configure HDR color metadata for NVENC output
FFMPEG_EXTRA_FLAGS=()

if [[ "$HDR" == "YES" || "$PIXFMT" == *"10"* ]]; then
    if [[ "$COLOR_TRANSFER" == "smpte2084" ]]; then
        FFMPEG_EXTRA_FLAGS+=(
            -color_primaries bt2020
            -color_trc smpte2084
            -colorspace bt2020nc
        )
    fi
fi

START_EPOCH=$(date +%s)

log "Starting GPU transcoding..."

###############################################################################
# PROGRESS MONITORING
###############################################################################

launch_ffmpeg()
{
    local -a INPUT_ACCELERATION=()

    # The first attempt uses NVDEC plus CUDA filters. The fallback deliberately
    # decodes and filters on the CPU while still encoding with NVENC. Keeping
    # -hwaccel_output_format cuda on the fallback would feed CUDA frames into a
    # CPU filter graph and make the retry fail for the same reason as attempt 1.
    if (( ATTEMPT == 1 )); then
        INPUT_ACCELERATION=(
            -hwaccel cuda
            -hwaccel_output_format cuda
        )
    fi

    : > "$FFMPEG_ERROR_FILE"

    ffmpeg -y -v error \
        "${INPUT_ACCELERATION[@]}" \
        -i "$FILE" \
        -progress "$PROGRESS_FILE" \
        -vf "$FILTER" \
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
        "$OUTFILE" \
        < /dev/null \
        2> "$FFMPEG_ERROR_FILE" &

    FFMPEG_PID=$!
}

log_ffmpeg_error_tail()
{
    local line

    [[ -s "$FFMPEG_ERROR_FILE" ]] || return 0

    log "Last FFmpeg error messages:"
    while IFS= read -r line; do
        log "FFmpeg: $line"
    done < <(tail -n 20 "$FFMPEG_ERROR_FILE")
}

###############################################################################
# PROGRESS MONITORING
###############################################################################

TIMEOUT_LIMIT=300          # 5 minutes without progress
LAST_FRAME=0
LAST_ACTIVITY=$SECONDS

CANCEL_FLAG="${LOGS}/ffmpeg_cancelled_${NAME}.tmp"
rm -f "$CANCEL_FLAG"

# Reset progress file
PROGRESS_FILE="${LOGS}/ffmpeg.progress"
rm -f "$PROGRESS_FILE"
: > "$PROGRESS_FILE"

# Auxiliary status file used by monitor.sh
EXTRA_FILE="${LOGS}/ffmpeg.extra"
: > "$EXTRA_FILE"

GPU_FILTER="scale_cuda=w=${TARGET_W}:h=${TARGET_H}:force_original_aspect_ratio=decrease:interp_algo=lanczos"

CPU_FILTER="scale=w=${TARGET_W}:h=${TARGET_H}:force_original_aspect_ratio=decrease:flags=lanczos,pad=w=${TARGET_W}:h=${TARGET_H}:x=(ow-iw)/2:y=(oh-ih)/2"

FILTER="$GPU_FILTER"

for ATTEMPT in 1 2; do

    if (( ATTEMPT == 1 )); then
        FILTER="$GPU_FILTER"
        log "Trying GPU filters..."
    else
        FILTER="$CPU_FILTER"
        log "GPU filter failed. Retrying with CPU padding..."
        rm -f "$OUTFILE"
    fi

    : > "$PROGRESS_FILE"
    LAST_FRAME=0
    LAST_ACTIVITY=$SECONDS

    JOB_ACTIVE=true
    launch_ffmpeg

    # Monitor FFmpeg progress while the encoder is running
    while kill -0 "$FFMPEG_PID" 2>/dev/null; do

        sleep 2

        if [[ -f "$PROGRESS_FILE" ]]; then

            encoder_usage=$(
                nvidia-smi \
                    --query-gpu=utilization.encoder \
                    --format=csv,noheader,nounits \
                    -i 0 2>/dev/null |
                tr -d '[:space:]' || echo "0"
            )

            # Read current FPS
            fps_line=$(grep "^fps=" "$PROGRESS_FILE" | tail -1 || true)

            # Read current encoder quality
            quality_line=$(grep "^stream_0_0_q=" "$PROGRESS_FILE" | tail -1 || true)

            [[ "$fps_line" =~ fps=([0-9.]+) ]] \
                && current_fps="${BASH_REMATCH[1]}" \
                || current_fps="0"

            [[ "$quality_line" =~ stream_0_0_q=([0-9.-]+) ]] \
                && current_q="${BASH_REMATCH[1]}" \
                || current_q="0.0"

            # Update monitor status file
            cat > "$EXTRA_FILE" <<EOF
encoder_usage=${encoder_usage}
current_q=${current_q}
START_EPOCH=${START_EPOCH}
CURRENT_FILE="${BASENAME}"
TITLE="${TITLE}"
RAW_DUR=${DURATION_INT}
PID=${FFMPEG_PID}
STATUS_TEXT=encoding
EOF

            # Check whether FFmpeg is still making progress
            frame_line=$(grep "^frame=" "$PROGRESS_FILE" | tail -1 || true)

            if [[ "$frame_line" =~ frame=([0-9]+) ]]; then
                current_frame="${BASH_REMATCH[1]}"

                if (( current_frame > LAST_FRAME )); then
                    LAST_FRAME=$current_frame
                    LAST_ACTIVITY=$SECONDS
                fi
            fi

            # Abort if encoding makes no progress for 5 minutes
            if (( SECONDS - LAST_ACTIVITY >= TIMEOUT_LIMIT )); then
                echo "==============================================================="
                echo "WARNING: FFmpeg has made no progress for 5 minutes."
                echo "Stopping encoder..."
                echo "==============================================================="

                touch "$CANCEL_FLAG"
                kill -9 "$FFMPEG_PID" 2>/dev/null || true
                break
            fi
        fi
    done

    if wait "$FFMPEG_PID"; then
        FFMPEG_EXIT=0
    else
        FFMPEG_EXIT=$?
    fi

    if (( FFMPEG_EXIT == 0 )); then
        break
    fi

    log "FFmpeg attempt $ATTEMPT failed with exit code $FFMPEG_EXIT."
    log_ffmpeg_error_tail

done

###############################################################################
# HANDLE ENCODING RESULT
###############################################################################

if [[ -f "$CANCEL_FLAG" ]]; then

    log "TIMEOUT: FFmpeg stalled while processing $BASENAME"

    rm -f "$CANCEL_FLAG"
    rm -f "$OUTFILE" "$PROGRESS_FILE" "$EXTRA_FILE" "$FFMPEG_ERROR_FILE"

    move_source_without_overwrite "$FILE" "$FAILED" >/dev/null || true
    reset_job_state
    continue

elif (( FFMPEG_EXIT != 0 )); then

    log "ERROR: Both transcoding attempts failed."

    rm -f "$OUTFILE" "$PROGRESS_FILE" "$EXTRA_FILE" "$FFMPEG_ERROR_FILE"

    move_source_without_overwrite "$FILE" "$FAILED" >/dev/null || true
    reset_job_state
    continue

elif [[ ! -s "$OUTFILE" ]]; then

    log "ERROR: Output file is missing or empty."

    rm -f "$OUTFILE" "$PROGRESS_FILE" "$EXTRA_FILE" "$FFMPEG_ERROR_FILE"

    move_source_without_overwrite "$FILE" "$FAILED" >/dev/null || true
    reset_job_state
    continue

else

    log "Transcoding completed successfully."

    rm -f "$PROGRESS_FILE" "$EXTRA_FILE" "$FFMPEG_ERROR_FILE"

    # Create the Jellyfin folder only after a valid transcode exists.
    if ! mkdir -p -- "$DESTINATION_DIR"; then

        log "ERROR: Could not create destination directory: $DESTINATION_DIR"
        rm -f -- "$OUTFILE"
        move_source_without_overwrite "$FILE" "$FAILED" >/dev/null || true

    # Never overwrite an existing library file, including races with another job.
    elif [[ -e "$FINAL_FILE" ]]; then

        log "ERROR: Destination file already exists:"
        log "$FINAL_FILE"

        rm -f -- "$OUTFILE"
        move_to_metadata_review "$FILE" \
            "Destination appeared while transcoding: $FINAL_FILE"

    elif mv -- "$OUTFILE" "$FINAL_FILE"; then

        log "$MEDIA_LABEL moved to library: $FINAL_FILE"

        if COMPLETED_PATH=$(move_source_without_overwrite "$FILE" "$COMPLETED"); then
            log "Original moved to completed: $COMPLETED_PATH"
        else
            log "WARNING: The library file is complete, but the original could not be moved to completed."
        fi

    else

        log "ERROR: Failed to move $MEDIA_LABEL into the library."

        rm -f -- "$OUTFILE"
        move_source_without_overwrite "$FILE" "$FAILED" >/dev/null || true

    fi

fi

reset_job_state

done

if $OUTPUT_BLOCKED; then

    log "Waiting 60 seconds before checking output disks again..."

    sleep 60
    continue

fi

log "Batch completed. Waiting for new files..."

sleep 5

done
