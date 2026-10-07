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
# Specify which models to use on each GPU (gemma4 models require Ollama >= 0.33)
FRANKEN_GPU0_MODEL="gemma4:12b"
FRANKEN_GPU1_MODEL="qwen3.5:4b"

# Guard/moderation model kept resident on GPU 0 alongside the main model
# (e.g. for AI moderation bots; set empty to skip during warmup)
FRANKEN_GPU0_GUARD_MODEL="llama-guard3:8b"

# Per-instance context length, written to OLLAMA_CONTEXT_LENGTH in the
# systemd units by scripts/install-ollama-native.sh
FRANKEN_GPU0_CONTEXT=8192
FRANKEN_GPU1_CONTEXT=32768
```

Optional extras (all empty/unset by default, which leaves the layout above
unchanged) are covered in [Per-Model Layout and Context](#per-model-layout-and-context).

**Dual-resident VRAM budget (16GB GPU):** Ollama >= 0.33 defaults to a 32768
context, and the KV cache scales with it (~130MB per 1K tokens for an 8B
model). Measured on an RTX 5060 Ti 16GB: `gemma4:12b` + `llama-guard3:8b`
both stay resident at 8192 context (~14.2GB); at 16384 the guard evicts the
main model. If you change models, re-check with `ollama ps` that both show
`100% GPU` after warmup.

**How Model Configuration Works:**

1. **Isolated Model Storage** (v2.0+):
   - Each GPU has its own model directory
   - GPU 0 models: `~/.ollama/models-gpu0`
   - GPU 1 models: `~/.ollama/models-gpu1`
   - Models added to one GPU won't appear on another

2. **Add Models to Specific GPUs**:
   ```bash
   ./bin/add-model.sh 0 gemma4:12b   # Add to GPU 0
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
FRANKEN_GPU0_MODEL="gemma4:12b"

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
FRANKEN_GPU1_MODEL="gemma4:12b"

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
- `gemma4:26b` ⭐ **Recommended** - Gemma 4 MoE (26B, A4B active), requires Ollama >= 0.33
- `gemma3:27b` - Largest Gemma 3, perfect fit
- `llama3.1:45b-instruct-q4_0` - High capability quantized
- `qwen2.5:14b` - Excellent multilingual
- `deepseek-coder:33b-instruct-q4_0` - Professional coding
- `mistral:22b` - Great all-rounder

### 16GB VRAM
- `gemma4:12b` ⭐ **Recommended** - Perfect fit (requires Ollama >= 0.33); coexists with `llama-guard3:8b` at 8192 context
- `gemma3:12b` - Previous generation, still excellent
- `gemma2:9b` - Stable alternative
- `codellama:13b` - For programming
- `llama3.2` - General purpose
- `mistral:7b-instruct` - Great for instructions

### 12GB VRAM
- `gemma4:12b` - Fits with some room
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

3. **Pull Models**: `./bin/pull-dual-models.sh gemma4:12b gemma3:4b`
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
2. Pull the model if missing: `./bin/pull-model.sh gemma4:12b`
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

# Dual-resident and context settings
FRANKEN_GPU0_GUARD_MODEL  # Guard/moderation model warmed alongside GPU 0's main model (empty = off)
FRANKEN_GPU0_CONTEXT      # OLLAMA_CONTEXT_LENGTH for GPU 0's instance (default 8192)
FRANKEN_GPU1_CONTEXT      # OLLAMA_CONTEXT_LENGTH for GPU 1's instance (default 32768)

# Per-model layout (all default empty = off / instance context)
FRANKEN_GPU1_GUARD_MODEL    # Guard model warmed on GPU 1
FRANKEN_GPU0_GUARD_CONTEXT  # num_ctx for the GPU 0 guard (empty = FRANKEN_GPU0_CONTEXT)
FRANKEN_GPU1_GUARD_CONTEXT  # num_ctx for the GPU 1 guard (empty = FRANKEN_GPU1_CONTEXT)
FRANKEN_GPU0_EXTRA_MODEL    # Second resident model on GPU 0
FRANKEN_GPU0_EXTRA_CONTEXT  # num_ctx for that model (empty = FRANKEN_GPU0_CONTEXT)
FRANKEN_GPU0_WARMUP_TIMEOUT # Seconds to wait for a GPU 0 load (default 180)
FRANKEN_GPU1_WARMUP_TIMEOUT # Seconds to wait for a GPU 1 load (default 120)
```

## Per-Model Layout and Context

### How warm-up loads a model

`./bin/warmup-models.sh` loads every model with two extra request fields:

- `options.num_ctx`: the model's own context setting, falling back to its
  instance's (`FRANKEN_GPU0_CONTEXT` / `FRANKEN_GPU1_CONTEXT`).
- `keep_alive: -1`: keep it resident.

| Model | Context used |
|-------|--------------|
| `FRANKEN_GPU0_MODEL` | `FRANKEN_GPU0_CONTEXT` |
| `FRANKEN_GPU0_GUARD_MODEL` | `FRANKEN_GPU0_GUARD_CONTEXT`, else `FRANKEN_GPU0_CONTEXT` |
| `FRANKEN_GPU0_EXTRA_MODEL` | `FRANKEN_GPU0_EXTRA_CONTEXT`, else `FRANKEN_GPU0_CONTEXT` |
| `FRANKEN_GPU1_MODEL` | `FRANKEN_GPU1_CONTEXT` |
| `FRANKEN_GPU1_GUARD_MODEL` | `FRANKEN_GPU1_GUARD_CONTEXT`, else `FRANKEN_GPU1_CONTEXT` |

`FRANKEN_GPUn_CONTEXT` is also `OLLAMA_CONTEXT_LENGTH` for that whole instance,
so it is the context any client gets when it does not send `num_ctx`.

> **Clients must send the same `num_ctx` that warm-up used.** Ollama keys a
> loaded model on its context size. A request with a different `num_ctx` (or none,
> when the model was warmed at a non-default size) makes Ollama unload and reload
> the model, which costs the load time and can evict a neighbour. For a model
> warmed at a per-model size, set that size in the client (for example
> `"options": {"num_ctx": 8192}` in the API, or Advanced Params > Context Length in
> Open WebUI).

### Cheap tasks: send `think: false`

Qwen3.5 thinks by default. For one-sentence tasks (classification, titles,
summaries) turn it off per request:

```bash
curl -s http://$FRANKEN_SERVER_IP:11434/api/chat -d '{
  "model": "qwen3.5:4b",
  "messages": [{"role": "user", "content": "Summarize in one sentence: ..."}],
  "think": false,
  "stream": false,
  "options": {"num_ctx": 8192}
}'
```

Measured on 2026-10-07, a one-sentence Qwen3.5 task cost about 15x fewer
tokens with thinking off than with it on.

### Worked example: 16 GB card + 8 GB card

Layout: the backbone model alone at a large context on the large card, next to a
small cheap-task model; the guard model by itself on the small card.

```bash
# GPU 0 (16 GB): backbone at a large context + a small extra model
FRANKEN_GPU0_MODEL="gemma4:12b"
FRANKEN_GPU0_CONTEXT=65536
FRANKEN_GPU0_GUARD_MODEL=              # explicitly empty: the guard moves to GPU 1
FRANKEN_GPU0_EXTRA_MODEL="qwen3.5:4b"
FRANKEN_GPU0_EXTRA_CONTEXT=8192

# GPU 1 (8 GB): the guard model alone
FRANKEN_GPU1_MODEL="llama-guard3:8b"
FRANKEN_GPU1_CONTEXT=8192
```

`FRANKEN_GPU1_MODEL` is always warmed, so on a guard-only card the guard is simply
that card's main model. `FRANKEN_GPU1_GUARD_MODEL` is for a card that also hosts a
main model next to its guard.

**VRAM caveat:** the sizes above are estimates. The KV cache grows with context
(roughly 130 MB per 1K tokens for an 8B model), so 65536 on the 16 GB card is the
number most likely to need lowering. After warm-up, confirm with `ollama ps`
(both should show `100% GPU`) and `nvidia-smi`. If the backbone and the extra
model do not both fit, lower `FRANKEN_GPU0_CONTEXT` or drop the extra model.

### Migrating an existing install to this layout

1. Back up: `cp .env .env.backup`
2. Edit `.env` on the server: apply the variables from the worked example
   (change `FRANKEN_GPU0_CONTEXT` and `FRANKEN_GPU1_CONTEXT`, set
   `FRANKEN_GPU0_GUARD_MODEL=` empty, set `FRANKEN_GPU0_EXTRA_MODEL` and
   `FRANKEN_GPU1_MODEL`). Keep `FRANKEN_SERVER_IP=localhost` in the deployed `.env`.
3. Pull what is new on the right card, for example
   `./bin/add-model.sh 1 llama-guard3:8b` and `./bin/add-model.sh 0 qwen3.5:4b`.
4. Write the new `OLLAMA_CONTEXT_LENGTH` into the systemd units, then restart
   **both** instances (a context change only takes effect on restart). Either
   re-run `./scripts/install-ollama-native.sh` (it rewrites the unit files from
   `.env`, and also re-runs the Ollama installer), or edit the
   `Environment="OLLAMA_CONTEXT_LENGTH=..."` line in
   `/etc/systemd/system/ollama-gpu0.service` and `ollama-gpu1.service` by hand:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl restart ollama-gpu0 ollama-gpu1
   ```
5. Re-run warm-up: `./bin/warmup-models.sh`
6. Verify what is resident and at what size, on each instance:
   ```bash
   curl -s http://localhost:11434/api/ps | jq '.models[] | {name, size_vram, context_length}'
   curl -s http://localhost:11435/api/ps | jq '.models[] | {name, size_vram, context_length}'
   ```
   `size_vram` should equal `size` for every model (fully on GPU), and
   `context_length` should match the contexts you set (if your Ollama version
   does not report it, use `ollama ps`).
7. Update every client to send the matching `num_ctx` (see above).

Existing installs that change nothing keep their layout: the new variables default
to empty, so the same models load at the same contexts as before. The only visible
differences are the explicit `num_ctx`/`keep_alive` fields in the warm-up request,
which equal what the instance already used, and the new default
`FRANKEN_GPU1_MODEL` of `qwen3.5:4b` for installs that never set it.

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
   FRANKEN_GPU0_MODEL="gemma4:12b"
   FRANKEN_GPU1_MODEL="qwen3.5:4b"
   ```
3. **Warm up**: `./bin/warmup-models.sh`
4. **Verify**: `./bin/health-check.sh`

Your existing models and services remain unchanged - you're just adding explicit configuration.

---

**Need help?** See [README.md](../README.md) or [REMOTE_MANAGEMENT.md](REMOTE_MANAGEMENT.md)
