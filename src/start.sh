#!/usr/bin/env bash

# Function to check if a directory exists and is writable
can_write_to() {
    local target="$1"
    [ -z "$target" ] && return 1

    if [ -d "$target" ]; then
        touch "$target/.write_test" 2> /dev/null || return 1
        rm -f "$target/.write_test"
    else
        mkdir -p "$target" 2> /dev/null || return 1
        touch "$target/.write_test" 2> /dev/null || return 1
        rm -f "$target/.write_test"
    fi

    return 0
}

# Determine NETWORK_VOLUME
if [ -n "${NETWORK_VOLUME-}" ] && can_write_to "$NETWORK_VOLUME"; then
    echo "Using provided NETWORK_VOLUME: $NETWORK_VOLUME"

elif can_write_to "/workspace"; then
    NETWORK_VOLUME="/workspace"
    echo "Defaulting to /workspace"

elif can_write_to "/runpod-volume"; then
    NETWORK_VOLUME="/runpod-volume"
    echo "Defaulting to /runpod-volume"

else
    NETWORK_VOLUME="$(pwd)"
    echo "Fallback to current dir: $NETWORK_VOLUME"
fi

mkdir -p "$NETWORK_VOLUME"
export NETWORK_VOLUME
sed -i '/^export NETWORK_VOLUME=/d' /etc/profile.d/container_env.sh
echo "export NETWORK_VOLUME=\"$NETWORK_VOLUME\"" >> /etc/profile.d/container_env.sh

# Helper functions for cleaner output
status_msg() { echo -e "\n---> $1"; }

# Try to find full tcmalloc first, fallback to minimal
TCMALLOC_PATH=$(ldconfig -p 2> /dev/null | grep -E 'libtcmalloc\.so' | head -n1 | awk '{print $NF}')

if [ -z "$TCMALLOC_PATH" ]; then
    TCMALLOC_PATH=$(ldconfig -p 2> /dev/null | grep -E 'libtcmalloc_minimal\.so' | head -n1 | awk '{print $NF}')
fi

# Apply if found
if [ -n "$TCMALLOC_PATH" ]; then
    export LD_PRELOAD="$TCMALLOC_PATH"
    echo "Using tcmalloc: $TCMALLOC_PATH"
else
    echo "tcmalloc not found, skipping LD_PRELOAD"
fi

# PATH AND VIRTUAL ENV SETUP
# Explicitly use the venv python to avoid "module not found" errors
PYTHON_BIN="/opt/venv/bin/python3"
export PATH="/opt/venv/bin:$PATH"

# This is in case there's any special installs or overrides that needs to occur when starting the machine before starting ComfyUI
if [ -f "$NETWORK_VOLUME/comfyui-wan/src/additional_params.sh" ]; then
    chmod +x "$NETWORK_VOLUME/comfyui-wan/src/additional_params.sh"
    echo "Executing additional_params.sh..."
    "$NETWORK_VOLUME/comfyui-wan/src/additional_params.sh"
else
    echo "No additional_params.sh found. Skipping..."
fi

if ! which aria2 > /dev/null 2>&1; then
    echo "Installing aria2..."
    apt-get update && apt-get install -y aria2
else
    echo "aria2 is already installed"
fi

if ! which curl > /dev/null 2>&1; then
    echo "Installing curl..."
    apt-get update && apt-get install -y curl
else
    echo "curl is already installed"
fi

echo "Starting JupyterLab in $NETWORK_VOLUME"
jupyter-lab --ip=0.0.0.0 --allow-root --no-browser \
    --NotebookApp.token='' --NotebookApp.password='' \
    --ServerApp.allow_origin='*' --ServerApp.allow_credentials=True \
    --notebook-dir="$NETWORK_VOLUME" &

COMFYUI_DIR="$NETWORK_VOLUME/ComfyUI"
WORKFLOW_DIR="$NETWORK_VOLUME/ComfyUI/user/default/workflows"
CUSTOM_NODES_DIR="$COMFYUI_DIR/custom_nodes"
mkdir -p "$CUSTOM_NODES_DIR"

if [ ! -d "$COMFYUI_DIR" ]; then
    status_msg "First Boot: Moving ComfyUI to Volume..."
    mv /ComfyUI "$COMFYUI_DIR"
else
    status_msg "Restart detected: Syncing latest Image changes to Volume..."
    # Using . ensures hidden files are included, and -T treats destination as a directory
    cp -ruvT /ComfyUI "$COMFYUI_DIR"
    rm -rf /ComfyUI
    echo "✅ Sync complete."
fi

echo "📥 Setting up CivitAI Downloader..."
if [ ! -f "/usr/local/bin/download_with_aria.py" ]; then
    git clone "https://github.com/concreteshoes/CivitAI_Downloader.git" /tmp/CivitAI_Downloader || echo "Git clone failed"
    mv /tmp/CivitAI_Downloader/download_with_aria.py "/usr/local/bin/" || echo "Move failed"
    chmod +x "/usr/local/bin/download_with_aria.py" || echo "Chmod failed"
    rm -rf /tmp/CivitAI_Downloader
else
    echo "✅ CivitAI Downloader already exists."
fi

# SMART SYNC: Update all existing nodes automatically
echo "🔄 Checking for updates and new dependencies..."
find "$CUSTOM_NODES_DIR" -maxdepth 1 -type d -not -path "$CUSTOM_NODES_DIR" | while read -r node_path; do
    if [ -d "$node_path/.git" ]; then
        node_name=$(basename "$node_path")

        # Check the 'mtime' (modified time) of requirements.txt before pulling
        REQ_FILE="$node_path/requirements.txt"
        BEFORE_MOD=0
        [ -f "$REQ_FILE" ] && BEFORE_MOD=$(stat -c %Y "$REQ_FILE" 2> /dev/null || stat -f %m "$REQ_FILE" 2> /dev/null)

        # Perform the update
        (cd "$node_path" && git pull --ff-only -q > /dev/null 2>&1)

        # Check if requirements.txt exists and if it was updated
        if [ -f "$REQ_FILE" ]; then
            AFTER_MOD=$(stat -c %Y "$REQ_FILE" 2> /dev/null || stat -f %m "$REQ_FILE" 2> /dev/null)

            if [ "$BEFORE_MOD" != "$AFTER_MOD" ]; then
                echo "📦 New dependencies detected for $node_name. Installing..."
                # Use --no-cache-dir to save space on your volume
                $PYTHON_BIN -m pip install --no-cache-dir -r "$REQ_FILE" > /dev/null 2>&1
            fi
        fi
    fi
done
echo "✅ All nodes updated and dependencies verified."

# VERSION LOCKS: Pin specific nodes that break when updated
if [ -d "$CUSTOM_NODES_DIR/ComfyUI-KJNodes" ]; then
    echo "📌 Pinning KJNodes to stable commit 204f6d5..."
    (cd "$CUSTOM_NODES_DIR/ComfyUI-KJNodes" && git reset --hard 204f6d5 > /dev/null 2>&1)
fi

echo "🔧 Installing requirements for core Wan nodes in background..."
(
    $PYTHON_BIN -m pip install --no-cache-dir \
        -r "$CUSTOM_NODES_DIR/ComfyUI-KJNodes/requirements.txt"
) &
# Save the Process ID so we can wait for it later
WAN_REQS_PID=$!

export CHANGE_PREVIEW_METHOD="true"

# Change to the directory
cd "$CUSTOM_NODES_DIR" || exit 1

# Function to download a model using huggingface-cli
download_model() {
    local url="$1"
    local full_path="$2"

    local destination_dir=$(dirname "$full_path")
    local destination_file=$(basename "$full_path")

    mkdir -p "$destination_dir"

    # Simple corruption check: file < 10MB or .aria2 files
    if [ -f "$full_path" ]; then
        local size_bytes=$(stat -f%z "$full_path" 2> /dev/null || stat -c%s "$full_path" 2> /dev/null || echo 0)
        local size_mb=$((size_bytes / 1024 / 1024))

        if [ "$size_bytes" -lt 10485760 ]; then # Less than 10MB
            echo "🗑️  Deleting corrupted file (${size_mb}MB < 10MB): $full_path"
            rm -f "$full_path"
        else
            echo "✅ $destination_file already exists (${size_mb}MB), skipping download."
            return 0
        fi
    fi

    # Check for and remove .aria2 control files
    if [ -f "${full_path}.aria2" ]; then
        echo "🗑️  Deleting .aria2 control file: ${full_path}.aria2"
        rm -f "${full_path}.aria2"
        rm -f "$full_path" # Also remove any partial file
    fi

    echo "📥 Downloading $destination_file to $destination_dir..."

    # Download without falloc (since it's not supported in your environment)
    aria2c -x 16 -s 16 -k 1M --continue=true -d "$destination_dir" -o "$destination_file" "$url" &

    echo "Download started in background for $destination_file"
}

# Define base paths
DIFFUSION_MODELS_DIR="$NETWORK_VOLUME/ComfyUI/models/diffusion_models"
TEXT_ENCODERS_DIR="$NETWORK_VOLUME/ComfyUI/models/text_encoders"
CLIP_VISION_DIR="$NETWORK_VOLUME/ComfyUI/models/clip_vision"
VAE_DIR="$NETWORK_VOLUME/ComfyUI/models/vae"
LORAS_DIR="$NETWORK_VOLUME/ComfyUI/models/loras"
DETECTION_DIR="$NETWORK_VOLUME/ComfyUI/models/detection"

# Download 480p native models
if [ "${DOWNLOAD_480P_NATIVE_MODELS:-false}" = "true" ]; then
    echo "Downloading 480p native models..."
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_480p_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_i2v_480p_14B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_t2v_14B_bf16.safetensors"
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_t2v_1.3B_bf16.safetensors"
fi

if [ "${DEBUG_MODELS:-false}" = "true" ]; then
    echo "Downloading 480p native models..."
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_480p_14B_fp16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_i2v_480p_14B_fp16.safetensors"
fi

# Handle full download (with SDXL)
if [ "${DOWNLOAD_WAN_FUN_AND_SDXL_HELPER:-false}" = "true" ]; then
    echo "Downloading Wan Fun 14B Model"

    download_model "https://huggingface.co/alibaba-pai/Wan2.1-Fun-14B-Control/resolve/main/diffusion_pytorch_model.safetensors" "$DIFFUSION_MODELS_DIR/diffusion_pytorch_model.safetensors"

    UNION_DIR="$NETWORK_VOLUME/ComfyUI/models/controlnet/SDXL/controlnet-union-sdxl-1.0"
    mkdir -p "$UNION_DIR"
    if [ ! -f "$UNION_DIR/diffusion_pytorch_model_promax.safetensors" ]; then
        download_model "https://huggingface.co/xinsir/controlnet-union-sdxl-1.0/resolve/main/diffusion_pytorch_model_promax.safetensors" "$UNION_DIR/diffusion_pytorch_model_promax.safetensors"
    fi
fi

# Download Wan 2.2 model by default
if [ "${DOWNLOAD_WAN22:-true}" = "true" ]; then
    echo "Downloading Wan 2.2"

    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.2_t2v_high_noise_14B_fp16.safetensors"

    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.2_t2v_low_noise_14B_fp16.safetensors"

    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.2_i2v_high_noise_14B_fp16.safetensors"

    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.2_i2v_low_noise_14B_fp16.safetensors"

    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_ti2v_5B_fp16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.2_ti2v_5B_fp16.safetensors"

    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/vae/wan2.2_vae.safetensors" "$VAE_DIR/wan2.2_vae.safetensors"

fi

if [ "${DOWNLOAD_VACE:-false}" = "true" ]; then
    echo "Downloading Wan 1.3B and 14B"

    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_t2v_1.3B_bf16.safetensors"

    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_t2v_14B_bf16.safetensors"

    echo "Downloading VACE 14B Model"

    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-VACE_module_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/Wan2_1-VACE_module_14B_bf16.safetensors"

    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1-VACE_module_1_3B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/Wan2_1-VACE_module_1_3B_bf16.safetensors"

fi

if [ "${DOWNLOAD_VACE_DEBUG:-false}" = "true" ]; then
    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_vace_14B_fp16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_vace_14B_fp16.safetensors"
fi

# Download 720p native models
if [ "${DOWNLOAD_720P_NATIVE_MODELS:-false}" = "true" ]; then
    echo "Downloading 720p native models..."

    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_i2v_720p_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_i2v_720p_14B_bf16.safetensors"

    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_t2v_14B_bf16.safetensors"

    download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/diffusion_models/wan2.1_t2v_1.3B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.1_t2v_1.3B_bf16.safetensors"
fi

# Download Wan Animate model by default
if [ "${DOWNLOAD_WAN_ANIMATE:-true}" = "true" ]; then
    echo "Downloading Wan Animate model..."

    download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/diffusion_models/wan2.2_animate_14B_bf16.safetensors" "$DIFFUSION_MODELS_DIR/wan2.2_animate_14B_bf16.safetensors"
fi

# Download Steady Dancer model
if [ "${DOWNLOAD_STEADY_DANCER:-false}" = "true" ]; then
    echo "Downloading Steady Dancer model..."

    download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/SteadyDancer/Wan21_I2V_SteadyDancer_fp16.safetensors" "$DIFFUSION_MODELS_DIR/Wan21_I2V_SteadyDancer_fp16.safetensors"
fi

echo "Downloading InfiniteTalk model"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/InfiniteTalk/Wan2_1-InfiniTetalk-Single_fp16.safetensors" "$DIFFUSION_MODELS_DIR/Wan2_1-InfiniTetalk-Single_fp16.safetensors"

echo "Downloading optimization loras"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_CausVid_14B_T2V_lora_rank32.safetensors" "$LORAS_DIR/Wan21_CausVid_14B_T2V_lora_rank32.safetensors"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors" "$LORAS_DIR/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors"
download_model "https://huggingface.co/Comfy-Org/Wan_2.2_ComfyUI_Repackaged/resolve/main/split_files/loras/wan2.2_animate_14B_relight_lora_bf16.safetensors" "$LORAS_DIR/wan2.2_animate_14B_relight_lora_bf16.safetensors"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Lightx2v/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors" "$LORAS_DIR/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors"
download_model "https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/high_noise_model.safetensors" "$LORAS_DIR/t2v_lightx2v_high_noise_model.safetensors"
download_model "https://huggingface.co/lightx2v/Wan2.2-Lightning/resolve/main/Wan2.2-T2V-A14B-4steps-lora-rank64-Seko-V1.1/low_noise_model.safetensors" "$LORAS_DIR/t2v_lightx2v_low_noise_model.safetensors"
download_model "https://huggingface.co/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_i2v_A14b_high_noise_lora_rank64_lightx2v_4step_1022.safetensors" "$LORAS_DIR/i2v_lightx2v_high_noise_model.safetensors"
download_model "https://huggingface.co/lightx2v/Wan2.2-Distill-Loras/resolve/main/wan2.2_i2v_A14b_low_noise_lora_rank64_lightx2v_4step_1022.safetensors" "$LORAS_DIR/i2v_lightx2v_low_noise_model.safetensors"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Stable-Video-Infinity/v2.0/SVI_v2_PRO_Wan2.2-I2V-A14B_HIGH_lora_rank_128_fp16.safetensors" "$LORAS_DIR/SVI_v2_PRO_Wan2.2-I2V-A14B_HIGH_lora_rank_128_fp16.safetensors"
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/LoRAs/Stable-Video-Infinity/v2.0/SVI_v2_PRO_Wan2.2-I2V-A14B_LOW_lora_rank_128_fp16.safetensors" "$LORAS_DIR/SVI_v2_PRO_Wan2.2-I2V-A14B_LOW_lora_rank_128_fp16.safetensors"

# Download text encoders
echo "Downloading text encoders..."

download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors" "$TEXT_ENCODERS_DIR/umt5_xxl_fp8_e4m3fn_scaled.safetensors"

download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/open-clip-xlm-roberta-large-vit-huge-14_visual_fp16.safetensors" "$TEXT_ENCODERS_DIR/open-clip-xlm-roberta-large-vit-huge-14_visual_fp16.safetensors"

download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/umt5-xxl-enc-bf16.safetensors" "$TEXT_ENCODERS_DIR/umt5-xxl-enc-bf16.safetensors"

# Create CLIP vision directory and download models
mkdir -p "$CLIP_VISION_DIR"
download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/clip_vision/clip_vision_h.safetensors" "$CLIP_VISION_DIR/clip_vision_h.safetensors"

# Download VAE
echo "Downloading VAE..."
download_model "https://huggingface.co/Kijai/WanVideo_comfy/resolve/main/Wan2_1_VAE_bf16.safetensors" "$VAE_DIR/Wan2_1_VAE_bf16.safetensors"

download_model "https://huggingface.co/Comfy-Org/Wan_2.1_ComfyUI_repackaged/resolve/main/split_files/vae/wan_2.1_vae.safetensors" "$VAE_DIR/wan_2.1_vae.safetensors"

download_model "https://huggingface.co/spacepxl/Wan2.1-VAE-upscale2x/resolve/main/Wan2.1_VAE_upscale2x_imageonly_real_v1.safetensors" "$VAE_DIR/Wan2.1_VAE_upscale2x_imageonly_real_v1.safetensors"

# Download detection models for WanAnimatePreprocess
echo "Downloading detection models..."
mkdir -p "$DETECTION_DIR"
download_model "https://huggingface.co/Wan-AI/Wan2.2-Animate-14B/resolve/main/process_checkpoint/det/yolov10m.onnx" "$DETECTION_DIR/yolov10m.onnx"
download_model "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_data.bin" "$DETECTION_DIR/vitpose_h_wholebody_data.bin"
download_model "https://huggingface.co/Kijai/vitpose_comfy/resolve/main/onnx/vitpose_h_wholebody_model.onnx" "$DETECTION_DIR/vitpose_h_wholebody_model.onnx"

# Keep checking until no aria2c processes are running
if pgrep -x "aria2c" > /dev/null; then
    echo "⏳ Waiting for downloads..."
    while pgrep -x "aria2c" > /dev/null; do
        sleep 5
    done
fi

declare -A MODEL_CATEGORIES=(
    ["$NETWORK_VOLUME/ComfyUI/models/checkpoints"]="$CHECKPOINT_IDS_TO_DOWNLOAD"
    ["$NETWORK_VOLUME/ComfyUI/models/loras"]="$LORAS_IDS_TO_DOWNLOAD"
)

# Counter to track background jobs
download_count=0

# Ensure directories exist and schedule downloads in background
for TARGET_DIR in "${!MODEL_CATEGORIES[@]}"; do
    mkdir -p "$TARGET_DIR"
    MODEL_IDS_STRING="${MODEL_CATEGORIES[$TARGET_DIR]}"

    # Skip if the value is the default placeholder
    if [[ "$MODEL_IDS_STRING" == "replace_with_ids" ]]; then
        echo "⏭️  Skipping downloads for $TARGET_DIR (default value detected)"
        continue
    fi

    IFS=',' read -ra MODEL_IDS <<< "$MODEL_IDS_STRING"

    for MODEL_ID in "${MODEL_IDS[@]}"; do
        sleep 1
        echo "🚀 Scheduling download: $MODEL_ID to $TARGET_DIR"
        (cd "$TARGET_DIR" && download_with_aria.py -m "$MODEL_ID") &
        ((download_count++))
    done
done

echo "📋 Scheduled $download_count downloads in background"

# Wait for all downloads to complete
if pgrep -x "aria2c" > /dev/null; then
    echo "⏳ Waiting for downloads..."
    while pgrep -x "aria2c" > /dev/null; do
        sleep 5
    done
fi

echo "✅ All models downloaded successfully!"

echo "All downloads completed!"

echo "Downloading upscale models"
mkdir -p "$NETWORK_VOLUME/ComfyUI/models/upscale_models"
if [ ! -f "$NETWORK_VOLUME/ComfyUI/models/upscale_models/4xLSDIR.pth" ]; then
    if [ -f "/4xLSDIR.pth" ]; then
        mv "/4xLSDIR.pth" "$NETWORK_VOLUME/ComfyUI/models/upscale_models/4xLSDIR.pth"
        echo "Moved 4xLSDIR.pth to the correct location."
    else
        echo "4xLSDIR.pth not found in the root directory."
    fi
else
    echo "4xLSDIR.pth already exists. Skipping."
fi

echo "Finished downloading models!"

echo "Checking and copying workflow..."
mkdir -p "$WORKFLOW_DIR"

# Ensure the file exists in the current directory before moving it
cd /

SOURCE_DIR="/comfyui-wan/workflows"

# Loop over each subdirectory in the source directory
for dir in "$SOURCE_DIR"/*/; do
    # Skip if no directories match (empty glob)
    [[ -d "$dir" ]] || continue

    dir_name="$(basename "$dir")"
    dest_dir="$WORKFLOW_DIR/$dir_name"

    if [[ -e "$dest_dir" ]]; then
        echo "Directory already exists in destination. Deleting source: $dir"
        rm -rf "$dir"
    else
        echo "Moving: $dir to $WORKFLOW_DIR"
        mv "$dir" "$WORKFLOW_DIR/"
    fi
done

if [ "${CHANGE_PREVIEW_METHOD:-false}" = "true" ]; then
    echo "Updating default preview method..."
    sed -i '/id: *'"'"'VHS.LatentPreview'"'"'/,/defaultValue:/s/defaultValue: false/defaultValue: true/' $NETWORK_VOLUME/ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite/web/js/VHS.core.js
    CONFIG_PATH="$COMFYUI_DIR/user/default/ComfyUI-Manager"
    CONFIG_FILE="$CONFIG_PATH/config.ini"

    # Ensure the directory exists
    mkdir -p "$CONFIG_PATH"

    # Create the config file if it doesn't exist
    if [ ! -f "$CONFIG_FILE" ]; then
        echo "Creating config.ini..."
        cat << EOL > "$CONFIG_FILE"
[default]
preview_method = auto
git_exe =
use_uv = False
channel_url = https://raw.githubusercontent.com/ltdrdata/ComfyUI-Manager/main
share_option = all
bypass_ssl = False
file_logging = True
component_policy = workflow
update_policy = stable-comfyui
windows_selector_event_loop_policy = False
model_download_by_agent = False
downgrade_blacklist =
security_level = normal
skip_migration_check = False
always_lazy_install = False
network_mode = public
db_mode = cache
EOL
    else
        echo "config.ini already exists. Updating preview_method..."
        sed -i 's/^preview_method = .*/preview_method = auto/' "$CONFIG_FILE"
    fi
    echo "Config file setup complete!"
    echo "Default preview method updated to 'auto'"
else
    echo "Skipping preview method update (CHANGE_PREVIEW_METHOD is not 'true')."
fi

# Workspace as main working directory
echo "cd $NETWORK_VOLUME" >> ~/.bashrc

# Install dependencies
echo "⏳ Waiting for background dependency installs to finish..."
wait $WAN_REQS_PID
REQ_STATUS=$?

if [ $REQ_STATUS -ne 0 ]; then
    echo "❌ Core Wan node requirements failed to install."
else
    echo "✅ All Wan dependencies installed successfully."
fi

status_msg "Checking for ZIP-masked LoRAs..."
cd "$LORAS_DIR" || echo "LoRA dir not found, skipping rename."
# The 'nullglob' prevents the loop from running if no .zip files exist
shopt -s nullglob
for file in *.zip; do
    echo "📦 Unmasking $file to .safetensors"
    mv "$file" "${file%.zip}.safetensors"
done
shopt -u nullglob

# Return to the ComfyUI root directory before launching
cd "$NETWORK_VOLUME/ComfyUI" || exit 1

# GPU VRAM check
# Grabs the total memory of the first GPU in MB
GPU_VRAM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | head -n 1)
VRAM_THRESHOLD=40000 # 40GB in MB

echo "📟 Detected GPU VRAM: ${GPU_VRAM_MB}MB"

# Sage Attention check
echo "🔍 Checking for SageAttention..."
if $PYTHON_BIN -c "import sageattention" &> /dev/null; then
    SAGE_ATTENTION_AVAILABLE=true
else
    SAGE_ATTENTION_AVAILABLE=false
fi

# Build Command
EXTRA_FLAGS="--listen --fp8_e4m3fn-text-enc --preview-method auto"

# Memory Optimization based on VRAM
if [ "$GPU_VRAM_MB" -ge "$VRAM_THRESHOLD" ]; then
    echo "🚀 High VRAM detected (40GB+). Enabling --highvram."
    EXTRA_FLAGS="$EXTRA_FLAGS --highvram"
else
    echo "⚖️ Standard VRAM detected (24GB). Forcing FP8 for Model and VAE."
    EXTRA_FLAGS="$EXTRA_FLAGS --fp8_base --fp8_e4m3fn-vae"
fi

# SageAttention check
if [ "$SAGE_ATTENTION_AVAILABLE" = "true" ]; then
    echo "✨ SageAttention enabled."
    EXTRA_FLAGS="$EXTRA_FLAGS --use-sage-attention"
fi

COMFYUI_CMD="$PYTHON_BIN $COMFYUI_DIR/main.py $EXTRA_FLAGS"

# Runtime Updates (Added 'install' keyword)
echo "🆙 Updating runtime extensions..."
$PYTHON_BIN -m pip install --no-cache-dir comfy-aimdo comfy-kitchen --upgrade

# Launch
URL="http://127.0.0.1:8188"
status_msg "▶️ Starting ComfyUI for Wan Video Generation..."
nohup $COMFYUI_CMD > "$NETWORK_VOLUME/comfyui_nohup.log" 2>&1 &

# Timeout logic
counter=0
max_wait=80 # Increased slightly for Wan model loading

until curl --silent --fail "$URL" --output /dev/null; do
    if [ $counter -ge $max_wait ]; then
        echo "❌ Timeout: ComfyUI failed to start within ${max_wait}s."
        echo "📋 Check logs: tail -n 50 $NETWORK_VOLUME/comfyui_nohup.log"
        exit 1
    fi

    echo "🔄 ComfyUI Starting... ($counter/${max_wait}s)"
    sleep 5
    counter=$((counter + 5))
done

# Final Verification
if curl --silent --fail "$URL" --output /dev/null; then
    echo "🚀 ComfyUI is UP and optimized for Wan Video."
    echo "💡 Note: First Wan generation will take ~60s to compile Triton kernels."
    echo "--- Last 10 lines of startup log ---"
    tail -n 10 "$NETWORK_VOLUME/comfyui_nohup.log"
fi

echo ""
echo "================================================"
echo ""
echo "  Template ready!"
echo ""
echo "  To access JupyterLab from your local machine:"
echo ""
echo "  1) Use the SSH command provided by your host (Vast.ai / RunPod),"
echo "     and add port forwarding like this:"
echo ""
echo "     ssh -p <SSH_PORT> hostname@<SERVER_IP> -L 8888:localhost:8888"
echo ""
echo "  2) Then open your browser:"
echo "     http://localhost:8888/lab"
echo ""
echo "  To access ComfyUI GUI on port 8188:"
echo ""
echo "     ssh -p <SSH_PORT> hostname@<SERVER_IP> -L 8188:localhost:8188"
echo ""
echo "     Then open your browser to:"
echo "     http://localhost:8188"
echo ""
echo "  You can also access JupyterLab via the RunPod web interface if deployed there"
echo ""
echo "================================================"
echo ""

# ================================
# SSH Startup
# ================================

echo "🔐 Starting SSH server..."

mkdir -p /var/run/sshd
chmod 700 /root/.ssh

# If SSH_PUBLIC_KEY provided via env, append safely
if [ -n "${SSH_PUBLIC_KEY:-}" ]; then
    echo "Adding SSH_PUBLIC_KEY from environment..."
    touch /root/.ssh/authorized_keys
    chmod 600 /root/.ssh/authorized_keys

    # Avoid duplicates
    grep -qxF "$SSH_PUBLIC_KEY" /root/.ssh/authorized_keys 2> /dev/null \
        || echo "$SSH_PUBLIC_KEY" >> /root/.ssh/authorized_keys
fi

/usr/sbin/sshd

echo "✅ SSH ready."

sleep infinity
