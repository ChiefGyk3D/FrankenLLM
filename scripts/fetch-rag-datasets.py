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
# Upload to Open WebUI
# ═══════════════════════════════════════════════════════════════════════════════

def upload_datasets(output_dir: Path, webui_url: str, api_key: str):
    """Upload all fetched datasets to Open WebUI as knowledge collections."""
    base_url = webui_url.rstrip("/")

    dataset_dirs = sorted([d for d in output_dir.iterdir()
                           if d.is_dir() and not d.name.startswith(".")])

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

        for i, filepath in enumerate(files):
            file_id = _upload_file(base_url, api_key, filepath)
            if file_id:
                _wait_processing(base_url, api_key, file_id)
                _add_to_knowledge(base_url, api_key, kid, file_id)

            if (i + 1) % 25 == 0:
                log.info(f"  [{i+1}/{len(files)}] uploaded")
            time.sleep(0.3)

        log.info(f"  Done: {len(files)} files → '{collection_name}'")


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
        with urllib.request.urlopen(req, timeout=30) as resp:
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

    for cat in ["high-value", "day-to-day", "threat-intel"]:
        if cat not in categories:
            continue
        print(f"\n  [{cat.upper()}]")
        for name, desc in categories[cat]:
            print(f"    {name:25s} {desc}")
    print()
    print("Usage: --datasets <name1> <name2> ...  OR  --category <category>  OR  --datasets all")
    print()


def main():
    parser = argparse.ArgumentParser(
        description="FrankenLLM - RAG Dataset Fetcher",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument("--list", action="store_true", help="List available datasets")
    parser.add_argument("--datasets", nargs="+", help="Datasets to fetch (or 'all')")
    parser.add_argument("--category", choices=["high-value", "day-to-day", "threat-intel"],
                        help="Fetch all datasets in category")
    parser.add_argument("--output-dir", default=DEFAULT_OUTPUT_DIR,
                        help=f"Output directory (default: {DEFAULT_OUTPUT_DIR})")
    parser.add_argument("--upload", action="store_true",
                        help="Upload to Open WebUI after fetching")
    parser.add_argument("--api-key", default=os.environ.get("OPENWEBUI_API_KEY"),
                        help="Open WebUI API key")
    parser.add_argument("--webui-url", default=os.environ.get("OPENWEBUI_URL", DEFAULT_WEBUI_URL),
                        help=f"Open WebUI URL (default: {DEFAULT_WEBUI_URL})")
    args = parser.parse_args()

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
