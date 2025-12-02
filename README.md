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

### RTX 5060 Ti (16GB VRAM)
- `llama3.2` (8B parameters)
- `mistral` (7B parameters)
- `llama3:8b-instruct-q4_0` (4-bit quantized)
- `codellama:13b` (with quantization)

### RTX 3050 (8GB VRAM)
- `llama3.2:1b` (1B parameters)
- `llama3.2:3b` (3B parameters)
- `phi3` (3.8B parameters)
- `gemma:2b` (2B parameters)

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
