# FrankenLLM 🧟

**Stitched-together GPUs, but it lives!**

Multi-GPU LLM Server Setup - Works locally or remotely via SSH

## Configuration

FrankenLLM is now fully configurable! You can install it locally or on a remote server.

### Quick Configure

Run the interactive configuration wizard:

```bash
./configure.sh
```

This will create a `.env` file with your settings:
- Server IP (localhost for local, or remote IP like 192.168.201.145)
- Installation directory
- Port numbers for each GPU
- GPU names

### Manual Configuration

Alternatively, create a `.env` file manually or set environment variables:

```bash
# For local installation
export FRANKEN_SERVER_IP=localhost

# For remote installation
export FRANKEN_SERVER_IP=192.168.201.145

# Optional: customize ports and names
export FRANKEN_GPU0_PORT=11434
export FRANKEN_GPU1_PORT=11435
export FRANKEN_GPU0_NAME="RTX 5060 Ti"
export FRANKEN_GPU1_NAME="RTX 3050"
```

## GPU Configuration (Example)
- **GPU 0**: NVIDIA GeForce RTX 5060 Ti (16GB VRAM)
- **GPU 1**: NVIDIA GeForce RTX 3050 (8GB VRAM)
- **Driver**: 580.95.05
- **CUDA**: 13.0

## Quick Start (Recommended - Native Ollama)

### 1. Configure FrankenLLM
```bash
./configure.sh
```

### 2. Check GPU Configuration
```bash
./check-gpus.sh
```

### 3. Install Ollama on both GPUs
```bash
./install-ollama-native.sh
```

This creates two systemd services:
- `ollama-gpu0` - GPU 0 on configured port (default: 11434)
- `ollama-gpu1` - GPU 1 on configured port (default: 11435)

### 4. Start the services
```bash
./manage-services.sh start
```

### 5. Enable services on boot (optional)
```bash
./manage-services.sh enable
```

### 6. Pull a model on both GPUs
```bash
./pull-model.sh llama3.2
```

Available models: `llama3.2`, `llama3.2:1b`, `mistral`, `codellama`, `phi3`, etc.

### 7. Test the servers
```bash
./test-llm.sh "Write a hello world in Python"
```

## Installation Modes

FrankenLLM automatically detects whether you're installing locally or remotely:

### Local Installation
- Set `FRANKEN_SERVER_IP=localhost` or run `./configure.sh` and select local
- All commands run directly on your machine
- No SSH required

### Remote Installation
- Set `FRANKEN_SERVER_IP=192.168.201.145` (or your server IP)
- All commands execute via SSH
- Requires SSH access to the remote server

## Management Commands

### Check service status
```bash
./manage-services.sh status
```

### View logs
```bash
./manage-services.sh logs
```

### Restart services
```bash
./manage-services.sh restart
```

### Stop services
```bash
./manage-services.sh stop
```

## API Endpoints

The endpoints will be available at your configured server IP and ports.

### GPU 0 - Port (default: 11434)
```bash
# List models (replace SERVER_IP with your configured IP)
curl http://SERVER_IP:11434/api/tags

# Generate response
curl -X POST http://SERVER_IP:11434/api/generate -d '{
  "model": "llama3.2",
  "prompt": "Why is the sky blue?",
  "stream": false
}'
```

### GPU 1 - Port (default: 11435)
```bash
# List models
curl http://SERVER_IP:11435/api/tags

# Generate response
curl -X POST http://SERVER_IP:11435/api/generate -d '{
  "model": "llama3.2",
  "prompt": "Why is the sky blue?",
  "stream": false
}'
```

For local installations, use `localhost` as SERVER_IP.
For remote installations, use your configured IP (e.g., `192.168.201.145`).

## Alternative: Docker Installation

If you prefer Docker:

### 1. Install Docker and NVIDIA Container Toolkit
```bash
./install-docker.sh
```

### 2. Deploy with Docker Compose
```bash
./deploy.sh
ssh 192.168.201.145
cd /opt/llm-servers
docker-compose up -d
```

## Model Recommendations

### For 16GB VRAM (RTX 5060 Ti) - Larger Models

**Best General Purpose Models:**
- `llama3.2` (8B parameters) - Excellent general-purpose model, great balance
- `llama3.1:8b` (8B parameters) - Newer version with improved capabilities
- `mistral:7b-instruct` (7B parameters) - Fast and efficient, great for chat
- `gemma2:9b` (9B parameters) - **Google's Gemma 2, excellent quality**
- `qwen2.5:7b` (7B parameters) - Strong multilingual and coding

**Specialized Models:**
- `codellama:13b` (13B, quantized) - Best for code generation
- `llama3.2-vision:11b` (11B) - Multimodal with vision capabilities
- `deepseek-coder:6.7b` (6.7B) - Excellent for coding tasks
- `mixtral:8x7b` (47B MoE, heavily quantized) - Mixture of Experts model

**Google Gemma Options (Recommended!):**
- `gemma3:12b` - **NEWEST! Gemma 3 (March 2025) - Perfect for 16GB!**
- `gemma2:9b` - Gemma 2, fits perfectly in 16GB
- `gemma:7b` - Original Gemma, very capable

### For 8GB VRAM (RTX 3050) - Efficient Models

**Best Lightweight Models:**
- `llama3.2:3b` (3B parameters) - Surprisingly capable for its size
- `gemma2:2b` (2B parameters) - **Google's Gemma 2, great for 8GB**
- `phi3:3.8b` (3.8B) - Microsoft's efficient model, excellent reasoning
- `qwen2.5:3b` (3B) - Strong performance, good for multiple languages

**Smallest but Capable:**
- `llama3.2:1b` (1B parameters) - Fast responses, basic tasks
- `gemma:2b` (2B parameters) - Original Gemma, very efficient
- `tinyllama` (1.1B) - Ultra-fast, good for simple tasks
- `phi3:mini` (3.8B) - Same as phi3 but optimized

**Google Gemma Options (Recommended!):**
- `gemma3:4b` - **NEWEST! Gemma 3 (March 2025) - Perfect for 8GB!**
- `gemma3:1b` - Gemma 3 ultra-fast
- `gemma2:2b` - Gemma 2, best quality for 8GB
- `gemma:2b` - Original, still excellent

### Recommended Dual-GPU Setup

**Strategy 1: All Gemma 3 - Latest! (BEST CHOICE)**
- GPU 0 (16GB): `gemma3:12b` - **NEWEST Gemma 3 with vision support**
- GPU 1 (8GB): `gemma3:4b` - **NEWEST Gemma 3, perfect fit**

**Strategy 1b: Gemma 3 Fast Combo**
- GPU 0 (16GB): `gemma3:12b` - Main multimodal workload
- GPU 1 (8GB): `gemma3:1b` - Ultra-fast responses

**Strategy 1c: Gemma 2 (Stable)**
- GPU 0 (16GB): `gemma2:9b` - General purpose and chat
- GPU 1 (8GB): `gemma2:2b` - Quick tasks and testing

**Strategy 2: Code + General**
- GPU 0 (16GB): `codellama:13b` or `deepseek-coder:6.7b` - Coding
- GPU 1 (8GB): `phi3:3.8b` - General tasks and reasoning

**Strategy 3: All Gemma 2 (Stable, Well-Tested)**
- GPU 0 (16GB): `gemma2:9b` - Main workload
- GPU 1 (8GB): `gemma2:2b` - Fast responses

**Strategy 4: Power User**
- GPU 0 (16GB): `llama3.2` or `mistral:7b-instruct` - Main LLM
- GPU 1 (8GB): `llama3.2:3b` - Same family, faster responses

### Quick Pull Commands

For 16GB GPU (pull on GPU 0):
```bash
# Google Gemma 3 12B - NEWEST! Perfect fit for 16GB
OLLAMA_HOST=http://localhost:11434 ollama pull gemma3:12b

# Google Gemma 2 (stable, well-tested)
OLLAMA_HOST=http://localhost:11434 ollama pull gemma2:9b

# Or remotely
ssh YOUR_SERVER "OLLAMA_HOST=http://localhost:11434 ollama pull gemma3:12b"

# Other great options
ollama pull llama3.2
ollama pull mistral:7b-instruct
ollama pull codellama:13b
```

For 8GB GPU (pull on GPU 1):
```bash
# Google Gemma 3 4B - NEWEST! Perfect fit for 8GB
OLLAMA_HOST=http://localhost:11435 ollama pull gemma3:4b

# Google Gemma 3 1B - Ultra-fast
OLLAMA_HOST=http://localhost:11435 ollama pull gemma3:1b

# Google Gemma 2 (stable, well-tested)
OLLAMA_HOST=http://localhost:11435 ollama pull gemma2:2b

# Or remotely
ssh YOUR_SERVER "OLLAMA_HOST=http://localhost:11435 ollama pull gemma3:4b"

# Other great options
ollama pull llama3.2:3b
ollama pull phi3:3.8b
```

Or use the script to pull different models on each GPU:
```bash
# Latest Gemma 3 - PERFECT FIT! (12B + 4B)
./pull-dual-models.sh gemma3:12b gemma3:4b

# Latest Gemma 3 - Fast combo (12B + 1B)
./pull-dual-models.sh gemma3:12b gemma3:1b

# Stable Gemma 2
./pull-dual-models.sh gemma2:9b gemma2:2b

# Same model on both GPUs
./pull-model.sh gemma3:12b
```

### Performance Tips

**For 16GB GPU (RTX 5060 Ti):**
- **Gemma3:12b** is the perfect fit with multimodal support
- 7-12B models run smoothly with full context (4K-8K tokens)
- Can handle up to 13B models with quantization

**For 8GB GPU (RTX 3050):**
- **Gemma3:4b** is the sweet spot - newer and more capable
- 2-4B models are ideal
- Keep context window to 2K-4K tokens for best performance

**Gemma Models Advantages:**
- Trained by Google DeepMind
- Excellent instruction following
- Strong reasoning capabilities
- Open weights and commercial-friendly license
- **Gemma 3 (March 2025):** 
  - Multimodal with vision support (can process images!)
  - 128K context length
  - Improved architecture with sliding window attention
  - Available in: 270M, **1B, 4B, 12B**, 27B
  - **Gemma3:12b and Gemma3:4b are PERFECT for your GPUs!**
- Gemma 2: Better performance than original Gemma
- Progressive improvements across versions

## Troubleshooting

All scripts automatically work with your configured server (local or remote).

### Check GPU usage
```bash
./check-gpus.sh
```

### View service logs
```bash
./manage-services.sh logs
```

### Check service status
```bash
./manage-services.sh status
```

### Manual commands (if needed)
For remote servers:
```bash
ssh YOUR_SERVER_IP "nvidia-smi"
ssh YOUR_SERVER_IP "ss -tlnp | grep -E 'PORT1|PORT2'"
ssh YOUR_SERVER_IP "sudo journalctl -u ollama-gpu0 -f"
```

For local installations, run commands directly without SSH.

## Files Overview

### Configuration
- `configure.sh` - Interactive configuration wizard (creates .env)
- `config.sh` - Configuration loader (auto-loaded by all scripts)
- `.env` - Your configuration file (created by configure.sh)

### Installation Scripts
- `install-ollama-native.sh` - Install Ollama natively (recommended)
- `install-docker.sh` - Install Docker + NVIDIA Container Toolkit
- `deploy.sh` - Deploy Docker configuration

### Management Scripts
- `manage-services.sh` - Control Ollama services (start/stop/restart/status/logs)
- `pull-model.sh` - Download models on both GPUs
- `test-llm.sh` - Test both servers with a prompt
- `check-gpus.sh` - Verify GPU configuration

### Docker Compose Files
- `docker-compose.yml` - llama.cpp Docker config
- `vllm-compose.yml` - vLLM Docker config
- `ollama-compose.yml` - Ollama Docker config
