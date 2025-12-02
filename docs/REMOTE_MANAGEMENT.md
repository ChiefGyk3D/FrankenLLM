# FrankenLLM - Remote Management Guide

## 🎯 Understanding Model Loading

**Important:** Ollama does NOT "start with" specific models. Models are loaded **on-demand** when you make a request.

### How It Works:
1. Both Ollama instances share the same model storage
2. When you request a model, it loads into that GPU's memory
3. The last-used model stays in GPU memory until another is requested
4. Each GPU can only run ONE model at a time in memory

## 🔥 Warming Up GPUs

To pre-load your preferred models into GPU memory after restart:

```bash
./bin/warmup-models.sh gemma3:12b gemma3:4b
```

This makes a small request to each GPU to load the models, so they're ready for use.

## 🎛️ Service Management

### From VS Code Terminal (No sudo needed)

```bash
# Check health (works perfectly from VS Code)
./bin/health-check.sh

# Get management instructions
./manage.sh status    # Shows health check + instructions
./manage.sh start     # Shows command to run
./manage.sh restart   # Shows command to run
./manage.sh logs      # Shows command to run
```

### From External Terminal (Full control)

Open a separate terminal (outside VS Code) and run:

```bash
cd ~/src/llm

# Direct service control
./remote/service-control.sh start
./remote/service-control.sh stop
./remote/service-control.sh restart
./remote/service-control.sh status
./remote/service-control.sh logs
```

### Manual SSH Commands

```bash
# One-liner to restart services
ssh -t 192.168.201.145 'sudo systemctl restart ollama-gpu0 ollama-gpu1'

# SSH into server for full control
ssh 192.168.201.145
sudo systemctl status ollama-gpu0 ollama-gpu1
sudo systemctl restart ollama-gpu0 ollama-gpu1
sudo journalctl -u ollama-gpu0 -n 50
sudo journalctl -u ollama-gpu1 -n 50
```

## 📊 Ensuring Correct Model Usage

### Method 1: Always Specify the Model (Recommended)

```bash
# GPU 0 (16GB) - Use 12B model
curl http://192.168.201.145:11434/api/generate -d '{
  "model": "gemma3:12b",
  "prompt": "Your question"
}'

# GPU 1 (8GB) - Use 4B model
curl http://192.168.201.145:11435/api/generate -d '{
  "model": "gemma3:4b",
  "prompt": "Your question"
}'
```

### Method 2: Warm Up After Restart

Add to your workflow:

```bash
# After system restart or service restart
./bin/warmup-models.sh gemma3:12b gemma3:4b
```

### Method 3: Create a Startup Script

Want models to warm up automatically when services start? SSH into the server and create:

```bash
ssh 192.168.201.145
sudo nano /usr/local/bin/franken-warmup.sh
```

Add this content:

```bash
#!/bin/bash
# Wait for services to be ready
sleep 10

# Warm up GPU 0 with 12B
curl -s http://localhost:11434/api/generate -d '{"model": "gemma3:12b", "prompt": "Hi", "stream": false}' > /dev/null

# Warm up GPU 1 with 4B
curl -s http://localhost:11435/api/generate -d '{"model": "gemma3:4b", "prompt": "Hi", "stream": false}' > /dev/null
```

Make it executable and create a systemd service:

```bash
sudo chmod +x /usr/local/bin/franken-warmup.sh

sudo tee /etc/systemd/system/franken-warmup.service > /dev/null << 'EOF'
[Unit]
Description=FrankenLLM Model Warmup
After=ollama-gpu0.service ollama-gpu1.service
Requires=ollama-gpu0.service ollama-gpu1.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/franken-warmup.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable franken-warmup.service
sudo systemctl start franken-warmup.service
```

## 🐛 Why SSH Terminal Issues?

VS Code's integrated terminal doesn't allocate a proper PTY (pseudo-terminal), which breaks interactive sudo prompts over SSH.

**Solutions:**
1. Use `./bin/health-check.sh` for status (no sudo needed)
2. Use `./remote/service-control.sh` from an external terminal
3. Run `ssh -t` commands manually from a real terminal
4. SSH directly into the server for service management

## ✅ Best Workflow

### Daily Use (From VS Code):
```bash
# Check health
./bin/health-check.sh

# Warm up models after restart
./bin/warmup-models.sh gemma3:12b gemma3:4b

# Test with correct models
./bin/test-llm.sh
```

### Service Management (From External Terminal):
```bash
# Open a real terminal outside VS Code
cd ~/src/llm
./remote/service-control.sh restart
./remote/service-control.sh status
```

### Advanced (Direct SSH):
```bash
ssh 192.168.201.145
sudo systemctl restart ollama-gpu0 ollama-gpu1
nvidia-smi
```

## 📝 Quick Reference

| Task | Command |
|------|---------|
| **Check Health** | `./bin/health-check.sh` |
| **Warm Up Models** | `./bin/warmup-models.sh gemma3:12b gemma3:4b` |
| **Test Both** | `./bin/test-llm.sh` |
| **Restart Services** | `./remote/service-control.sh restart` (external terminal) |
| **View Logs** | `./remote/service-control.sh logs` (external terminal) |
| **SSH In** | `ssh 192.168.201.145` |

## 🎯 Summary

1. **Model Storage**: Both GPUs see both models (shared storage)
2. **Model Loading**: Models load on-demand into GPU memory
3. **Ensuring Correct Usage**: Always specify model in API calls OR warm up after restart
4. **SSH Issues**: VS Code terminal limitations - use external terminal for service control
5. **Best Practice**: Use `health-check.sh` and `warmup-models.sh` from VS Code, service control from external terminal
