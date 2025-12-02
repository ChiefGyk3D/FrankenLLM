# FrankenLLM 🧟

**Stitched-together GPUs, but it lives!**

Multi-GPU LLM Server Setup

Server: **192.168.201.x** (local testnet)

## GPU Configuration
- **GPU 0**: NVIDIA GeForce RTX 5060 Ti (16GB VRAM)
- **GPU 1**: NVIDIA GeForce RTX 3050 (8GB VRAM)
- **Driver**: 580.95.05
- **CUDA**: 13.0

## Quick Start (Recommended - Native Ollama)

Since Docker isn't installed, the easiest approach is to use native Ollama:

### 1. Install Ollama on both GPUs
```bash
./install-ollama-native.sh
```

This creates two systemd services:
- `ollama-gpu0` - RTX 5060 Ti on port **11434**
- `ollama-gpu1` - RTX 3050 on port **11435**

### 2. Start the services
```bash
./manage-services.sh start
```

### 3. Enable services on boot (optional)
```bash
./manage-services.sh enable
```

### 4. Pull a model on both GPUs
```bash
./pull-model.sh llama3.2
```

Available models: `llama3.2`, `llama3.2:1b`, `mistral`, `codellama`, `phi3`, etc.

### 5. Test the servers
```bash
./test-llm.sh "Write a hello world in Python"
```

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

### GPU 0 (RTX 5060 Ti) - Port 11434
```bash
# List models
curl http://192.168.201.145:11434/api/tags

# Generate response
curl -X POST http://192.168.201.145:11434/api/generate -d '{
  "model": "llama3.2",
  "prompt": "Why is the sky blue?",
  "stream": false
}'
```

### GPU 1 (RTX 3050) - Port 11435
```bash
# List models
curl http://192.168.201.145:11435/api/tags

# Generate response
curl -X POST http://192.168.201.145:11435/api/generate -d '{
  "model": "llama3.2",
  "prompt": "Why is the sky blue?",
  "stream": false
}'
```

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

### Check GPU usage
```bash
ssh 192.168.201.145 "nvidia-smi"
```

### Check if ports are listening
```bash
ssh 192.168.201.145 "ss -tlnp | grep -E '11434|11435'"
```

### View detailed logs
```bash
ssh 192.168.201.145 "sudo journalctl -u ollama-gpu0 -f"
ssh 192.168.201.145 "sudo journalctl -u ollama-gpu1 -f"
```

## Files Overview

- `install-ollama-native.sh` - Install Ollama natively (recommended)
- `install-docker.sh` - Install Docker + NVIDIA Container Toolkit
- `manage-services.sh` - Control Ollama services
- `pull-model.sh` - Download models on both GPUs
- `test-llm.sh` - Test both servers
- `check-gpus.sh` - Verify GPU configuration
- `deploy.sh` - Deploy Docker configuration
- `docker-compose.yml` - llama.cpp Docker config
- `vllm-compose.yml` - vLLM Docker config
- `ollama-compose.yml` - Ollama Docker config
