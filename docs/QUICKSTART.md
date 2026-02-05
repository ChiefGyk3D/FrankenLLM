# FrankenLLM - Quick Reference

## 🚀 Installation

```bash
# 1. Configure
./configure.sh

# 2. Install (auto-detects local/remote)
./install.sh

# 3. Pull models to specific GPUs
./bin/add-model.sh 0 gemma3:12b   # Add 12b to GPU 0
./bin/add-model.sh 1 gemma3:4b    # Add 4b to GPU 1

# 4. Test
./bin/health-check.sh
```

## 🎮 Daily Commands

```bash
# Service Management
./manage.sh status          # Check if running
./manage.sh restart         # Restart services
./manage.sh logs            # View logs

# Updates
./update.sh check           # Check for updates
./update.sh all             # Update Ollama + Open WebUI

# Health Checks
./bin/health-check.sh       # Quick status
./bin/check-gpus.sh         # Detailed GPU info

# Model Management
./bin/add-model.sh                   # Interactive mode
./bin/add-model.sh 0 MODEL           # Add to specific GPU
./bin/add-model.sh list              # List models per GPU
./bin/pull-dual-models.sh MODEL1 MODEL2  # Legacy: different models per GPU

# Warmup Configuration
./bin/warmup-config.sh set           # Configure warmup models
./bin/warmup-config.sh warmup        # Load models into GPU memory
./bin/warmup-config.sh status        # Show GPU memory status
./bin/warmup-config.sh clear         # Unload all models

# Testing
./bin/test-llm.sh "Your question here"
```

## 🔧 Direct API Access

```bash
# GPU 0 (Port 11434)
curl http://YOUR_IP:11434/api/tags
curl http://YOUR_IP:11434/api/generate -d '{
  "model": "gemma3:12b",
  "prompt": "Hello!",
  "stream": false
}'

# GPU 1 (Port 11435)
curl http://YOUR_IP:11435/api/tags
curl http://YOUR_IP:11435/api/generate -d '{
  "model": "gemma3:4b",
  "prompt": "Hello!",
  "stream": false
}'
```

## 📦 Recommended Models

**16GB GPU:** `gemma3:12b`, `gemma2:9b`, `llama3.2`, `mistral:7b-instruct`

**8GB GPU:** `gemma3:4b`, `gemma3:1b`, `gemma2:2b`, `llama3.2:3b`, `phi3:3.8b`

## 🆘 Troubleshooting

**GPU0 keeps restarting / Port 11434 in use?**
```bash
# The default ollama.service may be stealing the port
# Mask it permanently:
sudo systemctl stop ollama.service
sudo systemctl mask ollama.service
sudo systemctl restart ollama-gpu0
```

**Services offline?**
```bash
./manage.sh restart
./bin/health-check.sh
```

**Need to check logs?**
```bash
./manage.sh logs
```

**Model on wrong GPU?**
```bash
# Check which models are on which GPU
./bin/add-model.sh list

# Each GPU has isolated storage - models don't cross over
```

**Remote SSH issues?**
- Make sure SSH keys are set up: `ssh-copy-id YOUR_SERVER_IP`
- Check `.env` has correct server IP
- Run `./configure.sh` to reconfigure

**Upgrading/Replacing a GPU?**
- See [GPU Upgrade Guide](GPU_UPGRADE.md) for step-by-step instructions
- Quick: Stop services → Swap hardware → Verify with `nvidia-smi` → Pull models → Start

## 📁 File Organization

- `install.sh` - Main installer
- `manage.sh` - Main service manager
- `configure.sh` - Setup wizard
- `bin/` - Utility scripts
- `local/` - Local installation scripts
- `remote/` - Remote installation scripts
- `docs/` - Documentation
