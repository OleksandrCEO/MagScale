#!/usr/bin/env bash

# === MagScale: Universal Bash Script ===
# Версія для звичайних Linux дистрибутивів (Ubuntu, Debian, Arch тощо)
# Вимагає встановлених: ffmpeg, waifu2x-converter-cpp, libnotify

set -euo pipefail

# --- CONFIGURATION ---
TARGET_FPS=10
BLOCK_SIZE=512
THREADS=$(nproc)
TEMP_DIR="/tmp/magscale_cache_$(date +%s)"
MIN_SPACE_GB=15

# --- DEPENDENCY CHECK ---
# Функція перевірки наявності програм
check_dep() {
    if ! command -v "$1" &> /dev/null; then
        echo -e "\e[31m[ERROR] Програма '$1' не знайдена!\e[0m"
        echo "Будь ласка, встановіть її перед запуском."
        exit 1
    fi
}

check_dep "ffmpeg"
check_dep "ffprobe"
check_dep "waifu2x-converter-cpp"
# notify-send не критичний, перевіримо пізніше

# --- VARIABLES ---
INPUT_FILE="${1:-}"
OUTPUT_FILE="${INPUT_FILE%.*}_upscaled.mp4"

FFMPEG="ffmpeg"
WAIFU2X="waifu2x-converter-cpp"
NOTIFY="notify-send"

# --- HELPERS ---
log() { echo -e "\e[34m[INFO]\e[0m $1"; }

send_notify() {
    if command -v "$NOTIFY" &> /dev/null; then
        $NOTIFY -u "$1" "MagScale" "$2"
    fi
}

error() {
    echo -e "\n\e[31m[ERROR]\e[0m $1" >&2
    send_notify critical "$1"
    cleanup
    exit 1
}

cleanup() {
    tput cnorm # Повернути курсор
    if [ -d "$TEMP_DIR" ]; then rm -rf "$TEMP_DIR"; fi
}

format_time() {
    local T=$1
    local H=$((T/3600))
    local M=$(( (T/60) % 60 ))
    local S=$((T%60))
    if [ "$H" -gt 0 ]; then printf "%d:%02d:%02d" $H $M $S; else printf "%02d:%02d" $M $S; fi
}

wait_and_progress() {
    local pid=$1
    local total=$2
    local start_time=$(date +%s)

    tput civis # Сховати курсор
    while kill -0 "$pid" 2>/dev/null; do
        local current=$(ls -1 "$TEMP_DIR/out" 2>/dev/null | wc -l)
        local percent=0
        if [ "$total" -gt 0 ]; then percent=$(( 100 * current / total )); fi
        [ "$percent" -gt 100 ] && percent=100

        local now=$(date +%s)
        local elapsed=$(( now - start_time ))

        local eta_str="--:--"
        if [ "$current" -gt 5 ] && [ "$percent" -lt 100 ]; then
            local seconds_remaining=$(( (elapsed * (total - current)) / current ))
            eta_str=$(format_time $seconds_remaining)
        fi

        local elapsed_str=$(format_time $elapsed)
        local filled=$(( percent / 2 ))

        printf "\r\e[36m[%-50s] %3d%% | %d/%d | %s < %s\e[0m" \
            "$(printf '#%.0s' $(seq 1 $filled 2>/dev/null || echo 0))" \
            "$percent" "$current" "$total" "$elapsed_str" "$eta_str"

        sleep 1
    done
    tput cnorm
    echo ""
    wait "$pid" || true
    sleep 1
}

# --- MAIN LOGIC ---

if [ -z "$INPUT_FILE" ]; then
    echo "Usage: $(basename "$0") file.mp4"
    exit 1
fi

trap cleanup EXIT INT TERM

mkdir -p "$TEMP_DIR/in" "$TEMP_DIR/out"

log "Step 1: Extracting frames at $TARGET_FPS FPS..."
$FFMPEG -i "$INPUT_FILE" -r "$TARGET_FPS" -hide_banner -loglevel error -stats -start_number 0 "$TEMP_DIR/in/%08d.png"
$FFMPEG -i "$INPUT_FILE" -vn -acodec copy -hide_banner -loglevel error -y "$TEMP_DIR/audio.m4a"

TOTAL_FRAMES=$(find "$TEMP_DIR/in" -name "*.png" | wc -l)
log "Total frames to process: $TOTAL_FRAMES"