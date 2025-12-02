# 🎉 FrankenLLM - Setup Complete!

## ✅ What's Done

### 1. Complete Project Reorganization ✅
- Professional directory structure
- Separate local/remote workflows
- Clean, maintainable codebase

### 2. Remote Installation ✅
- Ollama installed on 192.168.201.145
- Two systemd services created:
  - `ollama-gpu0` on port 11434 (RTX 5060 Ti 16GB)
  - `ollama-gpu1` on port 11435 (RTX 3050 8GB)
- Both services enabled and running

### 3. Model Downloads (In Progress) ⏳
- **GPU 0 (16GB)**: gemma3:12b ✅ Downloaded!
- **GPU 1 (8GB)**: gemma3:4b ⏳ Downloading...

## 🎮 Quick Command Reference

```bash
# Health Check (anytime)
./bin/health-check.sh

# Service Management
./manage.sh status
./manage.sh restart
./manage.sh logs

# Test the LLMs (after models download)
./bin/test-llm.sh "What is your purpose?"

# Pull more models
./bin/pull-model.sh llama3.2          # Same on both
./bin/pull-dual-models.sh M1 M2       # Different per GPU
```

## 🌐 Access Your LLMs

### Via Scripts (Recommended)
```bash
./bin/test-llm.sh "Your question here"
```

### Via API Directly

**GPU 0 (RTX 5060 Ti - gemma3:12b):**
```bash
curl http://192.168.201.145:11434/api/generate -d '{
  "model": "gemma3:12b",
  "prompt": "Explain quantum computing in simple terms",
  "stream": false
}'
```

**GPU 1 (RTX 3050 - gemma3:4b):**
```bash
curl http://192.168.201.145:11435/api/generate -d '{
  "model": "gemma3:4b",
  "prompt": "Write a Python function to sort a list",
  "stream": false
}'
```

## 📊 Your Setup

| Component | Details |
|-----------|---------|
| **Server** | 192.168.201.145 (llm1) |
| **GPU 0** | RTX 5060 Ti (16GB) - Port 11434 |
| **GPU 1** | RTX 3050 (8GB) - Port 11435 |
| **Model (GPU 0)** | gemma3:12b (8.1GB) |
| **Model (GPU 1)** | gemma3:4b (~2.5GB) |
| **Driver** | NVIDIA 580.95.05 |
| **CUDA** | 13.0 |

## 🚀 Next Steps

### Once Models Finish Downloading:

1. **Test Both LLMs:**
   ```bash
   ./bin/test-llm.sh "What can you help me with?"
   ```

2. **Try Different Prompts:**
   ```bash
   # Coding on GPU 1 (faster)
   ./bin/test-llm.sh "Write a Python function to calculate fibonacci"
   
   # Complex reasoning on GPU 0 (more capable)
   ./bin/test-llm.sh "Explain the differences between supervised and unsupervised learning"
   ```

3. **Monitor GPU Usage:**
   ```bash
   ssh 192.168.201.145 "nvidia-smi"
   ```

4. **View Service Logs:**
   ```bash
   ./manage.sh logs
   ```

## 🎯 Best Practices

### When to Use GPU 0 (gemma3:12b - 16GB):
- Complex reasoning tasks
- Longer context requirements
- Code generation and analysis
- Document summarization
- Technical explanations

### When to Use GPU 1 (gemma3:4b - 8GB):
- Quick responses
- Simple queries
- Fast iterations
- Testing prompts
- Chat conversations

## 🔧 Maintenance

### Regular Tasks:
```bash
# Check health
./bin/health-check.sh

# View logs if issues
./manage.sh logs

# Restart if needed
./manage.sh restart
```

### Pull Additional Models:
```bash
# For GPU 0 (16GB) - other good options
OLLAMA_HOST=http://192.168.201.145:11434 ssh 192.168.201.145 "ollama pull llama3.2"
OLLAMA_HOST=http://192.168.201.145:11434 ssh 192.168.201.145 "ollama pull mistral:7b-instruct"

# For GPU 1 (8GB) - other good options
OLLAMA_HOST=http://192.168.201.145:11435 ssh 192.168.201.145 "ollama pull gemma3:1b"
OLLAMA_HOST=http://192.168.201.145:11435 ssh 192.168.201.145 "ollama pull phi3:3.8b"
```

## 📝 Files You Can Delete

Now that everything is reorganized, you can safely delete these old files:
```bash
rm check-gpus.sh health-check.sh install-docker.sh install-ollama-native.sh
rm list-models.sh manage-services.sh pull-dual-models.sh pull-model.sh
rm remote-install.sh start-services.sh test-llm.sh deploy.sh setup.sh test-connection.sh
rm docker-compose.yml ollama-compose.yml vllm-compose.yml
```

Use the new organized structure:
- `./install.sh` - Installation
- `./manage.sh` - Service management  
- `./bin/*` - Utility scripts

## 🎉 You're All Set!

Your FrankenLLM is alive! Two GPUs, two models, maximum utilization!

```
⚡ RTX 5060 Ti (16GB) → gemma3:12b → Port 11434
⚡ RTX 3050 (8GB)     → gemma3:4b  → Port 11435
                    ↓
            🧟 FrankenLLM Lives!
```

**Stitched-together GPUs, but it lives!** 🚀
