# ComfyUI Wan w/ Sage Attention for CUDA 12.8

### Variables Selection

Wan 2.2 and Wan Animate are downloaded by default, change to `false` if desired:

```env
DOWNLOAD_WAN22=""
DOWNLOAD_WAN_ANIMATE=""
```

The following models are **not** downloaded unless explicitly set to `true`:

Wan 2.1 & FP16 version / Vace & FP16 version / SDXL Helper / SteadyDancer

```env
DOWNLOAD_480P_NATIVE_MODELS=""
DOWNLOAD_720P_NATIVE_MODELS=""
DEBUG_MODELS=""
DOWNLOAD_VACE=""
DOWNLOAD_VACE_DEBUG=""
DOWNLOAD_WAN_FUN_AND_SDXL_HELPER=""
DOWNLOAD_STEADY_DANCER=""
```
###### If you want absolutely everything, make sure your disk is at least 200GB

### Auth Tokens

```env
CIVITAI_TOKEN=""
SSH_PUBLIC_KEY=""
```

### Ports

| Port | Service  |
|------|----------|
| 8188 | ComfyUI  |
| 8888 | Jupyter  |
| 22   | SSH      |

### Accessing the Instance

```bash 
If you are using custom SSH key location you might want to create a config file in
~/.ssh/config for Linux or $HOME\.ssh\config for Windows.
```
Linux:
```bash
Host *
    IdentityFile PATH/.ssh/id_ed25519
    IdentitiesOnly yes
```
Windows:
```bash 
Host *
    IdentityFile PATH\.ssh\id_ed25519
    IdentitiesOnly yes
```

You can transfer files using `rsync` and connect via SSH:

```bash
# Example: sync local dataset to remote
rsync -avP -e "ssh -p <SSH_PORT>" /path/to/local/dataset/ hostname@<SERVER_IP>:/path/to/remote/dataset/

# SSH with port forwarding for JupyterLab
ssh -p <SSH_PORT> hostname@<SERVER_IP> -L 8888:localhost:8888
```
Then open your browser to:
```bash
http://localhost:8888/lab
```

#### Accessing ComfyUI GUI

ComfyUI runs its interface on port `8188`. To access it from your local browser, use SSH port forwarding:

```bash
# SSH with port forwarding for ComfyUI
ssh -p <SSH_PORT> hostname@<SERVER_IP> -L 8188:localhost:8188
```
Then open your browser to:
```bash
http://localhost:8188
```
---

# Civitai Downloader

### 📖 Usage

Download a model using its ID:

```bash
./download_with_aria.py -m 123456

# Download to specific directory
./download_with_aria.py -m 123456 -o ./models

# Use custom filename
./download_with_aria.py -m 123456 --filename "my_custom_model.safetensors"

# Force re-download (ignore existing files)
./download_with_aria.py -m 123456 --force

# Provide token via command line (not recommended for security)
./download_with_aria.py -m 123456 --token "your_token_here"
```

### Command Line Arguments

| Argument     | Short | Description                          |
|--------------|-------|--------------------------------------|
| `--model-id` | `-m`  | CivitAI model version ID (required)  |
| `--output`   | `-o`  | Output directory                     |
| `--token`    | —     | CivitAI API token                    |
| `--filename` | —     | Override default filename            |
| `--force`    | —     | Force re-download                    |

---

### 🎯 Examples

**Download a LoRA model:**

```bash
./download_with_aria.py -m 245589

# Download character LoRA
./download_with_aria.py -m 245589 -o ./models/lora/characters

# Download style LoRA
./download_with_aria.py -m 234567 -o ./models/lora/styles

# Download checkpoint
./download_with_aria.py -m 345678 -o ./models/checkpoints
```

**Batch download with a simple script:**

```bash
#!/bin/bash
# download_batch.sh
models=(245589 234567 345678 456789)
for model_id in "${models[@]}"; do
    ./download_with_aria.py -m "$model_id" -o ./models
done
```
