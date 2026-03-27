# 🧟 FrankenLLM

<div align="center">
  <img src="media/banner.png" alt="FrankenLLM Banner" width="600"/>
</div>

**Stitched-together GPUs, but it lives!**

Run separate LLM models on each of your NVIDIA GPUs simultaneously. Perfect for multi-GPU setups where you want to maximize utilization.

```
    ⚡ GPU 0 (16GB) ━━━━┓
                        ┣━━━ FrankenLLM ━━━━ Multiple Models!
    ⚡ GPU 1 (8GB)  ━━━━┛
```

---

## ✨ Features

- 🎯 **Per-GPU Model Serving** - Run different models optimized for each GPU's VRAM
- 🚀 **Zero Interference** - Each GPU has its own Ollama instance on separate ports
- 🔧 **Easy Management** - Simple scripts for installation, service control, and testing
- 🌐 **Local & Remote** - Works on localhost or remote servers via SSH
- ⚙️ **Systemd Services** - Automatic startup, monitoring, and restart on failure
- 🔥 **Auto-Warmup** - Models automatically load into GPU memory on boot
- 🩺 **GPU Health Monitor** - Auto-fix driver issues on boot with intelligent retry and alerts
- ⚡ **Configurable** - Support for 1+ GPUs with flexible model selection
- 🖥️ **Headless Ready** - Designed for Ubuntu Server 24.04 (tested with Linux 6.14 + NVIDIA 580 drivers)

---

## 📁 Project Structure

```
FrankenLLM/
├── 🚀 setup-frankenllm.sh  # ⭐ RECOMMENDED! Complete interactive installer
├── ⚙️  configure.sh         # Manual mode: Step 1 - Create .env config
├── 🔧 install.sh            # Manual mode: Step 2 - Run installation
├── 🎛️  manage.sh            # Day-to-day: Start/stop/restart/logs
├── 🔄 update.sh             # Update Ollama, Open WebUI, or all
├── 📝 config.sh             # Internal: Configuration loader
├── .env.example            # 📋 Configuration template
│
├── bin/                    # 🔧 Core utilities (15 tools)
│   ├── add-model.sh        #    Add models to specific GPUs
│   ├── warmup-config.sh    #    Configure which models stay warm
│   ├── check-gpus.sh       #    GPU status & utilization
│   ├── health-check.sh     #    Service connectivity test
│   ├── chat.sh             #    Interactive CLI chat
│   ├── test-connection.sh  #    Connection test + chat option
│   ├── test-llm.sh         #    Test with specific query
│   ├── pull-model.sh       #    Pull same model (all GPUs)
│   ├── pull-dual-models.sh #    Pull different models (per GPU)
│   ├── warmup-models.sh    #    Pre-load models into VRAM
│   ├── warmup-on-boot.sh   #    Boot warmup service script
│   ├── enable-keep-alive.sh #   Keep models in VRAM forever
│   ├── install-webui.sh    #    Install Open WebUI locally
│   ├── manage-webui.sh     #    Manage Open WebUI locally
│   └── update.sh           #    Update components locally
│
├── local/                  # 💻 Local installation
│   ├── install.sh          #    Install on THIS machine
│   └── manage.sh           #    Manage local services
│
├── remote/                 # 🌐 Remote installation (via SSH)
│   ├── install.sh          #    Install on remote server
│   ├── manage.sh           #    Manage remote services
│   ├── service-control.sh  #    Remote service control
│   ├── setup-warmup.sh     #    Configure auto-warmup remotely
│   ├── install-webui.sh    #    Install Open WebUI remotely
│   ├── manage-webui.sh     #    Manage remote Open WebUI
│   └── update.sh           #    Update components remotely
│
├── scripts/                # 📦 Installation components
│   ├── install-docker.sh   #    Docker + NVIDIA Container Toolkit
│   ├── install-ollama-native.sh # Native Ollama installation
│   ├── health-check.sh     #    GPU health diagnostics
│   ├── auto-fix.sh         #    Automatic GPU issue repair
│   └── install-health-module.sh # Health module installer
│
├── docs/                   # 📚 Complete documentation
│   ├── README.md           #    Full documentation
│   ├── WORKFLOWS.md        #    Super Installer vs Manual Mode
│   ├── GETTING_STARTED.md  #    Complete setup guide
│   ├── SUPER_INSTALLER.md  #    setup-frankenllm.sh guide
│   ├── CONFIGURATION.md    #    Configuration options
│   ├── AUTO_WARMUP.md      #    Auto-warmup setup guide
│   ├── OPEN_WEBUI.md       #    Web UI + N8n integration
│   ├── QUICKSTART.md       #    Command reference
│   ├── REMOTE_MANAGEMENT.md #   Remote server guide
│   ├── GPU_UPGRADE.md      #    GPU replacement/upgrade guide
│   └── archive/            #    Historical documentation
│
└── archive/                # 🗂️  Old scripts (reference only)
    └── old-root-scripts/   #    Previous versions
```

---

## 🚀 Quick Start

### 🤔 Choose Your Workflow

| Feature | 🚀 Super Installer | 🛠️ Manual Mode |
|---------|-------------------|-----------------|
| **Command** | `./setup-frankenllm.sh` | `./configure.sh` → `./install.sh` |
| **Best For** | Most users, fresh installs | Advanced users, automation |
| **Detects Existing** | ✅ Docker, Ollama, services | ❌ Overwrites |
| **Sudo Caching** | ✅ Enter password once | ❌ Multiple prompts |
| **Flexible GPUs** | ✅ Auto-detects 1+ GPUs | ✅ Manual configuration |
| **Reinstall Options** | ✅ Keep/upgrade/skip | ❌ Always reinstalls |
| **Interactive** | ✅ Guided wizard | ✅ Step-by-step |
| **Config Review** | ⚠️ No (immediate install) | ✅ Edit `.env` before install |

---

### ⚡ Complete Setup (Recommended - Super Installer)

**For first-time installation or complete setup:**

```bash
git clone https://github.com/ChiefGyk3D/FrankenLLM.git
cd FrankenLLM
./setup-frankenllm.sh
```

**This intelligent wizard handles:**

🔍 **Smart Detection:**
- Detects existing Docker, Ollama, services
- Offers upgrade/reinstall/skip options
- Works with 1, 2, or more GPUs flexibly

📦 **Complete Installation:**
- ✅ Docker (detects if already installed)
- ✅ Ollama per-GPU services (with systemd)
- ✅ Open WebUI (optional web interface)
- ✅ Auto-warmup on boot (optional, instant queries)
- ✅ Model downloads (optional, during setup)

🎯 **User-Friendly Features:**
- Caches sudo password (enter once!)
- Color-coded progress
- Works local OR remote (via SSH)
- Handles reinstalls gracefully

⚙️ **Auto-Start on Boot:**
- Ollama services: Enabled automatically
- Open WebUI: Enabled automatically
- Model warmup: Optional (50s total boot time)

**Perfect for:**
- 🆕 Fresh Ubuntu Server 24.04 setups
- 🔄 Upgrading existing installations
- 🎮 Dedicated LLM servers (2+ GPUs)
- 🏠 Home lab multi-GPU machines
- 🌐 Remote server deployments

---

### 🛠️ Manual Setup (Advanced Users)

**Why use manual mode?**
- Need to configure `.env` without installing yet
- Want to review configuration before installation
- Integrating with existing automation/scripts
- Prefer traditional two-step workflow

**Manual workflow:**

#### 1. Configure Your Environment

```bash
./configure.sh
```

This creates a `.env` file with:
- Server IP (localhost or remote IP like 192.168.201.145)
- GPU ports (default: 11434, 11435)
- GPU names (optional)

> **Note:** You can edit `.env` manually after creation for fine-tuned control.

#### 2. Install Ollama Services

```bash
./install.sh
```

Auto-detects local or remote from your configuration and:
- Installs Ollama
- Creates systemd services for each GPU
- Starts and enables services

> **Note:** Unlike `setup-frankenllm.sh`, this won't detect existing installations or cache sudo password.

#### 3. Pull Models

```bash
# Pull different models optimized for each GPU
./bin/pull-dual-models.sh gemma3:12b gemma3:4b

# Or pull the same model on both
./bin/pull-model.sh gemma2:9b
```

#### 4. Pre-warm Models (Optional but Recommended)

```bash
# Load models into GPU memory for instant responses
./bin/warmup-models.sh
```

> 💡 For automatic warmup on boot, see the [Auto-Warmup Guide](docs/AUTO_WARMUP.md)

#### 5. Test Your Setup

```bash
./bin/health-check.sh
./bin/test-llm.sh "What is your purpose?"
```

---

## 📊 Recommended Models

### For 32GB+ GPU (e.g., RTX 4090, RTX 6000 Ada, A6000)

**Flagship Models:**
- `gemma3:27b` - ⭐ **Google's largest Gemma!** Multimodal, 128K context
- `llama3.1:70b-instruct-q4_0` - Meta's most capable (quantized to fit)
- `qwen2.5:32b` - Alibaba's powerful multilingual model
- `mixtral:8x7b` - Mixture of experts, excellent performance

**Coding Specialists:**
- `deepseek-coder:33b-instruct` - Top-tier code generation
- `codellama:34b` - Meta's code specialist

### For 24GB GPU (e.g., RTX 4090, RTX 3090, A5000)

**Premium Models:**
- `gemma3:27b` - ⭐ **FITS PERFECTLY!** Google's flagship multimodal
- `llama3.1:45b-instruct-q4_0` - High capability (quantized)
- `qwen2.5:14b` - Excellent reasoning and multilingual
- `deepseek-coder:33b-instruct-q4_0` - Professional code generation

**Balanced Options:**
- `mistral:22b` - Great all-rounder
- `solar:10.7b` - Efficient and powerful

### For 16GB GPU (e.g., RTX 5060 Ti, RTX 4060 Ti)

**Google Gemma 3 (Newest! March 2025):**
- `gemma3:12b` - ⭐ **PERFECT FIT!** Multimodal (text + images), 128K context
- `gemma2:9b` - Stable, excellent performance
- `gemma:7b` - Original Gemma

**Other Great Options:**
- `llama3.2` - Meta's latest
- `mistral:7b-instruct` - Great for instruction following
- `codellama:13b` - Coding specialist
- `deepseek-coder:6.7b` - Another excellent code model

### For 8GB GPU (e.g., RTX 3050, RTX 4060)

**Google Gemma 3 (Newest! March 2025):**
- `gemma3:4b` - ⭐ **PERFECT FIT!** Multimodal, great capability/memory balance
- `gemma3:1b` - Ultra-fast responses
- `gemma2:2b` - Stable, best quality for 8GB
- `gemma:2b` - Original, still excellent

**Other Great Options:**
- `llama3.2:3b` - Compact but capable
- `phi3:3.8b` - Microsoft's efficient model
- `qwen:4b` - Strong multilingual model

### 🎯 Recommended Combos

**High-End Setup (32GB + 24GB):**
```bash
./bin/pull-dual-models.sh llama3.1:70b-instruct-q4_0 gemma3:27b
```

**Premium Dual 24GB:**
```bash
./bin/pull-dual-models.sh gemma3:27b qwen2.5:14b
```

**All Gemma 3 (16GB + 8GB):**
```bash
./bin/pull-dual-models.sh gemma3:12b gemma3:4b
```

**Fast Combo (16GB + 8GB):**
```bash
./bin/pull-dual-models.sh gemma3:12b gemma3:1b
```

**Stable Gemma 2:**
```bash
./bin/pull-dual-models.sh gemma2:9b gemma2:2b
```

**Code + General:**
```bash
./bin/pull-dual-models.sh codellama:13b llama3.2:3b
```

**Three GPU Setup (24GB + 16GB + 8GB):**
```bash
./bin/pull-dual-models.sh gemma3:27b gemma3:12b gemma3:4b
```

---

## 🎮 Usage

### Service Management

```bash
# Check status
./manage.sh status

# Start/stop/restart services
./manage.sh start
./manage.sh stop
./manage.sh restart

# View logs
./manage.sh logs

# Enable/disable auto-start on boot
./manage.sh enable
./manage.sh disable
```

### Updating Components

```bash
# Check for available updates
./update.sh check

# Update everything (Ollama + Open WebUI)
./update.sh all

# Update individual components
./update.sh ollama    # Update Ollama to latest
./update.sh webui     # Update Open WebUI to latest
```

### Model Management

```bash
# Add a model to a specific GPU
./bin/add-model.sh 0 gemma3:12b    # Add to GPU 0
./bin/add-model.sh 1 gemma3:4b     # Add to GPU 1
./bin/add-model.sh                  # Interactive mode

# List models on each GPU
./bin/add-model.sh list

# Configure which models stay warmed up
./bin/warmup-config.sh set          # Interactive setup
./bin/warmup-config.sh show         # Show current config
./bin/warmup-config.sh warmup       # Load configured models
./bin/warmup-config.sh clear        # Unload all models
./bin/warmup-config.sh status       # Show GPU memory status
```

> 💡 Each GPU has isolated model storage - models added to GPU 0 won't appear on GPU 1.

### Embedding Models for RAG

You can add embedding models to a GPU for RAG (Retrieval Augmented Generation) in Open WebUI:

```bash
# Pull an embedding model onto GPU 1
./bin/add-model.sh 1 qwen3-embedding:0.6b

# Other options depending on your VRAM:
# ./bin/add-model.sh 1 qwen3-embedding:4b    # 2.5 GB, better quality
# ./bin/add-model.sh 1 qwen3-embedding:8b    # 4.7 GB, best quality (#1 MTEB)
# ./bin/add-model.sh 1 nomic-embed-text      # 270 MB, minimal footprint
```

Then configure Open WebUI: **Admin > Settings > Documents > Embedding** — set Engine to Ollama, model to your embedding model, and URL to your GPU's port. See [docs/OPEN_WEBUI.md](docs/OPEN_WEBUI.md#rag-retrieval-augmented-generation) for full setup guide.

### Interactive Chat

```bash
# Start interactive chat session
./bin/chat.sh

# Features:
# - Select which GPU to use
# - Choose from available models
# - Real-time conversation
# - Commands: 'quit', 'exit', 'clear', 'info'
```

### Testing & Monitoring

```bash
# Test connections and optionally chat with both GPUs
./bin/test-connection.sh

# Test both LLMs with a specific query
./bin/test-llm.sh "Your question here"

# Quick health check (no sudo required)
./bin/health-check.sh

# Detailed GPU information
./bin/check-gpus.sh
```

### Open WebUI (Web Interface)

```bash
# Install Open WebUI
./bin/install-webui.sh

# Access at http://localhost:3000
# - ChatGPT-like web interface
# - Multi-GPU support (add both Ollama instances)
# - OpenAI-compatible API for N8n, LangChain, etc.
# - User accounts, chat history, RAG, and more

# Manage Open WebUI
./bin/manage-webui.sh start    # Start
./bin/manage-webui.sh status   # Check status
./bin/manage-webui.sh logs     # View logs
./bin/manage-webui.sh update   # Update to latest

# See docs/OPEN_WEBUI.md for full guide
```

### Using the APIs

**GPU 0 (Port 11434):**
```bash
# List models
curl http://YOUR_IP:11434/api/tags

# Generate response
curl http://YOUR_IP:11434/api/generate -d '{
  "model": "gemma3:12b",
  "prompt": "Explain quantum computing",
  "stream": false
}'
```

**GPU 1 (Port 11435):**
```bash
# List models
curl http://YOUR_IP:11435/api/tags

# Generate response
curl http://YOUR_IP:11435/api/generate -d '{
  "model": "gemma3:4b",
  "prompt": "Write a Python function",
  "stream": false
}'
```

---

## ⚙️ Configuration

Configuration is stored in `.env` (create from `.env.example`):

```bash
# Server Configuration
FRANKEN_SERVER_IP=192.168.201.145    # or "localhost" for local
FRANKEN_INSTALL_DIR=/opt/frankenllm

# GPU Configuration
FRANKEN_GPU_COUNT=2                  # Number of GPUs (1 or more)

# Port Configuration
FRANKEN_GPU0_PORT=11434
FRANKEN_GPU1_PORT=11435

# GPU Names (optional, for display)
FRANKEN_GPU0_NAME="RTX 5060 Ti"
FRANKEN_GPU1_NAME="RTX 3050"

# Model Configuration
# Specify which models to use on each GPU
FRANKEN_GPU0_MODEL="gemma3:12b"
FRANKEN_GPU1_MODEL="gemma3:4b"
```

Run `./configure.sh` for an interactive setup wizard that will guide you through all options.

### Customizing for Your Setup

The configuration is flexible and supports:
- **1 or more GPUs**: Set `FRANKEN_GPU_COUNT` to match your hardware
- **Custom models**: Choose any Ollama-compatible model for each GPU
- **Different GPU sizes**: Optimize model selection based on VRAM
- **Local or remote**: Works on localhost or over SSH

Example configurations:

**Single GPU Setup:**
```bash
FRANKEN_GPU_COUNT=1
FRANKEN_GPU0_MODEL="gemma3:12b"
```

**Different Model Families:**
```bash
FRANKEN_GPU0_MODEL="llama3.2"      # Meta's Llama on GPU 0
FRANKEN_GPU1_MODEL="mistral:7b"    # Mistral on GPU 1
```

**Code-focused Setup:**
```bash
FRANKEN_GPU0_MODEL="codellama:13b"
FRANKEN_GPU1_MODEL="deepseek-coder:6.7b"
```

---

## 🩺 GPU Health Monitoring

FrankenLLM includes automatic GPU health monitoring that detects and fixes common NVIDIA driver issues.

### Health Check Commands

```bash
# Full health check (GPU, drivers, services, disk, RAM)
frankenllm health

# Quick pass/fail check
frankenllm health quick

# Or use manage.sh
./manage.sh health
./manage.sh health quick
```

### Auto-Fix on Boot

The health module automatically:
1. Checks GPU health on every boot (before Ollama starts)
2. Detects driver/library version mismatches
3. Attempts to reload NVIDIA modules to fix issues
4. Reboots up to 3 times if fixes fail
5. Creates a login alert if issues persist

### Manual Fix Commands

```bash
# Attempt to fix GPU issues manually
frankenllm fix

# View auto-fix status (failure count, last error)
frankenllm autofix-status

# Clear alerts after manual fix
frankenllm reset-alerts
```

### Installing Health Module (Existing Systems)

If you installed FrankenLLM before v1.2.0, add the health module:

```bash
# Full installation (recommended)
sudo ./scripts/install-health-module.sh install

# Check installation status
./scripts/install-health-module.sh status

# Uninstall
sudo ./scripts/install-health-module.sh uninstall
```

---

## 🔍 Troubleshooting

### Port 11434 Already in Use / GPU0 Won't Start

**Symptom**: `ollama-gpu0` service keeps restarting with "address already in use" error

**Cause**: The default `ollama.service` (installed by Ollama's official installer) is running and grabbing port 11434 before FrankenLLM's `ollama-gpu0` can start.

**Solution**:
```bash
# Check what's using the port
sudo ss -tlnp | grep 11434
# If you see 127.0.0.1:11434, the default service is the culprit

# Stop, disable, and MASK the default service permanently
sudo systemctl stop ollama.service
sudo systemctl disable ollama.service
sudo rm -f /etc/systemd/system/ollama.service
sudo systemctl daemon-reload
sudo systemctl mask ollama.service

# Restart FrankenLLM GPU0
sudo systemctl restart ollama-gpu0
```

> 💡 **Why mask?** Masking creates a symlink to `/dev/null`, permanently preventing the service from starting - even after system updates or Ollama updates that might try to re-enable it. FrankenLLM's install scripts do this automatically since v1.2.0.

### NVIDIA Driver/Library Version Mismatch

**Symptom**: `nvidia-smi` fails with "Driver/library version mismatch"

**Cause**: Driver was updated but system wasn't rebooted

**Solution**:
```bash
# Option 1: Let auto-fix handle it (if health module installed)
frankenllm fix

# Option 2: Reboot
sudo reboot

# Option 3: Manual module reload (if GPUs not in use)
sudo systemctl stop ollama-gpu0 ollama-gpu1
sudo rmmod nvidia_uvm nvidia_drm nvidia_modeset nvidia
sudo modprobe nvidia
sudo systemctl start ollama-gpu0 ollama-gpu1
```

### Services won't start

```bash
# Check service status
./manage.sh status

# View logs
./manage.sh logs

# Manually check systemd
ssh YOUR_SERVER  # if remote
sudo systemctl status ollama-gpu0
sudo systemctl status ollama-gpu1
```

### Slow first response / health check lag

**Problem**: First API call is slow (10-30 seconds), or queries become slow after a few minutes of inactivity.

**Cause**: 
1. Models aren't loaded into GPU memory yet (first call triggers loading)
2. Ollama unloads idle models after 5 minutes by default

**Solution**: 

**Step 1 - Enable Keep-Alive** (keeps models loaded indefinitely):

```bash
# For existing installations
./bin/enable-keep-alive.sh

# New installations (v1.1.0+) have this enabled automatically
```

**Step 2 - Warmup Models** (loads models into memory):

```bash
./bin/warmup-models.sh
```

For automatic warmup on boot, see [Auto-Warmup Guide](docs/AUTO_WARMUP.md).

> 💡 **Why both?** Keep-alive prevents unloading, warmup loads models on boot. Together they ensure instant responses 24/7.

### Models not responding

```bash
# Verify services are online
./bin/health-check.sh

# Check if models are installed
curl http://YOUR_IP:11434/api/tags
curl http://YOUR_IP:11435/api/tags

# Warm up models
./bin/warmup-models.sh

# Restart services if needed
./manage.sh restart
```

### Out of memory errors

- Use smaller models for 8GB GPU (4b or smaller)
- Reduce context window size in your API calls
- Consider using quantized versions

---

## 📚 Why Gemma 3?

**Google Gemma 3** (Released March 2025) offers:
- 🖼️ **Multimodal**: Can process both text AND images (4B, 12B, 27B sizes)
- 📏 **128K Context**: Massive context window for large documents
- ⚡ **Efficient**: Sliding window attention for better performance
- 🎯 **Perfect Sizes**: 4B fits 8GB, 12B fits 16GB perfectly
- 🆓 **Open Weights**: Commercial-friendly license

Available sizes: 270M, 1B, **4B**, **12B**, 27B

---

## 🤝 Contributing

Found a bug? Want to add a feature? PRs welcome!

### Contribution Guidelines

- Follow clean code practices and shell scripting best practices
- Test your changes on both local and remote setups
- Add comments to complex logic
- Update relevant documentation in `docs/`
- Ensure scripts are executable and have proper shebangs
- Test with different GPU configurations when possible

---

## 📚 Documentation

Complete documentation is available in the [`docs/`](docs/) directory:

### 📘 Getting Started

- **[Installation Workflows](docs/WORKFLOWS.md)** - 🔀 Choose between Super Installer vs Manual Mode
- **[Getting Started Guide](docs/GETTING_STARTED.md)** - 🚀 Complete setup guide for new users
- **[Super Installer Guide](docs/SUPER_INSTALLER.md)** - ⚡ Using the one-command installer

### 📚 Core Guides

- **[Configuration Guide](docs/CONFIGURATION.md)** - ⚙️ Complete configuration reference with examples
- **[Auto-Warmup Setup](docs/AUTO_WARMUP.md)** - 🔥 Keep models loaded and ready on boot
- **[Open WebUI Integration](docs/OPEN_WEBUI.md)** - 🌐 Web interface and N8n automation
- **[Remote Management](docs/REMOTE_MANAGEMENT.md)** - 🌐 SSH and remote server setup
- **[GPU Upgrade Guide](docs/GPU_UPGRADE.md)** - 🔧 Replace, add, or reconfigure GPUs
- **[Quick Start Reference](docs/QUICKSTART.md)** - ⚡ Fast command reference

### 📋 Additional Resources

- **[Full Documentation](docs/README.md)** - Complete documentation with all features
- **[Q&A Document](docs/QUESTIONS_ANSWERED.md)** - Common questions answered
- **[Historical Docs](docs/archive/)** - Past troubleshooting and reorganization notes

### Quick Links

- 🚀 **[Getting Started](#-quick-start)**
- 🎯 **[Recommended Models](#-recommended-models)**
- 🎮 **[Usage Guide](#-usage)**
- 🔧 **[Configuration](#️-configuration)**
- 🔍 **[Troubleshooting](#-troubleshooting)**

---

## 🆘 Support

If you encounter any issues or have questions:

1. **Check Documentation**: Review the docs in [`docs/`](docs/) directory
2. **GPU Detection**: Run `./bin/check-gpus.sh` to verify GPU configuration
3. **Health Check**: Use `./bin/health-check.sh` to verify services are online
4. **Service Logs**: Check logs with `./manage.sh logs` (external terminal)
5. **Model Issues**: Run `./bin/warmup-models.sh` to pre-load correct models
6. **SSH Problems**: See [Remote Management Guide](docs/REMOTE_MANAGEMENT.md)
7. **Open an Issue**: If problems persist, [open a GitHub issue](https://github.com/ChiefGyk3D/FrankenLLM/issues)

---

## 📜 License

This Source Code Form is subject to the terms of the Mozilla Public License, v. 2.0.
If a copy of the MPL was not distributed with this file, You can obtain one at https://mozilla.org/MPL/2.0/.

SPDX-License-Identifier: MPL-2.0

---

## 🙏 Credits

- Built on [Ollama](https://ollama.com/)
- Inspired by the need to utilize all available GPU resources
- Named after Frankenstein's monster: stitched together from parts, but it works!

---

## 💝 Donations and Tips

If you find FrankenLLM useful, consider supporting development:

**Donate**:

<div align="center">
  <table>
    <tr>
      <td align="center"><a href="https://patreon.com/chiefgyk3d?utm_medium=unknown&utm_source=join_link&utm_campaign=creatorshare_creator&utm_content=copyLink" title="Patreon"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/patreon.svg" width="32" height="32" alt="Patreon"/></a></td>
      <td align="center"><a href="https://streamelements.com/chiefgyk3d/tip" title="StreamElements"><img src="media/streamelements.png" width="32" height="32" alt="StreamElements"/></a></td>
    </tr>
    <tr>
      <td align="center">Patreon</td>
      <td align="center">StreamElements</td>
    </tr>
  </table>
</div>

### Cryptocurrency Tips

<div align="center">
  <table style="border:none;">
    <tr>
      <td align="center" style="padding:8px; min-width:120px;">
        <img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/bitcoin.svg" width="28" height="28" alt="Bitcoin"/>
      </td>
      <td align="left" style="padding:8px;">
        <b>Bitcoin</b><br/>
        <code style="font-size:12px;">bc1qztdzcy2wyavj2tsuandu4p0tcklzttvdnzalla</code>
      </td>
    </tr>
    <tr>
      <td align="center" style="padding:8px; min-width:120px;">
        <img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/monero.svg" width="28" height="28" alt="Monero"/>
      </td>
      <td align="left" style="padding:8px;">
        <b>Monero</b><br/>
        <code style="font-size:12px;">84Y34QubRwQYK2HNviezeH9r6aRcPvgWmKtDkN3EwiuVbp6sNLhm9ffRgs6BA9X1n9jY7wEN16ZEpiEngZbecXseUrW8SeQ</code>
      </td>
    </tr>
    <tr>
      <td align="center" style="padding:8px; min-width:120px;">
        <img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/ethereum.svg" width="28" height="28" alt="Ethereum"/>
      </td>
      <td align="left" style="padding:8px;">
        <b>Ethereum</b><br/>
        <code style="font-size:12px;">0x554f18cfB684889c3A60219BDBE7b050C39335ED</code>
      </td>
    </tr>
  </table>
</div>

---

<div align="center">

Made with ❤️ by [ChiefGyk3D](https://github.com/ChiefGyk3D)

## Author & Socials

<table>
  <tr>
    <td align="center"><a href="https://social.chiefgyk3d.com/@chiefgyk3d" title="Mastodon"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/mastodon.svg" width="32" height="32" alt="Mastodon"/></a></td>
    <td align="center"><a href="https://bsky.app/profile/chiefgyk3d.com" title="Bluesky"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/bluesky.svg" width="32" height="32" alt="Bluesky"/></a></td>
    <td align="center"><a href="http://twitch.tv/chiefgyk3d" title="Twitch"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/twitch.svg" width="32" height="32" alt="Twitch"/></a></td>
    <td align="center"><a href="https://www.youtube.com/channel/UCvFY4KyqVBuYd7JAl3NRyiQ" title="YouTube"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/youtube.svg" width="32" height="32" alt="YouTube"/></a></td>
    <td align="center"><a href="https://kick.com/chiefgyk3d" title="Kick"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/kick.svg" width="32" height="32" alt="Kick"/></a></td>
    <td align="center"><a href="https://www.tiktok.com/@chiefgyk3d" title="TikTok"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/tiktok.svg" width="32" height="32" alt="TikTok"/></a></td>
    <td align="center"><a href="https://discord.chiefgyk3d.com" title="Discord"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/discord.svg" width="32" height="32" alt="Discord"/></a></td>
    <td align="center"><a href="https://matrix-invite.chiefgyk3d.com" title="Matrix"><img src="https://cdn.jsdelivr.net/gh/simple-icons/simple-icons/icons/matrix.svg" width="32" height="32" alt="Matrix"/></a></td>
  </tr>
  <tr>
    <td align="center">Mastodon</td>
    <td align="center">Bluesky</td>
    <td align="center">Twitch</td>
    <td align="center">YouTube</td>
    <td align="center">Kick</td>
    <td align="center">TikTok</td>
    <td align="center">Discord</td>
    <td align="center">Matrix</td>
  </tr>
</table>

</div>
