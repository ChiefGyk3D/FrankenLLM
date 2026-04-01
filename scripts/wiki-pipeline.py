#!/usr/bin/env python3
"""
FrankenLLM - Wikipedia RAG Pipeline
Downloads, extracts, and uploads Wikipedia articles to Open WebUI.

Designed to run headless on the server (via tmux/screen).
Resumable — tracks progress in a state file.
Fully configurable via JSON config file or CLI flags.

Usage:
    # Generate a config file with defaults (edit to customize)
    python3 scripts/wiki-pipeline.py --generate-config my-config.json

    # Full pipeline using config
    python3 scripts/wiki-pipeline.py --config my-config.json --api-key YOUR_KEY

    # Full pipeline (download → extract → upload)
    python3 scripts/wiki-pipeline.py --api-key YOUR_OPENWEBUI_API_KEY

    # Just download and extract (no upload)
    python3 scripts/wiki-pipeline.py --step extract

    # Resume upload from where it left off
    python3 scripts/wiki-pipeline.py --step upload --api-key YOUR_OPENWEBUI_API_KEY

    # Check status
    python3 scripts/wiki-pipeline.py --step status

    # Filter: only articles with 2000+ chars (skip stubs)
    python3 scripts/wiki-pipeline.py --min-length 2000 --api-key YOUR_KEY

    # Fast mode: skip per-file embedding wait (~10x faster)
    python3 scripts/wiki-pipeline.py --step upload --fast --api-key YOUR_KEY

    # Batch mode: consolidate articles into larger files before upload (~50x faster)
    python3 scripts/wiki-pipeline.py --step consolidate --batch-size 50
    python3 scripts/wiki-pipeline.py --step upload --fast --api-key YOUR_KEY

    # Full pipeline with batch mode (recommended for large wikis)
    python3 scripts/wiki-pipeline.py --batch-size 50 --fast --api-key YOUR_KEY

    # Use a different Wikipedia (e.g., full English)
    python3 scripts/wiki-pipeline.py --dump-url https://dumps.wikimedia.org/enwiki/latest/enwiki-latest-pages-articles.xml.bz2 --api-key YOUR_KEY

Environment variables (alternative to flags):
    OPENWEBUI_API_KEY   - API key for Open WebUI
    OPENWEBUI_URL       - Base URL (default: http://localhost:3000)
"""

import argparse
import bz2
import json
import logging
import os
import re
import signal
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from concurrent.futures import ThreadPoolExecutor, as_completed
from datetime import datetime, timezone
from pathlib import Path

# ─── Constants ───────────────────────────────────────────────────────────────

STATE_FILENAME = "wiki-pipeline-state.json"
LOG_FILENAME = "wiki-pipeline.log"

# Built-in defaults — override via config file or CLI flags
DEFAULT_DUMP_URL = "https://dumps.wikimedia.org/simplewiki/latest/simplewiki-latest-pages-articles.xml.bz2"
DEFAULT_WEBUI_URL = "http://localhost:3000"
DEFAULT_MIN_LENGTH = 500       # Skip articles shorter than this (chars)
DEFAULT_BATCH_SIZE = 50        # Articles per consolidated batch file
DEFAULT_WORKERS = 3
DEFAULT_SOURCE_LABEL = "Simple English Wikipedia"
DEFAULT_COLLECTION_PREFIX = "Wikipedia"

# Default topic categories for auto-sorting articles into knowledge collections.
# Customize via config file: add/remove/rename topics and keywords freely.
DEFAULT_TOPIC_KEYWORDS = {
    "cybersecurity": [
        "security", "hacking", "malware", "ransomware", "phishing", "encryption",
        "firewall", "vulnerability", "cyber", "intrusion", "cryptography",
        "authentication", "botnet", "rootkit", "exploit", "penetration test",
    ],
    "technology": [
        "computer", "software", "programming", "algorithm", "internet",
        "artificial intelligence", "machine learning", "database", "operating system",
        "processor", "semiconductor", "robot", "server", "network", "protocol",
        "linux", "windows", "apple inc", "google", "microsoft", "nvidia",
        "gpu", "cpu", "ram", "transistor", "circuit", "bluetooth", "wifi",
    ],
    "science": [
        "physics", "chemistry", "biology", "astronomy", "geology",
        "evolution", "atom", "molecule", "cell ", "gene", "dna", "rna",
        "planet", "star ", "galaxy", "universe", "quantum", "relativity",
        "species", "ecosystem", "climate", "energy", "gravity",
        "experiment", "hypothesis", "photosynthesis", "thermodynamic",
    ],
    "history": [
        "war ", "battle ", "empire", "revolution", "dynasty", "ancient",
        "medieval", "century", "civilization", "colony", "independence",
        "treaty", " king ", " queen ", "president ", "civil war",
        "world war", "cold war", "invasion", "conquest",
    ],
    "politics": [
        "government", "democracy", "republic", "parliament", "congress",
        "election", "political", "constitution", "legislation", "law ",
        "court ", "judge", "rights", "amendment", "senate", "vote",
        "diplomacy", "united nations", "nato", "socialist", "communist",
        "capitalism", "liberal", "conservative",
    ],
}


class PipelineConfig:
    """Central configuration — loaded from defaults, config file, and CLI overrides."""

    def __init__(self):
        # Source
        self.dump_url: str = DEFAULT_DUMP_URL
        self.source_label: str = DEFAULT_SOURCE_LABEL
        self.collection_prefix: str = DEFAULT_COLLECTION_PREFIX

        # Processing
        self.min_length: int = DEFAULT_MIN_LENGTH
        self.batch_size: int = DEFAULT_BATCH_SIZE
        self.workers: int = DEFAULT_WORKERS

        # Upload
        self.webui_url: str = DEFAULT_WEBUI_URL

        # Topics
        self.topics: dict[str, list[str]] = dict(DEFAULT_TOPIC_KEYWORDS)

    @property
    def dump_filename(self) -> str:
        """Derive dump filename from URL."""
        return self.dump_url.rstrip("/").rsplit("/", 1)[-1]

    def to_dict(self) -> dict:
        """Serialize to JSON-friendly dict."""
        return {
            "dump_url": self.dump_url,
            "source_label": self.source_label,
            "collection_prefix": self.collection_prefix,
            "min_length": self.min_length,
            "batch_size": self.batch_size,
            "workers": self.workers,
            "webui_url": self.webui_url,
            "topics": self.topics,
        }

    def load_file(self, path: str):
        """Load config from a JSON file, merging over defaults."""
        with open(path) as f:
            data = json.load(f)
        for key in ("dump_url", "source_label", "collection_prefix", "webui_url"):
            if key in data:
                setattr(self, key, str(data[key]))
        for key in ("min_length", "batch_size", "workers"):
            if key in data:
                setattr(self, key, int(data[key]))
        if "topics" in data and isinstance(data["topics"], dict):
            self.topics = {str(k): [str(w) for w in v] for k, v in data["topics"].items()}

    def apply_cli(self, args):
        """CLI flags override config file values (only if explicitly set)."""
        if args.dump_url:
            self.dump_url = args.dump_url
        if args.source_label:
            self.source_label = args.source_label
        if args.collection_prefix:
            self.collection_prefix = args.collection_prefix
        if args.webui_url != DEFAULT_WEBUI_URL:
            self.webui_url = args.webui_url
        if args.min_length != DEFAULT_MIN_LENGTH:
            self.min_length = args.min_length
        if args.workers != DEFAULT_WORKERS:
            self.workers = args.workers
        if args.batch_size != 0:
            self.batch_size = args.batch_size

    @staticmethod
    def generate(path: str):
        """Write default config to a JSON file for customization."""
        cfg = PipelineConfig()
        with open(path, "w") as f:
            json.dump(cfg.to_dict(), f, indent=2)
        print(f"Default config written to {path}")
        print("Edit topics, dump_url, source_label, etc. then run with --config {path}".format(path=path))


# ─── Logging ─────────────────────────────────────────────────────────────────

def setup_logging(work_dir: Path):
    log_path = work_dir / LOG_FILENAME
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s",
        handlers=[
            logging.FileHandler(log_path),
            logging.StreamHandler(sys.stdout),
        ],
    )
    return logging.getLogger("wiki-pipeline")


# ─── State Management ────────────────────────────────────────────────────────

class PipelineState:
    """Tracks pipeline progress for resume capability."""

    def __init__(self, state_path: Path):
        self.path = state_path
        self.data = {
            "started_at": None,
            "step": "idle",
            "download": {"completed": False, "bytes_downloaded": 0},
            "extract": {"completed": False, "articles_extracted": 0},
            "upload": {
                "completed": False,
                "knowledge_ids": {},
                "files_uploaded": 0,
                "files_total": 0,
                "files_failed": 0,
                "last_uploaded_file": None,
                "uploaded_files": [],
            },
        }
        self._load()

    def _load(self):
        if self.path.exists():
            with open(self.path) as f:
                saved = json.load(f)
                self.data.update(saved)

    def save(self):
        with open(self.path, "w") as f:
            json.dump(self.data, f, indent=2, default=str)

    def reset(self):
        self.data["started_at"] = datetime.now(timezone.utc).isoformat()
        self.save()


# ─── Download ────────────────────────────────────────────────────────────────

def download_dump(work_dir: Path, state: PipelineState, log: logging.Logger,
                  config: PipelineConfig):
    dump_path = work_dir / config.dump_filename

    if dump_path.exists() and state.data["download"]["completed"]:
        log.info(f"Dump already downloaded: {dump_path} ({dump_path.stat().st_size / 1e6:.0f} MB)")
        return dump_path

    state.data["step"] = "download"
    state.save()

    log.info(f"Downloading Wikipedia dump...")
    log.info(f"URL: {config.dump_url}")
    log.info(f"Destination: {dump_path}")

    req = urllib.request.Request(config.dump_url, headers={"User-Agent": "FrankenLLM-Wiki-Pipeline/1.0"})

    with urllib.request.urlopen(req, timeout=300) as response:
        total = int(response.headers.get("Content-Length", 0))
        log.info(f"Download size: {total / 1e6:.0f} MB")

        downloaded = 0
        last_report = time.time()
        with open(dump_path, "wb") as f:
            while True:
                chunk = response.read(1024 * 1024)  # 1 MB chunks
                if not chunk:
                    break
                f.write(chunk)
                downloaded += len(chunk)

                # Report progress every 10 seconds
                if time.time() - last_report > 10:
                    pct = (downloaded / total * 100) if total else 0
                    log.info(f"  Download: {downloaded / 1e6:.0f} / {total / 1e6:.0f} MB ({pct:.1f}%)")
                    state.data["download"]["bytes_downloaded"] = downloaded
                    state.save()
                    last_report = time.time()

    state.data["download"]["completed"] = True
    state.data["download"]["bytes_downloaded"] = downloaded
    state.save()
    log.info(f"Download complete: {downloaded / 1e6:.0f} MB")
    return dump_path


# ─── Extract ─────────────────────────────────────────────────────────────────

def extract_articles(work_dir: Path, dump_path: Path, min_length: int,
                     state: PipelineState, log: logging.Logger,
                     config: PipelineConfig) -> Path:
    articles_dir = work_dir / "articles"

    if state.data["extract"]["completed"] and articles_dir.exists():
        count = sum(1 for _ in articles_dir.rglob("*.txt"))
        log.info(f"Articles already extracted: {count} files in {articles_dir}")
        return articles_dir

    state.data["step"] = "extract"
    state.save()

    log.info("Extracting articles from Wikipedia dump...")
    log.info(f"Minimum article length: {min_length} characters")

    articles_dir.mkdir(parents=True, exist_ok=True)

    # Parse the XML dump directly — no wikiextractor dependency needed
    # Simple English Wikipedia is small enough to stream-parse
    log.info("Decompressing and parsing XML (this takes a few minutes)...")
    article_count = 0
    skipped_short = 0
    skipped_special = 0

    current_title = None
    current_text = None
    in_page = False
    in_title = False
    in_text = False
    text_buffer = []
    title_buffer = []

    # Namespaces to skip (not articles)
    skip_namespaces = {
        "Wikipedia:", "Template:", "Category:", "File:",
        "Portal:", "Module:", "MediaWiki:", "Help:", "Draft:",
        "User:", "Talk:", "Wikipedia talk:", "Template talk:",
        "User talk:", "Category talk:", "File talk:",
    }

    with bz2.open(dump_path, "rt", encoding="utf-8", errors="replace") as f:
        for line in f:
            stripped = line.strip()

            if "<page>" in stripped:
                in_page = True
                current_title = None
                current_text = None
                title_buffer = []
                text_buffer = []
                continue

            if "</page>" in stripped:
                in_page = False
                if current_title and current_text:
                    # Check minimum length
                    if len(current_text) < min_length:
                        skipped_short += 1
                    else:
                        # Categorize and save
                        topic = categorize_article(current_title, current_text, config)
                        topic_dir = articles_dir / topic
                        topic_dir.mkdir(parents=True, exist_ok=True)

                        safe_name = sanitize_filename(current_title) + ".txt"
                        filepath = topic_dir / safe_name

                        with open(filepath, "w", encoding="utf-8") as out:
                            out.write(f"# {current_title}\n\n")
                            out.write(f"Source: {config.source_label}\n")
                            out.write(f"Topic: {topic}\n\n")
                            out.write(current_text)

                        article_count += 1
                        if article_count % 1000 == 0:
                            log.info(f"  Extracted {article_count} articles (skipped {skipped_short} short, {skipped_special} non-article)")
                            state.data["extract"]["articles_extracted"] = article_count
                            state.save()
                continue

            if in_page:
                if "<title>" in stripped:
                    # Handle single-line title
                    match = re.search(r"<title>(.*?)</title>", stripped)
                    if match:
                        current_title = match.group(1)
                        # Skip non-article pages
                        if any(current_title.startswith(ns) for ns in skip_namespaces):
                            skipped_special += 1
                            in_page = False
                            continue
                    else:
                        in_title = True
                        title_buffer = [stripped.replace("<title>", "")]
                    continue

                if in_title:
                    if "</title>" in stripped:
                        title_buffer.append(stripped.replace("</title>", ""))
                        current_title = " ".join(title_buffer).strip()
                        in_title = False
                        if any(current_title.startswith(ns) for ns in skip_namespaces):
                            skipped_special += 1
                            in_page = False
                    else:
                        title_buffer.append(stripped)
                    continue

                if "<text" in stripped:
                    # Extract text content, handling <text ...>content</text> on one line
                    match_full = re.search(r"<text[^>]*>(.*?)</text>", stripped, re.DOTALL)
                    if match_full:
                        current_text = clean_wikitext(match_full.group(1))
                        continue
                    match_start = re.search(r"<text[^>]*>(.*)", stripped)
                    if match_start:
                        in_text = True
                        text_buffer = [match_start.group(1)]
                    continue

                if in_text:
                    if "</text>" in stripped:
                        text_buffer.append(stripped.replace("</text>", ""))
                        raw_text = "\n".join(text_buffer)
                        current_text = clean_wikitext(raw_text)
                        in_text = False
                    else:
                        text_buffer.append(stripped)
                    continue

    state.data["extract"]["completed"] = True
    state.data["extract"]["articles_extracted"] = article_count
    state.save()

    log.info(f"Extraction complete:")
    log.info(f"  Articles saved: {article_count}")
    log.info(f"  Skipped (too short): {skipped_short}")
    log.info(f"  Skipped (non-article): {skipped_special}")

    # Log per-topic counts
    for topic_dir in sorted(articles_dir.iterdir()):
        if topic_dir.is_dir():
            count = sum(1 for _ in topic_dir.glob("*.txt"))
            log.info(f"  {topic_dir.name}: {count} articles")

    return articles_dir


def clean_wikitext(text: str) -> str:
    """Strip wiki markup to produce readable plain text."""
    # Remove redirect pages
    if text.strip().upper().startswith("#REDIRECT"):
        return ""

    # Remove templates {{ }}
    # Handle nested templates with iterative approach
    depth = 0
    result = []
    i = 0
    while i < len(text):
        if i < len(text) - 1 and text[i] == '{' and text[i+1] == '{':
            depth += 1
            i += 2
            continue
        if i < len(text) - 1 and text[i] == '}' and text[i+1] == '}':
            depth = max(0, depth - 1)
            i += 2
            continue
        if depth == 0:
            result.append(text[i])
        i += 1
    text = "".join(result)

    # Remove HTML tags
    text = re.sub(r"<ref[^>]*>.*?</ref>", "", text, flags=re.DOTALL)
    text = re.sub(r"<ref[^/>]*/>", "", text)
    text = re.sub(r"<[^>]+>", "", text)

    # Remove wiki links, keep display text: [[target|display]] → display
    text = re.sub(r"\[\[[^\]]*?\|([^\]]+?)\]\]", r"\1", text)
    text = re.sub(r"\[\[([^\]]+?)\]\]", r"\1", text)

    # Remove external links: [http://... display] → display
    text = re.sub(r"\[https?://[^\s\]]+\s+([^\]]+)\]", r"\1", text)
    text = re.sub(r"\[https?://[^\]]+\]", "", text)

    # Remove wiki formatting
    text = re.sub(r"'{2,5}", "", text)  # Bold/italic markers
    text = re.sub(r"^=+\s*(.*?)\s*=+$", r"\n\1\n", text, flags=re.MULTILINE)  # Headers
    text = re.sub(r"^\*+\s*", "• ", text, flags=re.MULTILINE)  # Bullet points
    text = re.sub(r"^#+\s*", "", text, flags=re.MULTILINE)  # Numbered lists
    text = re.sub(r"^;", "", text, flags=re.MULTILINE)  # Definition lists
    text = re.sub(r"^:", "", text, flags=re.MULTILINE)  # Indentation

    # Remove tables
    text = re.sub(r"\{\|.*?\|\}", "", text, flags=re.DOTALL)

    # Remove categories and interwiki links
    text = re.sub(r"\[\[Category:[^\]]+\]\]", "", text)

    # Clean up whitespace
    text = re.sub(r"\n{3,}", "\n\n", text)
    text = re.sub(r" {2,}", " ", text)
    text = text.strip()

    return text


def categorize_article(title: str, text: str, config: PipelineConfig) -> str:
    """Assign an article to a topic based on title and content."""
    combined = (title + " " + text[:2000]).lower()

    scores = {}
    for topic, keywords in config.topics.items():
        score = sum(1 for kw in keywords if kw.lower() in combined)
        if score > 0:
            scores[topic] = score

    if scores:
        return max(scores, key=scores.get)
    return "general"


# ─── Consolidate ─────────────────────────────────────────────────────────────

def consolidate_articles(work_dir: Path, state: PipelineState,
                         log: logging.Logger, batch_size: int = 50) -> Path:
    """Merge individual article files into larger batch files for faster upload.

    Instead of uploading 171K tiny files (each triggering server-side processing),
    this merges them into ~batch_size-article files separated by clear markers.
    Open WebUI's chunking will still split them for embedding.

    articles/              →  batches/
      general/                  general/
        Article1.txt              general_batch_001.txt  (50 articles)
        Article2.txt              general_batch_002.txt  (50 articles)
        ...                       ...
    """
    articles_dir = work_dir / "articles"
    batches_dir = work_dir / "batches"

    if not articles_dir.exists():
        log.error(f"Articles directory not found: {articles_dir}")
        log.error("Run --step extract first")
        return batches_dir

    # Check if already consolidated
    if batches_dir.exists() and state.data.get("consolidate", {}).get("completed"):
        count = sum(1 for _ in batches_dir.rglob("*.txt"))
        log.info(f"Already consolidated: {count} batch files in {batches_dir}")
        return batches_dir

    state.data["step"] = "consolidate"
    state.data.setdefault("consolidate", {"completed": False, "batch_size": batch_size,
                                           "batches_created": 0, "articles_batched": 0})
    state.save()

    log.info(f"Consolidating articles into batch files (batch_size={batch_size})...")
    batches_dir.mkdir(parents=True, exist_ok=True)

    total_batches = 0
    total_articles = 0
    separator = "\n\n" + "=" * 80 + "\n\n"

    topic_dirs = sorted([d for d in articles_dir.iterdir() if d.is_dir()])

    for topic_dir in topic_dirs:
        topic = topic_dir.name
        topic_batch_dir = batches_dir / topic
        topic_batch_dir.mkdir(parents=True, exist_ok=True)

        files = sorted(topic_dir.glob("*.txt"))
        log.info(f"  {topic}: {len(files)} articles → ~{(len(files) + batch_size - 1) // batch_size} batches")

        batch_num = 0
        batch_buffer = []
        batch_articles = 0

        for filepath in files:
            try:
                content = filepath.read_text(encoding="utf-8")
                if content.strip():
                    batch_buffer.append(content)
                    batch_articles += 1
                    total_articles += 1
            except Exception as e:
                log.warning(f"  Skipping {filepath.name}: {e}")
                continue

            if len(batch_buffer) >= batch_size:
                batch_num += 1
                batch_path = topic_batch_dir / f"{topic}_batch_{batch_num:04d}.txt"
                batch_path.write_text(separator.join(batch_buffer), encoding="utf-8")
                total_batches += 1
                batch_buffer = []

        # Write remaining articles in final batch
        if batch_buffer:
            batch_num += 1
            batch_path = topic_batch_dir / f"{topic}_batch_{batch_num:04d}.txt"
            batch_path.write_text(separator.join(batch_buffer), encoding="utf-8")
            total_batches += 1

    state.data["consolidate"]["completed"] = True
    state.data["consolidate"]["batches_created"] = total_batches
    state.data["consolidate"]["articles_batched"] = total_articles
    state.data["consolidate"]["batch_size"] = batch_size
    state.save()

    log.info(f"Consolidation complete:")
    log.info(f"  {total_articles} articles → {total_batches} batch files")
    log.info(f"  Batch size: ~{batch_size} articles per file")

    # Show per-topic stats
    for topic_dir in sorted(batches_dir.iterdir()):
        if topic_dir.is_dir():
            count = sum(1 for _ in topic_dir.glob("*.txt"))
            log.info(f"    {topic_dir.name}: {count} batch files")

    return batches_dir


def sanitize_filename(name: str) -> str:
    """Create a filesystem-safe filename."""
    name = re.sub(r'[^\w\s-]', '', name)
    name = re.sub(r'\s+', '_', name.strip())
    return name[:120]


# ─── Upload to Open WebUI ───────────────────────────────────────────────────

def _upload_one(args_tuple):
    """Upload a single file and add it to its knowledge collection.
    Returns (rel_path, success: bool).
    Runs in a thread pool worker.
    """
    base_url, api_key, filepath, articles_dir, knowledge_id, fast, log = args_tuple
    rel_path = str(filepath.relative_to(articles_dir))
    is_batch = "_batch_" in filepath.name

    # Retry loop with exponential backoff
    for attempt in range(4):  # up to 4 attempts
        if attempt > 0:
            wait = 2 ** attempt + (hash(rel_path) % 3)  # 2-6s, 4-8s, 8-12s
            time.sleep(wait)

        file_id = upload_file(base_url, api_key, filepath, log)
        if not file_id:
            continue  # retry upload

        # Batch files are large (50+ articles); server MUST finish extracting
        # content before we can add to knowledge, otherwise we get "content
        # provided is empty".  For individual files, --fast can safely skip.
        if is_batch or not fast:
            proc_timeout = 600 if is_batch else 120
            if not wait_for_file_processing(base_url, api_key, file_id, log,
                                            timeout=proc_timeout):
                log.warning(f"File processing may not be complete for {filepath.name}, adding anyway")

        ok = add_file_to_knowledge(base_url, api_key, knowledge_id, file_id, log)
        if ok:
            return rel_path, True
        # If add_file failed with a non-duplicate error, retry the whole thing

    return rel_path, False


def upload_to_webui(articles_dir: Path, webui_url: str, api_key: str,
                    state: PipelineState, log: logging.Logger,
                    fast: bool = False, workers: int = 3,
                    config: PipelineConfig = None):
    state.data["step"] = "upload"
    state.save()

    base_url = webui_url.rstrip("/")
    already_uploaded = set(state.data["upload"].get("uploaded_files", []))
    state_lock = threading.Lock()

    # Gather all files to upload
    all_files = sorted(articles_dir.rglob("*.txt"))
    total = len(all_files)

    # Detect mode switch (individual → batch or vice versa): if the old
    # uploaded_files list doesn't match the current file paths, reset upload state
    if already_uploaded:
        sample_old = next(iter(already_uploaded))
        sample_new = str(all_files[0].relative_to(articles_dir)) if all_files else ""
        # If old paths have "batch" but new don't (or vice versa), clear state
        old_is_batch = "_batch_" in sample_old
        new_is_batch = "_batch_" in sample_new
        if old_is_batch != new_is_batch:
            log.info("Upload mode changed (individual ↔ batch), resetting upload state")
            already_uploaded = set()
            state.data["upload"]["uploaded_files"] = []
            state.data["upload"]["files_uploaded"] = 0
            state.data["upload"]["files_failed"] = 0
            state.data["upload"]["completed"] = False
            # Keep knowledge_ids — collections are reusable

    state.data["upload"]["files_total"] = total
    state.save()

    log.info(f"Found {total} files to upload")
    log.info(f"Already uploaded: {len(already_uploaded)}")
    log.info(f"Remaining: {total - len(already_uploaded)}")
    log.info(f"Workers: {workers}")

    # Create or get knowledge collections per topic
    cfg = config or PipelineConfig()
    topic_dirs = sorted([d for d in articles_dir.iterdir() if d.is_dir()])
    for topic_dir in topic_dirs:
        topic = topic_dir.name
        if topic not in state.data["upload"]["knowledge_ids"]:
            knowledge_id = create_knowledge_collection(base_url, api_key, topic, log, cfg)
            if knowledge_id:
                state.data["upload"]["knowledge_ids"][topic] = knowledge_id
                state.save()
            else:
                log.error(f"Failed to create knowledge collection for '{topic}', skipping")

    # Build work queue (files not yet uploaded)
    work = []
    for filepath in all_files:
        rel_path = str(filepath.relative_to(articles_dir))
        if rel_path in already_uploaded:
            continue
        topic = filepath.parent.name
        knowledge_id = state.data["upload"]["knowledge_ids"].get(topic)
        if not knowledge_id:
            log.warning(f"No knowledge collection for topic '{topic}', skipping {filepath.name}")
            continue
        work.append((base_url, api_key, filepath, articles_dir, knowledge_id, fast, log))

    # Process with thread pool
    last_save = time.time()
    last_progress = time.time()
    start_time = time.time()
    start_count = len(already_uploaded)

    with ThreadPoolExecutor(max_workers=workers) as pool:
        futures = {pool.submit(_upload_one, item): item for item in work}
        for future in as_completed(futures):
            try:
                rel_path, ok = future.result()
            except Exception as e:
                log.error(f"Worker exception: {e}")
                with state_lock:
                    state.data["upload"]["files_failed"] += 1
                continue

            with state_lock:
                if ok:
                    already_uploaded.add(rel_path)
                    state.data["upload"]["files_uploaded"] = len(already_uploaded)
                    state.data["upload"]["last_uploaded_file"] = rel_path
                else:
                    state.data["upload"]["files_failed"] += 1

                now = time.time()

                # Save state every 5 seconds
                if now - last_save >= 5:
                    state.data["upload"]["uploaded_files"] = list(already_uploaded)
                    state.save()
                    last_save = now

                # Progress log every 30 seconds
                if now - last_progress >= 30:
                    uploaded_count = len(already_uploaded)
                    new_this_session = uploaded_count - start_count
                    elapsed = now - start_time
                    rate = new_this_session / elapsed if elapsed > 0 else 0
                    remaining = total - uploaded_count
                    eta_s = int(remaining / rate) if rate > 0 else 0
                    eta_h = eta_s // 3600
                    eta_m = (eta_s % 3600) // 60
                    failed = state.data["upload"]["files_failed"]
                    log.info(
                        f"  Progress: {uploaded_count}/{total} "
                        f"({uploaded_count/total*100:.1f}%) | "
                        f"{rate:.1f} files/s | "
                        f"ETA: {eta_h}h {eta_m}m | "
                        f"failed: {failed}"
                    )
                    last_progress = now

    # Final state save
    state.data["upload"]["uploaded_files"] = list(already_uploaded)
    state.data["upload"]["completed"] = True
    state.save()
    log.info(f"Upload complete: {len(already_uploaded)} files uploaded, {state.data['upload']['files_failed']} failed")


def api_request(url: str, api_key: str, data=None, method="GET",
                content_type="application/json", raw_data=None,
                timeout: int = 120):
    """Make an authenticated API request to Open WebUI."""
    headers = {"Authorization": f"Bearer {api_key}"}

    if raw_data is not None:
        # Multipart — headers set by caller via raw_data
        req = urllib.request.Request(url, data=raw_data, headers=headers, method=method)
    elif data is not None:
        body = json.dumps(data).encode("utf-8")
        headers["Content-Type"] = content_type
        req = urllib.request.Request(url, data=body, headers=headers, method=method)
    else:
        req = urllib.request.Request(url, headers=headers, method=method)

    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def create_knowledge_collection(base_url: str, api_key: str, topic: str,
                                log: logging.Logger,
                                config: PipelineConfig) -> str | None:
    """Create a knowledge collection in Open WebUI, return its ID."""
    url = f"{base_url}/api/v1/knowledge/create"
    name = f"{config.collection_prefix} - {topic.replace('_', ' ').title()}"
    description = f"{config.source_label} articles about {topic}"

    try:
        result = api_request(url, api_key, data={
            "name": name,
            "description": description,
        }, method="POST")
        kid = result.get("id")
        log.info(f"Created knowledge collection: '{name}' (ID: {kid})")
        return kid
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        log.error(f"Failed to create collection '{name}': {e.code} {body}")
        return None
    except Exception as e:
        log.error(f"Failed to create collection '{name}': {e}")
        return None


def upload_file(base_url: str, api_key: str, filepath: Path,
                log: logging.Logger) -> str | None:
    """Upload a file to Open WebUI, return file ID."""
    url = f"{base_url}/api/v1/files/"
    boundary = f"----FrankenLLM{os.urandom(8).hex()}"

    with open(filepath, "rb") as f:
        file_content = f.read()

    # Build multipart form data
    body = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="file"; filename="{filepath.name}"\r\n'
        f"Content-Type: text/plain\r\n"
        f"\r\n"
    ).encode("utf-8") + file_content + f"\r\n--{boundary}--\r\n".encode("utf-8")

    headers = {
        "Authorization": f"Bearer {api_key}",
        "Content-Type": f"multipart/form-data; boundary={boundary}",
    }

    try:
        req = urllib.request.Request(url, data=body, headers=headers, method="POST")
        with urllib.request.urlopen(req, timeout=120) as resp:
            result = json.loads(resp.read().decode("utf-8"))
        file_id = result.get("id")
        return file_id
    except urllib.error.HTTPError as e:
        body_text = e.read().decode("utf-8", errors="replace")
        log.error(f"Upload failed for {filepath.name}: {e.code} {body_text}")
        return None
    except Exception as e:
        log.error(f"Upload failed for {filepath.name}: {e}")
        return None


def wait_for_file_processing(base_url: str, api_key: str, file_id: str,
                             log: logging.Logger, timeout: int = 120) -> bool:
    """Wait for Open WebUI to finish processing (embedding) a file."""
    url = f"{base_url}/api/v1/files/{file_id}/process/status"
    start = time.time()

    while time.time() - start < timeout:
        try:
            result = api_request(url, api_key)
            status = result.get("status", "")
            if status == "completed":
                return True
            if status == "failed":
                error = result.get("error", "unknown")
                log.warning(f"File processing failed for {file_id}: {error}")
                return False
            # Still pending/processing, wait
            time.sleep(2)
        except Exception:
            time.sleep(2)

    log.warning(f"Timed out waiting for file {file_id} processing ({timeout}s)")
    return False


def add_file_to_knowledge(base_url: str, api_key: str, knowledge_id: str,
                          file_id: str, log: logging.Logger,
                          timeout: int = 600) -> bool:
    """Add an uploaded file to a knowledge collection."""
    url = f"{base_url}/api/v1/knowledge/{knowledge_id}/file/add"

    try:
        api_request(url, api_key, data={"file_id": file_id}, method="POST",
                    timeout=timeout)
        return True
    except urllib.error.HTTPError as e:
        body = e.read().decode("utf-8", errors="replace")
        # Duplicate content = already uploaded, treat as success
        if e.code == 400 and "Duplicate content" in body:
            log.debug(f"Duplicate content for {file_id}, already exists — skipping")
            return True
        log.error(f"Failed to add file {file_id} to knowledge {knowledge_id}: {e.code} {body}")
        return False
    except Exception as e:
        log.error(f"Failed to add file {file_id} to knowledge {knowledge_id}: {e}")
        return False


# ─── Status Report ───────────────────────────────────────────────────────────

def show_status(work_dir: Path):
    state_path = work_dir / STATE_FILENAME
    if not state_path.exists():
        print("No pipeline state found. Pipeline hasn't been run yet.")
        return

    with open(state_path) as f:
        data = json.load(f)

    print("=" * 60)
    print("  FrankenLLM Wikipedia Pipeline Status")
    print("=" * 60)
    print(f"  Started:      {data.get('started_at', 'N/A')}")
    print(f"  Current step: {data.get('step', 'idle')}")
    print()

    dl = data.get("download", {})
    print(f"  Download:")
    print(f"    Completed:  {'✅' if dl.get('completed') else '❌'}")
    print(f"    Downloaded: {dl.get('bytes_downloaded', 0) / 1e6:.0f} MB")
    print()

    ext = data.get("extract", {})
    print(f"  Extract:")
    print(f"    Completed:  {'✅' if ext.get('completed') else '❌'}")
    print(f"    Articles:   {ext.get('articles_extracted', 0)}")
    print()

    con = data.get("consolidate", {})
    if con:
        print(f"  Consolidate:")
        print(f"    Completed:  {'✅' if con.get('completed') else '❌'}")
        print(f"    Batches:    {con.get('batches_created', 0)} (batch_size={con.get('batch_size', 'N/A')})")
        print(f"    Articles:   {con.get('articles_batched', 0)}")
        print()

    up = data.get("upload", {})
    total = up.get("files_total", 0)
    uploaded = up.get("files_uploaded", 0)
    failed = up.get("files_failed", 0)
    pct = (uploaded / total * 100) if total > 0 else 0
    print(f"  Upload:")
    print(f"    Completed:  {'✅' if up.get('completed') else '❌'}")
    print(f"    Progress:   {uploaded} / {total} ({pct:.1f}%)")
    print(f"    Failed:     {failed}")
    print(f"    Last file:  {up.get('last_uploaded_file', 'N/A')}")
    print()

    collections = up.get("knowledge_ids", {})
    if collections:
        print(f"  Knowledge Collections:")
        for topic, kid in collections.items():
            print(f"    {topic}: {kid}")
    print()

    # Check log file
    log_path = work_dir / LOG_FILENAME
    if log_path.exists():
        size = log_path.stat().st_size
        print(f"  Log file: {log_path} ({size / 1024:.0f} KB)")
        print(f"  Last 5 log lines:")
        with open(log_path) as f:
            lines = f.readlines()
            for line in lines[-5:]:
                print(f"    {line.rstrip()}")
    print("=" * 60)


# ─── Main ────────────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(
        description="FrankenLLM - Wikipedia RAG Pipeline",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Generate a config file (edit to customize topics, dump URL, etc.)
  python3 wiki-pipeline.py --generate-config my-wiki.json

  # Run with custom config
  python3 wiki-pipeline.py --config my-wiki.json --api-key sk-xxx

  # Full pipeline (Simple English Wikipedia by default)
  python3 wiki-pipeline.py --api-key sk-xxx

  # Use a different Wikipedia dump
  python3 wiki-pipeline.py --dump-url https://dumps.wikimedia.org/enwiki/latest/enwiki-latest-pages-articles.xml.bz2 --api-key sk-xxx

  # Just download and extract
  python3 wiki-pipeline.py --step extract

  # Resume upload
  python3 wiki-pipeline.py --step upload --api-key sk-xxx

  # Batch mode (recommended): consolidate then upload
  python3 wiki-pipeline.py --step consolidate --batch-size 50
  python3 wiki-pipeline.py --step upload --fast --api-key sk-xxx

  # Full pipeline with batching
  python3 wiki-pipeline.py --batch-size 50 --fast --api-key sk-xxx

  # Check progress
  python3 wiki-pipeline.py --step status

  # Run in tmux (recommended for long runs)
  tmux new -s wiki
  python3 wiki-pipeline.py --api-key sk-xxx
  # Ctrl+B, D to detach
  # tmux attach -t wiki to reattach
        """,
    )
    parser.add_argument("--step", choices=["all", "download", "extract", "consolidate", "upload", "status"],
                        default="all", help="Which step to run (default: all)")
    parser.add_argument("--api-key", default=os.environ.get("OPENWEBUI_API_KEY"),
                        help="Open WebUI API key (or set OPENWEBUI_API_KEY env var)")
    parser.add_argument("--webui-url", default=os.environ.get("OPENWEBUI_URL", DEFAULT_WEBUI_URL),
                        help=f"Open WebUI URL (default: {DEFAULT_WEBUI_URL})")
    parser.add_argument("--work-dir", default="wiki-pipeline-data",
                        help="Working directory for downloads and state (default: wiki-pipeline-data)")
    parser.add_argument("--min-length", type=int, default=DEFAULT_MIN_LENGTH,
                        help=f"Minimum article length in chars (default: {DEFAULT_MIN_LENGTH})")
    parser.add_argument("--fast", action="store_true",
                        help="Skip per-file embedding wait")
    parser.add_argument("--workers", type=int, default=DEFAULT_WORKERS,
                        help=f"Concurrent upload workers (default: {DEFAULT_WORKERS})")
    parser.add_argument("--batch-size", type=int, default=0,
                        help=f"Articles per batch file (0=upload individually, default: 0, recommended: 50)")

    # Config & customization
    parser.add_argument("--config", default=None,
                        help="JSON config file (topics, dump URL, labels, etc.)")
    parser.add_argument("--generate-config", metavar="FILE",
                        help="Generate a default config file and exit")
    parser.add_argument("--dump-url", default=None,
                        help="Wikipedia dump URL (overrides config file)")
    parser.add_argument("--source-label", default=None,
                        help="Label written into articles, e.g. 'English Wikipedia' (overrides config)")
    parser.add_argument("--collection-prefix", default=None,
                        help="Knowledge collection name prefix, e.g. 'Wikipedia' (overrides config)")
    args = parser.parse_args()

    # Handle --generate-config
    if args.generate_config:
        PipelineConfig.generate(args.generate_config)
        return

    # Build config: defaults → config file → CLI flags
    config = PipelineConfig()
    if args.config:
        config.load_file(args.config)
    config.apply_cli(args)

    work_dir = Path(args.work_dir).resolve()
    work_dir.mkdir(parents=True, exist_ok=True)

    # Status check doesn't need anything else
    if args.step == "status":
        show_status(work_dir)
        return

    # Validate API key for upload steps
    if args.step in ("all", "upload") and not args.api_key:
        print("ERROR: --api-key is required for upload step")
        print("  Generate one in Open WebUI: Settings > Account > API Keys")
        print("  Or set OPENWEBUI_API_KEY environment variable")
        sys.exit(1)

    # If --batch-size given with --step all, auto-include consolidate
    use_batches = args.batch_size > 0 or args.step == "consolidate"

    log = setup_logging(work_dir)
    state = PipelineState(work_dir / STATE_FILENAME)

    if not state.data.get("started_at"):
        state.reset()

    # Handle SIGINT/SIGTERM gracefully
    def signal_handler(sig, frame):
        log.info("Received shutdown signal, saving state...")
        state.save()
        sys.exit(0)
    signal.signal(signal.SIGINT, signal_handler)
    signal.signal(signal.SIGTERM, signal_handler)

    log.info("=" * 60)
    log.info("FrankenLLM Wikipedia Pipeline")
    log.info(f"Step: {args.step}")
    log.info(f"Source: {config.source_label}")
    log.info(f"Dump: {config.dump_url}")
    log.info(f"Work dir: {work_dir}")
    log.info(f"Topics: {', '.join(sorted(config.topics.keys()))} + general")
    log.info(f"Min article length: {config.min_length} chars")
    if args.step in ("all", "upload"):
        log.info(f"WebUI URL: {config.webui_url}")
    if use_batches:
        log.info(f"Batch mode: {args.batch_size or config.batch_size} articles per file")
    else:
        log.info("Individual file mode (batch auto-detected if available)")
    if args.config:
        log.info(f"Config file: {args.config}")
    log.info("=" * 60)

    try:
        # Download
        if args.step in ("all", "download"):
            dump_path = download_dump(work_dir, state, log, config)
        else:
            dump_path = work_dir / config.dump_filename

        # Extract
        if args.step in ("all", "extract", "download"):
            if not dump_path.exists():
                log.error(f"Dump file not found: {dump_path}")
                log.error("Run with --step download first")
                sys.exit(1)
            articles_dir = extract_articles(work_dir, dump_path, config.min_length,
                                            state, log, config)
        else:
            articles_dir = work_dir / "articles"

        # Consolidate (batch mode)
        if use_batches and args.step in ("all", "consolidate"):
            if not articles_dir.exists():
                log.error(f"Articles directory not found: {articles_dir}")
                log.error("Run with --step extract first")
                sys.exit(1)
            bs = args.batch_size if args.batch_size > 0 else config.batch_size
            batches_dir = consolidate_articles(work_dir, state, log, batch_size=bs)

        # Determine upload source directory
        if use_batches:
            upload_dir = work_dir / "batches"
        else:
            upload_dir = articles_dir

        # Upload
        if args.step in ("all", "upload"):
            # Auto-detect: if batches/ exists, use it
            if (work_dir / "batches").exists() and any((work_dir / "batches").iterdir()):
                upload_dir = work_dir / "batches"
                log.info(f"Using batch files from {upload_dir}")
                # Batch files are much larger; cap workers to avoid overwhelming server
                effective_workers = min(config.workers, 1)
                if effective_workers < config.workers:
                    log.info(f"Batch mode: reducing workers from {config.workers} to {effective_workers}")
            elif articles_dir.exists():
                upload_dir = articles_dir
                effective_workers = config.workers
                log.info(f"Using individual article files from {upload_dir}")
            else:
                log.error("No files to upload. Run --step extract first")
                sys.exit(1)

            if args.fast:
                log.info("FAST MODE: skipping per-file embedding wait")
            upload_to_webui(upload_dir, config.webui_url, args.api_key, state, log,
                            fast=args.fast, workers=effective_workers, config=config)

        log.info("Pipeline complete!")
        state.data["step"] = "done"
        state.save()

    except Exception as e:
        log.exception(f"Pipeline error: {e}")
        state.save()
        sys.exit(1)


if __name__ == "__main__":
    main()
