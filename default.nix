{ pkgs }:

let
  deps = with pkgs; [
    ffmpeg-full
    waifu2x-converter-cpp
    libnotify
    coreutils
    gnused
    gawk
    ncurses
    findutils
  ];

  # Змінюємо назву бінарника на magscale
  script = pkgs.writeShellScriptBin "magscale" ''
    set -euo pipefail

    # --- PERFORMANCE TUNING ---
    TARGET_FPS=10
    BLOCK_SIZE=512
    THREADS=$(nproc)

    # --- Configuration ---
    INPUT_FILE="''${1:-}"

    if [ -z "$INPUT_FILE" ]; then
        echo "Usage: magscale file.mp4"
        exit 1
    fi

    OUTPUT_FILE="''${INPUT_FILE%.*}_upscaled.mp4"
    TEMP_DIR="/tmp/magscale_cache"  # Змінив назву папки

    # Використовуємо абсолютні шляхи з Nix Store
    FFMPEG="${pkgs.ffmpeg-full}/bin/ffmpeg"
    WAIFU2X="${pkgs.waifu2x-converter-cpp}/bin/waifu2x-converter-cpp"
    NOTIFY="${pkgs.libnotify}/bin/notify-send"

    # --- Helpers ---
    log() { echo -e "\e[34m[INFO]\e[0m $1"; }

    error() {
        echo -e "\n\e[31m[ERROR]\e[0m $1" >&2
        $NOTIFY -u critical "MagScale Error" "$1"
        exit 1
    }

    cleanup() {
        tput cnorm
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

        tput civis
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

    # --- Logic ---
    trap cleanup EXIT
    mkdir -p "$TEMP_DIR/in" "$TEMP_DIR/out"

    log "Step 1: Extracting at $TARGET_FPS FPS..."
    $FFMPEG -i "$INPUT_FILE" -r "$TARGET_FPS" -hide_banner -loglevel error -stats -start_number 0 "$TEMP_DIR/in/%08d.png"
    $FFMPEG -i "$INPUT_FILE" -vn -acodec copy -hide_banner -loglevel error -y "$TEMP_DIR/audio.m4a"

    TOTAL_FRAMES=$(find "$TEMP_DIR/in" -name "*.png" | wc -l)
    log "Total frames to process: $TOTAL_FRAMES"

    log "Step 2: AI Upscaling (GPU Boost)..."
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

    log "Step 2.5: Sanitizing frame sequence..."
    cd "$TEMP_DIR/out"
    count=0
    for f in $(ls -1v *.png); do
        new_name=$(printf "%08d.png" "$count")
        [ "$f" != "$new_name" ] && mv "$f" "$new_name"
        count=$((count + 1))
    done
    cd - > /dev/null

    log "Step 3: Assembling video..."
    $FFMPEG -framerate "$TARGET_FPS" -start_number 0 -i "$TEMP_DIR/out/%08d.png" -i "$TEMP_DIR/audio.m4a" \
        -c:v libx264 -crf 18 -preset faster -pix_fmt yuv420p -shortest -y \
        -hide_banner -loglevel error -stats \
        "$OUTPUT_FILE"

    log "Success! File: $OUTPUT_FILE"
    $NOTIFY -i video-x-generic "MagScale Complete" "Готово: $OUTPUT_FILE"
  '';
in
  pkgs.symlinkJoin {
    name = "magscale";
    paths = [ script ] ++ deps;
    buildInputs = [ pkgs.makeWrapper ];
    postBuild = "wrapProgram $out/bin/magscale --prefix PATH : $out/bin";
  }