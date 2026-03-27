#!/usr/bin/env python3
"""
FrankenLLM - Wikipedia Article Fetcher for RAG Testing
Downloads curated Wikipedia articles by topic for use with Open WebUI Knowledge.

Usage:
    python3 scripts/fetch-wiki-articles.py [--output-dir DIR] [--max-per-topic N]

Articles are saved as individual .txt files, ready to upload to Open WebUI.
"""

import argparse
import json
import os
import re
import sys
import time
import urllib.request
import urllib.parse
import urllib.error

# Curated article lists by topic
TOPICS = {
    "cybersecurity": [
        "Computer security", "Encryption", "Firewall (computing)",
        "Intrusion detection system", "Malware", "Ransomware", "Phishing",
        "Zero-day vulnerability", "Buffer overflow", "SQL injection",
        "Cross-site scripting", "Man-in-the-middle attack", "Denial-of-service attack",
        "Advanced persistent threat", "Penetration testing", "Vulnerability (computing)",
        "Public-key cryptography", "Transport Layer Security", "Virtual private network",
        "Tor (network)", "Signal Protocol", "OWASP", "NIST Cybersecurity Framework",
        "Stuxnet", "WannaCry ransomware attack", "SolarWinds hack",
        "Social engineering (security)", "Botnet", "Rootkit",
        "Multi-factor authentication", "Zero trust security model",
        "Security information and event management", "Kali Linux",
        "Capture the flag (cybersecurity)", "Bug bounty program",
        "Common Vulnerabilities and Exposures", "Cyber threat intelligence",
        "Digital forensics", "Honeypot (computing)",
    ],
    "technology": [
        "Artificial intelligence", "Machine learning", "Deep learning",
        "Large language model", "Graphics processing unit", "NVIDIA",
        "Linux", "Linux kernel", "Ubuntu", "Docker (software)",
        "Kubernetes", "Git", "Open-source software", "Raspberry Pi",
        "Internet of things", "5G", "Wi-Fi", "Bluetooth",
        "Solid-state drive", "RISC-V", "ARM architecture family",
        "Quantum computing", "Blockchain", "Cloud computing",
        "Containerization (computing)", "WebAssembly", "Rust (programming language)",
        "Python (programming language)", "TypeScript", "PostgreSQL",
        "Redis", "Apache Kafka", "Terraform (software)", "Ansible (software)",
        "Prometheus (software)", "Grafana", "OpenAI", "Meta Platforms",
        "System on a chip", "Field-programmable gate array",
    ],
    "science": [
        "Scientific method", "Theory of relativity", "Quantum mechanics",
        "Evolution", "DNA", "CRISPR gene editing", "Climate change",
        "Photosynthesis", "Black hole", "Neutron star", "Exoplanet",
        "James Webb Space Telescope", "Standard Model", "Higgs boson",
        "Nuclear fusion", "Periodic table", "Organic chemistry",
        "Neuroscience", "Vaccine", "Antibiotic resistance",
        "Plate tectonics", "Geothermal energy", "Solar energy",
        "Nuclear power", "Superconductivity", "Nanotechnology",
        "Asteroid", "Mars", "Moon", "International Space Station",
        "SpaceX", "Hubble Space Telescope", "Gravitational wave",
        "Dark matter", "Dark energy", "LIGO", "Fermi paradox",
        "Drake equation", "Abiogenesis", "Extremophile",
    ],
    "history": [
        "World War I", "World War II", "Cold War", "American Revolution",
        "French Revolution", "Industrial Revolution", "Renaissance",
        "Ancient Rome", "Ancient Greece", "Ancient Egypt",
        "Byzantine Empire", "Ottoman Empire", "Mongol Empire",
        "British Empire", "Colonialism", "Decolonization",
        "Civil rights movement", "Apartheid", "Berlin Wall",
        "Cuban Missile Crisis", "Space Race", "Moon landing",
        "Hiroshima and Nagasaki atomic bombings", "D-Day",
        "Manhattan Project", "Vietnam War", "Korean War",
        "Fall of the Soviet Union", "September 11 attacks",
        "Magna Carta", "Declaration of Independence",
        "Constitution of the United States", "Emancipation Proclamation",
        "Treaty of Versailles", "United Nations", "NATO",
        "European Union", "Abraham Lincoln", "Winston Churchill",
        "Nelson Mandela", "Martin Luther King Jr.",
    ],
    "politics": [
        "Democracy", "Republic", "Authoritarianism", "Totalitarianism",
        "Federalism", "Separation of powers", "Constitution",
        "United States Congress", "Supreme Court of the United States",
        "Electoral College (United States)", "Political party",
        "Lobbying", "Gerrymandering", "Filibuster",
        "First Amendment to the United States Constitution",
        "Second Amendment to the United States Constitution",
        "Fourth Amendment to the United States Constitution",
        "European Parliament", "United Nations Security Council",
        "International Criminal Court", "Geneva Conventions",
        "Human rights", "Freedom of speech", "Freedom of the press",
        "Diplomacy", "Foreign policy", "Sanctions (law)",
        "Socialism", "Capitalism", "Communism", "Libertarianism",
        "Populism", "Nationalism", "Globalization",
        "Propaganda", "Disinformation", "Political polarization",
        "Whistleblower", "Government surveillance", "FISA court",
    ],
}


def fetch_article(title: str) -> dict | None:
    """Fetch a single Wikipedia article's plain text extract."""
    params = urllib.parse.urlencode({
        "action": "query",
        "titles": title,
        "prop": "extracts",
        "explaintext": "1",
        "format": "json",
    })
    url = f"https://en.wikipedia.org/w/api.php?{params}"

    try:
        req = urllib.request.Request(url, headers={"User-Agent": "FrankenLLM-RAG-Fetcher/1.0"})
        with urllib.request.urlopen(req, timeout=15) as resp:
            data = json.loads(resp.read().decode("utf-8"))
    except (urllib.error.URLError, json.JSONDecodeError, OSError) as e:
        print(f"  ⚠ Failed to fetch '{title}': {e}")
        return None

    pages = data.get("query", {}).get("pages", {})
    for page_id, page in pages.items():
        if page_id == "-1":
            print(f"  ⚠ Article not found: '{title}'")
            return None
        extract = page.get("extract", "").strip()
        if not extract or len(extract) < 200:
            print(f"  ⚠ Article too short: '{title}' ({len(extract)} chars)")
            return None
        return {
            "title": page.get("title", title),
            "text": extract,
        }
    return None


def sanitize_filename(name: str) -> str:
    """Create a safe filename from an article title."""
    name = re.sub(r'[^\w\s-]', '', name)
    name = re.sub(r'\s+', '_', name.strip())
    return name[:80]


def main():
    parser = argparse.ArgumentParser(description="Download Wikipedia articles for RAG testing")
    parser.add_argument("--output-dir", default="wiki_articles",
                        help="Output directory for articles (default: wiki_articles)")
    parser.add_argument("--max-per-topic", type=int, default=0,
                        help="Max articles per topic (0 = all, default: all)")
    parser.add_argument("--topics", nargs="+",
                        choices=list(TOPICS.keys()) + ["all"], default=["all"],
                        help="Topics to fetch (default: all)")
    args = parser.parse_args()

    os.makedirs(args.output_dir, exist_ok=True)

    selected_topics = TOPICS if "all" in args.topics else {t: TOPICS[t] for t in args.topics}

    total = sum(len(v) for v in selected_topics.values())
    if args.max_per_topic > 0:
        total = sum(min(len(v), args.max_per_topic) for v in selected_topics.values())

    print(f"📚 FrankenLLM Wikipedia Article Fetcher")
    print(f"   Topics: {', '.join(selected_topics.keys())}")
    print(f"   Target: ~{total} articles")
    print(f"   Output: {os.path.abspath(args.output_dir)}")
    print()

    fetched = 0
    failed = 0

    for topic, articles in selected_topics.items():
        topic_dir = os.path.join(args.output_dir, topic)
        os.makedirs(topic_dir, exist_ok=True)

        article_list = articles[:args.max_per_topic] if args.max_per_topic > 0 else articles

        print(f"📂 {topic} ({len(article_list)} articles)")

        for i, title in enumerate(article_list):
            filename = sanitize_filename(title) + ".txt"
            filepath = os.path.join(topic_dir, filename)

            # Skip if already downloaded
            if os.path.exists(filepath) and os.path.getsize(filepath) > 200:
                print(f"  ✓ [{i+1}/{len(article_list)}] {title} (cached)")
                fetched += 1
                continue

            article = fetch_article(title)
            if article:
                with open(filepath, "w", encoding="utf-8") as f:
                    f.write(f"# {article['title']}\n\n")
                    f.write(f"Source: Wikipedia\n")
                    f.write(f"Topic: {topic}\n\n")
                    f.write(article["text"])
                size_kb = os.path.getsize(filepath) / 1024
                print(f"  ✅ [{i+1}/{len(article_list)}] {title} ({size_kb:.1f} KB)")
                fetched += 1
            else:
                failed += 1

            # Rate limit: ~1 request per second to be respectful to Wikipedia
            time.sleep(1.0)

        print()

    print(f"{'='*50}")
    print(f"✅ Downloaded: {fetched} articles")
    if failed:
        print(f"⚠  Failed:     {failed} articles")
    total_size = sum(
        os.path.getsize(os.path.join(dp, f))
        for dp, _, filenames in os.walk(args.output_dir)
        for f in filenames
    )
    print(f"📦 Total size:  {total_size / (1024*1024):.1f} MB")
    print(f"📁 Location:    {os.path.abspath(args.output_dir)}")
    print()
    print("Next steps:")
    print("  1. Go to Open WebUI → Workspace → Knowledge")
    print("  2. Create a collection per topic (or one big collection)")
    print("  3. Upload the .txt files from each topic folder")
    print("  4. Start asking questions!")


if __name__ == "__main__":
    main()
