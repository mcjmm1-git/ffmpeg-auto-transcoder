#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$SCRIPT_DIR/lib/tmdb.sh"

failures=0
checks=0

check_movie()
{
    local filename="$1"
    local expected_title="$2"
    local expected_year="$3"

    normalize_filename "$filename"
    ((checks += 1))

    if [[ "$MEDIA_TYPE" != "movie" ||
          "$TITLE" != "$expected_title" ||
          "$YEAR" != "$expected_year" ]]
    then
        printf 'FAIL\n  file:  %s\n  got:   type=%s title=%q year=%s\n  want:  type=movie title=%q year=%s\n' \
            "$filename" "$MEDIA_TYPE" "$TITLE" "$YEAR" \
            "$expected_title" "$expected_year" >&2
        ((failures += 1))
    else
        printf 'PASS  %s -> %s (%s)\n' "$filename" "$TITLE" "$YEAR"
    fi
}

check_episode()
{
    local filename="$1"
    local expected_title="$2"
    local expected_season="$3"
    local expected_episode="$4"

    normalize_filename "$filename"
    ((checks += 1))

    if [[ "$MEDIA_TYPE" != "episode" ||
          "$TITLE" != "$expected_title" ||
          "$SEASON_NUMBER" != "$expected_season" ||
          "$EPISODE_NUMBER" != "$expected_episode" ]]
    then
        printf 'FAIL\n  file:  %s\n  got:   type=%s title=%q S=%s E=%s\n  want:  type=episode title=%q S=%s E=%s\n' \
            "$filename" "$MEDIA_TYPE" "$TITLE" "$SEASON_NUMBER" "$EPISODE_NUMBER" \
            "$expected_title" "$expected_season" "$expected_episode" >&2
        ((failures += 1))
    else
        printf 'PASS  %s -> %s (S%02dE%02d)\n' \
            "$filename" "$TITLE" "$SEASON_NUMBER" "$EPISODE_NUMBER"
    fi
}

check_movie 'La ciudad no es para mi (1966) FlixOle WEB-DL 1080p [Buzz].mkv' \
    'La ciudad no es para mi' '1966'
check_movie 'La vida por delante (1958) (WEB-DL 1080p) by ser_ismael (exploradoresp2p).mkv' \
    'La vida por delante' '1958'
check_movie 'Lanza rota (1954) Edward Dmytryk.avi' \
    'Lanza rota' '1954'
check_movie 'Llega un pistolero (1956) (Russell Rouse) (US).avi' \
    'Llega un pistolero' '1956'
check_movie 'Los ladrones somos gente honrada (1956) 6.2 [Pedro Luis RamÃ­rez](JosÃ© Luis Ozores, JosÃ© Isbert) 1h22m.mkv' \
    'Los ladrones somos gente honrada' '1956'
check_movie 'Los valientes andan solos - 1962 (David Miller - Kirk Douglas, Gena Rowlands, Walter Matthau)(BRRip-XviD-AC3) Spanish_English.avi' \
    'Los valientes andan solos' '1962'
check_movie 'Nace Una Canción (1948) 6.4 [Howard Hawks](Danny Kaye, Virginia Mayo) 1h53m.avi' \
    'Nace Una Canción' '1948'
check_movie 'Raices.Profundas.(Shane).(1953).(H.Remaster).(Spanish.English.Subs).HD.1080p.HEVC.10b-AAC.by.Geot.mkv' \
    'Raices Profundas' '1953'
check_movie 'Recluta con Niño (1955) 5.4 [Pedro Luis Ramírez](José Luis Ozores, Manolo Morán) 1h30m.avi' \
    'Recluta con Niño' '1955'

# Regression checks: a number in the real title must not replace the release year.
check_movie '1984 (1984).mkv' '1984' '1984'
check_movie '2001: Una odisea del espacio (1968).mkv' \
    '2001: Una odisea del espacio' '1968'
check_movie 'Blade Runner 2049 (2017).mkv' 'Blade Runner 2049' '2017'
check_movie '(1953) La túnica.mkv' 'La túnica' '1953'
check_movie 'Stand by Me (1986).mkv' 'Stand by Me' '1986'

# Newly reported cases.
check_movie 'Capitán Veneno - 1943.mkv' 'Capitán Veneno' '1943'
check_movie 'La.conquista.del.Oeste.1962.(Spanish.English.Spanishsub.Englishsub).BDrip.1080p.x264-AC3.by.jose1969.(exploradoresp2p.co.mkv' \
    'La conquista del Oeste' '1962'
check_movie 'SOLO LOS ANGELES TIENEN ALAS. Cary Grant, Jean Arthur, Rita Hayworth - Spanish English.avi' \
    'SOLO LOS ANGELES TIENEN ALAS' ''

# Valid compact chapter forms must continue to work.
check_episode 'Silo [HDTV 720p][Cap.302].mkv' 'Silo' '3' '2'
check_episode 'Serie Capitulo 1203.mkv' 'Serie' '12' '3'
check_episode 'Serie Capítulo 407.mkv' 'Serie' '4' '7'

if (( failures > 0 )); then
    printf '\n%d of %d checks failed.\n' "$failures" "$checks" >&2
    exit 1
fi

printf '\nAll %d filename normalization checks passed.\n' "$checks"
