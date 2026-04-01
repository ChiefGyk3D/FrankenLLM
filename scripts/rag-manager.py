#!/usr/bin/env python3
"""
FrankenLLM - Unified RAG Manager
Orchestrates all RAG data sources: Wikipedia pipeline, built-in datasets,
and custom user sources. Single command to build your entire knowledge base.

Usage:
    # Build everything (Wikipedia + all datasets)
    python3 scripts/rag-manager.py --all --api-key sk-xxx

    # Just Wikipedia
    python3 scripts/rag-manager.py --wiki --api-key sk-xxx

    # Just cybersecurity datasets
    python3 scripts/rag-manager.py --datasets --category high-value --api-key sk-xxx

    # Wikipedia + specific datasets + custom sources
    python3 scripts/rag-manager.py --wiki --datasets owasp mitre-attack \
        --sources my-sources.json --api-key sk-xxx

    # Status check across all sources
    python3 scripts/rag-manager.py --status

    # Generate config templates for customization
    python3 scripts/rag-manager.py --init

Environment variables:
    OPENWEBUI_API_KEY   - API key for Open WebUI
    OPENWEBUI_URL       - Base URL (default: http://localhost:3000)
"""

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
WIKI_PIPELINE = SCRIPT_DIR / "wiki-pipeline.py"
DATASET_FETCHER = SCRIPT_DIR / "fetch-rag-datasets.py"

DEFAULT_WEBUI_URL = "http://localhost:3000"


def run_script(script: Path, args: list[str], label: str) -> bool:
    """Run a child script, streaming output live."""
    cmd = [sys.executable, str(script)] + args
    print(f"\n{'='*60}")
    print(f"  {label}")
    print(f"  Command: {' '.join(cmd)}")
    print(f"{'='*60}\n")

    start = time.time()
    result = subprocess.run(cmd)
    elapsed = time.time() - start

    mins = int(elapsed) // 60
    secs = int(elapsed) % 60
    status = "OK" if result.returncode == 0 else f"FAILED (exit {result.returncode})"
    print(f"\n  [{status}] {label} — {mins}m {secs}s")

    return result.returncode == 0


def cmd_init(args):
    """Generate config templates for all components."""
    configs_dir = Path("rag-configs")
    configs_dir.mkdir(exist_ok=True)

    wiki_config = configs_dir / "wiki-config.json"
    sources_config = configs_dir / "custom-sources.json"

    # Generate wiki config
    if not wiki_config.exists():
        run_script(WIKI_PIPELINE, ["--generate-config", str(wiki_config)], "Generate wiki config")
    else:
        print(f"  Wiki config already exists: {wiki_config}")

    # Generate custom sources template
    if not sources_config.exists():
        run_script(DATASET_FETCHER, ["--generate-sources", str(sources_config)], "Generate sources template")
    else:
        print(f"  Sources template already exists: {sources_config}")

    print(f"\nConfig files created in {configs_dir}/")
    print(f"  {wiki_config} — customize Wikipedia source, topics, labels")
    print(f"  {sources_config} — add your own GitHub repos, URLs, etc.")
    print()
    print("Next steps:")
    print("  1. Edit the config files to your liking")
    print("  2. Run: python3 scripts/rag-manager.py --all --api-key YOUR_KEY")


def cmd_status(args):
    """Show status of all RAG sources."""
    print("=" * 60)
    print("  FrankenLLM RAG Manager — Status")
    print("=" * 60)

    # Wiki pipeline status
    wiki_state = Path("wiki-pipeline-data/wiki-pipeline-state.json")
    if wiki_state.exists():
        with open(wiki_state) as f:
            data = json.load(f)
        up = data.get("upload", {})
        total = up.get("files_total", 0)
        uploaded = up.get("files_uploaded", 0)
        failed = up.get("files_failed", 0)
        step = data.get("step", "idle")
        pct = (uploaded / total * 100) if total > 0 else 0
        print(f"\n  Wikipedia Pipeline:")
        print(f"    Step:     {step}")
        print(f"    Uploaded: {uploaded}/{total} ({pct:.1f}%)")
        print(f"    Failed:   {failed}")
        cons = data.get("consolidate", {})
        if cons.get("completed"):
            print(f"    Batches:  {cons.get('batches_created', 'N/A')} files ({cons.get('articles_batched', 'N/A')} articles)")
    else:
        print(f"\n  Wikipedia Pipeline: not started")

    # Dataset fetcher status
    ds_dir = Path("rag-datasets")
    if ds_dir.exists():
        print(f"\n  RAG Datasets ({ds_dir}):")
        total_files = 0
        total_size = 0
        for sub in sorted(ds_dir.iterdir()):
            if sub.is_dir() and not sub.name.startswith("."):
                files = list(sub.glob("*.txt"))
                size = sum(f.stat().st_size for f in files)
                total_files += len(files)
                total_size += size
                print(f"    {sub.name:35s} {len(files):5d} files  {size/1024:.0f} KB")
        print(f"    {'─'*50}")
        print(f"    {'TOTAL':35s} {total_files:5d} files  {total_size/(1024*1024):.1f} MB")
    else:
        print(f"\n  RAG Datasets: not fetched yet")

    # Custom sources
    configs_dir = Path("rag-configs")
    sources_file = configs_dir / "custom-sources.json"
    if sources_file.exists():
        with open(sources_file) as f:
            data = json.load(f)
        enabled = [s for s in data.get("sources", []) if s.get("enabled", True)]
        print(f"\n  Custom Sources: {len(enabled)} enabled in {sources_file}")
        for src in enabled:
            print(f"    {src['name']:25s} ({src['type']})")
    else:
        print(f"\n  Custom Sources: none configured")
        print(f"    Run: python3 scripts/rag-manager.py --init")

    print()
    print("=" * 60)


def cmd_run(args):
    """Run the selected RAG sources."""
    results = []

    common_args = []
    if args.api_key:
        common_args += ["--api-key", args.api_key]
    if args.webui_url != DEFAULT_WEBUI_URL:
        common_args += ["--webui-url", args.webui_url]

    # ── Wikipedia pipeline ──
    if args.wiki or args.run_all:
        wiki_args = ["--step", "all", "--batch-size", "50", "--fast"]
        wiki_args += common_args

        if args.wiki_config:
            wiki_args += ["--config", args.wiki_config]
        elif Path("rag-configs/wiki-config.json").exists():
            wiki_args += ["--config", "rag-configs/wiki-config.json"]

        ok = run_script(WIKI_PIPELINE, wiki_args, "Wikipedia Pipeline")
        results.append(("Wikipedia", ok))

    # ── Built-in datasets ──
    if args.datasets or args.run_all:
        ds_args = []

        if args.run_all:
            ds_args += ["--datasets", "all"]
        elif args.ds_category:
            ds_args += ["--category", args.ds_category]
        elif args.ds_names:
            ds_args += ["--datasets"] + args.ds_names
        else:
            ds_args += ["--datasets", "all"]

        ds_args += ["--upload"] + common_args

        if args.sources:
            ds_args += ["--sources", args.sources]
        elif Path("rag-configs/custom-sources.json").exists():
            ds_args += ["--sources", "rag-configs/custom-sources.json"]

        ok = run_script(DATASET_FETCHER, ds_args, "RAG Dataset Fetcher")
        results.append(("Datasets", ok))

    # ── Summary ──
    print(f"\n{'='*60}")
    print("  RAG Manager — Summary")
    print(f"{'='*60}")
    for name, ok in results:
        status = "OK" if ok else "FAILED"
        print(f"  {name:30s} [{status}]")
    print(f"{'='*60}")

    if any(not ok for _, ok in results):
        sys.exit(1)


def main():
    parser = argparse.ArgumentParser(
        description="FrankenLLM - Unified RAG Manager",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # First-time setup: generate config templates
  python3 scripts/rag-manager.py --init

  # Build everything
  python3 scripts/rag-manager.py --all --api-key sk-xxx

  # Just Wikipedia with custom config
  python3 scripts/rag-manager.py --wiki --wiki-config my-wiki.json --api-key sk-xxx

  # Just cybersecurity datasets
  python3 scripts/rag-manager.py --datasets --category high-value --api-key sk-xxx

  # Specific datasets with custom sources
  python3 scripts/rag-manager.py --datasets owasp mitre-attack \\
      --sources my-sources.json --api-key sk-xxx

  # Check status
  python3 scripts/rag-manager.py --status
        """,
    )

    # Actions
    parser.add_argument("--all", dest="run_all", action="store_true",
                        help="Run everything: Wikipedia + all datasets + custom sources")
    parser.add_argument("--wiki", action="store_true",
                        help="Run Wikipedia pipeline")
    parser.add_argument("--datasets", nargs="*", dest="ds_names", default=None,
                        help="Run dataset fetcher (optionally list specific datasets)")
    parser.add_argument("--category", dest="ds_category",
                        help="Fetch datasets from a specific category")
    parser.add_argument("--status", action="store_true",
                        help="Show status of all RAG sources")
    parser.add_argument("--init", action="store_true",
                        help="Generate config templates for customization")

    # Config
    parser.add_argument("--api-key", default=os.environ.get("OPENWEBUI_API_KEY"),
                        help="Open WebUI API key (or set OPENWEBUI_API_KEY env var)")
    parser.add_argument("--webui-url", default=os.environ.get("OPENWEBUI_URL", DEFAULT_WEBUI_URL),
                        help=f"Open WebUI URL (default: {DEFAULT_WEBUI_URL})")
    parser.add_argument("--wiki-config", default=None,
                        help="Wiki pipeline config JSON file")
    parser.add_argument("--sources", default=None,
                        help="Custom sources JSON file for dataset fetcher")
    args = parser.parse_args()

    # Route to the right command
    if args.init:
        cmd_init(args)
    elif args.status:
        cmd_status(args)
    elif args.run_all or args.wiki or args.ds_names is not None or args.ds_category:
        # --datasets was passed (possibly with no names = fetch all)
        if args.ds_names is not None and len(args.ds_names) == 0:
            args.ds_names = None  # Will default to "all" in cmd_run
        args.datasets = args.ds_names is not None or args.ds_category is not None
        if not args.api_key and not args.status:
            print("ERROR: --api-key is required")
            print("  Generate one in Open WebUI: Settings > Account > API Keys")
            sys.exit(1)
        cmd_run(args)
    else:
        parser.print_help()
        print("\nQuick start:")
        print("  python3 scripts/rag-manager.py --init            # Generate configs")
        print("  python3 scripts/rag-manager.py --status          # Check progress")
        print("  python3 scripts/rag-manager.py --all --api-key sk-xxx  # Build everything")


if __name__ == "__main__":
    main()
