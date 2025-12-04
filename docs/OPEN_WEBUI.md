# Open WebUI Integration Guide

This guide explains how to use Open WebUI with FrankenLLM for a web-based LLM interface.

## Overview

Open WebUI provides:
- 🌐 **Web Interface** - ChatGPT-like UI for your local LLMs
- 🔌 **OpenAI-Compatible API** - Use with N8n, LangChain, etc.
- 👥 **Multi-User** - User accounts, permissions, and sharing
- 💾 **Chat History** - Save and organize conversations
- 🎨 **Rich Features** - Image generation, RAG, web search, and more
- 🔄 **Simultaneous Access** - Use CLI tools and WebUI at the same time

## Installation

```bash
# Install Open WebUI
./bin/install-webui.sh
```

This will:
1. Install Open WebUI in a Docker container
2. **Automatically connect to ALL your GPUs** (both GPU 0 and GPU 1)
3. Make it available at http://localhost:3000

## Initial Setup

1. **Open the WebUI**: Navigate to http://localhost:3000
2. **Create Admin Account**: First user becomes admin
3. **Select Models**: Choose from models on any GPU

## Multi-GPU Support

**Automatic Configuration (v2.0+)**: Open WebUI is now automatically configured to connect to all your GPUs. Each GPU has isolated model storage, so:

- Models on GPU 0 appear as: `gemma3:12b`, etc.
- Models on GPU 1 appear as: `gemma3:4b`, etc.

When you select a model in Open WebUI, it automatically uses the correct GPU based on which instance has that model.

### Verify GPU Connections

1. Go to **Settings** (gear icon) → **Admin Settings** → **Connections**
2. You should see both Ollama connections:
   - `http://host.docker.internal:11434` (GPU 0)
   - `http://host.docker.internal:11435` (GPU 1)

### Adding Models to Specific GPUs

Use the model management tool to add models to specific GPUs:

```bash
# Add models to specific GPUs
./bin/add-model.sh 0 gemma3:12b   # GPU 0 (larger GPU)
./bin/add-model.sh 1 gemma3:4b    # GPU 1 (smaller GPU)

# List models per GPU
./bin/add-model.sh list
```

After adding models, refresh your browser or restart Open WebUI to see the new models.

## Management Commands

```bash
# Start/Stop
./bin/manage-webui.sh start
./bin/manage-webui.sh stop
./bin/manage-webui.sh restart

# View status
./bin/manage-webui.sh status

# View logs
./bin/manage-webui.sh logs

# Update to latest
./bin/manage-webui.sh update

# Show URLs
./bin/manage-webui.sh url

# Remove (keeps data)
./bin/manage-webui.sh remove
```

## Using with N8n

Open WebUI provides an OpenAI-compatible API that works with N8n and other tools:

### 1. Get API Key
1. In Open WebUI, click Settings → Account
2. Go to **API Keys** tab
3. Click **Create new secret key**
4. Copy the key (you'll only see it once!)

### 2. Configure N8n
1. In N8n, add an **OpenAI** node
2. Create new credentials:
   - **API Key**: Paste your Open WebUI API key
   - **Base URL**: `http://YOUR_SERVER_IP:3000/api`
3. Select your model from the dropdown

### Compatible Tools
- N8n
- LangChain
- LlamaIndex
- Continue.dev
- Any OpenAI-compatible client

## CLI + WebUI Simultaneous Use

**Yes!** You can use both at the same time:

```bash
# Use CLI while WebUI is running
./bin/chat.sh              # Interactive CLI chat
./bin/test-llm.sh "test"   # Quick CLI test

# Or direct API calls
curl http://YOUR_IP:11434/api/generate -d '{
  "model": "gemma3:12b",
  "prompt": "Hello"
}'
```

All methods access the same Ollama instances - no conflicts!

## GPU Selection in WebUI

Users can select which model (and thus which GPU) to use:

1. Click the **model selector** dropdown at top
2. Choose from available models:
   - Models from GPU 0 (primary connection)
   - Models from GPU 1 (if added as secondary connection)
3. The model name shows which connection it's from

## Architecture

```
┌─────────────┐
│ Open WebUI  │ :3000 (Web Interface + API)
└──────┬──────┘
       │
       ├─────────> Ollama GPU 0 :11434 (Primary)
       │           └─> RTX 5060 Ti (gemma3:12b)
       │
       └─────────> Ollama GPU 1 :11435 (Secondary)
                   └─> RTX 3050 (gemma3:4b)
```

## Port Reference

| Service | Port | Purpose |
|---------|------|---------|
| Open WebUI | 3000 | Web interface and API |
| Ollama GPU 0 | 11434 | Primary Ollama instance |
| Ollama GPU 1 | 11435 | Secondary Ollama instance |

## Advanced Features

### RAG (Retrieval Augmented Generation)
- Upload documents in chat
- Create document collections
- Use `#` to reference documents

### Image Generation
- Configure DALL-E, Stable Diffusion, or ComfyUI
- Generate images directly in chat

### Web Search
- Enable web search providers
- Get real-time information

### Multi-User
- Create user accounts
- Set permissions
- Share conversations

### API Keys
- Create multiple API keys
- Per-key permissions
- Revoke access anytime

## Troubleshooting

### Can't connect to Ollama
```bash
# Check Ollama is running
./manage.sh status

# Check Open WebUI logs
./bin/manage-webui.sh logs
```

### Models not showing up
1. Verify models are pulled: `./bin/check-gpus.sh`
2. Check Ollama connection in WebUI settings
3. Restart Open WebUI: `./bin/manage-webui.sh restart`

### Port already in use
```bash
# If port 3000 is taken, modify the docker run command in install-webui.sh
# Change -p 3000:8080 to -p 3001:8080 (or any free port)
```

## Data Persistence

Your data is stored in Docker volume `open-webui`:
- User accounts
- Chat history
- Settings
- Uploaded documents

To backup:
```bash
docker run --rm -v open-webui:/data -v $(pwd):/backup alpine tar czf /backup/open-webui-backup.tar.gz -C /data .
```

To restore:
```bash
docker run --rm -v open-webui:/data -v $(pwd):/backup alpine sh -c "cd /data && tar xzf /backup/open-webui-backup.tar.gz"
```

## Resources

- [Open WebUI Documentation](https://docs.openwebui.com/)
- [Open WebUI GitHub](https://github.com/open-webui/open-webui)
- [Open WebUI Discord](https://discord.gg/5rJgQTnV4s)

## Summary

✅ **Web interface** for your LLMs  
✅ **Multi-GPU support** (add both Ollama instances)  
✅ **API for N8n** and other tools  
✅ **Works alongside CLI** tools  
✅ **User-friendly** ChatGPT-like experience  
✅ **Self-hosted** and private
