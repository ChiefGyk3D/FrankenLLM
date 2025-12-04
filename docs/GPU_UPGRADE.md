# 🔧 GPU Upgrade & Reconfiguration Guide

This guide covers how to add, replace, or upgrade GPUs in your FrankenLLM setup.

## 📋 Common Scenarios

1. **Replace a GPU** - Swap one GPU for another (e.g., RTX 3050 → RTX 3070)
2. **Add a GPU** - Add a third (or more) GPU to the system
3. **Remove a GPU** - Go from 2 GPUs to 1
4. **Reorder GPUs** - Change which GPU is GPU 0 vs GPU 1

---

## 🔄 Scenario 1: Replace a GPU (Same Slot)

**Example:** Upgrading RTX 3050 (GPU 1) to RTX 3070

### Step 1: Stop Services

```bash
# Local
./manage.sh stop

# Remote
ssh YOUR_SERVER_IP "sudo systemctl stop ollama-gpu0 ollama-gpu1"
```

### Step 2: Power Down & Swap Hardware

1. Shut down the server completely
2. Physically swap the GPU
3. Boot the server

### Step 3: Verify GPU Detection

```bash
# Check that the new GPU is detected
./bin/check-gpus.sh

# Or directly on the server
nvidia-smi
```

You should see your new GPU listed. The GPU index (0 or 1) depends on the PCIe slot.

### Step 4: Update Configuration (Optional)

If you want to update the GPU name in your config:

```bash
# Edit .env file
nano .env

# Update the name
FRANKEN_GPU1_NAME="RTX 3070"
```

### Step 5: Update systemd Service (Optional)

If you changed the GPU name:

```bash
# Remote server
ssh YOUR_SERVER_IP

# Edit the service file
sudo nano /etc/systemd/system/ollama-gpu1.service

# Update the Description line
# Description=Ollama Service for GPU 1 (RTX 3070)

# Reload systemd
sudo systemctl daemon-reload
```

### Step 6: Pull Models for New GPU

If the new GPU has more VRAM, you might want different models:

```bash
# Pull a larger model for the upgraded GPU
./bin/add-model.sh 1 gemma3:12b

# Or interactively
./bin/add-model.sh
```

### Step 7: Update Warmup Configuration

```bash
# Reconfigure which models to keep warm
./bin/warmup-config.sh set
```

### Step 8: Start Services

```bash
./manage.sh start
./bin/health-check.sh
```

---

## ➕ Scenario 2: Add a Third GPU

### Step 1: Physical Installation

1. Shut down the server
2. Install the new GPU in an available PCIe slot
3. Boot the server

### Step 2: Verify Detection

```bash
nvidia-smi
```

You should see 3 GPUs (indices 0, 1, 2).

### Step 3: Update .env Configuration

```bash
nano .env
```

Add GPU 2 configuration:

```bash
FRANKEN_GPU_COUNT=3
FRANKEN_GPU2_PORT=11436
FRANKEN_GPU2_NAME="RTX 4070"  # Your GPU name
```

### Step 4: Create New systemd Service

```bash
# On the server
ssh YOUR_SERVER_IP

# Create model directory
mkdir -p ~/.ollama/models-gpu2

# Create service file
sudo tee /etc/systemd/system/ollama-gpu2.service > /dev/null << 'EOF'
[Unit]
Description=Ollama Service for GPU 2 (RTX 4070)
After=network-online.target

[Service]
Type=simple
User=$USER
Environment="CUDA_VISIBLE_DEVICES=2"
Environment="OLLAMA_HOST=0.0.0.0:11436"
Environment="OLLAMA_MODELS=/home/$USER/.ollama/models-gpu2"
Environment="OLLAMA_KEEP_ALIVE=-1"
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF

# Enable and start
sudo systemctl daemon-reload
sudo systemctl enable ollama-gpu2
sudo systemctl start ollama-gpu2
```

### Step 5: Pull Models

```bash
# Add models to GPU 2
OLLAMA_HOST=127.0.0.1:11436 ollama pull gemma3:12b
```

### Step 6: Update Open WebUI (if installed)

```bash
# Stop current container
docker stop open-webui

# Remove old container
docker rm open-webui

# Restart with 3 backends
docker run -d \
  --name open-webui \
  --restart always \
  -p 3000:8080 \
  -e OLLAMA_BASE_URLS="http://YOUR_SERVER_IP:11434;http://YOUR_SERVER_IP:11435;http://YOUR_SERVER_IP:11436" \
  -v open-webui:/app/backend/data \
  ghcr.io/open-webui/open-webui:main
```

---

## ➖ Scenario 3: Remove a GPU (2 → 1)

### Step 1: Backup Model List

```bash
# Note which models you have
./bin/add-model.sh list
```

### Step 2: Stop Services

```bash
./manage.sh stop
```

### Step 3: Physical Removal

1. Shut down server
2. Remove the GPU
3. Boot server

### Step 4: Disable Removed GPU Service

```bash
ssh YOUR_SERVER_IP
sudo systemctl disable ollama-gpu1
sudo rm /etc/systemd/system/ollama-gpu1.service
sudo systemctl daemon-reload
```

### Step 5: Update .env

```bash
nano .env
FRANKEN_GPU_COUNT=1
```

### Step 6: Migrate Models (Optional)

If you had important models on GPU 1, re-pull them on GPU 0:

```bash
./bin/add-model.sh 0 your-model-name
```

### Step 7: Update Open WebUI

```bash
docker stop open-webui && docker rm open-webui

docker run -d \
  --name open-webui \
  --restart always \
  -p 3000:8080 \
  -e OLLAMA_BASE_URLS="http://YOUR_SERVER_IP:11434" \
  -v open-webui:/app/backend/data \
  ghcr.io/open-webui/open-webui:main
```

---

## 🔀 Scenario 4: GPUs Reordered After Hardware Change

Sometimes after hardware changes, Linux assigns different GPU indices.

### Check Current GPU Order

```bash
nvidia-smi
```

Note which GPU is at which index based on the GPU name.

### Option A: Swap Service Configurations

If GPU 0 and GPU 1 swapped positions:

```bash
ssh YOUR_SERVER_IP

# Swap the CUDA_VISIBLE_DEVICES in the service files
sudo nano /etc/systemd/system/ollama-gpu0.service
# Change CUDA_VISIBLE_DEVICES=0 to CUDA_VISIBLE_DEVICES=1

sudo nano /etc/systemd/system/ollama-gpu1.service
# Change CUDA_VISIBLE_DEVICES=1 to CUDA_VISIBLE_DEVICES=0

sudo systemctl daemon-reload
sudo systemctl restart ollama-gpu0 ollama-gpu1
```

### Option B: Reinstall Services

For a clean slate:

```bash
./setup-frankenllm.sh
# Choose "Reinstall" when prompted about existing Ollama services
```

---

## 📁 Understanding Model Storage

Each GPU has isolated model storage:

```
~/.ollama/
├── models-gpu0/    # Models for GPU 0 only
├── models-gpu1/    # Models for GPU 1 only
└── models-gpu2/    # Models for GPU 2 only (if added)
```

When you replace a GPU, the models stay in their directory. You can:

1. **Keep them** - They'll work on the new GPU
2. **Remove them** - `rm -rf ~/.ollama/models-gpu1/*`
3. **Pull new ones** - `./bin/add-model.sh 1 new-model`

---

## 🛠️ Quick Reference Commands

| Task | Command |
|------|---------|
| Check GPU detection | `nvidia-smi` or `./bin/check-gpus.sh` |
| Stop all services | `./manage.sh stop` |
| Start all services | `./manage.sh start` |
| List models per GPU | `./bin/add-model.sh list` |
| Add model to GPU | `./bin/add-model.sh GPU_NUM MODEL` |
| Reconfigure warmup | `./bin/warmup-config.sh set` |
| Health check | `./bin/health-check.sh` |
| Full reinstall | `./setup-frankenllm.sh` |

---

## ⚡ Quick Upgrade Checklist

When upgrading a GPU:

- [ ] Stop services (`./manage.sh stop`)
- [ ] Power down and swap hardware
- [ ] Boot and verify with `nvidia-smi`
- [ ] (Optional) Update GPU name in `.env` and service file
- [ ] Pull appropriate models (`./bin/add-model.sh`)
- [ ] Configure warmup (`./bin/warmup-config.sh set`)
- [ ] Start services (`./manage.sh start`)
- [ ] Test (`./bin/health-check.sh`)

---

## 🔍 Troubleshooting

### GPU Not Detected

```bash
# Check NVIDIA driver
nvidia-smi

# If not working, reinstall driver
sudo apt install --reinstall nvidia-driver-XXX
```

### Wrong GPU Running Models

```bash
# Check which GPU is actually in use
nvidia-smi

# Verify service configuration
cat /etc/systemd/system/ollama-gpu0.service | grep CUDA
cat /etc/systemd/system/ollama-gpu1.service | grep CUDA
```

### Models Not Loading

```bash
# Check service status
./manage.sh status

# Check logs
./manage.sh logs
./manage.sh logs1
```

---

*Stitched-together GPUs, but it lives!* 🧟⚡
