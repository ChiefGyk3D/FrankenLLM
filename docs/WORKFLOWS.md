# 🔀 FrankenLLM Installation Workflows

## Overview

FrankenLLM offers **two installation workflows** to suit different user needs:

1. **🚀 Super Installer Mode** (Recommended) - One command, full automation
2. **🛠️ Manual Mode** (Advanced) - Step-by-step control with configuration review

---

## 🚀 Super Installer Mode (Recommended)

### Command

```bash
./setup-frankenllm.sh
```

### What It Does

- **Interactive wizard** that asks questions and configures everything
- **Detects existing installations** (Docker, Ollama, services)
- **Offers smart choices**: Keep/upgrade/reinstall/skip existing components
- **Caches sudo password** so you only enter it once
- **Auto-detects GPUs** using `nvidia-smi`
- **Handles all installation** from start to finish

### Best For

- ✅ First-time installations
- ✅ Fresh Ubuntu Server 24.04 setups
- ✅ Upgrading existing installations
- ✅ Users who want a guided experience
- ✅ Reducing installation friction (single sudo prompt!)

### What You Get

- Complete installation with smart detection
- Color-coded progress output
- Auto-start configuration
- Boot behavior explanation
- Component selection (Docker, Ollama, WebUI, warmup, models)

### Limitations

- ⚠️ No manual `.env` editing before installation
- ⚠️ Must answer wizard questions interactively
- ⚠️ Not ideal for automated deployment scripts

---

## 🛠️ Manual Mode (Advanced)

### Commands

```bash
./configure.sh    # Step 1: Create .env configuration
./install.sh      # Step 2: Run installation
```

### What It Does

**Step 1 - `configure.sh`:**
- Interactive configuration wizard
- Creates `.env` file with your settings
- Can be edited manually before installation

**Step 2 - `install.sh`:**
- Reads configuration from `.env`
- Auto-detects local vs remote installation
- Calls appropriate installer (`local/install.sh` or `remote/install.sh`)

### Best For

- ✅ Advanced users who understand the architecture
- ✅ Need to review/edit `.env` before installation
- ✅ Integrating with existing automation/deployment scripts
- ✅ CI/CD pipelines (can prepare `.env` programmatically)
- ✅ Troubleshooting specific installation steps

### What You Get

- Full control over configuration
- Ability to edit `.env` manually between steps
- Traditional Unix philosophy (do one thing well)
- Reproducible installations (same `.env` = same result)

### Limitations

- ⚠️ No detection of existing installations (may overwrite)
- ⚠️ No sudo password caching (multiple prompts)
- ⚠️ No upgrade/reinstall options
- ⚠️ Must manually ensure dependencies are met

---

## 📊 Feature Comparison

| Feature | Super Installer | Manual Mode |
|---------|----------------|-------------|
| **Installation Command** | `./setup-frankenllm.sh` | `./configure.sh` + `./install.sh` |
| **Detection** | Docker, Ollama, services | None (blind install) |
| **Sudo Password** | Cached (enter once) | Multiple prompts |
| **GPU Detection** | Auto via `nvidia-smi` | Manual configuration |
| **Reinstall Handling** | Keep/upgrade/skip | Always overwrites |
| **Configuration Review** | No (immediate) | Yes (edit `.env`) |
| **Interactive Wizard** | Yes | Yes (both steps) |
| **Color Output** | Yes | Basic |
| **Progress Indicators** | Yes | Basic |
| **Automation-Friendly** | No (interactive) | Yes (prepare `.env`) |
| **Boot Config Display** | Yes | No |
| **Component Selection** | Yes (checkboxes) | No (installs all) |

---

## 🎯 Which Should You Use?

### Use Super Installer If...

- 🆕 This is your first time installing FrankenLLM
- 🔄 You're upgrading an existing installation
- 🎮 You have a dedicated LLM server with 2+ GPUs
- 🏠 Setting up a home lab multi-GPU machine
- ⏱️ You want the fastest, smoothest experience
- 🤝 You appreciate guided, user-friendly wizards

### Use Manual Mode If...

- 🔧 You need to review `.env` before installing
- 🤖 You're building automation/deployment scripts
- 🔍 You're troubleshooting a specific issue
- 📝 You need reproducible installations
- 🎛️ You prefer explicit control over each step
- 🏢 You're integrating with existing infrastructure

---

## 🔄 Can I Switch Between Workflows?

**Yes!** Both workflows:

- Use the same configuration format (`.env` file)
- Call the same underlying installers (`local/install.sh` or `remote/install.sh`)
- Create the same systemd services
- Result in identical installations

**Examples:**

```bash
# Start with super installer, later reconfigure manually
./setup-frankenllm.sh          # Initial install
./configure.sh                 # Later: Reconfigure
./install.sh                   # Reinstall with new config

# Start with manual mode, later upgrade with super installer
./configure.sh                 # Initial config
./install.sh                   # Initial install
./setup-frankenllm.sh          # Later: Upgrade (detects existing!)
```

---

## 🎛️ Day-to-Day Management (Both Workflows)

After installation (regardless of method), use **`manage.sh`** for operations:

```bash
./manage.sh status      # Check all services
./manage.sh start       # Start services
./manage.sh stop        # Stop services
./manage.sh restart     # Restart services
./manage.sh logs        # View logs
./manage.sh enable      # Enable auto-start
./manage.sh disable     # Disable auto-start
```

**This script works the same way after both installation methods!**

---

## 📦 Core Scripts at Root

Here's what each root script does:

| Script | Purpose | Used By |
|--------|---------|---------|
| `setup-frankenllm.sh` | Complete interactive installer | Super Installer workflow |
| `configure.sh` | Create `.env` configuration | Manual workflow (step 1) |
| `install.sh` | Run installation from `.env` | Manual workflow (step 2) |
| `manage.sh` | Day-to-day operations | Both workflows (after install) |
| `update.sh` | Update Ollama & Open WebUI | Both workflows (after install) |
| `config.sh` | Load `.env` variables | All scripts (internal) |

**All 6 scripts serve distinct purposes and are necessary!**

---

## 🔧 Additional Management Tools

These tools in `bin/` help manage your installation:

| Script | Purpose |
|--------|---------|
| `bin/add-model.sh` | Add models to specific GPUs (isolated storage) |
| `bin/warmup-config.sh` | Configure which models stay loaded in VRAM |
| `bin/health-check.sh` | Test service connectivity |
| `bin/test-llm.sh` | Test both LLMs with a query |

```bash
# Add models to specific GPUs
./bin/add-model.sh 0 gemma3:12b    # Add to GPU 0
./bin/add-model.sh 1 gemma3:4b     # Add to GPU 1
./bin/add-model.sh list            # Show all models

# Configure persistent warmup
./bin/warmup-config.sh set         # Interactive setup
./bin/warmup-config.sh status      # Show GPU memory

# Keep components updated
./update.sh check                  # Check for updates
./update.sh all                    # Update everything
```

---

## 🤝 Related Documentation

- [SUPER_INSTALLER.md](SUPER_INSTALLER.md) - Detailed guide to `setup-frankenllm.sh`
- [GETTING_STARTED.md](GETTING_STARTED.md) - Complete setup guide
- [CONFIGURATION.md](CONFIGURATION.md) - `.env` configuration reference
- [GPU_UPGRADE.md](GPU_UPGRADE.md) - Replace, add, or reconfigure GPUs
- [QUICKSTART.md](QUICKSTART.md) - Command reference
- [QUESTIONS_ANSWERED.md](QUESTIONS_ANSWERED.md) - FAQ

---

## 💡 Pro Tips

1. **First installation?** → Use Super Installer
2. **Need to script it?** → Use Manual Mode with prepared `.env`
3. **Upgrading software?** → Super Installer detects and handles it gracefully
4. **Upgrading hardware?** → See [GPU Upgrade Guide](GPU_UPGRADE.md) for GPU replacement
5. **Troubleshooting?** → Manual Mode gives you step-by-step control
6. **Daily operations?** → Always use `manage.sh` regardless of install method

---

*Stitched-together GPUs, but it lives!* 🧟⚡
