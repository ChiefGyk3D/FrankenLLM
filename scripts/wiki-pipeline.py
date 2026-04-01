#!/usr/bin/env python3
"""
FrankenLLM - Simple English Wikipedia RAG Pipeline
Downloads, extracts, and uploads Simple English Wikipedia to Open WebUI.

Designed to run headless on the server (via tmux/screen).
Resumable — tracks progress in a state file.

Usage:
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

Environment variables (alternative to flags):
    OPENWEBUI_API_KEY   - API key for Open WebUI
    OPENWEBUI_URL       - Base URL (default: http://localhost:3000)

Requirements:
    pip install wikiextractor   (for XML dump extraction)
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

DUMP_URL = "https://dumps.wikimedia.org/simplewiki/latest/simplewiki-latest-pages-articles.xml.bz2"
DUMP_FILENAME = "simplewiki-latest-pages-articles.xml.bz2"
STATE_FILENAME = "wiki-pipeline-state.json"
LOG_FILENAME = "wiki-pipeline.log"

DEFAULT_WEBUI_URL = "http://localhost:3000"
DEFAULT_MIN_LENGTH = 500       # Skip articles shorter than this (chars)
DEFAULT_BATCH_SIZE = 5         # Files per batch upload
DEFAULT_COLLECTION_NAME = "Simple English Wikipedia"

# Categories for auto-sorting articles into collections
TOPIC_KEYWORDS = {
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

def download_dump(work_dir: Path, state: PipelineState, log: logging.Logger):
    dump_path = work_dir / DUMP_FILENAME

    if dump_path.exists() and state.data["download"]["completed"]:
        log.info(f"Dump already downloaded: {dump_path} ({dump_path.stat().st_size / 1e6:.0f} MB)")
        return dump_path

    state.data["step"] = "download"
    state.save()

    log.info(f"Downloading Simple English Wikipedia dump...")
    log.info(f"URL: {DUMP_URL}")
    log.info(f"Destination: {dump_path}")

    req = urllib.request.Request(DUMP_URL, headers={"User-Agent": "FrankenLLM-Wiki-Pipeline/1.0"})

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
                     state: PipelineState, log: logging.Logger) -> Path:
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
                        topic = categorize_article(current_title, current_text)
                        topic_dir = articles_dir / topic
                        topic_dir.mkdir(parents=True, exist_ok=True)

                        safe_name = sanitize_filename(current_title) + ".txt"
                        filepath = topic_dir / safe_name

                        with open(filepath, "w", encoding="utf-8") as out:
                            out.write(f"# {current_title}\n\n")
                            out.write(f"Source: Simple English Wikipedia\n")
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


def categorize_article(title: str, text: str) -> str:
    """Assign an article to a topic based on title and content."""
    combined = (title + " " + text[:2000]).lower()

    scores = {}
    for topic, keywords in TOPIC_KEYWORDS.items():
        score = sum(1 for kw in keywords if kw.lower() in combined)
        if score > 0:
            scores[topic] = score

    if scores:
        return max(scores, key=scores.get)
    return "general"


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

    # Retry loop with exponential backoff
    for attempt in range(4):  # up to 4 attempts
        if attempt > 0:
            wait = 2 ** attempt + (hash(rel_path) % 3)  # 2-6s, 4-8s, 8-12s
            time.sleep(wait)

        file_id = upload_file(base_url, api_key, filepath, log)
        if not file_id:
            continue  # retry upload

        if not fast:
            if not wait_for_file_processing(base_url, api_key, file_id, log, timeout=120):
                log.warning(f"File processing may not be complete for {filepath.name}, adding anyway")

        ok = add_file_to_knowledge(base_url, api_key, knowledge_id, file_id, log)
        if ok:
            return rel_path, True
        # If add_file failed with a non-duplicate error, retry the whole thing

    return rel_path, False


def upload_to_webui(articles_dir: Path, webui_url: str, api_key: str,
                    state: PipelineState, log: logging.Logger,
                    fast: bool = False, workers: int = 3):
    state.data["step"] = "upload"
    state.save()

    base_url = webui_url.rstrip("/")
    already_uploaded = set(state.data["upload"].get("uploaded_files", []))
    state_lock = threading.Lock()

    # Gather all article files
    all_files = sorted(articles_dir.rglob("*.txt"))
    total = len(all_files)
    state.data["upload"]["files_total"] = total
    state.save()

    log.info(f"Found {total} articles to upload")
    log.info(f"Already uploaded: {len(already_uploaded)}")
    log.info(f"Remaining: {total - len(already_uploaded)}")
    log.info(f"Workers: {workers}")

    # Create or get knowledge collections per topic
    topic_dirs = sorted([d for d in articles_dir.iterdir() if d.is_dir()])
    for topic_dir in topic_dirs:
        topic = topic_dir.name
        if topic not in state.data["upload"]["knowledge_ids"]:
            knowledge_id = create_knowledge_collection(base_url, api_key, topic, log)
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
                content_type="application/json", raw_data=None):
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

    with urllib.request.urlopen(req, timeout=120) as resp:
        return json.loads(resp.read().decode("utf-8"))


def create_knowledge_collection(base_url: str, api_key: str, topic: str,
                                log: logging.Logger) -> str | None:
    """Create a knowledge collection in Open WebUI, return its ID."""
    url = f"{base_url}/api/v1/knowledge/create"
    name = f"Wikipedia - {topic.replace('_', ' ').title()}"
    description = f"Simple English Wikipedia articles about {topic}"

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
                          file_id: str, log: logging.Logger) -> bool:
    """Add an uploaded file to a knowledge collection."""
    url = f"{base_url}/api/v1/knowledge/{knowledge_id}/file/add"

    try:
        api_request(url, api_key, data={"file_id": file_id}, method="POST")
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
        description="FrankenLLM - Simple English Wikipedia RAG Pipeline",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Full pipeline
  python3 wiki-pipeline.py --api-key sk-xxx

  # Just download and extract
  python3 wiki-pipeline.py --step extract

  # Resume upload
  python3 wiki-pipeline.py --step upload --api-key sk-xxx

  # Check progress
  python3 wiki-pipeline.py --step status

  # Run in tmux (recommended for long runs)
  tmux new -s wiki
  python3 wiki-pipeline.py --api-key sk-xxx
  # Ctrl+B, D to detach
  # tmux attach -t wiki to reattach
        """,
    )
    parser.add_argument("--step", choices=["all", "download", "extract", "upload", "status"],
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
    parser.add_argument("--workers", type=int, default=3,
                        help="Concurrent upload workers (default: 3)")
    args = parser.parse_args()

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
    log.info(f"Work dir: {work_dir}")
    log.info(f"Min article length: {args.min_length} chars")
    if args.step in ("all", "upload"):
        log.info(f"WebUI URL: {args.webui_url}")
    log.info("=" * 60)

    try:
        # Download
        if args.step in ("all", "download"):
            dump_path = download_dump(work_dir, state, log)
        else:
            dump_path = work_dir / DUMP_FILENAME

        # Extract
        if args.step in ("all", "extract", "download"):
            if not dump_path.exists():
                log.error(f"Dump file not found: {dump_path}")
                log.error("Run with --step download first")
                sys.exit(1)
            articles_dir = extract_articles(work_dir, dump_path, args.min_length, state, log)
        else:
            articles_dir = work_dir / "articles"

        # Upload
        if args.step in ("all", "upload"):
            if not articles_dir.exists():
                log.error(f"Articles directory not found: {articles_dir}")
                log.error("Run with --step extract first")
                sys.exit(1)
            if args.fast:
                log.info("FAST MODE: skipping per-file embedding wait")
            upload_to_webui(articles_dir, args.webui_url, args.api_key, state, log,
                            fast=args.fast, workers=args.workers)

        log.info("Pipeline complete!")
        state.data["step"] = "done"
        state.save()

    except Exception as e:
        log.exception(f"Pipeline error: {e}")
        state.save()
        sys.exit(1)


if __name__ == "__main__":
    main()
