#!/usr/bin/env bash

# ==============================================================================
# Script Name: magscale.sh
# Description: Professional Video Upscaling Automation (FFmpeg + Waifu2x)
# Author:      M2 Architecture
# Safety:      Strict Mode, Secure Temp Dirs, Full Quoting
# ==============================================================================

# ------------------------------------------------------------------------------
# 1. STRICT MODE & SAFETY SETTINGS
# ------------------------------------------------------------------------------
# -e: Exit immediately if a command exits with a non-zero status.
# -u: Treat unset variables as an error when substituting.
# -o pipefail: The return value of a pipeline is the status of the last command
#              to exit with a non-zero status (prevents hidden errors).
set -euo pipefail
IFS=$'\n\t' # Set Internal Field Separator to newline/tab to prevent space splitting issues

# ------------------------------------------------------------------------------
# 2. CONFIGURATION (User override supported via ENV variables)
# ------------------------------------------------------------------------------
TARGET_FPS="${TARGET_FPS:-10}"       # Low FPS optimized for screencasts
BLOCK_SIZE="${BLOCK_SIZE:-512}"      # GPU Block size for waifu2x
THREADS="$(nproc)"                   # CPU Threads
NVENC_PRESET="${NVENC_PRESET:-p6}"   # NVENC Quality preset (p1-p7)
CRF_VALUE="${CRF_VALUE:-28}"         # Constant Rate Factor (Quality)

# Dependencies required for execution
REQUIRED_PKGS=("ffmpeg" "waifu2x-converter-cpp" "notify-send" "tput")

# ------------------------------------------------------------------------------
# 3. SECURE TEMPORARY DIRECTORY
# ------------------------------------------------------------------------------
# mktemp -d ensures a unique, secure directory owned by the user.
# -t ensures it is created inside /tmp (or $TMPDIR).
TEMP_DIR="$(mktemp -d -t magscale.XXXXXX)"

# ------------------------------------------------------------------------------
# 4. HELPER FUNCTIONS
# ------------------------------------------------------------------------------

log_info() {
    echo -e "\e[34m[INFO]\e[0m $1"
}

log_error() {
    echo -e "\e[31m[ERROR]\e[0m $1" >&2
}

log_warn() {
    echo -e "\e[33m[WARN]\e[0m $1"
}

# Cleanup function to be called on EXIT (Signal trapping)
cleanup() {
    local exit_code=$?
    tput cnorm # Restore cursor
    if [[ $exit_code -eq 0 ]]; then
        log_info "Cleaning up temporary files..."
        rm -rf "$TEMP_DIR"
    else
        log_warn "Script failed or interrupted. Temp files kept for debugging: $TEMP_DIR"
    fi
    exit "$exit_code"
}

check_dependencies() {
    local missing=()
    for pkg in "${REQUIRED_PKGS[@]}"; do
        if ! command -v "$pkg" &> /dev/null; then
            missing+=("$pkg")
        fi
    done

    if [[ ${#missing[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing[*]}"
        exit 1
    fi
}

format_time() {
    local T="$1"
    local H=$((T/3600))
    local M=$(((T/60) % 60))
    local S=$((T%60))
    if [[ "$H" -gt 0 ]]; then
        printf "%d:%02d:%02d" "$H" "$M" "$S"
    else
        printf "%02d:%02d" "$M" "$S"
    fi
}

# Robust progress bar with safe quoting
wait_and_progress() {
    local pid="$1"
    local total="$2"
    local start_time
    start_time="$(date +%s)"

    tput civis # Hide cursor

    while kill -0 "$pid" 2>/dev/null; do
        # Count files safely
        local current
        current="$(find "$TEMP_DIR/out" -maxdepth 1 -name "*.png" -printf '.' | wc -c)"

        local percent=0
        if [[ "$total" -gt 0 ]]; then
            percent=$(( 100 * current / total ))
        fi
        [[ "$percent" -gt 100 ]] && percent=100

        local now
        now="$(date +%s)"
        local elapsed=$(( now - start_time ))

        local eta_str="--:--"
        if [[ "$current" -gt 5 ]] && [[ "$percent" -lt 100 ]]; then
            # Avoid division by zero
            local seconds_remaining=$(( (elapsed * (total - current)) / current ))
            eta_str="$(format_time "$seconds_remaining")"
        fi

        # Draw Bar
        local filled=$(( percent / 2 ))
        local bar=""
        if [[ "$filled" -gt 0 ]]; then
            # Safe generation of filler characters
            bar="$(printf '#%.0s' $(seq 1 "$filled"))"
        fi
        local padded_bar
        padded_bar="$(printf "%-50s" "$bar")"

        printf "\r\e[36m[%s] %3d%% | %d/%d | %s < %s\e[0m" \
            "$padded_bar" "$percent" "$current" "$total" "$(format_time "$elapsed")" "$eta_str"

        sleep 1
    done
    tput cnorm
    echo ""
    wait "$pid" || true
}

# ------------------------------------------------------------------------------
# 5. MAIN LOGIC
# ------------------------------------------------------------------------------

# Trap signals (EXIT, CTRL+C, Termination)
trap cleanup EXIT INT TERM

check_dependencies

# Argument Validation
if [[ -z "${1:-}" ]]; then
    log_error "Usage: $0 <input_video_file>"
    exit 1
fi

INPUT_FILE="$1"

if [[ ! -f "$INPUT_FILE" ]]; then
    log_error "File not found: $INPUT_FILE"
    exit 1
fi

# Prepare paths
RAW_NAME="$(basename "${INPUT_FILE%.*}")"
OUTPUT_FILE="$(pwd)/${RAW_NAME} upscaled.mp4"

log_info "Input:  $INPUT_FILE"
log_info "Output: $OUTPUT_FILE"
log_info "Temp:   $TEMP_DIR"

# Create structure
mkdir -p "$TEMP_DIR/in" "$TEMP_DIR/out"

# --- STEP 1: EXTRACTION ---
log_info "Step 1/3: Extracting raw frames ($TARGET_FPS FPS)..."

# Extract Audio
ffmpeg -i "$INPUT_FILE" -vn -acodec copy -hide_banner -loglevel error -y "$TEMP_DIR/audio.m4a"

# Extract Video Frames
ffmpeg -i "$INPUT_FILE" \
    -vf "hqdn3d=2:2:4:4" \
    -r "$TARGET_FPS" \
    -hide_banner -loglevel error -stats -start_number 0 \
    "$TEMP_DIR/in/%08d.png"

TOTAL_FRAMES="$(find "$TEMP_DIR/in" -name "*.png" | wc -l)"
log_info "Extracted $TOTAL_FRAMES frames."

# --- STEP 2: AI UPSCALING ---
log_info "Step 2/3: AI Upscaling (Waifu2x C++)..."

nice -n 10 waifu2x-converter-cpp \
    --processor 0 \
    --jobs "$THREADS" \
    --mode noise-scale \
    --noise-level 3 \
    --scale-ratio 2 \
    --block-size "$BLOCK_SIZE" \
    -i "$TEMP_DIR/in" \
    -o "$TEMP_DIR/out" > /dev/null 2>&1 &

wait_and_progress "$!" "$TOTAL_FRAMES"

# --- STEP 2.5: NORMALIZATION ---
log_info "Step 2.5: Normalizing frame sequence for Assembly..."

# Using a subshell to isolate directory change
(
    cd "$TEMP_DIR/out"
    count=0
    # Safe file renaming loop
    # Using 'sort -V' (version sort) is safer than 'ls -v' on some strict shells
    find . -maxdepth 1 -name "*.png" -print0 | sort -zV | while IFS= read -r -d '' f; do
        # Remove "./" prefix if present
        filename="${f#./}"
        new_name="$(printf "%08d.png" "$count")"
        if [[ "$filename" != "$new_name" ]]; then
            mv "$filename" "$new_name"
        fi
        count=$((count + 1))
    done
)

# --- STEP 3: ASSEMBLY ---
log_info "Step 3/3: Assembling final video (H.264 NVENC)..."

tput civis

# NOTE: If NVENC fails, fallback to libx264 would require explicit logic change here.
# Currently strict for Nvidia users.
ffmpeg -framerate "$TARGET_FPS" -start_number 0 \
    -i "$TEMP_DIR/out/%08d.png" \
    -i "$TEMP_DIR/audio.m4a" \
    -c:v h264_nvenc \
    -rc vbr -cq "$CRF_VALUE" -preset "$NVENC_PRESET" \
    -pix_fmt yuv420p -shortest \
    -y -progress - -hide_banner -loglevel error \
    "$OUTPUT_FILE" | \
while read -r line; do
    # Only process progress lines
    if [[ "$line" == frame=* ]]; then
        current_frame="${line#*=}"
        # Trim whitespace
        current_frame="${current_frame//[[:space:]]/}"

        percent=0
        if [[ "$TOTAL_FRAMES" -gt 0 ]]; then
            percent=$(( 100 * current_frame / TOTAL_FRAMES ))
        fi
        [[ "$percent" -gt 100 ]] && percent=100

        filled=$(( percent / 2 ))
        bar=""
        if [[ "$filled" -gt 0 ]]; then
            bar="$(printf '#%.0s' $(seq 1 "$filled"))"
        fi
        padded_bar="$(printf "%-50s" "$bar")"

        printf "\r\e[35m[%s] %3d%% | Frame: %d/%d\e[0m" "$padded_bar" "$percent" "$current_frame" "$TOTAL_FRAMES"
    fi
done

tput cnorm
echo ""
log_info "Done! Saved to: $OUTPUT_FILE"
notify-send "Upscale Complete" "Video is ready: $RAW_NAME"

# Cleanup happens automatically via trap