# FrankenLLM RAG Datasets

Curated dataset fetchers for building a comprehensive cybersecurity and IT knowledge base in Open WebUI.

## Quick Start

```bash
# List all available datasets
python3 scripts/fetch-rag-datasets.py --list

# Fetch everything
python3 scripts/fetch-rag-datasets.py --datasets all

# Fetch by category
python3 scripts/fetch-rag-datasets.py --category high-value
python3 scripts/fetch-rag-datasets.py --category day-to-day
python3 scripts/fetch-rag-datasets.py --category threat-intel

# Fetch specific datasets
python3 scripts/fetch-rag-datasets.py --datasets owasp mitre-attack cisa-kev

# Fetch and upload directly to Open WebUI
python3 scripts/fetch-rag-datasets.py --datasets all \
    --upload \
    --api-key sk-your-key-here \
    --webui-url http://localhost:3000
```

## Available Datasets

### High Value (Cybersecurity Fundamentals)

| Dataset | Description | Source | Est. Files |
|---------|-------------|--------|-----------|
| `owasp` | OWASP Cheat Sheet Series | GitHub/OWASP | ~130 |
| `mitre-attack` | MITRE ATT&CK Enterprise TTPs | GitHub/MITRE | ~700 |
| `nvd-cve` | NIST NVD recent CVEs (90 days) | NVD API 2.0 | varies |
| `nist-sp800` | NIST SP 800 publication index | Curated list | ~33 |
| `cis-benchmarks` | CIS Benchmark reference docs | Curated list | ~6 |

### Day-to-Day IT

| Dataset | Description | Source | Est. Files |
|---------|-------------|--------|-----------|
| `arch-wiki` | Arch Wiki articles (Linux admin) | MediaWiki API | ~80 |
| `rfc-core` | Essential internet RFCs | RFC Editor | ~40 |
| `kubernetes-docs` | Kubernetes concepts & tasks | GitHub/K8s | ~60 |
| `docker-docs` | Docker reference & best practices | GitHub/Docker | ~30 |
| `ansible-docs` | Ansible user guide & reference | GitHub/Ansible | ~30 |
| `terraform-docs` | Terraform/OpenTofu language & CLI | GitHub/HashiCorp | ~20 |

### Threat Intelligence

| Dataset | Description | Source | Est. Files |
|---------|-------------|--------|-----------|
| `cisa-kev` | CISA Known Exploited Vulns | CISA JSON feed | ~1100 |
| `sigma-rules` | Sigma detection rules | GitHub/SigmaHQ | ~500+ |
| `elastic-detection` | Elastic SIEM detection rules | GitHub/Elastic | ~500+ |

## How It Works

```
┌────────────────────┐     ┌──────────────────┐     ┌──────────────────┐
│   Data Sources     │     │   fetch-rag-     │     │   Open WebUI     │
│                    │     │   datasets.py     │     │                  │
│  GitHub repos      │────▶│                  │────▶│  Knowledge       │
│  REST APIs         │     │  Download        │     │  Collections     │
│  Public feeds      │     │  Process to .txt │     │                  │
│                    │     │  Upload via API  │     │  (embedded by    │
└────────────────────┘     └──────────────────┘     │  qwen3-embedding)│
                                                     └──────────────────┘
```

1. **Download** — Fetches raw data from public APIs and GitHub repos
2. **Process** — Converts to clean text files with metadata headers
3. **Save** — Stores in `rag-datasets/<dataset_name>/` directory
4. **Upload** (optional) — Creates knowledge collections in Open WebUI and uploads files via API

## Output Structure

```
rag-datasets/
├── owasp_cheat_sheets/
│   ├── Authentication_Cheat_Sheet.txt
│   ├── SQL_Injection_Prevention.txt
│   └── ...
├── mitre_attack/
│   ├── Phishing.txt
│   ├── Command_and_Scripting_Interpreter.txt
│   └── ...
├── nvd_cve/
│   ├── CVE-2024-xxxxx.txt
│   └── ...
├── cisa_kev/
│   ├── CVE-2024-xxxxx.txt
│   └── ...
├── sigma_rules/
│   ├── linux_xxxx.txt
│   └── ...
└── ...
```

Each text file includes a standardized header:

```
# Document Title

Source: <origin>
Category: <topic>

<content>
```

## Configuration

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `OPENWEBUI_API_KEY` | Open WebUI API key (sk-xxx) | — |
| `OPENWEBUI_URL` | Open WebUI base URL | `http://localhost:3000` |

### API Rate Limits

- **NVD API**: 5 requests/30 seconds (no API key). The fetcher auto-throttles.
- **GitHub API**: 60 requests/hour (unauthenticated). The fetcher paces requests with delays.
- **Arch Wiki**: No strict limit, but the fetcher uses 1s delays.

For large fetches, run datasets separately to stay within GitHub rate limits:

```bash
# Spread across time
python3 scripts/fetch-rag-datasets.py --datasets owasp mitre-attack
# ... wait 30 min ...
python3 scripts/fetch-rag-datasets.py --datasets sigma-rules elastic-detection
# ... wait 30 min ...
python3 scripts/fetch-rag-datasets.py --datasets arch-wiki rfc-core kubernetes-docs
```

### Resumability

The fetcher skips files that already exist on disk. If interrupted, just re-run the same command and it will pick up where it left off.

## Manual Upload

If you prefer manual upload instead of `--upload`:

1. Open WebUI → **Workspace** → **Knowledge**
2. Create a new collection (e.g., "MITRE ATT&CK")
3. Upload the `.txt` files from the corresponding `rag-datasets/` subdirectory

## Server Usage (Headless)

On the FrankenLLM server:

```bash
cd ~/FrankenLLM

# Fetch datasets (no GUI needed)
python3 scripts/fetch-rag-datasets.py --datasets all --output-dir rag-datasets

# Upload to local Open WebUI
python3 scripts/fetch-rag-datasets.py --datasets all \
    --upload \
    --api-key sk-your-key \
    --webui-url http://localhost:3000

# Check progress via log
tail -f rag-datasets/fetch-rag-datasets.log
```

## Keeping Data Fresh

Run periodically to get updated CVEs and new detection rules:

```bash
# Update threat intel (weekly recommended)
python3 scripts/fetch-rag-datasets.py --category threat-intel

# Update CVEs (delete old ones first for a rolling window)
rm -rf rag-datasets/nvd_cve/
python3 scripts/fetch-rag-datasets.py --datasets nvd-cve
```

## Dependencies

**None** — pure Python 3 stdlib. No pip packages required.
