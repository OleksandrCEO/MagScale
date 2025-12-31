{ pkgs ? import <nixpkgs> { } }:

let
  # Runtime dependencies for the script
  # We include them here to wrap the script's PATH later
  runtimeDeps = with pkgs; [
    ffmpeg-full            # Video processing
    waifu2x-converter-cpp  # AI engine
    libnotify              # Notifications
    coreutils              # ls, mkdir, etc.
    gnused                 # sed
    gawk                   # awk
    ncurses                # tput
    findutils              # find
    procps                 # nproc
  ];

  # The magscale script package
  magscale = pkgs.writeShellScriptBin "magscale" ''
    # Fail on any error, prevent unbound variables, and ensure pipe failures propagate
    set -euo pipefail

    # --- 1. ARGUMENT VALIDATION ---
    if [ -z "''${1:-}" ]; then
        echo -e "\e[31m[ERROR]\e[0m Usage: magscale <input_video_file>"
        exit 1
    fi

    # --- 2. CONFIGURATION & PATHS ---
    INPUT_FILE="$1"
    RAW_NAME=$(basename "''${INPUT_FILE%.*}")
    OUTPUT_FILE="$(pwd)/''${RAW_NAME} upscaled.mp4"
    TEMP_DIR="/tmp/magscale_''${RAW_NAME// /_}"

    TARGET_FPS=10     # Low FPS for screencasts
    BLOCK_SIZE=512    # GPU Block size
    THREADS=$(nproc)  # CPU Threads

    # Direct store paths for stability
    FFMPEG="${pkgs.ffmpeg-full}/bin/ffmpeg"
    WAIFU2X="${pkgs.waifu2x-converter-cpp}/bin/waifu2x-converter-cpp"
    NOTIFY="${pkgs.libnotify}/bin/notify-send"

    # --- 3. HELPER FUNCTIONS ---
    log() { echo -e "\e[34m[INFO]\e[0m $1"; }

    cleanup_success() {
        log "Task finished successfully. Purging temporary files..."
        tput cnorm
        [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"
    }

    format_time() {
        local T=$1
        local H=$((T/3600))
        local M=$(( (T/60) % 60 ))
        local S=$((T%60))
        [ "$H" -gt 0 ] && printf "%d:%02d:%02d" $H $M $S || printf "%02d:%02d" $M $S
    }

    wait_and_progress() {
        local pid=$1
        local total=$2
        local start_time=$(date +%s)
        tput civis

        while kill -0 "$pid" 2>/dev/null; do
            local current=$(ls -1 "$TEMP_DIR/out" 2>/dev/null | wc -l || echo 0)
            local percent=0
            [ "$total" -gt 0 ] && percent=$(( 100 * current / total ))
            [ "$percent" -gt 100 ] && percent=100

            local now=$(date +%s)
            local elapsed=$(( now - start_time ))

            local eta_str="--:--"
            if [ "$current" -gt 5 ] && [ "$percent" -lt 100 ]; then
                local seconds_remaining=$(( (elapsed * (total - current)) / current ))
                eta_str=$(format_time $seconds_remaining)
            fi

            local filled=$(( percent / 2 ))
            local bar=$(printf "%-50s" "$(printf '#%.0s' $(seq 1 $filled 2>/dev/null || echo 0))")

            printf "\r\e[36m[%s] %3d%% | %d/%d | %s < %s\e[0m" "$bar" "$percent" "$current" "$total" "$(format_time $elapsed)" "$eta_str"
            sleep 1
        done
        tput cnorm; echo ""
        wait "$pid" || true
    }

    # --- 4. EXECUTION LOGIC ---
    trap "tput cnorm" EXIT

    # RESUME LOGIC
    if [ -d "$TEMP_DIR/out" ] && [ "$(ls -A "$TEMP_DIR/out" 2>/dev/null)" ]; then
        echo -e "\e[33m[FOUND]\e[0m Previous frames detected in $TEMP_DIR"
        read -p "Skip AI upscaling and resume with video assembly? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            rm -rf "$TEMP_DIR"
            mkdir -p "$TEMP_DIR/in" "$TEMP_DIR/out"
        fi
    else
        mkdir -p "$TEMP_DIR/in" "$TEMP_DIR/out"
    fi

    # STEP 1 & 2
    if [ ! "$(ls -A "$TEMP_DIR/out" 2>/dev/null)" ]; then
        log "Step 1: Extracting raw frames at $TARGET_FPS FPS..."
        $FFMPEG -i "$INPUT_FILE" \
            -vf "hqdn3d=2:2:4:4" \
            -r "$TARGET_FPS" -hide_banner -loglevel error -stats -start_number 0 \
            "$TEMP_DIR/in/%08d.png"
        $FFMPEG -i "$INPUT_FILE" -vn -acodec copy -hide_banner -loglevel error -y "$TEMP_DIR/audio.m4a"

        TOTAL_FRAMES=$(find "$TEMP_DIR/in" -name "*.png" | wc -l)

        log "Step 2: AI Upscaling (Utilizing Noise Level 3 for maximum smoothing)..."
        nice -n 10 $WAIFU2X \
            --processor 0 \
            --jobs $THREADS \
            --mode noise-scale \
            --noise-level 3 \
            --scale-ratio 2 \
            --block-size $BLOCK_SIZE \
            -i "$TEMP_DIR/in" \
            -o "$TEMP_DIR/out" > /dev/null 2>&1 &

        wait_and_progress $! $TOTAL_FRAMES
    fi

    # STEP 2.5: SANITIZATION
    log "Step 2.5: Normalizing frame sequence for FFmpeg..."
    (
        cd "$TEMP_DIR/out"
        count=0
        for f in $(ls -1v *.png 2>/dev/null); do
            new_name=$(printf "%08d.png" "$count")
            if [ "$f" != "$new_name" ]; then
                mv "$f" "$new_name"
            fi
            count=$((count + 1))
        done
    )

    # STEP 3: ASSEMBLY
    TOTAL_FRAMES=$(find "$TEMP_DIR/out" -name "*.png" | wc -l)
    log "Step 3: Assembling final video using hardware acceleration (NVENC)..."
    tput civis

    $FFMPEG -framerate "$TARGET_FPS" -start_number 0 -i "$TEMP_DIR/out/%08d.png" -i "$TEMP_DIR/audio.m4a" \
        -c:v h264_nvenc \
        -rc vbr -cq 28 -preset p6 \
        -pix_fmt yuv420p -shortest \
        -y -progress - -hide_banner -loglevel error "$OUTPUT_FILE" | \
    while read -r line; do
        if [[ "$line" == frame=* ]]; then
            CUR=''${line#*=}
            CUR=$(echo "$CUR" | tr -d ' ')
            PERC=0
            [ "$TOTAL_FRAMES" -gt 0 ] && PERC=$(( 100 * CUR / TOTAL_FRAMES ))
            [ "$PERC" -gt 100 ] && PERC=100
            FILL=$(( PERC / 2 ))
            BAR=$(printf "%-50s" "$(printf '#%.0s' $(seq 1 $FILL 2>/dev/null || echo 0))")
            printf "\r\e[35m[%s] %3d%% | Frame: %d/%d\e[0m" "$BAR" "$PERC" "$CUR" "$TOTAL_FRAMES"
        fi
    done

    tput cnorm; echo ""
    log "Success! Output saved to: $OUTPUT_FILE"
    $NOTIFY "Upscale Complete" "Video is ready: $RAW_NAME"

    cleanup_success
  '';
in
# Wrap the script to ensure all runtime dependencies are in its PATH
pkgs.symlinkJoin {
  name = "magscale-wrapped";
  paths = [ magscale ] ++ runtimeDeps;
  buildInputs = [ pkgs.makeWrapper ];
  postBuild = ''
    wrapProgram $out/bin/magscale \
      --prefix PATH : ${pkgs.lib.makeBinPath runtimeDeps}
  '';
}