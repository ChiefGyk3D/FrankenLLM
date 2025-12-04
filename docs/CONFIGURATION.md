# Configuration Guide

## Overview

FrankenLLM uses a flexible configuration system that allows you to customize:
- Number of GPUs (1 or more)
- Models to run on each GPU
- Ports and network settings
- GPU names and display preferences

## Quick Setup

Run the interactive configuration wizard:

```bash
./configure.sh
```

This will create a `.env` file with all your settings.

## Configuration Options

### Server Configuration

```bash
# Set to "localhost" for local installation
# Set to IP address for remote installation
FRANKEN_SERVER_IP=192.168.201.145

# Installation directory on the target server
FRANKEN_INSTALL_DIR=/opt/frankenllm
```

### GPU Configuration

```bash
# Number of GPUs to use (1 or more, defaults to 2)
FRANKEN_GPU_COUNT=2
```

### Port Configuration

```bash
# Each GPU's Ollama instance needs its own port
FRANKEN_GPU0_PORT=11434
FRANKEN_GPU1_PORT=11435
# Add FRANKEN_GPU2_PORT, etc. for additional GPUs
```

### GPU Names

```bash
# Display names for your GPUs (optional)
FRANKEN_GPU0_NAME="RTX 5060 Ti"
FRANKEN_GPU1_NAME="RTX 3050"
```

### Model Configuration

**This is the key to ensuring the correct model loads on each GPU!**

```bash
# Specify which models to use on each GPU
FRANKEN_GPU0_MODEL="gemma3:12b"
FRANKEN_GPU1_MODEL="gemma3:4b"
```

**How Model Configuration Works:**

1. **Isolated Model Storage** (v2.0+):
   - Each GPU has its own model directory
   - GPU 0 models: `~/.ollama/models-gpu0`
   - GPU 1 models: `~/.ollama/models-gpu1`
   - Models added to one GPU won't appear on another

2. **Add Models to Specific GPUs**:
   ```bash
   ./bin/add-model.sh 0 gemma3:12b   # Add to GPU 0
   ./bin/add-model.sh 1 gemma3:4b    # Add to GPU 1
   ./bin/add-model.sh                 # Interactive mode
   ./bin/add-model.sh list            # List models per GPU
   ```

3. **Warmup Configuration**:
   ```bash
   ./bin/warmup-config.sh set         # Choose warmup models interactively
   ./bin/warmup-config.sh warmup      # Load models into GPU memory
   ./bin/warmup-config.sh status      # Check what's loaded
   ```

4. **Test Script** (`./bin/test-llm.sh`):
   - Uses configured models by default
   - Falls back to auto-detection if not configured
   - Shows which model it's using before running queries

5. **Health Check** (`./bin/health-check.sh`):
   - Displays your preferred model for each GPU
   - Shows all installed models
   - Helps verify correct configuration

## Example Configurations

### Single GPU Setup

Perfect for testing or single-GPU systems:

```bash
FRANKEN_GPU_COUNT=1
FRANKEN_GPU0_PORT=11434
FRANKEN_GPU0_NAME="RTX 4090"
FRANKEN_GPU0_MODEL="gemma3:27b"
```

### Dual GPU - Size Optimized

Maximize each GPU's capabilities:

```bash
FRANKEN_GPU_COUNT=2

# 16GB GPU
FRANKEN_GPU0_NAME="RTX 5060 Ti"
FRANKEN_GPU0_PORT=11434
FRANKEN_GPU0_MODEL="gemma3:12b"

# 8GB GPU
FRANKEN_GPU1_NAME="RTX 3050"
FRANKEN_GPU1_PORT=11435
FRANKEN_GPU1_MODEL="gemma3:4b"
```

### Code-Focused Setup

Specialized models for programming:

```bash
FRANKEN_GPU_COUNT=2

FRANKEN_GPU0_NAME="RTX 4060 Ti"
FRANKEN_GPU0_MODEL="codellama:13b"

FRANKEN_GPU1_NAME="RTX 3060"
FRANKEN_GPU1_MODEL="deepseek-coder:6.7b"
```

### Multi-Model Serving

Different model families on different GPUs:

```bash
FRANKEN_GPU_COUNT=2

# Meta's Llama
FRANKEN_GPU0_MODEL="llama3.2"

# Mistral
FRANKEN_GPU1_MODEL="mistral:7b-instruct"
```

### Triple GPU Setup

For systems with 3+ GPUs:

```bash
FRANKEN_GPU_COUNT=3

FRANKEN_GPU0_PORT=11434
FRANKEN_GPU0_NAME="RTX 4090"
FRANKEN_GPU0_MODEL="gemma3:27b"

FRANKEN_GPU1_PORT=11435
FRANKEN_GPU1_NAME="RTX 4060 Ti"
FRANKEN_GPU1_MODEL="gemma3:12b"

FRANKEN_GPU2_PORT=11436
FRANKEN_GPU2_NAME="RTX 3060"
FRANKEN_GPU2_MODEL="gemma3:4b"
```

## Recommended Models by VRAM

### 32GB+ VRAM
- `llama3.1:70b-instruct-q4_0` ⭐ **Meta's flagship** - Top capability
- `gemma3:27b` - Google's largest, multimodal
- `qwen2.5:32b` - Excellent reasoning
- `mixtral:8x7b` - Mixture of experts
- `deepseek-coder:33b-instruct` - Premium code generation

### 24GB VRAM
- `gemma3:27b` ⭐ **Recommended** - Largest Gemma 3, perfect fit
- `llama3.1:45b-instruct-q4_0` - High capability quantized
- `qwen2.5:14b` - Excellent multilingual
- `deepseek-coder:33b-instruct-q4_0` - Professional coding
- `mistral:22b` - Great all-rounder

### 16GB VRAM
- `gemma3:12b` ⭐ **Recommended** - Perfect fit
- `gemma2:9b` - Stable alternative
- `codellama:13b` - For programming
- `llama3.2` - General purpose
- `mistral:7b-instruct` - Great for instructions

### 12GB VRAM
- `gemma3:12b` - Fits with some room
- `mistral:7b-instruct` - Great performance
- `llama3.2:7b` - Good all-rounder
- `deepseek-coder:6.7b` - Coding specialist

### 8GB VRAM
- `gemma3:4b` ⭐ **Recommended** - Perfect fit
- `gemma2:2b` - Smaller, faster
- `phi3:3.8b` - Microsoft's efficient model
- `llama3.2:3b` - Compact Llama
- `qwen:4b` - Good multilingual

### 6GB VRAM
- `gemma3:1b` - Ultra-fast
- `gemma2:2b` - Good quality
- `phi3:mini` - Very efficient
- `tinyllama` - Extremely compact

## Workflow

### Initial Setup

1. **Configure**: `./configure.sh`
   - Set GPU count, models, ports

2. **Install**: `./install.sh`
   - Sets up Ollama services

3. **Pull Models**: `./bin/pull-dual-models.sh gemma3:12b gemma3:4b`
   - Downloads the models you specified

4. **Warm Up**: `./bin/warmup-models.sh`
   - Loads models into GPU memory
   - Uses your configured models

5. **Test**: `./bin/test-llm.sh`
   - Verifies everything works
   - Uses your configured models

### Daily Usage

```bash
# Check status
./bin/health-check.sh

# Warm up models (after restart)
./bin/warmup-models.sh

# Test queries
./bin/test-llm.sh "Your question here"
```

## Troubleshooting

### Wrong Model Loading

**Problem**: GPU keeps loading the wrong model

**Solution**: 
1. Check your `.env` file has the correct `FRANKEN_GPU0_MODEL` and `FRANKEN_GPU1_MODEL`
2. Run `./bin/warmup-models.sh` to explicitly load configured models
3. Verify with `./bin/health-check.sh` to see preferred vs installed models

### Model Not Found

**Problem**: Warmup script says "Failed to load model"

**Solution**:
1. Check the model is installed: `curl http://SERVER:11434/api/tags`
2. Pull the model if missing: `./bin/pull-model.sh gemma3:12b`
3. Check spelling matches Ollama's model name exactly

### Single GPU Not Working

**Problem**: Scripts expect 2 GPUs but you only have 1

**Solution**:
1. Edit `.env` and set `FRANKEN_GPU_COUNT=1`
2. Re-run scripts - they'll skip GPU 1 operations
3. Or run `./configure.sh` and specify 1 GPU

## Advanced Configuration

### Custom Ports

Need different ports? Edit `.env`:

```bash
FRANKEN_GPU0_PORT=8080
FRANKEN_GPU1_PORT=8081
```

### Remote Installation

For remote servers:

```bash
FRANKEN_SERVER_IP=192.168.1.100  # Your server IP
# Scripts will use SSH automatically
```

### Local Installation

For running on this machine:

```bash
FRANKEN_SERVER_IP=localhost
# Scripts will run commands directly
```

## Environment Variables

All configuration is loaded from `.env` through `config.sh`:

```bash
# Core
FRANKEN_SERVER_IP      # Server location
FRANKEN_INSTALL_DIR    # Install path
FRANKEN_GPU_COUNT      # Number of GPUs

# Per-GPU settings
FRANKEN_GPU0_PORT      # Port for GPU 0
FRANKEN_GPU0_NAME      # Display name for GPU 0
FRANKEN_GPU0_MODEL     # Model for GPU 0

FRANKEN_GPU1_PORT      # Port for GPU 1
FRANKEN_GPU1_NAME      # Display name for GPU 1
FRANKEN_GPU1_MODEL     # Model for GPU 1
# etc...
```

## Best Practices

1. **Always configure models** - Set `FRANKEN_GPU*_MODEL` to avoid auto-detection issues
2. **Match VRAM** - Choose models that fit comfortably in each GPU's memory
3. **Use warmup** - Run `./bin/warmup-models.sh` after service restarts
4. **Test configuration** - Use `./bin/health-check.sh` to verify settings
5. **Document changes** - Note your model choices and why (performance, quality, etc.)

## Migration from Old Setup

If you have an existing installation without model configuration:

1. **Backup**: `cp .env .env.backup`
2. **Add model config**: Edit `.env` and add:
   ```bash
   FRANKEN_GPU_COUNT=2
   FRANKEN_GPU0_MODEL="gemma3:12b"
   FRANKEN_GPU1_MODEL="gemma3:4b"
   ```
3. **Warm up**: `./bin/warmup-models.sh`
4. **Verify**: `./bin/health-check.sh`

Your existing models and services remain unchanged - you're just adding explicit configuration.

---

**Need help?** See [README.md](../README.md) or [REMOTE_MANAGEMENT.md](REMOTE_MANAGEMENT.md)
