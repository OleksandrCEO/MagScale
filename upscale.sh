#!/usr/bin/env nix-shell
#!nix-shell -i bash -p ffmpeg-full realesrgan-ncnn-vulkan libnotify

# --- Stable AI Video Upscaler (CPU Fallback for NixOS) ---

set -e

if [ -z "$1" ]; then
    echo "Usage: ./upscale.sh input.mp4"
    exit 1
fi

INPUT_FILE="$1"
ABS_PATH=$(realpath "$INPUT_FILE")
DIRNAME=$(dirname "$ABS_PATH")
BASENAME=$(basename "$ABS_PATH")
NAME_NO_EXT="${BASENAME%.*}"
OUTPUT_FILE="${DIRNAME}/${NAME_NO_EXT}_upscaled.mp4"

TEMP_DIR=$(mktemp -d -p /tmp upscale_XXXXXX)
cleanup() { rm -rf "$TEMP_DIR"; }
trap cleanup EXIT

echo "--- Processing: $INPUT_FILE ---"

# 1. Екстракція кадрів
ffmpeg -i "$INPUT_FILE" -hide_banner -loglevel error "$TEMP_DIR/%08d.png"

# 2. Аудіо
ffmpeg -i "$INPUT_FILE" -vn -acodec copy "$TEMP_DIR/audio.m4a" -hide_banner -loglevel error

# 3. AI Upscale (FORCE CPU MODE)
# -g -1  -> ПОВНІСТЮ ВИМИКАЄ GPU (використовує тільки процесор)
# Це повільно, але 100% не впаде.
echo "[3/4] AI Upscaling (CPU Mode)..."
# Використовуємо stdbuf для миттєвого оновлення рядка
# grep витягує лише відсотки
# tr замінює перенос рядка на повернення каретки (\r), щоб відсотки оновлювалися в одному рядку
realesrgan-ncnn-vulkan -i "$TEMP_DIR" -o "$TEMP_DIR" \
    -n realesrgan-x4plus-anime -s 1.5 -f png -g -1 -j 1:1:1 2>&1 \
    | stdbuf -oL grep -oP '\d+\.\d+%' \
    | while read -r line; do printf "\rProgress: $line"; done
echo -e "\n[3/4] Upscaling finished!"


# 4. Збірка
FPS=$(ffprobe -v 0 -of compact=p=0 -show_entries stream=r_frame_rate "$INPUT_FILE" | cut -d= -f2)

ffmpeg -framerate "$FPS" -i "$TEMP_DIR/%08d.png" -i "$TEMP_DIR/audio.m4a" \
    -map 0:v:0 -map 1:a:0? \
    -c:v libx264 -crf 18 -pix_fmt yuv420p \
    -shortest -y "$OUTPUT_FILE" -hide_banner -loglevel error

notify-send "AI Upscale Done" "CPU processing finished"
