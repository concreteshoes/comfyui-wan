# Use a single stage to ensure build-tools are available for custom node compilation
FROM nvidia/cuda:12.8.1-cudnn-devel-ubuntu24.04

# Consolidated environment variables
ENV DEBIAN_FRONTEND=noninteractive \
    PIP_PREFER_BINARY=1 \
    PYTHONUNBUFFERED=1 \
    CMAKE_BUILD_PARALLEL_LEVEL=8 \
    PATH="/opt/venv/bin:$PATH"

# 1. System Dependencies & SSH Setup
RUN --mount=type=cache,target=/var/cache/apt,sharing=locked \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        python3.12 python3.12-venv python3.12-dev python3-pip \
        curl unzip ffmpeg ninja-build git aria2 git-lfs wget vim rsync \
        libgl1 libglib2.0-0 libgoogle-perftools4 build-essential gcc openssh-server && \
    \
    # Setup Python 3.12 defaults
    ln -sf /usr/bin/python3.12 /usr/bin/python && \
    ln -sf /usr/bin/pip3 /usr/bin/pip && \
    python3.12 -m venv /opt/venv && \
    \
    # Surgical SSH Config
    mkdir -p /root/.ssh /var/run/sshd && \
    chmod 700 /root/.ssh && \
    sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config && \
    sed -i 's/^#\?PermitRootLogin .*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config && \
    \
    apt-get clean && rm -rf /var/lib/apt/lists/*

# 2. Stable PyTorch 2.9 Stack
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir \
        torch==2.9.0+cu128 \
        torchvision==0.24.0+cu128 \
        torchaudio==2.9.0+cu128 \
        --index-url https://download.pytorch.org/whl/cu128

# 3. Core Tooling & SageAttention
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir packaging setuptools wheel triton sageattention

# 4. Runtime Libraries & Comfy-CLI
RUN --mount=type=cache,target=/root/.cache/pip \
    pip install --no-cache-dir pyyaml gdown onnxruntime-gpu comfy-cli \
        jupyterlab jupyterlab-lsp opencv-python-headless \
        jupyter-server jupyter-server-terminals ipykernel jupyterlab_code_formatter

RUN curl -fsSL https://rclone.org/install.sh -o /tmp/rclone_install.sh && \
    bash /tmp/rclone_install.sh && \
    rm /tmp/rclone_install.sh

# 5. ComfyUI & Custom Nodes (with Directory Fix & CircleCI Heartbeat)
RUN --mount=type=cache,target=/root/.cache/pip \
    # Create workspace and install comfy with analytics disabled
    mkdir -p /ComfyUI/custom_nodes && \
    comfy --workspace /ComfyUI install --non-interactive --yes && \
    set -e; \
    cd /ComfyUI/custom_nodes; \
    for repo in \
        https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git \
        https://github.com/kijai/ComfyUI-KJNodes.git \
        https://github.com/rgthree/rgthree-comfy.git \
        https://github.com/JPS-GER/ComfyUI_JPS-Nodes.git \
        https://github.com/Suzie1/ComfyUI_Comfyroll_CustomNodes.git \
        https://github.com/Jordach/comfy-plasma.git \
        https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git \
        https://github.com/bash-j/mikey_nodes.git \
        https://github.com/ltdrdata/ComfyUI-Impact-Pack.git \
        https://github.com/Fannovel16/comfyui_controlnet_aux.git \
        https://github.com/yolain/ComfyUI-Easy-Use.git \
        https://github.com/kijai/ComfyUI-Florence2.git \
        https://github.com/ShmuelRonen/ComfyUI-LatentSyncWrapper.git \
        https://github.com/WASasquatch/was-node-suite-comfyui.git \
        https://github.com/theUpsider/ComfyUI-Logic.git \
        https://github.com/cubiq/ComfyUI_essentials.git \
        https://github.com/chrisgoringe/cg-image-picker.git \
        https://github.com/chflame163/ComfyUI_LayerStyle.git \
        https://github.com/chrisgoringe/cg-use-everywhere.git \
        https://github.com/kijai/ComfyUI-segment-anything-2.git \
        https://github.com/ClownsharkBatwing/RES4LYF \
        https://github.com/welltop-cn/ComfyUI-TeaCache.git \
        https://github.com/Fannovel16/ComfyUI-Frame-Interpolation.git \
        https://github.com/Jonseed/ComfyUI-Detail-Daemon.git \
        https://github.com/kijai/ComfyUI-WanVideoWrapper.git \
        https://github.com/wildminder/ComfyUI-VibeVoice.git \
        https://github.com/kijai/ComfyUI-WanAnimatePreprocess.git \
        https://github.com/obisin/ComfyUI-FSampler.git \
        https://github.com/cmeka/ComfyUI-WanMoEScheduler.git \
        https://github.com/lrzjason/ComfyUI-VAE-Utils.git \
        https://github.com/wallen0322/ComfyUI-Wan22FMLF.git \
        https://github.com/chflame163/ComfyUI_LayerStyle_Advance.git \
        https://github.com/BadCafeCode/masquerade-nodes-comfyui.git \
        https://github.com/1038lab/ComfyUI-RMBG.git \
        https://github.com/M1kep/ComfyLiterals.git; \
    do \
        repo_dir=$(basename "$repo" .git); \
        echo "CIRCLECI_HEARTBEAT: Installing $repo_dir into $(pwd)..."; \
        if [ "$repo" = "https://github.com/ssitu/ComfyUI_UltimateSDUpscale.git" ]; then \
            git clone --depth 1 --recursive "$repo"; \
        else \
            git clone --depth 1 "$repo"; \
        fi; \
        if [ -f "$repo_dir/requirements.txt" ]; then \
            pip install --progress-bar off -v -r "$repo_dir/requirements.txt" || echo "⚠️ Warning: Requirements for $repo_dir failed, skipping..."; \
        fi; \
        if [ -f "$repo_dir/install.py" ]; then \
            python3 "$repo_dir/install.py" || echo "⚠️ Warning: Install script for $repo_dir failed"; \
        fi; \
    done

# 6. Final Assets & Entrypoint
COPY src/start_script.sh /start_script.sh
COPY docker-entrypoint.sh /docker-entrypoint.sh
COPY 4xLSDIR.pth /4xLSDIR.pth

RUN chmod +x /start_script.sh /docker-entrypoint.sh

ENTRYPOINT ["/docker-entrypoint.sh"]
CMD ["/start_script.sh"]