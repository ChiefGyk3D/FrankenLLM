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

Single GPU or small card? Start with
[Per-Model Layout and Context](#per-model-layout-and-context): the guard model is
optional (`FRANKEN_GPU0_GUARD_MODEL=` disables it). The extras there (all
empty/unset by default) leave the layout above unchanged.

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

### A model loads on the other instance's GPU

**Problem**: Each unit pins its card with `CUDA_VISIBLE_DEVICES`, but recent
Ollama also discovers every GPU through its Vulkan backend, and Vulkan ignores
`CUDA_VISIBLE_DEVICES`. When the pinned card looks fuller than the other one, the
scheduler can load a model onto the other card through Vulkan.

**Check**: the device each runner picked is in the journal.

```bash
journalctl -u ollama-gpu1 | grep "using device"
```

Every line names a CUDA device (`CUDA0` inside each instance, because
`CUDA_VISIBLE_DEVICES` renumbers), never Vulkan. A `Vulkan0` device is this
problem.

**Solution**: `FRANKEN_OLLAMA_VULKAN` controls the `OLLAMA_VULKAN` line that
`scripts/install-ollama-native.sh` writes into each unit:

| Value | Result |
|-------|--------|
| `auto` (default) | writes `OLLAMA_VULKAN=0` when `nvidia-smi` lists a GPU on the install target, otherwise writes nothing |
| `0` | always write `OLLAMA_VULKAN=0` (CUDA only) |
| `1` | always write `OLLAMA_VULKAN=1` |
| empty | never write the line; Ollama's own default applies |

AMD and Intel cards (for example Arc) may need Vulkan, so `auto` leaves it alone
without an NVIDIA GPU. On a box that mixes NVIDIA with another vendor, `auto`
disables Vulkan for both instances: set `FRANKEN_OLLAMA_VULKAN=1` (or empty) if the
non-NVIDIA card needs it. Re-run `./scripts/install-ollama-native.sh`, then
`sudo systemctl daemon-reload` and restart the instances. To apply it by hand,
add `Environment="OLLAMA_VULKAN=0"` to each unit.

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
FRANKEN_GPU1_GUARD_MODEL    # Guard model warmed on GPU 1 (ignored with FRANKEN_GPU_COUNT=1)
FRANKEN_GPU0_GUARD_CONTEXT  # num_ctx sent when warming the GPU 0 guard (empty = send none)
FRANKEN_GPU1_GUARD_CONTEXT  # num_ctx sent when warming the GPU 1 guard (empty = send none)
FRANKEN_GPU0_EXTRA_MODEL    # Second resident model on GPU 0
FRANKEN_GPU0_EXTRA_CONTEXT  # num_ctx sent when warming that model (empty = send none)
FRANKEN_GPU0_WARMUP_TIMEOUT # Seconds to wait for a GPU 0 load (default 180)
FRANKEN_GPU1_WARMUP_TIMEOUT # Seconds to wait for a GPU 1 load (default 120)

# Per-card pinning
FRANKEN_OLLAMA_VULKAN       # auto (default) | 0 | 1 | empty - OLLAMA_VULKAN in the units
```

## Per-Model Layout and Context

### Single GPU / small card (start here)

One GPU, or cards with little VRAM, need nothing from the split layout below.

```bash
FRANKEN_GPU_COUNT=1
FRANKEN_GPU0_MODEL="<model>"       # something that fits your card with room for the KV cache
FRANKEN_GPU0_CONTEXT=8192          # modest; raise it only after checking VRAM (see below)

# The guard/moderation model is OPTIONAL. Its default is llama-guard3:8b, which
# is ~5 GB on its own; if you do not run AI moderation, turn it off:
FRANKEN_GPU0_GUARD_MODEL=
```

- The guard model is only for AI-moderation bots. If nothing of yours calls it,
  set `FRANKEN_GPU0_GUARD_MODEL=` (explicitly empty) so it is never loaded.
- `FRANKEN_GPU0_CONTEXT` is the instance's `OLLAMA_CONTEXT_LENGTH`. The KV cache
  grows with it, so on a small card keep it modest (8192 is the default) and
  confirm with `ollama ps` that the model shows `100% GPU`.
- `FRANKEN_GPU1_GUARD_MODEL` is ignored with `FRANKEN_GPU_COUNT=1`; warm-up prints
  a warning if it is set.
- Nothing else in this section is needed. Every other variable below defaults to
  empty.

### How warm-up loads a model

`./bin/warmup-models.sh` sends every model a tiny request with `keep_alive: -1`
(keep it resident):

| Model | `options.num_ctx` sent | Context it runs at |
|-------|------------------------|--------------------|
| `FRANKEN_GPU0_MODEL`, `FRANKEN_GPU1_MODEL` (main models) | never | the instance's `FRANKEN_GPUn_CONTEXT` |
| `FRANKEN_GPU0_GUARD_MODEL`, `FRANKEN_GPU1_GUARD_MODEL`, `FRANKEN_GPU0_EXTRA_MODEL` | only if its own `*_GUARD_CONTEXT` / `*_EXTRA_CONTEXT` is set | its own setting, else the instance's |

A main model's context therefore comes only from `FRANKEN_GPUn_CONTEXT`, which
is written into the systemd unit as `OLLAMA_CONTEXT_LENGTH`. After changing it,
re-run `./scripts/install-ollama-native.sh` (or edit the
`Environment="OLLAMA_CONTEXT_LENGTH=..."` line in
`/etc/systemd/system/ollama-gpu0.service` / `ollama-gpu1.service`), then
`sudo systemctl daemon-reload` and restart the instance. Changing the `.env`
value alone does not change the running instance.

> **Clients must send the same `num_ctx` the extra or guard model was warmed
> with.** Ollama keys a loaded model on its context size; a request with a
> different `num_ctx` makes it unload and reload the model, which costs the load
> time and can evict a neighbour. For a model warmed at its own size, set that
> size in the client (for example `"options": {"num_ctx": 8192}` in the API, or
> Advanced Params > Context Length in Open WebUI). Clients of a main model that
> send no `num_ctx` get the instance context, which is what warm-up used.

Warm-up requests have a timeout per model (`FRANKEN_GPU0_WARMUP_TIMEOUT`, default
180 s; `FRANKEN_GPU1_WARMUP_TIMEOUT`, default 120 s), run one after another, and
the script exits 1 if any model failed to load (see
[AUTO_WARMUP.md](AUTO_WARMUP.md)). Model names must match
`[A-Za-z0-9._:/@-]+` and contexts must be whole numbers, otherwise that model
fails with a clear message instead of sending a malformed request.

`./bin/warmup-config.sh warmup` (the interactive config) follows the same rules
for the model you picked per GPU, but it does **not** warm
`FRANKEN_GPU0_EXTRA_MODEL` or `FRANKEN_GPU1_GUARD_MODEL`; use
`./bin/warmup-models.sh` for those.

### Thinking models: send `think: false` for cheap tasks

Models that think before answering (Qwen3.5 is one) spend tokens on the thinking
for every request. For short, simple tasks (classification, titles, one-sentence
summaries) turn it off per request if the model supports it:

```bash
curl -s http://$FRANKEN_SERVER_IP:11434/api/chat -d '{
  "model": "<thinking-model>",
  "messages": [{"role": "user", "content": "Summarize in one sentence: ..."}],
  "think": false,
  "stream": false
}'
```

On one maintainer setup, a one-sentence task with a thinking model used far fewer
tokens with thinking off; measure on your own models before relying on a number.

### Optional: 16 GB card + 8 GB card split layout

This is one worked example, not a default. Placeholders are shown where your
choices belong; the sizes are the part that matters. Layout: the backbone model
alone at a large context on the large card next to a small cheap-task model, and
the guard model by itself on the small card.

```bash
# GPU 0 (16 GB): backbone at a large context + a small extra model
FRANKEN_GPU0_MODEL="<backbone-model>"
FRANKEN_GPU0_CONTEXT=65536             # the instance context; the backbone inherits it
FRANKEN_GPU0_GUARD_MODEL=              # explicitly empty: the guard moves to GPU 1
FRANKEN_GPU0_EXTRA_MODEL="<small-model>"
FRANKEN_GPU0_EXTRA_CONTEXT=8192        # sent at warm-up; clients must send 8192 too

# GPU 1 (8 GB): the guard model alone
FRANKEN_GPU1_MODEL="<guard-model>"
FRANKEN_GPU1_CONTEXT=8192
```

`FRANKEN_GPU1_MODEL` is always warmed, so on a guard-only card the guard is
simply that card's main model. `FRANKEN_GPU1_GUARD_MODEL` is for a card that also
hosts a main model next to its guard.

**VRAM caveat:** every size here is an estimate. The KV cache grows with context
(roughly 130 MB per 1K tokens for an 8B model), so 65536 on the large card is the
number most likely to need lowering. After warm-up, confirm with `ollama ps`
(each model should show `100% GPU`) and `nvidia-smi`. If the backbone and the
extra model do not both fit, lower `FRANKEN_GPU0_CONTEXT` or drop the extra model.

#### Migrating an existing install to a layout like this

1. Back up: `cp .env .env.backup`
2. Edit `.env` on the server with the variables above. Keep
   `FRANKEN_SERVER_IP=localhost` in the deployed `.env`.
3. Pull what is new onto the right card, for example
   `./bin/add-model.sh 1 <guard-model>` and `./bin/add-model.sh 0 <small-model>`.
4. Write the new `OLLAMA_CONTEXT_LENGTH` values into the units (re-run
   `./scripts/install-ollama-native.sh`, which also re-runs the Ollama installer,
   or edit the two unit files by hand), then restart **both** instances:
   ```bash
   sudo systemctl daemon-reload
   sudo systemctl restart ollama-gpu0 ollama-gpu1
   ```
5. Re-run warm-up: `./bin/warmup-models.sh` (check that it exits 0).
6. Verify what is resident and at what size, on each instance:
   ```bash
   curl -s http://localhost:11434/api/ps | jq '.models[] | {name, size, size_vram, context_length}'
   curl -s http://localhost:11435/api/ps | jq '.models[] | {name, size, size_vram, context_length}'
   ```
   `size_vram` should equal `size` for every model (fully on GPU). If your Ollama
   version does not report `context_length`, use `ollama ps`.
7. Update every client to send the matching `num_ctx` for the extra/guard model.

An install that changes nothing keeps its layout: the new variables default to
empty, so the same models load at the same instance contexts as before. The
differences are listed in the pull request that introduced them: the
`FRANKEN_GPU1_MODEL` default, the GPU 1 warm-up timeout, `keep_alive: -1` in the
warm-up request, stricter failure handling, and `FRANKEN_GPU0_GUARD_MODEL=` empty
now really disabling the guard.

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
