#!/usr/bin/env python3
"""
FrankenLLM - RAG Dataset Fetcher
Downloads cybersecurity, IT, and threat intel datasets for Open WebUI RAG.

Each dataset module downloads, processes, and saves text files ready for
upload via wiki-pipeline.py's upload mechanism or manual Open WebUI import.

Usage:
    # List available datasets
    python3 scripts/fetch-rag-datasets.py --list

    # Fetch specific datasets
    python3 scripts/fetch-rag-datasets.py --datasets owasp mitre-attack

    # Fetch all datasets
    python3 scripts/fetch-rag-datasets.py --datasets all

    # Fetch by category
    python3 scripts/fetch-rag-datasets.py --category high-value
    python3 scripts/fetch-rag-datasets.py --category day-to-day
    python3 scripts/fetch-rag-datasets.py --category threat-intel

    # Upload to Open WebUI after fetching
    python3 scripts/fetch-rag-datasets.py --datasets all --upload --api-key YOUR_KEY

Environment variables:
    OPENWEBUI_API_KEY   - API key for Open WebUI
    OPENWEBUI_URL       - Base URL (default: http://localhost:3000)

No external dependencies required (pure Python stdlib).
"""

import argparse
import json
import logging
import os
import re
import sys
import tarfile
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from datetime import datetime, timezone
from io import BytesIO
from pathlib import Path

# ─── Config ──────────────────────────────────────────────────────────────────

DEFAULT_OUTPUT_DIR = "rag-datasets"
DEFAULT_WEBUI_URL = "http://localhost:3000"
USER_AGENT = "FrankenLLM-RAG-Fetcher/1.0"

# ─── Logging ─────────────────────────────────────────────────────────────────

log = logging.getLogger("rag-fetcher")


def setup_logging(output_dir: Path):
    log_path = output_dir / "fetch-rag-datasets.log"
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            logging.FileHandler(log_path),
            logging.StreamHandler(sys.stdout),
        ],
    )


# ─── HTTP Helper ─────────────────────────────────────────────────────────────

def http_get(url: str, timeout: int = 60, binary: bool = False):
    """Simple HTTP GET with User-Agent."""
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        data = resp.read()
        if binary:
            return data
        return data.decode("utf-8")


def http_get_json(url: str, timeout: int = 60):
    """HTTP GET returning parsed JSON."""
    return json.loads(http_get(url, timeout))


def sanitize_filename(name: str, max_len: int = 120) -> str:
    """Create a filesystem-safe filename."""
    name = re.sub(r'[^\w\s\-.]', '', name)
    name = re.sub(r'\s+', '_', name.strip())
    return name[:max_len]


# ─── Dataset Registry ────────────────────────────────────────────────────────

DATASETS = {}


def dataset(name: str, category: str, description: str):
    """Decorator to register a dataset fetcher."""
    def wrapper(func):
        DATASETS[name] = {
            "func": func,
            "category": category,
            "description": description,
        }
        return func
    return wrapper


# ═══════════════════════════════════════════════════════════════════════════════
# HIGH VALUE DATASETS
# ═══════════════════════════════════════════════════════════════════════════════

@dataset("owasp", "high-value",
         "OWASP Cheat Sheet Series — 130+ security cheat sheets")
def fetch_owasp(output_dir: Path):
    """Download OWASP Cheat Sheet Series from GitHub."""
    ds_dir = output_dir / "owasp_cheat_sheets"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # Get file listing from GitHub API
    api_url = "https://api.github.com/repos/OWASP/CheatSheetSeries/contents/cheatsheets"
    log.info("Fetching OWASP Cheat Sheet index...")

    try:
        files = http_get_json(api_url)
    except Exception as e:
        log.error(f"Failed to list OWASP cheat sheets: {e}")
        return 0

    count = 0
    md_files = [f for f in files if f["name"].endswith(".md")]
    log.info(f"Found {len(md_files)} cheat sheets")

    for i, f in enumerate(md_files):
        filename = f["name"]
        safe_name = sanitize_filename(filename.replace(".md", "")) + ".txt"
        filepath = ds_dir / safe_name

        if filepath.exists() and filepath.stat().st_size > 100:
            count += 1
            continue

        try:
            content = http_get(f["download_url"])
            # Strip markdown image links but keep text
            content = re.sub(r'!\[.*?\]\(.*?\)', '', content)

            with open(filepath, "w", encoding="utf-8") as out:
                out.write(f"# OWASP: {filename.replace('.md', '').replace('_', ' ')}\n\n")
                out.write("Source: OWASP Cheat Sheet Series\n")
                out.write("Category: Cybersecurity\n\n")
                out.write(content)

            count += 1
            if count % 20 == 0:
                log.info(f"  [{count}/{len(md_files)}] downloaded")
            time.sleep(0.5)  # Rate limit
        except Exception as e:
            log.warning(f"  Failed: {filename}: {e}")

    log.info(f"OWASP: {count} cheat sheets saved")
    return count


@dataset("mitre-attack", "high-value",
         "MITRE ATT&CK — Tactics, techniques, and procedures")
def fetch_mitre_attack(output_dir: Path):
    """Download MITRE ATT&CK enterprise techniques."""
    ds_dir = output_dir / "mitre_attack"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # STIX bundle from MITRE's GitHub
    url = "https://raw.githubusercontent.com/mitre/cti/master/enterprise-attack/enterprise-attack.json"
    log.info("Downloading MITRE ATT&CK Enterprise dataset...")

    try:
        data = http_get_json(url, timeout=120)
    except Exception as e:
        log.error(f"Failed to download ATT&CK data: {e}")
        return 0

    count = 0
    objects = data.get("objects", [])

    for obj in objects:
        obj_type = obj.get("type", "")

        # We want attack-pattern (techniques), malware, tool, intrusion-set
        if obj_type not in ("attack-pattern", "malware", "tool", "intrusion-set"):
            continue

        name = obj.get("name", "Unknown")
        description = obj.get("description", "")
        if not description or len(description) < 50:
            continue

        # Build rich text
        lines = [f"# {name}\n"]
        lines.append(f"Source: MITRE ATT&CK\nType: {obj_type}\n")

        # External references (ATT&CK IDs)
        ext_refs = obj.get("external_references", [])
        for ref in ext_refs:
            if ref.get("source_name") == "mitre-attack":
                lines.append(f"ATT&CK ID: {ref.get('external_id', 'N/A')}")
                lines.append(f"URL: {ref.get('url', 'N/A')}")
                break

        # Kill chain phases
        phases = obj.get("kill_chain_phases", [])
        if phases:
            tactic_names = [p["phase_name"].replace("-", " ").title() for p in phases]
            lines.append(f"Tactics: {', '.join(tactic_names)}")

        # Platforms
        platforms = obj.get("x_mitre_platforms", [])
        if platforms:
            lines.append(f"Platforms: {', '.join(platforms)}")

        lines.append(f"\n{description}")

        # Detection
        detection = obj.get("x_mitre_detection", "")
        if detection:
            lines.append(f"\n## Detection\n\n{detection}")

        safe_name = sanitize_filename(name) + ".txt"
        filepath = ds_dir / safe_name

        with open(filepath, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))

        count += 1

    log.info(f"MITRE ATT&CK: {count} entries saved")
    return count


@dataset("nvd-cve", "high-value",
         "NIST NVD — Recent CVEs (last 90 days)")
def fetch_nvd_cve(output_dir: Path):
    """Download recent CVEs from NVD API 2.0."""
    ds_dir = output_dir / "nvd_cve"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # NVD API 2.0 — last 90 days, no API key needed (rate limited to 5 req/30s)
    # Fetch in pages of 500
    now = datetime.now(timezone.utc)
    start = now.replace(hour=0, minute=0, second=0, microsecond=0)
    from datetime import timedelta
    start = start - timedelta(days=90)

    start_str = start.strftime("%Y-%m-%dT%H:%M:%S.000")
    end_str = now.strftime("%Y-%m-%dT%H:%M:%S.000")

    base_url = "https://services.nvd.nist.gov/rest/json/cves/2.0"
    params = {
        "pubStartDate": start_str,
        "pubEndDate": end_str,
        "resultsPerPage": 200,
        "startIndex": 0,
    }

    count = 0
    total_results = None
    log.info("Fetching recent CVEs from NVD (last 90 days)...")

    while True:
        url = f"{base_url}?{urllib.parse.urlencode(params)}"
        try:
            data = http_get_json(url, timeout=120)
        except Exception as e:
            log.error(f"NVD API error at index {params['startIndex']}: {e}")
            # Rate limit — wait and retry once
            time.sleep(10)
            try:
                data = http_get_json(url, timeout=120)
            except Exception as e2:
                log.error(f"NVD API retry failed: {e2}")
                break

        if total_results is None:
            total_results = data.get("totalResults", 0)
            log.info(f"Total CVEs in range: {total_results}")

        vulns = data.get("vulnerabilities", [])
        if not vulns:
            break

        for item in vulns:
            cve = item.get("cve", {})
            cve_id = cve.get("id", "")
            descriptions = cve.get("descriptions", [])

            # Get English description
            desc = ""
            for d in descriptions:
                if d.get("lang") == "en":
                    desc = d.get("value", "")
                    break

            if not desc or desc == "Rejected reason: DO NOT USE":
                continue

            # CVSS scores
            metrics = cve.get("metrics", {})
            cvss_line = ""
            for version in ["cvssMetricV31", "cvssMetricV30", "cvssMetricV2"]:
                if version in metrics:
                    cvss_data = metrics[version][0].get("cvssData", {})
                    score = cvss_data.get("baseScore", "N/A")
                    severity = cvss_data.get("baseSeverity", "N/A")
                    cvss_line = f"CVSS Score: {score} ({severity})"
                    break

            # Affected products (CPE)
            configs = cve.get("configurations", [])
            affected = []
            for config in configs[:3]:  # Limit to avoid huge files
                for node in config.get("nodes", []):
                    for match in node.get("cpeMatch", [])[:5]:
                        criteria = match.get("criteria", "")
                        # Extract readable product from CPE string
                        parts = criteria.split(":")
                        if len(parts) >= 5:
                            vendor = parts[3].replace("_", " ")
                            product = parts[4].replace("_", " ")
                            affected.append(f"{vendor} {product}")

            lines = [f"# {cve_id}\n"]
            lines.append(f"Source: NIST National Vulnerability Database")
            lines.append(f"Published: {cve.get('published', 'N/A')}")
            if cvss_line:
                lines.append(cvss_line)
            if affected:
                lines.append(f"Affected: {', '.join(set(affected[:10]))}")
            lines.append(f"\n{desc}")

            # References
            refs = cve.get("references", [])
            if refs:
                lines.append("\n## References\n")
                for ref in refs[:5]:
                    lines.append(f"- {ref.get('url', '')}")

            filepath = ds_dir / f"{cve_id}.txt"
            with open(filepath, "w", encoding="utf-8") as f:
                f.write("\n".join(lines))

            count += 1

        log.info(f"  CVEs fetched: {count}/{total_results}")
        params["startIndex"] += len(vulns)

        if params["startIndex"] >= total_results:
            break

        # NVD rate limit: 5 requests per 30 seconds without API key
        time.sleep(6.5)

    log.info(f"NVD CVE: {count} entries saved")
    return count


@dataset("nist-sp800", "high-value",
         "NIST SP 800 special publications index and summaries")
def fetch_nist_sp800(output_dir: Path):
    """Fetch NIST SP 800 series publication metadata and abstracts."""
    ds_dir = output_dir / "nist_sp800"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # Key SP 800 publications with their titles
    key_pubs = [
        ("800-53", "Security and Privacy Controls for Information Systems"),
        ("800-53A", "Assessing Security and Privacy Controls"),
        ("800-53B", "Control Baselines for Information Systems"),
        ("800-171", "Protecting Controlled Unclassified Information"),
        ("800-171A", "Assessing CUI Security Requirements"),
        ("800-37", "Risk Management Framework"),
        ("800-39", "Managing Information Security Risk"),
        ("800-30", "Guide for Conducting Risk Assessments"),
        ("800-61", "Computer Security Incident Handling Guide"),
        ("800-63", "Digital Identity Guidelines"),
        ("800-63A", "Enrollment and Identity Proofing"),
        ("800-63B", "Authentication and Lifecycle Management"),
        ("800-88", "Guidelines for Media Sanitization"),
        ("800-115", "Technical Guide to Information Security Testing"),
        ("800-122", "Guide to Protecting PII Confidentiality"),
        ("800-123", "Guide to General Server Security"),
        ("800-124", "Guidelines for Managing Mobile Device Security"),
        ("800-125", "Guide to Security for Full Virtualization Technologies"),
        ("800-128", "Guide for Security-Focused Configuration Management"),
        ("800-137", "Information Security Continuous Monitoring"),
        ("800-144", "Guidelines on Security and Privacy in Public Cloud"),
        ("800-145", "The NIST Definition of Cloud Computing"),
        ("800-160", "Systems Security Engineering"),
        ("800-161", "Cybersecurity Supply Chain Risk Management"),
        ("800-175A", "Guideline for Using Cryptographic Standards"),
        ("800-175B", "Guideline for Using Cryptographic Standards: Cryptographic Mechanisms"),
        ("800-181", "NICE Cybersecurity Workforce Framework"),
        ("800-183", "Networks of Things"),
        ("800-184", "Guide for Cybersecurity Event Recovery"),
        ("800-190", "Application Container Security Guide"),
        ("800-207", "Zero Trust Architecture"),
        ("800-210", "General Access Control Guidance for Cloud Systems"),
        ("800-218", "Secure Software Development Framework"),
    ]

    count = 0
    for pub_num, title in key_pubs:
        filepath = ds_dir / f"NIST_SP_{sanitize_filename(pub_num)}.txt"

        if filepath.exists() and filepath.stat().st_size > 100:
            count += 1
            continue

        lines = [
            f"# NIST SP {pub_num}: {title}\n",
            f"Source: NIST Computer Security Resource Center",
            f"Type: Special Publication",
            f"Series: SP 800",
            f"URL: https://csrc.nist.gov/pubs/sp/800/{pub_num.lower().replace('800-', '')}/final",
            f"\n## Overview\n",
            f"NIST Special Publication {pub_num} — {title}.",
            f"\nThis is a reference entry for the NIST SP 800 series. "
            f"For the full publication, visit the NIST CSRC website.",
        ]

        with open(filepath, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
        count += 1

    log.info(f"NIST SP 800: {count} publication entries saved")
    return count


@dataset("cis-benchmarks", "high-value",
         "CIS Benchmarks overview — hardening reference by platform")
def fetch_cis_benchmarks(output_dir: Path):
    """Create CIS Benchmark reference documents."""
    ds_dir = output_dir / "cis_benchmarks"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # CIS doesn't have a public API, so we create reference docs
    # for the most important benchmarks
    benchmarks = [
        ("Ubuntu_Linux", "CIS Ubuntu Linux Benchmark", [
            "Filesystem configuration and partitioning",
            "Software updates and package management (apt)",
            "Filesystem integrity checking (AIDE)",
            "Secure boot settings and GRUB configuration",
            "Process hardening and core dumps",
            "Mandatory access control (AppArmor)",
            "Warning banners and MOTD",
            "Network configuration (IP forwarding, ICMP, TCP wrappers)",
            "Firewall configuration (ufw/iptables/nftables)",
            "Logging and auditing (rsyslog, journald, auditd)",
            "Cron and at job configuration",
            "SSH server hardening",
            "PAM and password configuration",
            "User account restrictions and umask",
            "File permissions (/etc/passwd, /etc/shadow, etc.)",
        ]),
        ("Docker", "CIS Docker Benchmark", [
            "Host configuration and kernel parameters",
            "Docker daemon configuration",
            "Docker daemon configuration files permissions",
            "Container images and build file",
            "Container runtime configuration",
            "Docker security operations",
            "Docker Swarm configuration",
            "Docker Enterprise configuration",
            "Limit container capabilities (--cap-drop)",
            "Use read-only containers where possible",
            "Resource limits (CPU, memory)",
            "Network segmentation between containers",
            "Content trust and image signing",
            "Logging driver configuration",
            "Secrets management",
        ]),
        ("Kubernetes", "CIS Kubernetes Benchmark", [
            "Control plane components (API server, controller, scheduler)",
            "etcd configuration and encryption",
            "Control plane configuration files",
            "Worker node configuration (kubelet)",
            "Pod security standards",
            "Network policies",
            "RBAC and service accounts",
            "Secrets management",
            "Pod security admission",
            "General policies (namespaces, resource quotas)",
        ]),
        ("Windows_Server", "CIS Windows Server Benchmark", [
            "Account policies (password, lockout, Kerberos)",
            "Local policies (audit, user rights, security options)",
            "Event log configuration",
            "System services hardening",
            "Registry permissions",
            "Windows Firewall with Advanced Security",
            "Advanced audit policy configuration",
            "Administrative templates (Group Policy)",
        ]),
        ("NGINX", "CIS NGINX Benchmark", [
            "Installation and initial configuration",
            "Basic configuration (worker processes, error logs)",
            "Logging configuration",
            "TLS/SSL configuration",
            "Request filtering (methods, URIs)",
            "Timeout settings",
            "Information disclosure prevention",
            "Rate limiting and connection limits",
            "Access controls and authentication",
        ]),
        ("PostgreSQL", "CIS PostgreSQL Benchmark", [
            "Installation and patches",
            "Directory and file permissions",
            "Logging and auditing",
            "User access and authorization",
            "Connection and authentication (pg_hba.conf)",
            "PostgreSQL settings (postgresql.conf)",
            "Replication security",
            "SSL/TLS configuration",
        ]),
    ]

    count = 0
    for platform, title, controls in benchmarks:
        filepath = ds_dir / f"CIS_{sanitize_filename(platform)}.txt"

        lines = [
            f"# {title}\n",
            f"Source: Center for Internet Security (CIS)",
            f"Type: Security Benchmark",
            f"Platform: {platform.replace('_', ' ')}",
            f"URL: https://www.cisecurity.org/benchmark/{platform.lower().replace('_', '-')}",
            f"\n## Key Control Areas\n",
        ]

        for i, control in enumerate(controls, 1):
            lines.append(f"{i}. {control}")

        lines.append(f"\n## About CIS Benchmarks\n")
        lines.append(
            "CIS Benchmarks are consensus-based security configuration guides. "
            "They provide Level 1 (practical, minimal impact) and Level 2 "
            "(defense in depth, may affect functionality) recommendations. "
            "Download the full benchmark from cisecurity.org for "
            "detailed implementation steps."
        )

        with open(filepath, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
        count += 1

    log.info(f"CIS Benchmarks: {count} reference documents saved")
    return count


# ═══════════════════════════════════════════════════════════════════════════════
# DAY-TO-DAY IT DATASETS
# ═══════════════════════════════════════════════════════════════════════════════

@dataset("arch-wiki", "day-to-day",
         "Arch Wiki — Comprehensive Linux documentation")
def fetch_arch_wiki(output_dir: Path):
    """Download Arch Wiki articles via the MediaWiki API."""
    ds_dir = output_dir / "arch_wiki"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # Key Arch Wiki articles for IT/sysadmin work
    articles = [
        "Systemd", "Systemd/Timers", "Systemd/Journal",
        "Iptables", "Nftables", "Firewalld",
        "SSH", "OpenSSH", "Fail2ban",
        "Docker", "Podman", "LXC",
        "Nginx", "Apache HTTP Server",
        "PostgreSQL", "MariaDB", "Redis",
        "LUKS", "Dm-crypt", "GPG",
        "Git", "Rsync", "Wget", "Curl",
        "ZFS", "Btrfs", "LVM",
        "RAID", "Swap", "Fstab",
        "NetworkManager", "Systemd-networkd", "WireGuard", "OpenVPN",
        "DNS", "Dnsmasq", "BIND",
        "NFS", "Samba", "SSHFS",
        "UFW", "SELinux", "AppArmor",
        "Cron", "Pacman", "AUR",
        "GnuPG", "PAM", "Sudo",
        "Kernel", "Kernel parameters", "Sysctl",
        "GRUB", "Dracut",
        "Power management", "CPU frequency scaling",
        "PCI passthrough via OVMF", "QEMU", "KVM", "Libvirt",
        "NVIDIA", "Xorg", "Wayland",
        "PipeWire", "PulseAudio",
        "Tmux", "GNU Screen",
        "Vim", "Neovim",
        "Zsh", "Bash",
        "Disk encryption", "Data-at-rest encryption",
        "Benchmarking", "Improving performance",
        "Security", "General recommendations",
        "Network configuration", "Wireless network configuration",
        "Bluetooth", "USB",
        "Backlight", "Display Power Management Signaling",
        "Smartcards", "YubiKey",
    ]

    count = 0
    for i, title in enumerate(articles):
        safe_name = sanitize_filename(title) + ".txt"
        filepath = ds_dir / safe_name

        if filepath.exists() and filepath.stat().st_size > 200:
            count += 1
            continue

        params = urllib.parse.urlencode({
            "action": "query",
            "titles": title,
            "prop": "extracts",
            "explaintext": "1",
            "format": "json",
        })
        url = f"https://wiki.archlinux.org/api.php?{params}"

        try:
            data = http_get_json(url)
            pages = data.get("query", {}).get("pages", {})
            for page_id, page in pages.items():
                if page_id == "-1":
                    log.warning(f"  Arch Wiki: '{title}' not found")
                    break
                extract = page.get("extract", "").strip()
                if not extract or len(extract) < 100:
                    log.warning(f"  Arch Wiki: '{title}' too short")
                    break

                with open(filepath, "w", encoding="utf-8") as f:
                    f.write(f"# {page.get('title', title)}\n\n")
                    f.write(f"Source: Arch Wiki\n")
                    f.write(f"Category: Linux Administration\n\n")
                    f.write(extract)
                count += 1
                break

            if (i + 1) % 20 == 0:
                log.info(f"  Arch Wiki: [{i+1}/{len(articles)}] fetched")
            time.sleep(1.0)  # Rate limit
        except Exception as e:
            log.warning(f"  Arch Wiki: failed to fetch '{title}': {e}")

    log.info(f"Arch Wiki: {count} articles saved")
    return count


@dataset("rfc-core", "day-to-day",
         "Core RFCs — Essential internet standards (HTTP, DNS, TLS, etc.)")
def fetch_core_rfcs(output_dir: Path):
    """Download essential RFC documents as plain text."""
    ds_dir = output_dir / "rfc_core"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # Most relevant RFCs for IT/security work
    rfcs = [
        (791, "Internet Protocol (IPv4)"),
        (793, "Transmission Control Protocol (TCP)"),
        (768, "User Datagram Protocol (UDP)"),
        (1035, "Domain Names — Implementation and Specification"),
        (2616, "HTTP/1.1"),
        (7230, "HTTP/1.1 Message Syntax and Routing"),
        (7231, "HTTP/1.1 Semantics and Content"),
        (7540, "HTTP/2"),
        (9110, "HTTP Semantics"),
        (9113, "HTTP/2"),
        (9114, "HTTP/3"),
        (2818, "HTTP Over TLS"),
        (5246, "TLS Protocol Version 1.2"),
        (8446, "TLS Protocol Version 1.3"),
        (4253, "SSH Transport Layer Protocol"),
        (4254, "SSH Connection Protocol"),
        (7519, "JSON Web Token (JWT)"),
        (7617, "HTTP Basic Authentication"),
        (6749, "OAuth 2.0 Authorization Framework"),
        (6750, "OAuth 2.0 Bearer Token Usage"),
        (8259, "JavaScript Object Notation (JSON)"),
        (5321, "Simple Mail Transfer Protocol (SMTP)"),
        (3986, "Uniform Resource Identifier (URI)"),
        (2119, "Key words for use in RFCs (MUST, SHOULD, etc.)"),
        (4271, "Border Gateway Protocol 4 (BGP-4)"),
        (6066, "TLS Extensions"),
        (5280, "X.509 PKI Certificate and CRL Profile"),
        (4648, "Base16, Base32, Base64 Encodings"),
        (7489, "DMARC"),
        (6376, "DKIM Signatures"),
        (7208, "SPF"),
        (8555, "ACME Protocol (Let's Encrypt)"),
        (7942, "Improving Awareness of Running Code"),
        (8484, "DNS Queries over HTTPS (DoH)"),
        (7858, "DNS over TLS (DoT)"),
        (8767, "DNS Push Notifications"),
        (3596, "DNS Extensions for IPv6"),
        (8200, "IPv6 Specification"),
        (7516, "JSON Web Encryption (JWE)"),
        (7515, "JSON Web Signature (JWS)"),
    ]

    count = 0
    for rfc_num, title in rfcs:
        filepath = ds_dir / f"RFC_{rfc_num}.txt"

        if filepath.exists() and filepath.stat().st_size > 500:
            count += 1
            continue

        url = f"https://www.rfc-editor.org/rfc/rfc{rfc_num}.txt"
        try:
            content = http_get(url, timeout=30)

            with open(filepath, "w", encoding="utf-8") as f:
                f.write(f"# RFC {rfc_num}: {title}\n\n")
                f.write(f"Source: IETF RFC Editor\n")
                f.write(f"Category: Internet Standards\n\n")
                f.write(content)
            count += 1

            if count % 10 == 0:
                log.info(f"  RFCs: [{count}/{len(rfcs)}] downloaded")
            time.sleep(0.5)
        except Exception as e:
            log.warning(f"  RFC {rfc_num}: failed: {e}")

    log.info(f"Core RFCs: {count} documents saved")
    return count


@dataset("kubernetes-docs", "day-to-day",
         "Kubernetes documentation — Core concepts and reference")
def fetch_kubernetes_docs(output_dir: Path):
    """Fetch Kubernetes documentation from GitHub."""
    ds_dir = output_dir / "kubernetes_docs"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # Key docs from the k8s website repo
    base_url = "https://api.github.com/repos/kubernetes/website/contents/content/en/docs"
    key_dirs = [
        "concepts/overview",
        "concepts/workloads",
        "concepts/services-networking",
        "concepts/storage",
        "concepts/configuration",
        "concepts/security",
        "concepts/scheduling-eviction",
        "tasks/configure-pod-container",
        "tasks/manage-daemon",
    ]

    count = 0
    for dir_path in key_dirs:
        url = f"{base_url}/{dir_path}"
        try:
            files = http_get_json(url)
        except Exception as e:
            log.warning(f"  K8s docs: couldn't list {dir_path}: {e}")
            continue

        md_files = [f for f in files if isinstance(f, dict) and f.get("name", "").endswith(".md")]
        for f in md_files:
            filename = f["name"]
            safe_name = sanitize_filename(f"{dir_path}_{filename}".replace("/", "_").replace(".md", "")) + ".txt"
            filepath = ds_dir / safe_name

            if filepath.exists() and filepath.stat().st_size > 100:
                count += 1
                continue

            try:
                content = http_get(f["download_url"])
                with open(filepath, "w", encoding="utf-8") as out:
                    out.write(f"# Kubernetes: {filename.replace('.md', '').replace('-', ' ').replace('_', ' ').title()}\n\n")
                    out.write(f"Source: Kubernetes Documentation\n")
                    out.write(f"Section: {dir_path}\n\n")
                    out.write(content)
                count += 1
                time.sleep(0.5)
            except Exception as e:
                log.warning(f"  K8s: failed {filename}: {e}")

        time.sleep(1)

    log.info(f"Kubernetes docs: {count} pages saved")
    return count


@dataset("docker-docs", "day-to-day",
         "Docker reference — Dockerfile, Compose, CLI")
def fetch_docker_docs(output_dir: Path):
    """Fetch key Docker documentation from GitHub."""
    ds_dir = output_dir / "docker_docs"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # Docker docs are in docs.docker.com repo — fetch key reference pages
    base = "https://api.github.com/repos/docker/docs/contents/content"
    key_paths = [
        "manuals/build/building/best-practices.md",
        "manuals/compose/how-tos/networking.md",
        "manuals/compose/how-tos/environment-variables.md",
        "manuals/engine/daemon/logs.md",
        "manuals/engine/security/_index.md",
        "manuals/engine/network/_index.md",
        "manuals/engine/storage/_index.md",
        "manuals/engine/containers/resource_constraints.md",
    ]

    # Also try to list some directories
    dir_paths = [
        "reference/compose-file",
        "reference/dockerfile",
    ]

    count = 0

    # Direct files
    for path in key_paths:
        filename = path.split("/")[-1]
        safe_name = sanitize_filename(path.replace("/", "_").replace(".md", "")) + ".txt"
        filepath = ds_dir / safe_name

        if filepath.exists() and filepath.stat().st_size > 100:
            count += 1
            continue

        url = f"https://raw.githubusercontent.com/docker/docs/main/content/{path}"
        try:
            content = http_get(url)
            with open(filepath, "w", encoding="utf-8") as f:
                f.write(f"# Docker: {filename.replace('.md', '').replace('_', ' ').replace('-', ' ').title()}\n\n")
                f.write(f"Source: Docker Documentation\n\n")
                f.write(content)
            count += 1
            time.sleep(0.5)
        except Exception as e:
            log.warning(f"  Docker: failed {path}: {e}")

    # Directory listings
    for dir_path in dir_paths:
        url = f"{base}/{dir_path}"
        try:
            files = http_get_json(url)
            md_files = [f for f in files if isinstance(f, dict) and f.get("name", "").endswith(".md")]
            for f in md_files:
                safe_name = sanitize_filename(f"{dir_path}_{f['name']}".replace("/", "_").replace(".md", "")) + ".txt"
                fp = ds_dir / safe_name
                if fp.exists() and fp.stat().st_size > 100:
                    count += 1
                    continue
                try:
                    content = http_get(f["download_url"])
                    with open(fp, "w", encoding="utf-8") as out:
                        out.write(f"# Docker: {f['name'].replace('.md', '').replace('-', ' ').title()}\n\n")
                        out.write(f"Source: Docker Documentation\nSection: {dir_path}\n\n")
                        out.write(content)
                    count += 1
                    time.sleep(0.5)
                except Exception as e:
                    log.warning(f"  Docker: failed {f['name']}: {e}")
            time.sleep(1)
        except Exception as e:
            log.warning(f"  Docker: couldn't list {dir_path}: {e}")

    log.info(f"Docker docs: {count} pages saved")
    return count


@dataset("ansible-docs", "day-to-day",
         "Ansible reference — Key modules and concepts")
def fetch_ansible_docs(output_dir: Path):
    """Fetch Ansible documentation from GitHub."""
    ds_dir = output_dir / "ansible_docs"
    ds_dir.mkdir(parents=True, exist_ok=True)

    base = "https://api.github.com/repos/ansible/ansible/contents/docs/docsite/rst"
    key_dirs = [
        "user_guide",
        "reference_appendices",
    ]

    count = 0
    for dir_path in key_dirs:
        url = f"{base}/{dir_path}"
        try:
            files = http_get_json(url)
        except Exception as e:
            log.warning(f"  Ansible: couldn't list {dir_path}: {e}")
            continue

        rst_files = [f for f in files if isinstance(f, dict) and f.get("name", "").endswith(".rst")]
        for f in rst_files[:30]:  # Limit per directory
            safe_name = sanitize_filename(f["name"].replace(".rst", "")) + ".txt"
            filepath = ds_dir / safe_name

            if filepath.exists() and filepath.stat().st_size > 100:
                count += 1
                continue

            try:
                content = http_get(f["download_url"])
                with open(filepath, "w", encoding="utf-8") as out:
                    out.write(f"# Ansible: {f['name'].replace('.rst', '').replace('_', ' ').title()}\n\n")
                    out.write(f"Source: Ansible Documentation\n\n")
                    out.write(content)
                count += 1
                time.sleep(0.5)
            except Exception as e:
                log.warning(f"  Ansible: failed {f['name']}: {e}")

        time.sleep(1)

    log.info(f"Ansible docs: {count} pages saved")
    return count


@dataset("terraform-docs", "day-to-day",
         "Terraform/OpenTofu documentation — Core concepts")
def fetch_terraform_docs(output_dir: Path):
    """Fetch Terraform documentation from GitHub."""
    ds_dir = output_dir / "terraform_docs"
    ds_dir.mkdir(parents=True, exist_ok=True)

    base = "https://api.github.com/repos/hashicorp/terraform/contents/website/docs"
    key_dirs = ["language", "cli", "internals"]

    count = 0
    for dir_path in key_dirs:
        url = f"{base}/{dir_path}"
        try:
            items = http_get_json(url)
        except Exception as e:
            log.warning(f"  Terraform: couldn't list {dir_path}: {e}")
            continue

        for item in items:
            if not isinstance(item, dict):
                continue
            name = item.get("name", "")
            if not name.endswith(".mdx") and not name.endswith(".md"):
                continue

            safe_name = sanitize_filename(f"{dir_path}_{name}".replace("/", "_").replace(".mdx", "").replace(".md", "")) + ".txt"
            filepath = ds_dir / safe_name

            if filepath.exists() and filepath.stat().st_size > 100:
                count += 1
                continue

            try:
                content = http_get(item["download_url"])
                with open(filepath, "w", encoding="utf-8") as f:
                    f.write(f"# Terraform: {name.replace('.mdx', '').replace('.md', '').replace('-', ' ').title()}\n\n")
                    f.write(f"Source: Terraform Documentation\nSection: {dir_path}\n\n")
                    f.write(content)
                count += 1
                time.sleep(0.5)
            except Exception as e:
                log.warning(f"  Terraform: failed {name}: {e}")

        time.sleep(1)

    log.info(f"Terraform docs: {count} pages saved")
    return count


# ═══════════════════════════════════════════════════════════════════════════════
# MEDICAL / HEALTH DATASETS
# ═══════════════════════════════════════════════════════════════════════════════

@dataset("medlineplus", "medical",
         "MedlinePlus Health Topics — NIH consumer health info")
def fetch_medlineplus(output_dir: Path):
    """Download MedlinePlus health topic summaries via the NLM web-services API."""
    ds_dir = output_dir / "medlineplus"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # MedlinePlus Connect returns XML; we use their JSON health-topics endpoint
    url = "https://connect.medlineplus.gov/service?mainSearchCriteria.v.cs=2.16.840.1.113883.6.90&knowledgeResponseType=application/json"
    # Simpler approach: scrape the A-Z health topic list via their public XML feed
    xml_url = "https://medlineplus.gov/xml/mplus_topics_2025-04-04.xml"  # updated quarterly
    # Most reliable: use their web-services REST endpoint for health topics
    topics_url = "https://wsearch.nlm.nih.gov/ws/query?db=healthTopics&term=health&retmax=1500"

    log.info("Fetching MedlinePlus health topics...")

    # Use the public XML topic list
    try:
        xml_data = http_get("https://medlineplus.gov/xml/mplus_topics_2026-04-04.xml", timeout=120)
    except Exception:
        # Fallback — the date in the filename changes quarterly
        try:
            xml_data = http_get("https://medlineplus.gov/xml/mplus_topics_2026-01-04.xml", timeout=120)
        except Exception:
            # Last resort: try fetching the topic index page
            log.warning("MedlinePlus XML feed unavailable, using A-Z page scraping")
            return _fetch_medlineplus_az(ds_dir)

    # Parse XML health topics
    count = 0
    # Simple XML parsing — each <health-topic> has title, url, full-summary
    topics = re.findall(
        r'<health-topic[^>]*title="([^"]+)"[^>]*url="([^"]+)"[^>]*>'
        r'(.*?)</health-topic>',
        xml_data, re.DOTALL
    )

    for title, topic_url, body in topics:
        summary_match = re.search(r'<full-summary>(.*?)</full-summary>', body, re.DOTALL)
        if not summary_match:
            continue
        summary = summary_match.group(1)
        # Strip HTML tags
        summary = re.sub(r'<[^>]+>', '', summary).strip()
        if len(summary) < 100:
            continue

        # Extract related groups/aliases
        aliases = re.findall(r'<also-called>(.*?)</also-called>', body)
        groups = re.findall(r'<group[^>]*url="[^"]*">([^<]+)</group>', body)

        safe_name = sanitize_filename(title) + ".txt"
        filepath = ds_dir / safe_name

        with open(filepath, "w", encoding="utf-8") as f:
            f.write(f"# {title}\n\n")
            f.write("Source: MedlinePlus (U.S. National Library of Medicine)\n")
            f.write("Category: Medical / Health\n")
            if aliases:
                f.write(f"Also Known As: {', '.join(aliases)}\n")
            if groups:
                f.write(f"Topic Groups: {', '.join(groups)}\n")
            f.write(f"URL: {topic_url}\n\n")
            f.write(summary)

        count += 1

    log.info(f"MedlinePlus: {count} health topics saved")
    return count


def _fetch_medlineplus_az(ds_dir: Path):
    """Fallback: scrape MedlinePlus A-Z index pages."""
    count = 0
    for letter in "ABCDEFGHIJKLMNOPQRSTUVWXYZ":
        url = f"https://medlineplus.gov/encyclopedia.html"
        # The A-Z pages are hard to parse cleanly; just note we tried
        pass
    log.warning("MedlinePlus A-Z scrape not fully implemented — use XML feed")
    return count


@dataset("openfda", "medical",
         "openFDA Drug Labels — FDA drug label data (indications, warnings, interactions)")
def fetch_openfda(output_dir: Path):
    """Download drug label summaries from openFDA API."""
    ds_dir = output_dir / "openfda_drug_labels"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # Fetch top drugs by count, 500 at a time (API limit)
    # We'll grab the most commonly searched drugs
    base_url = "https://api.fda.gov/drug/label.json"
    count = 0
    skip = 0
    batch_size = 100
    max_drugs = 600

    log.info("Fetching openFDA drug labels...")

    while skip < max_drugs:
        url = f"{base_url}?search=_exists_:openfda.brand_name&limit={batch_size}&skip={skip}"
        try:
            data = http_get_json(url, timeout=60)
        except Exception as e:
            log.warning(f"  openFDA: error at skip={skip}: {e}")
            break

        results = data.get("results", [])
        if not results:
            break

        for drug in results:
            openfda = drug.get("openfda", {})
            brand_names = openfda.get("brand_name", ["Unknown"])
            brand = brand_names[0] if brand_names else "Unknown"
            generic_names = openfda.get("generic_name", [])

            lines = [f"# {brand}\n"]
            lines.append("Source: openFDA Drug Label Database")
            lines.append("Category: Medical / Pharmacology\n")
            if generic_names:
                lines.append(f"Generic Name: {', '.join(generic_names)}")
            manufacturers = openfda.get("manufacturer_name", [])
            if manufacturers:
                lines.append(f"Manufacturer: {', '.join(manufacturers[:3])}")
            routes = openfda.get("route", [])
            if routes:
                lines.append(f"Route: {', '.join(routes)}")
            lines.append("")

            # Key sections
            for section, label in [
                ("indications_and_usage", "Indications and Usage"),
                ("dosage_and_administration", "Dosage and Administration"),
                ("warnings", "Warnings"),
                ("adverse_reactions", "Adverse Reactions"),
                ("drug_interactions", "Drug Interactions"),
                ("contraindications", "Contraindications"),
                ("mechanism_of_action", "Mechanism of Action"),
                ("overdosage", "Overdosage"),
            ]:
                content = drug.get(section, [])
                if content:
                    text = content[0] if isinstance(content, list) else str(content)
                    # Strip HTML
                    text = re.sub(r'<[^>]+>', '', text).strip()
                    if len(text) > 20:
                        lines.append(f"## {label}\n")
                        lines.append(text)
                        lines.append("")

            # Only save if we have meaningful content
            full_text = "\n".join(lines)
            if len(full_text) < 200:
                continue

            safe_name = sanitize_filename(brand) + ".txt"
            filepath = ds_dir / safe_name

            if not filepath.exists():
                with open(filepath, "w", encoding="utf-8") as f:
                    f.write(full_text)
                count += 1

        skip += batch_size
        time.sleep(1)  # Rate limit

    log.info(f"openFDA: {count} drug labels saved")
    return count


@dataset("icd10", "medical",
         "WHO ICD-10 — International Classification of Diseases codes")
def fetch_icd10(output_dir: Path):
    """Download ICD-10 code descriptions from CMS public data."""
    ds_dir = output_dir / "icd10_codes"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # CMS publishes ICD-10-CM code descriptions as a flat text file
    url = "https://www.cms.gov/files/zip/2025-code-descriptions-tabular-order-updated-01172025.zip"
    log.info("Downloading ICD-10 code descriptions...")

    try:
        zip_data = http_get(url, timeout=120, binary=True)
    except Exception as e:
        log.error(f"Failed to download ICD-10 data: {e}")
        return 0

    count = 0
    current_chapter = None
    chapter_lines = []

    try:
        with zipfile.ZipFile(BytesIO(zip_data)) as zf:
            # Find the descriptions file
            desc_file = None
            for name in zf.namelist():
                if "desc" in name.lower() and name.endswith(".txt"):
                    desc_file = name
                    break
            if not desc_file:
                # Fallback: take the biggest txt file
                txt_files = [n for n in zf.namelist() if n.endswith(".txt")]
                if txt_files:
                    desc_file = txt_files[0]

            if not desc_file:
                log.error("No description file found in ICD-10 ZIP")
                return 0

            raw = zf.read(desc_file).decode("utf-8", errors="replace")
    except Exception as e:
        log.error(f"Failed to extract ICD-10 ZIP: {e}")
        return 0

    # Group codes by chapter (first letter or first 3 chars)
    # ICD-10 codes: A00-B99 Infectious, C00-D49 Neoplasms, etc.
    chapter_map = {
        "A": "Infectious_and_Parasitic_Diseases", "B": "Infectious_and_Parasitic_Diseases",
        "C": "Neoplasms", "D": "Blood_and_Immune_Disorders",
        "E": "Endocrine_Nutritional_Metabolic",
        "F": "Mental_Behavioral_Neurodevelopmental",
        "G": "Nervous_System", "H": "Eye_Ear",
        "I": "Circulatory_System", "J": "Respiratory_System",
        "K": "Digestive_System", "L": "Skin_and_Subcutaneous",
        "M": "Musculoskeletal", "N": "Genitourinary",
        "O": "Pregnancy_Childbirth", "P": "Perinatal",
        "Q": "Congenital_Malformations", "R": "Symptoms_Signs_Abnormal_Findings",
        "S": "Injury_Poisoning", "T": "Injury_Poisoning",
        "V": "External_Causes", "W": "External_Causes",
        "X": "External_Causes", "Y": "External_Causes",
        "Z": "Factors_Influencing_Health_Status",
    }

    chapters = {}  # chapter_name -> list of lines
    for line in raw.strip().splitlines():
        line = line.strip()
        if not line or len(line) < 5:
            continue
        # Format: CODE  DESCRIPTION (space separated)
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        code, desc = parts
        chapter_key = chapter_map.get(code[0], "Other")
        if chapter_key not in chapters:
            chapters[chapter_key] = []
        chapters[chapter_key].append(f"{code}: {desc}")

    for chapter_name, entries in chapters.items():
        safe_name = sanitize_filename(f"ICD10_{chapter_name}") + ".txt"
        filepath = ds_dir / safe_name

        with open(filepath, "w", encoding="utf-8") as f:
            title = chapter_name.replace("_", " ")
            f.write(f"# ICD-10: {title}\n\n")
            f.write("Source: WHO / CMS ICD-10-CM 2025\n")
            f.write("Category: Medical\n")
            f.write(f"Codes in chapter: {len(entries)}\n\n")
            f.write("\n".join(entries))
        count += 1

    log.info(f"ICD-10: {count} chapter files saved ({sum(len(e) for e in chapters.values())} total codes)")
    return count


@dataset("cdc-diseases", "medical",
         "CDC Disease A-Z — Fact sheets for major diseases and conditions")
def fetch_cdc_diseases(output_dir: Path):
    """Download CDC disease fact sheet index and summaries."""
    ds_dir = output_dir / "cdc_diseases"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # CDC has a public API for some datasets, but health topics are best
    # fetched from their A-Z index. We use their open data API.
    # CDC WONDER API is complex; instead grab the diseases A-Z page content
    index_url = "https://www.cdc.gov/az/sitemap.html"

    log.info("Fetching CDC Disease A-Z index...")

    try:
        html = http_get(index_url, timeout=60)
    except Exception as e:
        log.error(f"Failed to fetch CDC A-Z index: {e}")
        return 0

    # Extract links to disease pages from the A-Z sitemap
    # Pattern: <a href="/disease-name/index.html">Disease Name</a>
    links = re.findall(
        r'<a[^>]*href="(https://www\.cdc\.gov/[^"]+)"[^>]*>([^<]+)</a>',
        html
    )

    # Filter to actual disease/condition topic pages
    seen = set()
    count = 0

    for url, title in links:
        title = title.strip()
        # Skip navigation, non-topic links
        if not title or len(title) < 3 or len(title) > 100:
            continue
        if any(skip in url.lower() for skip in [
            "javascript", "#", ".pdf", ".zip", "media/", "images/",
            "mmwr", "epi-info", "about", "contact", "careers",
        ]):
            continue
        if title.lower() in seen:
            continue
        seen.add(title.lower())

        # Fetch the topic page
        try:
            page_html = http_get(url, timeout=30)
        except Exception:
            continue

        # Extract main content — look for article body or main content div
        # Strip HTML to plain text
        # Remove script/style blocks first
        text = re.sub(r'<script[^>]*>.*?</script>', '', page_html, flags=re.DOTALL)
        text = re.sub(r'<style[^>]*>.*?</style>', '', text, flags=re.DOTALL)
        # Try to find main content area
        main_match = re.search(r'<main[^>]*>(.*?)</main>', text, re.DOTALL)
        if main_match:
            text = main_match.group(1)
        else:
            body_match = re.search(r'<article[^>]*>(.*?)</article>', text, re.DOTALL)
            if body_match:
                text = body_match.group(1)

        # Strip remaining HTML, keep text
        text = re.sub(r'<[^>]+>', ' ', text)
        text = re.sub(r'\s+', ' ', text).strip()

        if len(text) < 200:
            continue

        # Truncate extremely long pages
        if len(text) > 15000:
            text = text[:15000] + "\n\n[Truncated — see CDC website for full content]"

        safe_name = sanitize_filename(title) + ".txt"
        filepath = ds_dir / safe_name

        with open(filepath, "w", encoding="utf-8") as f:
            f.write(f"# {title}\n\n")
            f.write(f"Source: Centers for Disease Control and Prevention (CDC)\n")
            f.write(f"Category: Medical / Public Health\n")
            f.write(f"URL: {url}\n\n")
            f.write(text)

        count += 1
        if count % 20 == 0:
            log.info(f"  [{count}] {title}")
        time.sleep(0.5)  # Rate limit

        if count >= 300:  # Cap to avoid extremely long runs
            break

    log.info(f"CDC Diseases: {count} fact sheets saved")
    return count


# ═══════════════════════════════════════════════════════════════════════════════
# LEGAL / COMPLIANCE DATASETS
# ═══════════════════════════════════════════════════════════════════════════════

@dataset("gdpr", "legal",
         "GDPR Full Text — EU General Data Protection Regulation")
def fetch_gdpr(output_dir: Path):
    """Download GDPR articles and recitals from official EU source."""
    ds_dir = output_dir / "gdpr"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # The official GDPR text is available from EUR-Lex
    # We use the gdpr-info.eu structured version which is easier to parse
    log.info("Fetching GDPR text...")

    count = 0

    # Fetch individual articles (1-99)
    for art_num in range(1, 100):
        url = f"https://gdpr-info.eu/art-{art_num}-gdpr/"
        try:
            html = http_get(url, timeout=30)
        except Exception:
            continue

        # Extract article title and content
        title_match = re.search(r'<h1[^>]*>([^<]+)</h1>', html)
        # Get the entry-content div
        content_match = re.search(
            r'<div class="entry-content">(.*?)</div>\s*</(?:article|div)',
            html, re.DOTALL
        )

        if not content_match:
            continue

        title = title_match.group(1).strip() if title_match else f"Article {art_num}"
        body = content_match.group(1)
        # Strip HTML
        body = re.sub(r'<[^>]+>', ' ', body)
        body = re.sub(r'\s+', ' ', body).strip()

        if len(body) < 50:
            continue

        safe_name = sanitize_filename(f"GDPR_Art_{art_num:02d}") + ".txt"
        filepath = ds_dir / safe_name

        with open(filepath, "w", encoding="utf-8") as f:
            f.write(f"# GDPR {title}\n\n")
            f.write("Source: EU General Data Protection Regulation (2016/679)\n")
            f.write("Category: Legal / Privacy\n\n")
            f.write(body)

        count += 1
        time.sleep(0.3)

    # Fetch recitals (1-173)
    for rec_num in range(1, 174):
        url = f"https://gdpr-info.eu/recitals/no-{rec_num}/"
        try:
            html = http_get(url, timeout=30)
        except Exception:
            continue

        content_match = re.search(
            r'<div class="entry-content">(.*?)</div>\s*</(?:article|div)',
            html, re.DOTALL
        )
        if not content_match:
            continue

        body = re.sub(r'<[^>]+>', ' ', content_match.group(1))
        body = re.sub(r'\s+', ' ', body).strip()

        if len(body) < 30:
            continue

        safe_name = sanitize_filename(f"GDPR_Recital_{rec_num:03d}") + ".txt"
        filepath = ds_dir / safe_name

        with open(filepath, "w", encoding="utf-8") as f:
            f.write(f"# GDPR Recital {rec_num}\n\n")
            f.write("Source: EU General Data Protection Regulation (2016/679)\n")
            f.write("Category: Legal / Privacy\n\n")
            f.write(body)

        count += 1
        time.sleep(0.3)

    log.info(f"GDPR: {count} articles and recitals saved")
    return count


# ═══════════════════════════════════════════════════════════════════════════════
# SCIENCE / ENGINEERING DATASETS
# ═══════════════════════════════════════════════════════════════════════════════

@dataset("nist-fips", "science",
         "NIST FIPS Publications — Federal cryptographic and security standards")
def fetch_nist_fips(output_dir: Path):
    """Fetch NIST FIPS publication metadata and abstracts from CSRC."""
    ds_dir = output_dir / "nist_fips"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # NIST CSRC has a public API for publications
    url = "https://csrc.nist.gov/CSRC/media/feeds/framework/documents/fips-final-pubs.json"
    log.info("Fetching NIST FIPS publications...")

    # Use the NVD/CSRC API for FIPS pubs
    api_url = "https://csrc.nist.gov/extensions/nudp/services/json/get-publications?series=fips&status=Final"

    try:
        data = http_get_json(api_url, timeout=60)
    except Exception:
        # Fallback: try a known list of important FIPS docs
        log.warning("NIST FIPS API unavailable, using known publications list")
        return _fetch_nist_fips_fallback(ds_dir)

    pubs = data if isinstance(data, list) else data.get("publications", data.get("results", []))
    if not isinstance(pubs, list):
        log.warning("Unexpected NIST API response, using fallback")
        return _fetch_nist_fips_fallback(ds_dir)

    count = 0
    for pub in pubs:
        title = pub.get("title", "")
        abstract = pub.get("abstract", pub.get("summary", ""))
        pub_num = pub.get("docidentifier", pub.get("number", "unknown"))
        pub_date = pub.get("published", pub.get("date", "N/A"))

        if not abstract or len(abstract) < 50:
            continue

        safe_name = sanitize_filename(f"FIPS_{pub_num}") + ".txt"
        filepath = ds_dir / safe_name

        with open(filepath, "w", encoding="utf-8") as f:
            f.write(f"# NIST FIPS {pub_num}: {title}\n\n")
            f.write("Source: NIST Computer Security Resource Center\n")
            f.write(f"Category: Cryptographic Standards\n")
            f.write(f"Published: {pub_date}\n\n")
            f.write(abstract)

        count += 1

    log.info(f"NIST FIPS: {count} publications saved")
    return count


def _fetch_nist_fips_fallback(ds_dir: Path):
    """Fallback: save metadata for key FIPS publications."""
    key_fips = [
        ("140-3", "Security Requirements for Cryptographic Modules",
         "Specifies the security requirements for cryptographic modules utilized within a security system protecting sensitive information in computer and telecommunication systems."),
        ("180-4", "Secure Hash Standard (SHS)",
         "Specifies five secure hash algorithms: SHA-1, SHA-224, SHA-256, SHA-384, and SHA-512 for computing a condensed representation of electronic data."),
        ("186-5", "Digital Signature Standard (DSS)",
         "Specifies algorithms for digital signature generation and verification: RSA, ECDSA, and EdDSA."),
        ("197", "Advanced Encryption Standard (AES)",
         "Specifies the Rijndael algorithm, a symmetric block cipher that can process data blocks of 128 bits using cipher keys of 128, 192, and 256 bits."),
        ("198-1", "The Keyed-Hash Message Authentication Code (HMAC)",
         "Provides a mechanism for message authentication using cryptographic hash functions. HMAC can be used with any approved cryptographic hash function."),
        ("199", "Standards for Security Categorization of Federal Information and Information Systems",
         "Provides standards for categorizing information and information systems according to an agency's level of concern for confidentiality, integrity, and availability."),
        ("200", "Minimum Security Requirements for Federal Information and Information Systems",
         "Specifies minimum security requirements for federal information and information systems in seventeen security-related areas."),
        ("201-3", "Personal Identity Verification (PIV) of Federal Employees and Contractors",
         "Establishes a standard for a PIV system that meets the control and security objectives of HSPD-12."),
        ("202", "SHA-3 Standard: Permutation-Based Hash and Extendable-Output Functions",
         "Specifies the SHA-3 family of functions on binary data, based on KECCAK."),
    ]

    count = 0
    for num, title, abstract in key_fips:
        safe_name = sanitize_filename(f"FIPS_{num}") + ".txt"
        filepath = ds_dir / safe_name

        with open(filepath, "w", encoding="utf-8") as f:
            f.write(f"# NIST FIPS {num}: {title}\n\n")
            f.write("Source: NIST Computer Security Resource Center\n")
            f.write("Category: Cryptographic Standards\n\n")
            f.write(abstract)
        count += 1

    return count


@dataset("arxiv-ml", "science",
         "arXiv ML/AI Abstracts — Recent machine learning research papers")
def fetch_arxiv_ml(output_dir: Path):
    """Fetch recent ML/AI paper abstracts from arXiv API."""
    ds_dir = output_dir / "arxiv_ml_ai"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # arXiv API: search for recent ML, AI, and LLM papers
    categories = [
        ("cat:cs.LG", "Machine Learning"),
        ("cat:cs.AI", "Artificial Intelligence"),
        ("cat:cs.CL", "Computation and Language (NLP)"),
    ]

    count = 0
    for search_query, cat_label in categories:
        # Fetch 200 most recent per category
        url = (
            f"http://export.arxiv.org/api/query?"
            f"search_query={urllib.parse.quote(search_query)}"
            f"&start=0&max_results=200"
            f"&sortBy=submittedDate&sortOrder=descending"
        )

        log.info(f"Fetching arXiv {cat_label} papers...")

        try:
            xml = http_get(url, timeout=120)
        except Exception as e:
            log.warning(f"  arXiv: failed to fetch {cat_label}: {e}")
            continue

        # Parse Atom XML entries
        entries = re.findall(r'<entry>(.*?)</entry>', xml, re.DOTALL)

        for entry in entries:
            title_match = re.search(r'<title>([^<]+)</title>', entry)
            summary_match = re.search(r'<summary>([^<]+)</summary>', entry)
            id_match = re.search(r'<id>([^<]+)</id>', entry)
            published_match = re.search(r'<published>([^<]+)</published>', entry)
            authors = re.findall(r'<name>([^<]+)</name>', entry)

            if not title_match or not summary_match:
                continue

            title = title_match.group(1).strip().replace('\n', ' ')
            summary = summary_match.group(1).strip().replace('\n', ' ')
            arxiv_id = id_match.group(1).strip() if id_match else "N/A"
            published = published_match.group(1).strip()[:10] if published_match else "N/A"

            if len(summary) < 100:
                continue

            # Use arxiv ID for unique filename
            paper_id = arxiv_id.split('/')[-1] if '/' in arxiv_id else arxiv_id.split('abs/')[-1]
            safe_name = sanitize_filename(f"arxiv_{paper_id}") + ".txt"
            filepath = ds_dir / safe_name

            if filepath.exists():
                count += 1
                continue

            with open(filepath, "w", encoding="utf-8") as f:
                f.write(f"# {title}\n\n")
                f.write(f"Source: arXiv ({cat_label})\n")
                f.write(f"Category: Science / AI Research\n")
                f.write(f"arXiv ID: {arxiv_id}\n")
                f.write(f"Published: {published}\n")
                if authors:
                    f.write(f"Authors: {', '.join(authors[:5])}")
                    if len(authors) > 5:
                        f.write(f" et al. ({len(authors)} total)")
                    f.write("\n")
                f.write(f"\n## Abstract\n\n{summary}\n")

            count += 1

        time.sleep(3)  # arXiv rate limit: max 1 request per 3 seconds

    log.info(f"arXiv ML/AI: {count} papers saved")
    return count


@dataset("nasa-reports", "science",
         "NASA Technical Reports — Public domain aerospace research")
def fetch_nasa_reports(output_dir: Path):
    """Fetch NASA technical report metadata from NTRS API."""
    ds_dir = output_dir / "nasa_reports"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # NASA Technical Reports Server (NTRS) API
    base_url = "https://ntrs.nasa.gov/api/citations"

    # Search for recent, public-domain technical reports
    search_topics = [
        "machine learning",
        "space weather",
        "cybersecurity",
        "systems engineering",
        "data science",
    ]

    count = 0
    seen_ids = set()

    for topic in search_topics:
        url = f"{base_url}/search?q={urllib.parse.quote(topic)}&page.size=100&page.from=0"
        log.info(f"Fetching NASA reports: {topic}...")

        try:
            data = http_get_json(url, timeout=60)
        except Exception as e:
            log.warning(f"  NASA: failed to search '{topic}': {e}")
            continue

        results = data.get("results", [])
        for item in results:
            doc_id = item.get("id", "")
            if doc_id in seen_ids:
                continue
            seen_ids.add(doc_id)

            title = item.get("title", "")
            abstract = item.get("abstract", "")
            if not abstract or len(abstract) < 100:
                continue

            center = item.get("center", {}).get("name", "NASA")
            pub_date = item.get("publicationDate", "N/A")
            report_num = item.get("reportNumber", "N/A")
            authors = [a.get("name", "") for a in item.get("authorAffiliations", [])]

            safe_name = sanitize_filename(f"NASA_{doc_id}") + ".txt"
            filepath = ds_dir / safe_name

            with open(filepath, "w", encoding="utf-8") as f:
                f.write(f"# {title}\n\n")
                f.write(f"Source: NASA Technical Reports Server (NTRS)\n")
                f.write(f"Category: Science / Aerospace\n")
                f.write(f"Report Number: {report_num}\n")
                f.write(f"Center: {center}\n")
                f.write(f"Published: {pub_date}\n")
                if authors:
                    f.write(f"Authors: {', '.join(authors[:5])}\n")
                f.write(f"\n## Abstract\n\n{abstract}\n")

            count += 1

        time.sleep(1)

    log.info(f"NASA Reports: {count} reports saved")
    return count


# ═══════════════════════════════════════════════════════════════════════════════
# HOMELAB / SELF-HOSTED DATASETS
# ═══════════════════════════════════════════════════════════════════════════════

@dataset("proxmox-docs", "homelab",
         "Proxmox VE Documentation — Virtual machines, containers, storage")
def fetch_proxmox_docs(output_dir: Path):
    """Fetch Proxmox VE documentation from their wiki."""
    ds_dir = output_dir / "proxmox_docs"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # Key Proxmox wiki pages (manually curated — wiki has no clean API)
    key_pages = [
        "Main_Page", "Installation", "Getting_Started",
        "Qemu/KVM_Virtual_Machines", "Linux_Container",
        "Proxmox_Cluster_File_System_(pmxcfs)",
        "Cluster_Manager", "Storage", "ZFS_on_Linux",
        "Ceph_Server", "Network_Configuration",
        "Firewall", "High_Availability",
        "Backup_and_Restore", "User_Management",
        "API", "Cloud-Init_Support",
        "USB_Devices_in_Virtual_Machines",
        "PCI(e)_Passthrough", "SPICE",
        "Migrate_to_Proxmox_VE",
        "Package_Repositories",
        "Certificate_Management",
        "Notifications", "Metric_Server",
        "Resource_Mapping", "SDN",
    ]

    count = 0
    base_url = "https://pve.proxmox.com/wiki"

    log.info(f"Fetching {len(key_pages)} Proxmox wiki pages...")

    for page_name in key_pages:
        url = f"{base_url}/{page_name}"
        try:
            html = http_get(url, timeout=30)
        except Exception as e:
            log.warning(f"  Proxmox: failed {page_name}: {e}")
            continue

        # Extract main content
        content_match = re.search(
            r'<div id="mw-content-text"[^>]*>(.*?)</div>\s*(?:<div|<!--)',
            html, re.DOTALL
        )
        if not content_match:
            # Try broader match
            content_match = re.search(
                r'<div class="mw-parser-output">(.*?)</div>\s*(?:<div id="catlinks|<!--)',
                html, re.DOTALL
            )

        if not content_match:
            continue

        text = content_match.group(1)
        # Clean HTML
        text = re.sub(r'<script[^>]*>.*?</script>', '', text, flags=re.DOTALL)
        text = re.sub(r'<style[^>]*>.*?</style>', '', text, flags=re.DOTALL)
        text = re.sub(r'<[^>]+>', ' ', text)
        text = re.sub(r'\s+', ' ', text).strip()

        if len(text) < 200:
            continue

        if len(text) > 20000:
            text = text[:20000] + "\n\n[Truncated — see Proxmox wiki for full content]"

        safe_name = sanitize_filename(f"PVE_{page_name}") + ".txt"
        filepath = ds_dir / safe_name

        with open(filepath, "w", encoding="utf-8") as f:
            f.write(f"# Proxmox VE: {page_name.replace('_', ' ')}\n\n")
            f.write("Source: Proxmox VE Wiki\n")
            f.write("Category: Homelab / Virtualization\n")
            f.write(f"URL: {url}\n\n")
            f.write(text)

        count += 1
        time.sleep(0.5)

    log.info(f"Proxmox docs: {count} pages saved")
    return count


@dataset("pfsense-docs", "homelab",
         "pfSense/Netgate Documentation — Firewall, routing, VPN")
def fetch_pfsense_docs(output_dir: Path):
    """Fetch pfSense documentation from Netgate docs GitHub repo."""
    ds_dir = output_dir / "pfsense_docs"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # Netgate docs are on GitHub
    base_url = "https://api.github.com/repos/pfsense/docs/contents/source"
    key_dirs = [
        "firewall", "vpn", "routing", "nat", "interfaces",
        "dns", "dhcp", "certificates", "monitoring",
        "highavailability", "packages", "install",
        "usermanager", "backup", "config",
        "troubleshooting", "hardware",
    ]

    count = 0
    log.info("Fetching pfSense documentation...")

    for dir_name in key_dirs:
        url = f"{base_url}/{dir_name}"
        try:
            items = http_get_json(url)
        except Exception as e:
            log.warning(f"  pfSense: couldn't list {dir_name}: {e}")
            continue

        if not isinstance(items, list):
            continue

        rst_files = [f for f in items
                     if isinstance(f, dict) and f.get("name", "").endswith((".rst", ".md"))]

        for item in rst_files:
            name = item.get("name", "")
            safe_name = sanitize_filename(f"pfsense_{dir_name}_{name}".replace(".rst", "").replace(".md", "")) + ".txt"
            filepath = ds_dir / safe_name

            if filepath.exists() and filepath.stat().st_size > 100:
                count += 1
                continue

            try:
                content = http_get(item["download_url"])
                with open(filepath, "w", encoding="utf-8") as f:
                    f.write(f"# pfSense: {name.replace('.rst', '').replace('.md', '').replace('-', ' ').title()}\n\n")
                    f.write(f"Source: pfSense/Netgate Documentation\n")
                    f.write(f"Section: {dir_name}\nCategory: Homelab / Networking\n\n")
                    f.write(content)
                count += 1
                time.sleep(0.3)
            except Exception as e:
                log.warning(f"  pfSense: failed {name}: {e}")

        time.sleep(1)

    log.info(f"pfSense docs: {count} pages saved")
    return count


@dataset("grafana-docs", "homelab",
         "Grafana Documentation — Dashboards, alerting, data sources")
def fetch_grafana_docs(output_dir: Path):
    """Fetch Grafana documentation from GitHub repo."""
    ds_dir = output_dir / "grafana_docs"
    ds_dir.mkdir(parents=True, exist_ok=True)

    base_url = "https://api.github.com/repos/grafana/grafana/contents/docs/sources"
    key_dirs = [
        "alerting", "dashboards", "datasources",
        "panels-visualizations", "explore",
        "administration", "setup-grafana",
    ]

    count = 0
    log.info("Fetching Grafana documentation...")

    for dir_name in key_dirs:
        url = f"{base_url}/{dir_name}"
        try:
            items = http_get_json(url)
        except Exception as e:
            log.warning(f"  Grafana: couldn't list {dir_name}: {e}")
            continue

        if not isinstance(items, list):
            continue

        md_files = [f for f in items
                    if isinstance(f, dict) and f.get("name", "").endswith((".md", ".mdx"))]

        for item in md_files:
            name = item.get("name", "")
            safe_name = sanitize_filename(f"grafana_{dir_name}_{name}".replace(".md", "").replace(".mdx", "")) + ".txt"
            filepath = ds_dir / safe_name

            if filepath.exists() and filepath.stat().st_size > 100:
                count += 1
                continue

            try:
                content = http_get(item["download_url"])
                with open(filepath, "w", encoding="utf-8") as f:
                    f.write(f"# Grafana: {name.replace('.md', '').replace('.mdx', '').replace('-', ' ').title()}\n\n")
                    f.write(f"Source: Grafana Documentation\n")
                    f.write(f"Section: {dir_name}\nCategory: Homelab / Monitoring\n\n")
                    f.write(content)
                count += 1
                time.sleep(0.3)
            except Exception as e:
                log.warning(f"  Grafana: failed {name}: {e}")

        # Also check one level of subdirectories
        sub_dirs = [f for f in items if isinstance(f, dict) and f.get("type") == "dir"]
        for sub in sub_dirs[:5]:  # Limit depth
            try:
                sub_items = http_get_json(sub["url"])
                sub_md = [f for f in sub_items
                          if isinstance(f, dict) and f.get("name", "").endswith((".md", ".mdx"))]
                for item in sub_md:
                    name = item.get("name", "")
                    sub_name = sub.get("name", "")
                    safe_name = sanitize_filename(
                        f"grafana_{dir_name}_{sub_name}_{name}"
                        .replace(".md", "").replace(".mdx", "")
                    ) + ".txt"
                    filepath = ds_dir / safe_name

                    if filepath.exists() and filepath.stat().st_size > 100:
                        count += 1
                        continue

                    try:
                        content = http_get(item["download_url"])
                        with open(filepath, "w", encoding="utf-8") as f:
                            f.write(f"# Grafana: {name.replace('.md', '').replace('.mdx', '').replace('-', ' ').title()}\n\n")
                            f.write(f"Source: Grafana Documentation\n")
                            f.write(f"Section: {dir_name}/{sub_name}\nCategory: Homelab / Monitoring\n\n")
                            f.write(content)
                        count += 1
                        time.sleep(0.3)
                    except Exception:
                        pass
                time.sleep(1)
            except Exception:
                pass

        time.sleep(1)

    log.info(f"Grafana docs: {count} pages saved")
    return count


# ═══════════════════════════════════════════════════════════════════════════════
# THREAT INTEL DATASETS
# ═══════════════════════════════════════════════════════════════════════════════

@dataset("cisa-kev", "threat-intel",
         "CISA Known Exploited Vulnerabilities catalog")
def fetch_cisa_kev(output_dir: Path):
    """Download CISA Known Exploited Vulnerabilities catalog."""
    ds_dir = output_dir / "cisa_kev"
    ds_dir.mkdir(parents=True, exist_ok=True)

    url = "https://www.cisa.gov/sites/default/files/feeds/known_exploited_vulnerabilities.json"
    log.info("Downloading CISA KEV catalog...")

    try:
        data = http_get_json(url, timeout=60)
    except Exception as e:
        log.error(f"Failed to download CISA KEV: {e}")
        return 0

    vulns = data.get("vulnerabilities", [])
    log.info(f"CISA KEV: {len(vulns)} known exploited vulnerabilities")

    count = 0
    for vuln in vulns:
        cve_id = vuln.get("cveID", "unknown")
        filepath = ds_dir / f"{cve_id}.txt"

        lines = [
            f"# {cve_id} — Known Exploited Vulnerability\n",
            f"Source: CISA Known Exploited Vulnerabilities Catalog",
            f"Vendor: {vuln.get('vendorProject', 'N/A')}",
            f"Product: {vuln.get('product', 'N/A')}",
            f"Vulnerability: {vuln.get('vulnerabilityName', 'N/A')}",
            f"Date Added: {vuln.get('dateAdded', 'N/A')}",
            f"Due Date: {vuln.get('dueDate', 'N/A')}",
            f"Required Action: {vuln.get('requiredAction', 'N/A')}",
            f"Known Ransomware Use: {vuln.get('knownRansomwareCampaignUse', 'N/A')}",
            f"\n## Description\n",
            vuln.get("shortDescription", "No description available."),
            f"\n## Notes\n",
            vuln.get("notes", "None"),
        ]

        with open(filepath, "w", encoding="utf-8") as f:
            f.write("\n".join(lines))
        count += 1

    log.info(f"CISA KEV: {count} entries saved")
    return count


@dataset("sigma-rules", "threat-intel",
         "Sigma detection rules — SIEM-agnostic detection signatures")
def fetch_sigma_rules(output_dir: Path):
    """Download Sigma detection rules from SigmaHQ."""
    ds_dir = output_dir / "sigma_rules"
    ds_dir.mkdir(parents=True, exist_ok=True)

    # Fetch the rules directory listing from GitHub
    base_url = "https://api.github.com/repos/SigmaHQ/sigma/contents/rules"
    key_dirs = [
        "linux", "network", "web", "windows",
        "cloud", "application",
    ]

    count = 0
    for dir_name in key_dirs:
        url = f"{base_url}/{dir_name}"
        try:
            items = http_get_json(url)
        except Exception as e:
            log.warning(f"  Sigma: couldn't list {dir_name}: {e}")
            continue

        # Process YAML files and subdirectories
        for item in items:
            if not isinstance(item, dict):
                continue

            if item.get("type") == "dir":
                # Recurse one level into subdirectories
                try:
                    sub_items = http_get_json(item["url"])
                    yaml_files = [f for f in sub_items
                                  if isinstance(f, dict) and f.get("name", "").endswith((".yml", ".yaml"))]
                    for yf in yaml_files[:50]:  # Limit per subdir
                        _save_sigma_rule(ds_dir, dir_name, yf)
                        count += 1
                    time.sleep(1)
                except Exception as e:
                    log.warning(f"  Sigma: couldn't list {dir_name}/{item['name']}: {e}")
            elif item.get("name", "").endswith((".yml", ".yaml")):
                _save_sigma_rule(ds_dir, dir_name, item)
                count += 1

        log.info(f"  Sigma/{dir_name}: processed")
        time.sleep(1)

    log.info(f"Sigma rules: {count} rules saved")
    return count


def _save_sigma_rule(ds_dir: Path, category: str, file_info: dict):
    """Save a single Sigma rule as a text document."""
    name = file_info.get("name", "unknown")
    safe_name = sanitize_filename(f"{category}_{name}".replace(".yml", "").replace(".yaml", "")) + ".txt"
    filepath = ds_dir / safe_name

    if filepath.exists() and filepath.stat().st_size > 50:
        return

    try:
        content = http_get(file_info["download_url"])
        with open(filepath, "w", encoding="utf-8") as f:
            f.write(f"# Sigma Rule: {name}\n\n")
            f.write(f"Source: SigmaHQ\nCategory: {category}\nType: Detection Rule\n\n")
            f.write(content)
        time.sleep(0.3)
    except Exception:
        pass


@dataset("elastic-detection", "threat-intel",
         "Elastic detection rules — Pre-built security rules")
def fetch_elastic_detection(output_dir: Path):
    """Download Elastic detection rules."""
    ds_dir = output_dir / "elastic_detection_rules"
    ds_dir.mkdir(parents=True, exist_ok=True)

    base_url = "https://api.github.com/repos/elastic/detection-rules/contents/rules"
    log.info("Fetching Elastic detection rules...")

    try:
        categories = http_get_json(base_url)
    except Exception as e:
        log.error(f"Failed to list Elastic rules: {e}")
        return 0

    count = 0
    for cat in categories:
        if not isinstance(cat, dict) or cat.get("type") != "dir":
            continue

        cat_name = cat["name"]
        try:
            rules = http_get_json(cat["url"])
        except Exception as e:
            log.warning(f"  Elastic: couldn't list {cat_name}: {e}")
            continue

        toml_files = [f for f in rules
                      if isinstance(f, dict) and f.get("name", "").endswith(".toml")]

        for rf in toml_files[:40]:  # Limit per category
            safe_name = sanitize_filename(f"{cat_name}_{rf['name']}".replace(".toml", "")) + ".txt"
            filepath = ds_dir / safe_name

            if filepath.exists() and filepath.stat().st_size > 50:
                count += 1
                continue

            try:
                content = http_get(rf["download_url"])
                with open(filepath, "w", encoding="utf-8") as f:
                    f.write(f"# Elastic Detection Rule: {rf['name']}\n\n")
                    f.write(f"Source: Elastic Detection Rules\nCategory: {cat_name}\n\n")
                    f.write(content)
                count += 1
                time.sleep(0.3)
            except Exception:
                pass

        time.sleep(1)

    log.info(f"Elastic detection rules: {count} rules saved")
    return count


# ═══════════════════════════════════════════════════════════════════════════════
# Custom Sources (user-defined via JSON config)
# ═══════════════════════════════════════════════════════════════════════════════

DEFAULT_CUSTOM_SOURCES = {
    "_comment": "Add your own data sources here. Each entry becomes a fetchable dataset.",
    "sources": [
        {
            "name": "example-github-markdown",
            "type": "github-dir",
            "category": "custom",
            "description": "Example: Markdown files from a GitHub repo directory",
            "repo": "owner/repo",
            "path": "docs",
            "file_ext": ".md",
            "source_label": "My Custom Docs",
            "enabled": False
        },
        {
            "name": "example-url-list",
            "type": "url-list",
            "category": "custom",
            "description": "Example: Download specific files by URL",
            "source_label": "My URL Collection",
            "urls": [
                {"url": "https://example.com/doc1.txt", "filename": "doc1.txt"},
                {"url": "https://example.com/doc2.txt", "filename": "doc2.txt"}
            ],
            "enabled": False
        },
        {
            "name": "example-github-releases",
            "type": "github-releases",
            "category": "custom",
            "description": "Example: Text from GitHub release notes",
            "repo": "owner/repo",
            "max_releases": 20,
            "source_label": "Release Notes",
            "enabled": False
        }
    ]
}


def generate_sources_file(path: str):
    """Write an example custom sources JSON file."""
    with open(path, "w") as f:
        json.dump(DEFAULT_CUSTOM_SOURCES, f, indent=2)
    print(f"Custom sources template written to {path}")
    print(f"Edit the file to add your own sources, then run with --sources {path}")
    print()
    print("Supported source types:")
    print("  github-dir       — Download files from a GitHub repo directory")
    print("  url-list         — Download files from a list of URLs")
    print("  github-releases  — Extract text from GitHub release notes")
    print()
    print('Set "enabled": true on sources you want to fetch.')


def load_custom_sources(path: str):
    """Load custom sources from JSON and register them as datasets."""
    with open(path) as f:
        data = json.load(f)

    sources = data.get("sources", [])
    loaded = 0

    for src in sources:
        if not src.get("enabled", True):
            continue

        name = src["name"]
        src_type = src["type"]
        category = src.get("category", "custom")
        description = src.get("description", f"Custom: {name}")

        if src_type == "github-dir":
            fetcher = _make_github_dir_fetcher(src)
        elif src_type == "url-list":
            fetcher = _make_url_list_fetcher(src)
        elif src_type == "github-releases":
            fetcher = _make_github_releases_fetcher(src)
        else:
            log.warning(f"Unknown source type '{src_type}' for '{name}', skipping")
            continue

        DATASETS[name] = {
            "func": fetcher,
            "category": category,
            "description": description,
        }
        loaded += 1

    return loaded


def _make_github_dir_fetcher(src: dict):
    """Create a fetcher function for a GitHub directory source."""
    repo = src["repo"]
    path = src.get("path", "")
    file_ext = src.get("file_ext", ".md")
    source_label = src.get("source_label", repo)
    dir_name = sanitize_filename(src["name"])
    max_files = src.get("max_files", 500)

    def fetcher(output_dir: Path) -> int:
        ds_dir = output_dir / dir_name
        ds_dir.mkdir(parents=True, exist_ok=True)

        api_url = f"https://api.github.com/repos/{repo}/contents/{path}"
        log.info(f"Fetching from {repo}/{path}...")

        try:
            files = http_get_json(api_url)
        except Exception as e:
            log.error(f"Failed to list {repo}/{path}: {e}")
            return 0

        if not isinstance(files, list):
            log.error(f"Expected directory listing from {api_url}")
            return 0

        targets = [f for f in files
                   if isinstance(f, dict) and f.get("name", "").endswith(file_ext)]
        targets = targets[:max_files]
        log.info(f"Found {len(targets)} {file_ext} files")

        count = 0
        for i, f_info in enumerate(targets):
            safe_name = sanitize_filename(
                f_info["name"].replace(file_ext, "")
            ) + ".txt"
            filepath = ds_dir / safe_name

            if filepath.exists() and filepath.stat().st_size > 50:
                count += 1
                continue

            try:
                content = http_get(f_info["download_url"])
                if file_ext == ".md":
                    content = re.sub(r'!\[.*?\]\(.*?\)', '', content)

                with open(filepath, "w", encoding="utf-8") as out:
                    out.write(f"# {f_info['name'].replace(file_ext, '')}\n\n")
                    out.write(f"Source: {source_label}\n\n")
                    out.write(content)
                count += 1
                time.sleep(0.5)
            except Exception as e:
                log.warning(f"  Failed: {f_info['name']}: {e}")

            if (i + 1) % 25 == 0:
                log.info(f"  [{i+1}/{len(targets)}] downloaded")

        log.info(f"{dir_name}: {count} files saved")
        return count

    return fetcher


def _make_url_list_fetcher(src: dict):
    """Create a fetcher function for a URL list source."""
    source_label = src.get("source_label", src["name"])
    dir_name = sanitize_filename(src["name"])
    urls = src.get("urls", [])

    def fetcher(output_dir: Path) -> int:
        ds_dir = output_dir / dir_name
        ds_dir.mkdir(parents=True, exist_ok=True)

        count = 0
        for entry in urls:
            url = entry["url"]
            filename = sanitize_filename(entry.get("filename", url.rsplit("/", 1)[-1]))
            if not filename.endswith(".txt"):
                filename += ".txt"
            filepath = ds_dir / filename

            if filepath.exists() and filepath.stat().st_size > 50:
                count += 1
                continue

            try:
                content = http_get(url)
                with open(filepath, "w", encoding="utf-8") as out:
                    out.write(f"Source: {source_label}\n\n")
                    out.write(content)
                count += 1
                time.sleep(0.3)
            except Exception as e:
                log.warning(f"  Failed: {url}: {e}")

        log.info(f"{dir_name}: {count} files saved")
        return count

    return fetcher


def _make_github_releases_fetcher(src: dict):
    """Create a fetcher function for GitHub release notes."""
    repo = src["repo"]
    source_label = src.get("source_label", f"{repo} releases")
    dir_name = sanitize_filename(src["name"])
    max_releases = src.get("max_releases", 20)

    def fetcher(output_dir: Path) -> int:
        ds_dir = output_dir / dir_name
        ds_dir.mkdir(parents=True, exist_ok=True)

        api_url = f"https://api.github.com/repos/{repo}/releases?per_page={max_releases}"
        log.info(f"Fetching releases from {repo}...")

        try:
            releases = http_get_json(api_url)
        except Exception as e:
            log.error(f"Failed to fetch releases from {repo}: {e}")
            return 0

        count = 0
        for rel in releases:
            tag = rel.get("tag_name", "unknown")
            body = rel.get("body", "")
            if not body or not body.strip():
                continue

            safe_name = sanitize_filename(f"{tag}") + ".txt"
            filepath = ds_dir / safe_name

            if filepath.exists() and filepath.stat().st_size > 50:
                count += 1
                continue

            with open(filepath, "w", encoding="utf-8") as out:
                out.write(f"# {rel.get('name', tag)}\n\n")
                out.write(f"Source: {source_label}\nVersion: {tag}\n")
                out.write(f"Date: {rel.get('published_at', 'N/A')}\n\n")
                out.write(body)
            count += 1

        log.info(f"{dir_name}: {count} release notes saved")
        return count

    return fetcher


# ═══════════════════════════════════════════════════════════════════════════════
# Upload to Open WebUI
# ═══════════════════════════════════════════════════════════════════════════════

def upload_datasets(output_dir: Path, webui_url: str, api_key: str):
    """Upload all fetched datasets to Open WebUI as knowledge collections."""
    base_url = webui_url.rstrip("/")

    dataset_dirs = sorted([d for d in output_dir.iterdir()
                           if d.is_dir() and not d.name.startswith(".")])

    total_uploaded = 0
    total_failed = 0

    for ds_dir in dataset_dirs:
        files = sorted(ds_dir.glob("*.txt"))
        if not files:
            continue

        # Create knowledge collection
        ds_name = ds_dir.name.replace("_", " ").title()
        collection_name = f"RAG: {ds_name}"

        kid = _create_collection(base_url, api_key, collection_name,
                                 f"FrankenLLM RAG dataset: {ds_name}")
        if not kid:
            log.error(f"Failed to create collection for {ds_name}")
            continue

        log.info(f"Uploading {len(files)} files to '{collection_name}'...")
        ds_uploaded = 0
        ds_failed = 0

        for i, filepath in enumerate(files):
            # Retry loop (3 attempts)
            ok = False
            for attempt in range(3):
                if attempt > 0:
                    time.sleep(4 * attempt)

                file_id = _upload_file(base_url, api_key, filepath)
                if not file_id:
                    continue

                # Wait for server to extract content before adding to knowledge
                processed = _wait_processing(base_url, api_key, file_id)
                if not processed:
                    log.warning(f"  Processing incomplete for {filepath.name}, retrying")
                    continue

                if _add_to_knowledge(base_url, api_key, kid, file_id):
                    ok = True
                    break

            if ok:
                ds_uploaded += 1
            else:
                ds_failed += 1
                log.warning(f"  Failed after retries: {filepath.name}")

            if (i + 1) % 25 == 0:
                log.info(f"  [{i+1}/{len(files)}] {filepath.name}")
            time.sleep(0.3)

        total_uploaded += ds_uploaded
        total_failed += ds_failed
        log.info(f"  Done: {ds_uploaded}/{len(files)} uploaded, {ds_failed} failed → '{collection_name}'")

    log.info(f"Upload complete: {total_uploaded} files uploaded, {total_failed} failed across {len(dataset_dirs)} datasets")


def _create_collection(base_url, api_key, name, description):
    url = f"{base_url}/api/v1/knowledge/create"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    body = json.dumps({"name": name, "description": description}).encode()
    try:
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read())["id"]
    except Exception as e:
        log.error(f"Create collection failed: {e}")
        return None


def _upload_file(base_url, api_key, filepath):
    url = f"{base_url}/api/v1/files/"
    boundary = f"----FrankenLLM{os.urandom(8).hex()}"
    with open(filepath, "rb") as f:
        content = f.read()
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{filepath.name}"\r\n'
        f"Content-Type: text/plain\r\n\r\n"
    ).encode() + content + f"\r\n--{boundary}--\r\n".encode()
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    }
    try:
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=120) as resp:
            return json.loads(resp.read()).get("id")
    except Exception as e:
        log.warning(f"Upload failed {filepath.name}: {e}")
        return None


def _wait_processing(base_url, api_key, file_id, timeout=120):
    url = f"{base_url}/api/v1/files/{file_id}/process/status"
    headers = {"Authorization": f"Bearer {api_key}"}
    start = time.time()
    while time.time() - start < timeout:
        try:
            req = urllib.request.Request(url, headers=headers)
            with urllib.request.urlopen(req, timeout=15) as resp:
                result = json.loads(resp.read())
            st = result.get("status", "")
            if st in ("completed", "failed"):
                return st == "completed"
        except Exception:
            pass
        time.sleep(2)
    return False


def _add_to_knowledge(base_url, api_key, knowledge_id, file_id):
    url = f"{base_url}/api/v1/knowledge/{knowledge_id}/file/add"
    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": "application/json",
    }
    body = json.dumps({"file_id": file_id}).encode()
    try:
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=120) as resp:
            resp.read()
        return True
    except Exception:
        return False


# ─── Main ────────────────────────────────────────────────────────────────────

def list_datasets():
    print("Available RAG Datasets")
    print("=" * 70)
    categories = {}
    for name, info in sorted(DATASETS.items()):
        cat = info["category"]
        if cat not in categories:
            categories[cat] = []
        categories[cat].append((name, info["description"]))

    for cat in ["high-value", "medical", "day-to-day", "legal", "science", "homelab", "threat-intel", "custom"]:
        if cat not in categories:
            continue
        print(f"\n  [{cat.upper()}]")
        for name, desc in categories[cat]:
            print(f"    {name:25s} {desc}")

    # Show any other categories from custom sources
    for cat in sorted(categories.keys()):
        if cat in ("high-value", "medical", "day-to-day", "legal", "science", "homelab", "threat-intel", "custom"):
            continue
        print(f"\n  [{cat.upper()}]")
        for name, desc in categories[cat]:
            print(f"    {name:25s} {desc}")
    print()
    print("Usage: --datasets <name1> <name2> ...  OR  --category <category>  OR  --datasets all")
    print("       --sources my-sources.json       (load custom data sources)")
    print("       --generate-sources FILE          (create template sources file)")
    print()


def main():
    parser = argparse.ArgumentParser(
        description="FrankenLLM - RAG Dataset Fetcher",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # List built-in datasets
  python3 fetch-rag-datasets.py --list

  # Fetch high-value cybersecurity datasets
  python3 fetch-rag-datasets.py --category high-value

  # Fetch everything and upload to Open WebUI
  python3 fetch-rag-datasets.py --datasets all --fetch --upload --api-key sk-xxx

  # Generate a custom sources template
  python3 fetch-rag-datasets.py --generate-sources my-sources.json

  # Load custom sources and list all available
  python3 fetch-rag-datasets.py --sources my-sources.json --list

  # Fetch custom + built-in datasets
  python3 fetch-rag-datasets.py --sources my-sources.json --datasets all --upload --api-key sk-xxx
        """,
    )
    parser.add_argument("--list", action="store_true", help="List available datasets")
    parser.add_argument("--fetch", action="store_true", default=True,
                        help="Fetch datasets (default, kept for explicitness)")
    parser.add_argument("--datasets", nargs="+", help="Datasets to fetch (or 'all')")
    parser.add_argument("--category", help="Fetch all datasets in a category")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR,
                        help=f"Output directory (default: {DEFAULT_OUTPUT_DIR})")
    parser.add_argument("--upload", action="store_true",
                        help="Upload to Open WebUI after fetching")
    parser.add_argument("--api-key", default=os.environ.get("OPENWEBUI_API_KEY"),
                        help="Open WebUI API key")
    parser.add_argument("--webui-url", default=os.environ.get("OPENWEBUI_URL", DEFAULT_WEBUI_URL),
                        help=f"Open WebUI URL (default: {DEFAULT_WEBUI_URL})")
    parser.add_argument("--sources", default=None,
                        help="JSON file with custom data sources")
    parser.add_argument("--generate-sources", metavar="FILE",
                        help="Generate a custom sources template and exit")
    args = parser.parse_args()

    # Handle --generate-sources
    if args.generate_sources:
        generate_sources_file(args.generate_sources)
        return

    # Load custom sources if provided
    if args.sources:
        loaded = load_custom_sources(args.sources)
        print(f"Loaded {loaded} custom source(s) from {args.sources}")

    if args.list:
        list_datasets()
        return

    if not args.datasets and not args.category:
        parser.print_help()
        print("\nUse --list to see available datasets")
        return

    if args.upload and not args.api_key:
        print("ERROR: --api-key required for --upload")
        sys.exit(1)

    output_dir = Path(args.output_dir).resolve()
    output_dir.mkdir(parents=True, exist_ok=True)
    setup_logging(output_dir)

    # Determine which datasets to fetch
    if args.datasets and "all" in args.datasets:
        to_fetch = list(DATASETS.keys())
    elif args.category:
        to_fetch = [name for name, info in DATASETS.items()
                     if info["category"] == args.category]
    else:
        to_fetch = args.datasets

    # Validate
    for name in to_fetch:
        if name not in DATASETS:
            log.error(f"Unknown dataset: '{name}'. Use --list to see available datasets.")
            sys.exit(1)

    log.info("=" * 60)
    log.info("FrankenLLM RAG Dataset Fetcher")
    log.info(f"Datasets: {', '.join(to_fetch)}")
    log.info(f"Output: {output_dir}")
    log.info("=" * 60)

    total_files = 0
    for name in to_fetch:
        info = DATASETS[name]
        log.info(f"\n{'─'*40}")
        log.info(f"📦 {name}: {info['description']}")
        log.info(f"{'─'*40}")

        try:
            count = info["func"](output_dir)
            total_files += count
        except Exception as e:
            log.exception(f"Error fetching {name}: {e}")

    log.info(f"\n{'='*60}")
    log.info(f"Total: {total_files} files across {len(to_fetch)} datasets")

    # Show disk usage
    total_size = sum(
        f.stat().st_size for f in output_dir.rglob("*.txt")
    )
    log.info(f"Disk usage: {total_size / (1024*1024):.1f} MB")
    log.info(f"{'='*60}")

    if args.upload:
        log.info("\nUploading to Open WebUI...")
        upload_datasets(output_dir, args.webui_url, args.api_key)
        log.info("Upload complete!")


if __name__ == "__main__":
    main()
