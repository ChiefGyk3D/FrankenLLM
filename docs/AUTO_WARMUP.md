# Auto-Warmup on Boot

## Overview

FrankenLLM includes an automatic warmup service that loads your configured models into GPU memory after system boot. This ensures your models are ready to use immediately without manual warmup.

## How It Works

1. **Ollama services start** on boot (ollama-gpu0, ollama-gpu1)
2. **Warmup service activates** and waits for Ollama to be ready
3. **Models are loaded** into GPU memory based on your `.env` configuration
4. **System is ready** for immediate use

## Setup

### Local Installation

The warmup service is automatically configured during installation:

```bash
./install.sh
```

The installer will:
- Create `/etc/systemd/system/frankenllm-warmup.service`
- Enable it to run on boot
- Configure it to load your models from `.env`

### Remote Installation

For remote servers, run the installation first, then setup warmup:

```bash
# 1. Install Ollama services
./install.sh

# 2. Pull your models
./bin/pull-dual-models.sh gemma3:12b gemma3:4b

# 3. Setup warmup service
./remote/setup-warmup.sh
```

The remote setup script will:
- Copy warmup scripts to the remote server
- Create the systemd service
- Enable auto-warmup on boot

## Configuration

Warmup uses your `.env` configuration:

```bash
# Models to load on boot
FRANKEN_GPU0_MODEL="gemma3:12b"
FRANKEN_GPU1_MODEL="gemma3:4b"

# Number of GPUs
FRANKEN_GPU_COUNT=2
```

**Important**: Make sure these models are already pulled before enabling warmup!

## Verifying Warmup

### Check Service Status

**Local:**
```bash
sudo systemctl status frankenllm-warmup
```

**Remote:**
```bash
ssh YOUR_SERVER 'sudo systemctl status frankenllm-warmup'
```

### View Logs

**Local:**
```bash
sudo journalctl -u frankenllm-warmup -n 50
```

**Remote:**
```bash
ssh YOUR_SERVER 'sudo journalctl -u frankenllm-warmup -n 50'
```

### Manual Test

You can manually trigger warmup anytime:

**Local:**
```bash
./bin/warmup-models.sh
```

**Remote:**
```bash
ssh YOUR_SERVER 'cd /opt/frankenllm && ./bin/warmup-models.sh'
```

## Managing the Service

### Enable/Disable Auto-Warmup

**Disable:**
```bash
# Local
sudo systemctl disable frankenllm-warmup

# Remote
ssh YOUR_SERVER 'sudo systemctl disable frankenllm-warmup'
```

**Enable:**
```bash
# Local
sudo systemctl enable frankenllm-warmup

# Remote
ssh YOUR_SERVER 'sudo systemctl enable frankenllm-warmup'
```

### Trigger Warmup Manually

```bash
# Local
sudo systemctl start frankenllm-warmup

# Remote
ssh YOUR_SERVER 'sudo systemctl start frankenllm-warmup'
```

## Troubleshooting

### Warmup Service Fails to Start

**Check if Ollama services are running:**
```bash
sudo systemctl status ollama-gpu0 ollama-gpu1
```

**Check if models are installed:**
```bash
curl http://localhost:11434/api/tags
curl http://localhost:11435/api/tags
```

**View detailed logs:**
```bash
sudo journalctl -u frankenllm-warmup -xe
```

### Models Not Loading

**Verify model names match exactly:**
```bash
# Check installed models
curl http://localhost:11434/api/tags | jq '.models[].name'

# Compare with your .env
cat .env | grep MODEL
```

Model names must match exactly (including version tags).

### Warmup Timeout

The warmup service waits up to 120 seconds for Ollama to be ready. If your system is slow to boot:

1. Edit `/etc/systemd/system/frankenllm-warmup.service`
2. Increase the timeout in `bin/warmup-on-boot.sh` (TIMEOUT variable)
3. Reload: `sudo systemctl daemon-reload`

### Service Won't Enable on Remote

Make sure you've run the setup script:
```bash
./remote/setup-warmup.sh
```

This copies the necessary files and creates the service.

## Boot Sequence

```
1. System boots
2. Network comes online
3. ollama-gpu0.service starts → binds to port 11434
4. ollama-gpu1.service starts → binds to port 11435
5. frankenllm-warmup.service starts
   - Waits for Ollama services to respond
   - Loads FRANKEN_GPU0_MODEL on GPU 0
   - Loads FRANKEN_GPU1_MODEL on GPU 1
   - Logs completion to journal
6. System ready for use
```

## Performance Notes

### Warmup Time

- Small models (1B-4B): ~5-15 seconds
- Medium models (7B-13B): ~15-30 seconds
- Large models (27B+): ~30-60 seconds

The warmup happens in the background and doesn't block other services.

### Memory Usage

Models stay loaded in GPU memory until:
- The Ollama service restarts
- You explicitly load a different model
- System reboots

This is exactly what you want - the models stay "warm" and ready.

### When to Manual Warmup

You might want to manually run warmup after:
- Changing models in `.env`
- Restarting Ollama services
- Loading a different model for testing

Just run:
```bash
./bin/warmup-models.sh
```

## Advanced Configuration

### Custom Warmup Script

You can modify `bin/warmup-on-boot.sh` to:
- Add health checks before warmup
- Send notifications when ready
- Run additional setup commands

### Different Models Per Boot

Create multiple `.env` profiles and swap them:
```bash
# Development setup
cp .env.dev .env
sudo systemctl restart frankenllm-warmup

# Production setup
cp .env.prod .env
sudo systemctl restart frankenllm-warmup
```

### Scheduled Re-warmup

If you want periodic warmup (not just on boot), create a timer:

```bash
sudo tee /etc/systemd/system/frankenllm-warmup.timer > /dev/null << 'EOF'
[Unit]
Description=FrankenLLM Periodic Warmup

[Timer]
OnBootSec=5min
OnUnitActiveSec=6h

[Install]
WantedBy=timers.target
EOF

sudo systemctl enable --now frankenllm-warmup.timer
```

This will warmup 5 minutes after boot, then every 6 hours.

## Uninstalling

To remove the warmup service:

**Local:**
```bash
sudo systemctl stop frankenllm-warmup
sudo systemctl disable frankenllm-warmup
sudo rm /etc/systemd/system/frankenllm-warmup.service
sudo systemctl daemon-reload
```

**Remote:**
```bash
ssh YOUR_SERVER 'sudo systemctl stop frankenllm-warmup && \
  sudo systemctl disable frankenllm-warmup && \
  sudo rm /etc/systemd/system/frankenllm-warmup.service && \
  sudo systemctl daemon-reload'
```

The Ollama services will continue to run normally - you'll just need to manually warmup models.

## Best Practices

1. **Pull models first** - Always pull models before enabling auto-warmup
2. **Test manually** - Run `./bin/warmup-models.sh` to verify before rebooting
3. **Check logs** - Review `journalctl -u frankenllm-warmup` after first boot
4. **Match your hardware** - Choose models that fit comfortably in VRAM
5. **Update .env** - If you change models, update `.env` and test warmup

## FAQ

**Q: Will warmup slow down my boot?**  
A: No - the warmup service runs after boot is complete and doesn't block other services.

**Q: What if I don't want auto-warmup?**  
A: Disable it: `sudo systemctl disable frankenllm-warmup`

**Q: Can I change models without reinstalling?**  
A: Yes! Just edit `.env`, pull the new models, and rerun warmup.

**Q: How do I know warmup worked?**  
A: Check with `./bin/health-check.sh` - it shows which models are ready.

**Q: Does warmup work with 1 GPU or 3+ GPUs?**  
A: Yes - it adapts based on `FRANKEN_GPU_COUNT` in your `.env`.

---

**See Also:**
- [Configuration Guide](CONFIGURATION.md) - Setting up models
- [Remote Management](REMOTE_MANAGEMENT.md) - Managing remote services
- [Quick Start](QUICKSTART.md) - Getting started quickly
