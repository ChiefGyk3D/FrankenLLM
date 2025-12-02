# FrankenLLM - Quick Reference

## 🚀 Installation

```bash
# 1. Configure
./configure.sh

# 2. Install (auto-detects local/remote)
./install.sh

# 3. Pull models
./bin/pull-dual-models.sh gemma3:12b gemma3:4b

# 4. Test
./bin/health-check.sh
```

## 🎮 Daily Commands

```bash
# Service Management
./manage.sh status          # Check if running
./manage.sh restart         # Restart services
./manage.sh logs            # View logs

# Health Checks
./bin/health-check.sh       # Quick status
./bin/check-gpus.sh         # Detailed GPU info

# Model Management
./bin/pull-dual-models.sh MODEL1 MODEL2  # Different models per GPU
./bin/pull-model.sh MODEL                # Same model on both GPUs

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

**Services offline?**
```bash
./manage.sh restart
./bin/health-check.sh
```

**Need to check logs?**
```bash
./manage.sh logs
```

**Remote SSH issues?**
- Make sure SSH keys are set up
- Check `.env` has correct server IP
- Run `./configure.sh` to reconfigure

## 📁 File Organization

- `install.sh` - Main installer
- `manage.sh` - Main service manager
- `configure.sh` - Setup wizard
- `bin/` - Utility scripts
- `local/` - Local installation scripts
- `remote/` - Remote installation scripts
- `docs/` - Documentation
