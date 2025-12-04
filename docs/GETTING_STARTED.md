# 🚀 Getting Started with FrankenLLM

Welcome! This guide will walk you through setting up FrankenLLM from scratch.

## 📋 Prerequisites

### Hardware Requirements
- **1 or more NVIDIA GPUs** with sufficient VRAM
- Recommended: 8GB+ VRAM per GPU for optimal performance

### Software Requirements
- **Ubuntu Server 24.04** (tested and recommended)
  - Other Linux distributions should work but are untested
- **NVIDIA Drivers** (version 535+recommended, tested with 580)
- **CUDA Toolkit** (optional but recommended)
- **Docker** (for Open WebUI only)

### Tested Environment
✅ **Confirmed working on:**
- Ubuntu Server 24.04 (headless)
- Linux Kernel 6.14
- NVIDIA Driver 580
- Hardware: RTX 5060 Ti (16GB) + RTX 3050 (8GB)

---

## 🎯 Quick Start (3 Steps)

### Step 1: Configure

```bash
git clone https://github.com/ChiefGyk3D/FrankenLLM.git
cd FrankenLLM
./configure.sh
```

This creates a `.env` file with your settings:
- Server IP (localhost for local install, or remote IP like 192.168.1.100)
- Number of GPUs
- Port assignments for each GPU
- GPU names (optional)
- Model preferences (optional)

### Step 2: Install

```bash
./install.sh
```

This automatically:
- Detects local vs. remote installation
- Installs Ollama
- Creates systemd services (one per GPU)
- Sets up auto-start on boot
- Configures auto-warmup

**Installation takes:** ~5-10 minutes depending on your connection

### Step 3: Pull Models

```bash
# For same model on all GPUs:
./bin/pull-model.sh gemma3:12b

# For different models per GPU:
./bin/pull-dual-models.sh gemma3:12b gemma3:4b

# The script adapts to your GPU count automatically!
```

**Done!** 🎉 Your LLMs are ready to use.

---

## 🎮 Basic Usage

### Service Management

```bash
# Check status
./manage.sh status

# Start/stop/restart services
./manage.sh start
./manage.sh stop
./manage.sh restart

# View logs
./manage.sh logs      # GPU 0
./manage.sh logs1     # GPU 1 (if you have 2+ GPUs)

# Enable/disable auto-start on boot
./manage.sh enable
./manage.sh disable
```

### Testing Your Setup

```bash
# Test connectivity
./bin/test-connection.sh

# Test LLMs with a query
./bin/test-llm.sh "What is your purpose?"

# Interactive chat (select GPU and model)
./bin/chat.sh

# Check GPU utilization
./bin/check-gpus.sh
```

### Managing Models Per GPU

Each GPU has its own isolated model storage. Add models to specific GPUs:

```bash
# Add model to a specific GPU
./bin/add-model.sh 0 gemma3:12b    # Add to GPU 0 (larger GPU)
./bin/add-model.sh 1 gemma3:4b     # Add to GPU 1 (smaller GPU)

# Interactive mode
./bin/add-model.sh

# List models on each GPU
./bin/add-model.sh list
```

### Configuring Model Warmup

Choose which models stay loaded in GPU memory for instant responses:

```bash
# Interactive setup - select models to keep warm
./bin/warmup-config.sh set

# Show current warmup configuration
./bin/warmup-config.sh show

# Manually warm up configured models
./bin/warmup-config.sh warmup

# View GPU memory status
./bin/warmup-config.sh status
```

### Keeping Components Updated

```bash
# Check for available updates
./update.sh check

# Update everything
./update.sh all

# Update individual components
./update.sh ollama    # Update Ollama
./update.sh webui     # Update Open WebUI
```

### Installing Open WebUI (Optional but Recommended)

Open WebUI provides a ChatGPT-like web interface:

```bash
# For remote installations:
./remote/install-webui.sh

# For local installations:
./bin/install-webui.sh
```

Access at: `http://YOUR_SERVER_IP:3000`

---

## 📚 Detailed Guides

For more in-depth information, see:

- **[Configuration Guide](CONFIGURATION.md)** - Detailed configuration options
- **[Remote Management Guide](REMOTE_MANAGEMENT.md)** - Managing remote servers
- **[Auto-Warmup Guide](AUTO_WARMUP.md)** - Keep models loaded in VRAM
- **[Open WebUI Guide](OPEN_WEBUI.md)** - Web interface and N8n integration
- **[GPU Upgrade Guide](GPU_UPGRADE.md)** - Replace, add, or reconfigure GPUs
- **[Quick Reference](QUICKSTART.md)** - Command cheat sheet

---

## 🎯 Common Setup Scenarios

### Scenario 1: Home Lab Server (Remote)

You have a headless server with GPUs:

```bash
# On your workstation:
git clone https://github.com/ChiefGyk3D/FrankenLLM.git
cd FrankenLLM

# Configure (enter server IP when prompted)
./configure.sh

# Install on remote server
./install.sh

# Pull models
./bin/pull-dual-models.sh gemma3:12b gemma3:4b

# Install web UI
./remote/install-webui.sh

# Access: http://YOUR_SERVER_IP:3000
```

### Scenario 2: Local Workstation

You want to run LLMs on your desktop/laptop:

```bash
# Clone and setup
git clone https://github.com/ChiefGyk3D/FrankenLLM.git
cd FrankenLLM

# Configure (use localhost)
./configure.sh

# Install locally
./install.sh

# Pull models
./bin/pull-model.sh gemma3:12b

# Install web UI
./bin/install-webui.sh

# Access: http://localhost:3000
```

### Scenario 3: 3+ GPUs

You have multiple GPUs with different VRAM sizes:

```bash
# Configure with correct GPU count
./configure.sh
# Set FRANKEN_GPU_COUNT=3 (or more)
# Assign ports: 11434, 11435, 11436, etc.

# Install
./install.sh

# Pull different models based on VRAM
./bin/pull-dual-models.sh llama3.1:70b-q4 gemma3:27b gemma3:12b
# Script automatically handles N GPUs!
```

---

## 🔧 Troubleshooting

### Models Loading Slowly on First Request

**Problem:** First query takes 10+ seconds, then fast afterward.

**Solution:** Models aren't pre-loaded. Enable auto-warmup:
```bash
# For remote:
./remote/setup-warmup.sh

# For local:
./local/setup-warmup.sh
```

Models will now auto-load on boot! ⚡

### Can't Connect to Remote Server

**Problem:** `./manage.sh status` fails with connection errors.

**Check:**
1. SSH access works: `ssh YOUR_SERVER_IP`
2. Correct IP in `.env`: `FRANKEN_SERVER_IP=192.168.1.100`
3. Services are running on remote: `ssh YOUR_SERVER_IP 'systemctl status ollama-gpu0'`

### GPU Not Detected

**Problem:** `nvidia-smi` shows GPUs but Ollama doesn't use them.

**Solution:**
1. Check CUDA installation: `nvcc --version`
2. Verify driver: `nvidia-smi`
3. Restart Ollama: `./manage.sh restart`
4. Check logs: `./manage.sh logs`

### Port Already in Use

**Problem:** Installation fails with "port 11434 already in use".

**Solution:**
```bash
# Find what's using the port
sudo lsof -i :11434

# If it's Ollama, stop it
sudo systemctl stop ollama

# Then reinstall
./install.sh
```

### Open WebUI Not Loading

**Problem:** Can't access `http://SERVER_IP:3000`

**Check:**
1. Container running: `docker ps | grep open-webui`
2. Firewall allows port 3000
3. On remote? Use `./remote/manage-webui.sh status`
4. Check logs: `./remote/manage-webui.sh logs`

---

## 🏗️ Architecture Overview

FrankenLLM uses a **hybrid architecture** for optimal performance:

```
┌─────────────────────────────────────────────┐
│         Server (Your IP or localhost)        │
├─────────────────────────────────────────────┤
│                                              │
│  🖥️  Native Systemd Services                │
│  ├─ ollama-gpu0 → GPU 0 → Port 11434        │
│  ├─ ollama-gpu1 → GPU 1 → Port 11435        │
│  └─ frankenllm-warmup (auto-loads models)   │
│                                              │
│  🐳 Docker Container (Optional)              │
│  └─ open-webui → Port 3000                   │
│     └─ Connects to Ollama instances          │
│                                              │
└─────────────────────────────────────────────┘
```

**Why Native Ollama?**
- ⚡ Direct GPU access (no container overhead)
- 🚀 Better performance
- 🔧 Easier GPU management

**Why Docker for Open WebUI?**
- 📦 Self-contained
- 🔄 Easy updates
- 💾 Portable data

---

## 🎓 Next Steps

Once you have everything running:

1. **Add more models** - See [Configuration Guide](CONFIGURATION.md) for model recommendations
2. **Set up N8n integration** - See [Open WebUI Guide](OPEN_WEBUI.md)
3. **Optimize model selection** - Match models to your GPU VRAM sizes
4. **Configure backups** - Save your `.env` and Open WebUI data
5. **Explore CLI tools** - Try `./bin/chat.sh` for interactive conversations

---

## 💬 Support

- **Issues:** [GitHub Issues](https://github.com/ChiefGyk3D/FrankenLLM/issues)
- **Documentation:** Check the `docs/` directory
- **Examples:** See README.md for usage examples

---

## 🎉 You're All Set!

Your FrankenLLM installation is complete. Start chatting with your models:

```bash
# Web interface
open http://YOUR_SERVER_IP:3000

# or CLI
./bin/chat.sh

# or test
./bin/test-llm.sh "Hello, introduce yourself!"
```

**Welcome to the FrankenLLM family!** 🧟‍♂️
