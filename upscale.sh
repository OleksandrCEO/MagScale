#!/usr/bin/env bash

# 1. Налаштування шляхів
# Знаходимо шлях до моделей у Nix-системі автоматично
BINARY_PATH=$(readlink -f $(which realesrgan-ncnn-vulkan))
MODELS_PATH="$(dirname "$BINARY_PATH")/../share/realesrgan-ncnn-vulkan/models"

INPUT_FILE="$1"
OUTPUT_FILE="${INPUT_FILE%.*}_upscaled_2K.mp4"
TEMP_DIR="/tmp/upscale_work"

# Очищення перед початком
rm -rf "$TEMP_DIR" && mkdir -p "$TEMP_DIR/in" "$TEMP_DIR/out"

echo "--- Етап 1: Розбираємо відео на кадри ---"
ffmpeg -i "$INPUT_FILE" -hide_banner -loglevel error "$TEMP_DIR/in/%08d.png"
ffmpeg -i "$INPUT_FILE" -vn -acodec copy "$TEMP_DIR/audio.m4a" -hide_banner -loglevel error

echo "--- Етап 2: AI Апскейл (CPU Mode) ---"
# Приховуємо GPU для стабільності
export VK_VISIBLE_DEVICES=""

# Визначаємо шлях до моделей ще раз, максимально надійно
MODELS_PATH=$(dirname $(readlink -f $(which realesrgan-ncnn-vulkan)))/../share/realesrgan-ncnn-vulkan/models

# Використовуємо модель v3 - вона стабільніша для відео
# -n realesr-animevideov3
nice -n 19 realesrgan-ncnn-vulkan \
    -i "$TEMP_DIR/in" \
    -o "$TEMP_DIR/out" \
    -m "$MODELS_PATH" \
    -n realesr-animevideov3 \
    -s 2 \
    -f png \
    -j 1:1:1

echo "--- Етап 3: Збираємо 2K відео ---"
# Дізнаємося FPS оригіналу
FPS=$(ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of default=noprint_wrappers=1:nokey=1 "$INPUT_FILE" | cut -d/ -f1)

ffmpeg -framerate "$FPS" -i "$TEMP_DIR/out/%08d.png" -i "$TEMP_DIR/audio.m4a" \
    -c:v libx264 -crf 18 -pix_fmt yuv420p -shortest -y "$OUTPUT_FILE"

echo "Готово! Файл: $OUTPUT_FILE"
rm -rf "$TEMP_DIR"