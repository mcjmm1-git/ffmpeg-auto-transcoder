#!/usr/bin/env bash

set -Eeuo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

cat > "$TMP_DIR/ffmpeg" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$@" > "${MOCK_FFMPEG_ARGS:?}"
MOCK
chmod +x "$TMP_DIR/ffmpeg"

export PATH="$TMP_DIR:$PATH"
export MOCK_FFMPEG_ARGS="$TMP_DIR/args"

# Load the implementation directly from transcoder.sh without starting the
# service loop.
source <(sed -n '/^launch_ffmpeg()/,/^}/p' "$PROJECT_DIR/transcoder.sh")

FILE='/tmp/input movie.avi'
PROGRESS_FILE="$TMP_DIR/progress"
FILTER='scale=1280:720'
CALC_VIDEO_BPS=2000000
FFMPEG_EXTRA_FLAGS=()
OUTFILE="$TMP_DIR/output movie.mkv"
FFMPEG_ERROR_FILE="$TMP_DIR/error"

assert_has_arg()
{
    local expected="$1"
    grep -Fx -- "$expected" "$MOCK_FFMPEG_ARGS" >/dev/null || {
        printf 'Missing FFmpeg argument: %s\n' "$expected" >&2
        exit 1
    }
}

assert_lacks_arg()
{
    local unexpected="$1"
    if grep -Fx -- "$unexpected" "$MOCK_FFMPEG_ARGS" >/dev/null; then
        printf 'Unexpected FFmpeg argument: %s\n' "$unexpected" >&2
        exit 1
    fi
}

ATTEMPT=1
launch_ffmpeg
wait "$FFMPEG_PID"
assert_has_arg '-hwaccel'
assert_has_arg 'cuda'
assert_has_arg '-hwaccel_output_format'
assert_has_arg 'hevc_nvenc'
printf 'PASS  attempt 1 uses CUDA decoding and NVENC encoding\n'

ATTEMPT=2
launch_ffmpeg
wait "$FFMPEG_PID"
assert_lacks_arg '-hwaccel'
assert_lacks_arg '-hwaccel_output_format'
assert_has_arg 'hevc_nvenc'
printf 'PASS  attempt 2 uses CPU decoding/filtering and NVENC encoding\n'
