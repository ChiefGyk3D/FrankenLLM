# 🧟 FrankenLLM

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

---

## 📁 Project Structure

```
frankenllm/
├── install.sh              # 🚀 Main installer (auto-detects local/remote)
├── manage.sh               # 🎛️  Main service manager
├── configure.sh            # ⚙️  Configuration wizard
├── config.sh               # 📝 Configuration loader
├── .env.example            # 📋 Configuration template
│
├── bin/                    # 🔧 Core utilities
│   ├── check-gpus.sh       #    Check GPU configuration
│   ├── health-check.sh     #    Test service connectivity
│   ├── pull-model.sh       #    Pull same model on both GPUs
│   ├── pull-dual-models.sh #    Pull different models per GPU
│   └── test-llm.sh         #    Test both LLMs with a query
│
├── local/                  # 💻 Local installation scripts
│   ├── install.sh          #    Install on THIS machine
│   └── manage.sh           #    Manage local services
│
└── remote/                 # 🌐 Remote installation scripts
    ├── install.sh          #    Install on remote server via SSH
    └── manage.sh           #    Manage remote services via SSH
```

---

## 🚀 Quick Start

### 1. Configure Your Environment

```bash
./configure.sh
```

This creates a `.env` file with:
- Server IP (localhost or remote IP like 192.168.201.145)
- GPU ports (default: 11434, 11435)
- GPU names (optional)

### 2. Install Ollama Services

```bash
./install.sh
```

Auto-detects local or remote from your configuration and:
- Installs Ollama
- Creates systemd services for each GPU
- Starts and enables services

### 3. Pull Models

```bash
# Pull different models optimized for each GPU
./bin/pull-dual-models.sh gemma3:12b gemma3:4b

# Or pull the same model on both
./bin/pull-model.sh gemma2:9b
```

### 4. Test Your Setup

```bash
./bin/health-check.sh
./bin/test-llm.sh "What is your purpose?"
```

---

## 📊 Recommended Models

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

**All Gemma 3 (Latest!):**
```bash
./bin/pull-dual-models.sh gemma3:12b gemma3:4b
```

**Fast Combo:**
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

### Health Monitoring

```bash
# Quick health check (no sudo required)
./bin/health-check.sh

# Detailed GPU information
./bin/check-gpus.sh
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

# Port Configuration
FRANKEN_GPU0_PORT=11434
FRANKEN_GPU1_PORT=11435

# GPU Names (optional, for display)
FRANKEN_GPU0_NAME="RTX 5060 Ti"
FRANKEN_GPU1_NAME="RTX 3050"
```

Run `./configure.sh` for an interactive setup.

---

## 🔍 Troubleshooting

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

### Models not responding

```bash
# Verify services are online
./bin/health-check.sh

# Check if models are installed
curl http://YOUR_IP:11434/api/tags
curl http://YOUR_IP:11435/api/tags

# Restart services
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

---

## 📜 License

MIT License - see LICENSE file

---

## 🙏 Credits

- Built on [Ollama](https://ollama.com/)
- Inspired by the need to utilize all available GPU resources
- Named after Frankenstein's monster: stitched together from parts, but it works!

---

**⚡ FrankenLLM: Because one GPU is never enough! ⚡**
