# 🧟 FrankenLLM Super Installer

## What's New?

We've created `setup-frankenllm.sh` - a comprehensive, interactive installation wizard that handles **everything** from a fresh server to a fully operational multi-GPU LLM system!

## Why This Is Better

### Before (Old Way)
```bash
./configure.sh          # Step 1
./install.sh            # Step 2
./bin/install-webui.sh  # Step 3
./remote/setup-warmup.sh # Step 4
./bin/pull-model.sh ... # Step 5
# Plus entering sudo password multiple times! 😫
```

### Now (Super Installer)
```bash
./setup-frankenllm.sh   # ONE command! 🎉
# Interactive wizard guides you through everything
# Sudo password cached (enter once!)
```

## Features

### 🎯 Smart Detection
- Auto-detects GPUs
- Tests SSH connectivity for remote installs
- Validates prerequisites

### 🔧 Complete Installation
- ✅ Docker (for Open WebUI)
- ✅ Ollama (native, per-GPU instances with systemd)
- ✅ Open WebUI (optional, ChatGPT-like interface)
- ✅ Auto-warmup service (optional, keeps models hot on boot)
- ✅ Model downloads (optional, during setup)
- ✅ **Auto-start on boot** (systemd services enabled automatically)

### 💡 User-Friendly
- **Color-coded output** - Easy to follow
- **Interactive prompts** - Choose what you need
- **Progress indicators** - Know what's happening
- **Sudo caching** - Enter password once, not 50 times!
- **Smart defaults** - Just press Enter for recommended settings

### 🌐 Works Anywhere
- **Local installation** - On this machine
- **Remote installation** - Via SSH to another server
- **Hybrid friendly** - Mix and match as needed

## What Gets Installed

Based on your selections, the installer can set up:

1. **Docker** (if you want Open WebUI)
   - Latest Docker CE
   - User added to docker group
   
2. **Ollama Services** (one per GPU)
   - Native systemd services (not Docker!)
   - ✅ **Auto-start on boot ENABLED**
   - Dedicated ports per GPU (11434, 11435)
   - CUDA_VISIBLE_DEVICES per service
   - Automatic restart on failure
   
3. **Open WebUI** (optional)
   - Web interface at port 3000
   - ChatGPT-like experience
   - OpenAI-compatible API
   - ✅ **Auto-start on boot ENABLED** (Docker --restart always)
   
4. **Auto-Warmup** (optional)
   - Pre-loads models on boot
   - Eliminates first-query lag (from 30s to instant!)
   - ✅ **Systemd service runs after Ollama starts**
   - Models stay in VRAM permanently
   
5. **Models** (optional)
   - Downloads during setup
   - Same or different per GPU
   - Ready to use immediately

### 🔄 Boot Behavior

**After system restart:**
1. System boots
2. Ollama services auto-start (systemd) - ~5 seconds
3. Open WebUI auto-starts (Docker) - ~10 seconds
4. Warmup service loads models (if enabled) - ~35 seconds
5. **Total: ~50 seconds to fully ready with hot models**

**Without auto-warmup:**
- Ollama services start
- First query takes 10-30 seconds to load model
- Subsequent queries are fast

## Usage

### Quick Start (Recommended)
```bash
git clone https://github.com/ChiefGyk3D/FrankenLLM.git
cd FrankenLLM
./setup-frankenllm.sh
```

Then follow the interactive prompts!

### What You'll Be Asked

1. **Installation Mode**
   - Local or Remote?
   - Remote IP address (if remote)

2. **GPU Configuration**
   - Auto-detected, you confirm
   - Custom ports (or use defaults)

3. **Components**
   - Install Docker? (needed for Open WebUI)
   - Install Open WebUI? (web interface)
   - Setup auto-warmup? (keep models hot)
   - Pull models now? (or later)

4. **Models** (if you chose to pull)
   - Same model all GPUs, or different per GPU?
   - Which models?

### Example Session

```
╔══════════════════════════════════════════════════════════════╗
║              🧟 FrankenLLM - Complete Setup 🧟               ║
║            Stitched-together GPUs, but it lives!             ║
╚══════════════════════════════════════════════════════════════╝

Where do you want to install FrankenLLM?
  1) Local  - Install on THIS machine
  2) Remote - Install on a remote server via SSH

Select installation mode [1-2]: 2
Enter remote server IP address: 192.168.201.145
✓ Selected: Remote installation to 192.168.201.145

Testing SSH connection...
✓ SSH connection successful

Detected GPUs:
1  0, NVIDIA GeForce RTX 5060 Ti, 16384 MiB
2  1, NVIDIA GeForce RTX 3050, 8192 MiB

Found 2 GPU(s)

GPU 0 port [11434]: 
GPU 1 port [11435]: 

Install Docker? (Required for Open WebUI) [Y/n]: y
Install Open WebUI? (ChatGPT-like web interface) [Y/n]: y
Setup auto-warmup? (Keep models loaded in VRAM) [Y/n]: y
Pull models after installation? [Y/n]: y

Model selection:
  1) Same model on all GPUs
  2) Different models per GPU
Select [1-2]: 2

Enter model for GPU 0 (e.g., gemma3:12b): gemma3:12b
Enter model for GPU 1 (e.g., gemma3:4b): gemma3:4b

✓ Configuration saved to .env

Caching sudo credentials for smoother installation...

[1] Installing Docker...
✓ Docker installed

[2] Installing Ollama services...
✓ Ollama services installed and running

[3] Installing Open WebUI...
✓ Open WebUI installed

[4] Setting up auto-warmup service...
✓ Auto-warmup configured

[5] Pulling models...
✓ Models downloaded

╔══════════════════════════════════════════════════════════════╗
║             🎉 Installation Complete! 🎉                     ║
╚══════════════════════════════════════════════════════════════╝

🌐 Access Your Services:
  • Ollama GPU 0: http://192.168.201.145:11434
  • Ollama GPU 1: http://192.168.201.145:11435
  • Open WebUI:   http://192.168.201.145:3000

🎮 Useful Commands:
  • Test LLMs:     ./bin/test-connection.sh
  • Chat:          ./bin/chat.sh
  • Check GPUs:    ./bin/check-gpus.sh
  • Health check:  ./bin/health-check.sh
  • Manage:        ./manage.sh status

Happy FrankenLLMing! 🧟‍♂️⚡
```

## Prerequisites

The installer assumes:
- ✅ Ubuntu Server 24.04 (or similar Linux)
- ✅ NVIDIA GPU drivers installed
- ✅ User has sudo privileges
- ✅ SSH access configured (for remote installs)

## What If I Already Installed?

No problem! The installer is smart enough to:
- Detect existing installations
- Skip already-installed components
- Reconfigure if needed
- Not break existing setups

## Comparison with Old Methods

| Feature | Old Way | Super Installer |
|---------|---------|-----------------|
| **Steps** | 5+ separate commands | 1 command |
| **Sudo prompts** | 10-20 times | 1 time |
| **Configuration** | Manual `.env` editing | Interactive wizard |
| **Error handling** | Stop and debug | Guided recovery |
| **Installation time** | ~30 min (lots of waiting) | ~15 min (automated) |
| **User experience** | Terminal ninja required | Beginner friendly |
| **Mistakes** | Easy to miss steps | Guided, hard to mess up |

## Technical Details

### Sudo Password Caching

The installer uses this technique to avoid repeated prompts:
```bash
sudo -v  # Validate once
(while true; do sudo -v; sleep 50; done) &  # Keep alive
```

This background process refreshes sudo credentials every 50 seconds during installation.

### Remote Execution

For remote installs, the script:
1. Tests SSH connectivity
2. Copies necessary scripts to remote server
3. Executes via `ssh -t` (allocates TTY for sudo)
4. Cleans up temporary files

### Component Detection

The installer intelligently:
- Checks for existing Docker installation
- Detects running Ollama services
- Identifies already-pulled models
- Skips redundant steps

## Files Kept from Cleanup

We restored these important files that were almost removed:

- ✅ `install-docker.sh` - Still needed! Open WebUI requires Docker
- ✅ `install-ollama-native.sh` - Used by installation scripts

These are called by `setup-frankenllm.sh` and the modular installers.

## Future Enhancements

Potential additions:
- [ ] Model recommendation wizard based on GPU VRAM
- [ ] Backup/restore configuration
- [ ] Multi-server deployment (3+ machines)
- [ ] Automatic updates
- [ ] Health monitoring setup
- [ ] N8n integration wizard

## Support

If you have issues with the super installer:
1. Run with bash debug: `bash -x ./setup-frankenllm.sh`
2. Check logs in `/var/log/syslog` (systemd services)
3. Open a GitHub issue with the output

## Credits

Created to simplify FrankenLLM installation from "terminal expert required" to "anyone can do it!"

---

**Made the stitched-together monster easier to bring to life!** 🧟‍♂️⚡
