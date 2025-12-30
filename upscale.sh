#!/usr/bin/env bash

set -euo pipefail

# --- ТЮНІНГ ПРОДУКТИВНОСТІ ---
# Чим більше, тим швидше, але їсть більше VRAM.
# Якщо вилітає з помилкою пам'яті, зменши до 256 або 128.
BLOCK_SIZE=512

# Кількість потоків CPU для обробки PNG (співпроцесор)
THREADS=$(nproc)

# --- Конфігурація ---
INPUT_FILE="''${1:-}"
OUTPUT_FILE="''${INPUT_FILE%.*}_upscaled.mp4"
TEMP_DIR="/tmp/upscale_cloud"

FFMPEG="${pkgs.ffmpeg-full}/bin/ffmpeg"
FFPROBE="${pkgs.ffmpeg-full}/bin/ffprobe"
WAIFU2X="${pkgs.waifu2x-converter-cpp}/bin/waifu2x-converter-cpp"
NOTIFY="${pkgs.libnotify}/bin/notify-send"

# --- Функції ---
log() { echo -e "\e[34m[INFO]\e[0m $1"; }
error() {
    echo -e "\n\e[31m[ERROR]\e[0m $1" >&2
    $NOTIFY -u critical "Upscale Error" "$1"
    exit 1
}

cleanup() {
    tput cnorm
    if [ -d "$TEMP_DIR" ]; then
        # Видаляємо тихо, щоб не смітити в лог
        rm -rf "$TEMP_DIR"
    fi
}

format_time() {
    local T=$1
    local M=$((T/60))
    local S=$((T%60))
    printf "%02d:%02d" $M $S
}

wait_and_progress() {
    local pid=$1
    local total=$2
    local start_time=$(date +%s)

    tput civis
    while kill -0 "$pid" 2>/dev/null; do
        local current=$(ls -1 "$TEMP_DIR/out" | wc -l)

        local percent=0
        if [ "$total" -gt 0 ]; then
            percent=$(( 100 * current / total ))
        fi
        [ "$percent" -gt 100 ] && percent=100

        local now=$(date +%s)
        local elapsed=$(( now - start_time ))

        # Розрахунок ETA
        local eta_str="--:--"
        if [ "$current" -gt 5 ] && [ "$percent" -lt 100 ]; then
            # (elapsed / current) * (total - current)
            local time_per_frame=$(( (elapsed * 1000) / current )) # у мілісекундах для точності
            local remaining_frames=$(( total - current ))
            local seconds_remaining=$(( (time_per_frame * remaining_frames) / 1000 ))
            eta_str=$(format_time $seconds_remaining)
        fi

        local elapsed_str=$(format_time $elapsed)
        local filled=$(( percent / 2 ))
        local empty=$(( 50 - filled ))

        printf "\r\e[36m[%-50s] %3d%% | %d/%d | %s < %s\e[0m" \
            "$(printf '#%.0s' $(seq 1 $filled 2>/dev/null || echo 0))" \
            "$percent" "$current" "$total" "$elapsed_str" "$eta_str"

        sleep 1
    done
    tput cnorm
    echo ""
    wait "$pid" || log "Waifu2x завершив роботу (можливо з помилками на деяких кадрах, але йдемо далі)"
    sleep 1
}

# --- Main ---
if [ -z "$INPUT_FILE" ]; then echo "Usage: upscale file.mp4"; exit 1; fi
trap cleanup EXIT

mkdir -p "$TEMP_DIR/in" "$TEMP_DIR/out"

log "Етап 1: Екстракція (всі ядра CPU)..."
$FFMPEG -i "$INPUT_FILE" -hide_banner -loglevel error -stats -start_number 0 "$TEMP_DIR/in/%08d.png"
$FFMPEG -i "$INPUT_FILE" -vn -acodec copy -hide_banner -loglevel error -y "$TEMP_DIR/audio.m4a"

TOTAL_FRAMES=$(find "$TEMP_DIR/in" -name "*.png" | wc -l)
log "Всього кадрів: $TOTAL_FRAMES"

log "Етап 2: AI Апскейл (GPU Boost)..."
# Більший block-size = більше навантаження на GPU
nice -n 10 $WAIFU2X \
    --processor 0 \
    --jobs $THREADS \
    --mode noise-scale \
    --noise-level 1 \
    --scale-ratio 2 \
    --block-size $BLOCK_SIZE \
    -i "$TEMP_DIR/in" \
    -o "$TEMP_DIR/out" > /dev/null 2>&1 &

wait_and_progress $! $TOTAL_FRAMES

log "Етап 2.5: Санітарна обробка кадрів..."
# Це виправляє помилку "Could find no file". Ми перейменовуємо все, що є, у строгий порядок.
# Якщо було 37 кадрів, а стало 36 - відео просто стане коротшим на 1 кадр, але не впаде.

cd "$TEMP_DIR/out"
count=0
# ls -1v сортує числа правильно (1, 2, ... 10), а не (1, 10, 2...)
for f in $(ls -1v *.png); do
    new_name=$(printf "%08d.png" "$count")
    if [ "$f" != "$new_name" ]; then
        mv "$f" "$new_name"
    fi
    count=$((count + 1))
done
cd - > /dev/null

log "Етап 3: Збірка відео (знайдено $count кадрів)..."

FPS_RAW=$($FFPROBE -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE")
FPS=$(awk -F/ '{if($2) print $1/$2; else print $1}' <<< "$FPS_RAW")

$FFMPEG -framerate "$FPS" -start_number 0 -i "$TEMP_DIR/out/%08d.png" -i "$TEMP_DIR/audio.m4a" \
    -c:v libx264 -crf 18 -preset faster -pix_fmt yuv420p -shortest -y \
    -hide_banner -loglevel error -stats \
    "$OUTPUT_FILE"

log "Успіх! Файл: $OUTPUT_FILE"
$NOTIFY -i video-x-generic "Upscale Complete" "Готово: $OUTPUT_FILE"