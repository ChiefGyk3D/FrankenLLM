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

RAG lets you upload documents and have the LLM answer questions using their content. FrankenLLM's multi-GPU setup is ideal for RAG — dedicate one GPU to embedding models and keep your primary GPU free for chat.

#### How It Works

1. **Upload** — You upload a document (PDF, DOCX, TXT, etc.) to Open WebUI
2. **Chunk** — The document is split into chunks (default: 1000 characters with 100 overlap)
3. **Embed** — Each chunk is converted to a vector using the embedding model on your dedicated GPU
4. **Store** — Vectors are stored in Open WebUI's built-in vector database
5. **Retrieve** — When you ask a question, the most relevant chunks are found via similarity search
6. **Generate** — The retrieved chunks are injected into the prompt, and your chat model generates an answer

#### Embedding Model Setup

Pull an embedding model onto your secondary GPU (the one you want to dedicate to embeddings):

```bash
# Pull onto GPU 1 (e.g., RTX 3050)
./bin/add-model.sh 1 qwen3-embedding:0.6b
```

Then configure in Open WebUI at **Admin > Settings > Documents > Embedding**:

| Setting | Value |
|---------|-------|
| Embedding Model Engine | Ollama |
| Embedding Model | `qwen3-embedding:0.6b` (or your chosen model) |
| Ollama Base URL | `http://localhost:11435` (GPU 1 port) |

> **Tip:** You don't need to keep the embedding model warm. Ollama loads it on-demand when Open WebUI sends an embedding request, then unloads it after 5 minutes of idle time. This lets the GPU freely swap between embedding and chat models as needed.

#### Choosing an Embedding Model

Qwen3-Embedding is currently the top-performing embedding model family on Ollama. Here's how the sizes compare:

| Model | VRAM Usage | Context | Max Dimensions | Quality | Best For |
|-------|-----------|---------|----------------|---------|----------|
| `qwen3-embedding:0.6b` | ~639 MB | 32K | 1024 | Good | Light RAG, low VRAM GPUs, coexisting with chat models |
| `qwen3-embedding:4b` | ~2.5 GB | 40K | 2560 | Better | Balanced quality/VRAM, most multi-GPU setups |
| `qwen3-embedding:8b` | ~4.7 GB | 40K | 4096 | Best (#1 MTEB) | Maximum retrieval quality, dedicated embedding GPU |
| `nomic-embed-text` | ~270 MB | 8K | 768 | Good | Minimal footprint, always coexist with chat models |

**Tradeoffs:**
- **Larger models = better retrieval accuracy** — The 8B finds more relevant chunks, especially for nuanced or multilingual queries
- **Larger models = more VRAM** — May not coexist with a chat model on the same GPU simultaneously (Ollama swaps on-demand, so this is fine if the GPU isn't doing both at once)
- **Larger models = slower embedding** — First document upload takes longer, but this is a one-time cost per document
- **Embedding dimensions** — Higher dimensions capture more semantic detail but use more storage. For most RAG use cases, 1024 dims is sufficient
- **Context length** — 32K-40K means even large document chunks are handled without truncation

**Example GPU configurations:**

| GPU (VRAM) | Recommended Embedding Model | Can coexist with |
|------------|----------------------------|-------------------|
| 8 GB (e.g., RTX 3050) | `qwen3-embedding:0.6b` or `4b` | `gemma3:4b` or similar ≤4B chat model |
| 8 GB (dedicated to RAG) | `qwen3-embedding:8b` | Nothing simultaneously, swaps on-demand |
| 12-16 GB | `qwen3-embedding:8b` | Most 7B chat models |

#### Recommended Document Settings

Configure in **Admin > Settings > Documents**:

| Setting | Recommended | Notes |
|---------|-------------|-------|
| Chunk Size | 1000 | Good default. Increase to 1500-2000 for technical docs with long code blocks |
| Chunk Overlap | 100 | Prevents losing context at chunk boundaries |
| Embedding Batch Size | 8-16 | Process multiple chunks at once. Higher = faster uploads on dedicated GPU |
| Async Embedding Processing | On | Don't block the UI while embedding |
| Top K | 3-5 | Number of chunks injected into the prompt. More = more context but uses more tokens |
| Hybrid Search | On (recommended) | Combines vector similarity with keyword matching — better for technical/exact terms |
| Full Context Mode | Off | Sends entire document to LLM — defeats the purpose of RAG, wastes tokens |

#### Using RAG

1. **Upload documents** — Drag files into a chat, or go to **Workspace > Knowledge** to create collections
2. **Reference in chat** — Type `#` to browse and select a knowledge collection
3. **Ask questions** — The LLM will answer using the document content and cite sources

#### Architecture: Separating Embedding from Chat

The key advantage of FrankenLLM for RAG is GPU isolation:

```
 User Question
      │
      ├──► GPU 1 (RTX 3050) ──► qwen3-embedding ──► Find relevant chunks
      │                                                    │
      │◄──────────────────────── Top K chunks ◄────────────┘
      │
      └──► GPU 0 (RTX 5060 Ti) ──► gemma3:12b ──► Generate answer with chunks
```

- **GPU 0** stays free for chat generation — no VRAM competition
- **GPU 1** handles embedding on-demand — loads/unloads automatically
- Both can work simultaneously if needed (embedding new docs while chatting)

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
