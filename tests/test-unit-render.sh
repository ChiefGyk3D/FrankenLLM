#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Test the systemd unit text and validators in remote/unit-lib.sh. Pure
# rendering: no systemd, no sudo, no network, no .env is read.
#
# Usage: tests/test-unit-render.sh

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../remote/unit-lib.sh
source "$REPO/remote/unit-lib.sh"

PASS=0
FAIL=0
check() {
    local desc="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        echo "FAIL: $desc"
        echo "  want: $want"
        echo "  got:  $got"
    fi
}

# accepts VALIDATOR VALUE -> "ok" or "rejected"
verdict() { if "$1" "$2"; then echo ok; else echo rejected; fi; }

# --- default unit is unchanged (the pre-change text, byte for byte) ---------
EXPECTED_DEFAULT='[Unit]
Description=Ollama Service for GPU 0
After=network-online.target

[Service]
Type=simple
User=alice
Environment="CUDA_VISIBLE_DEVICES=0"
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_MODELS=/home/alice/.ollama/models-gpu0"
Environment="OLLAMA_KEEP_ALIVE=-1"
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3

[Install]
WantedBy=default.target'
check "default unit unchanged" "$EXPECTED_DEFAULT" \
    "$(franken_render_unit 0 11434 /home/alice/.ollama/models-gpu0 alice '' '' '')"

# --- opt-in values appear in the unit ---------------------------------------
UNIT=$(franken_render_unit 1 11435 /var/lib/svc/.ollama/models-gpu1 svc 192.0.2.10 24G 512)
check "bind address and port written" "1" "$(grep -c '^Environment="OLLAMA_HOST=192.0.2.10:11435"$' <<< "$UNIT")"
check "service user written" "1" "$(grep -c '^User=svc$' <<< "$UNIT")"
check "MemoryMax written" "1" "$(grep -c '^MemoryMax=24G$' <<< "$UNIT")"
check "TasksMax written" "1" "$(grep -c '^TasksMax=512$' <<< "$UNIT")"
check "limits sit in [Service]" "MemoryMax=24G" \
    "$(sed -n '/^\[Service\]/,/^\[Install\]/p' <<< "$UNIT" | grep '^MemoryMax=')"

# --- hostile values: bind address -------------------------------------------
for v in "0.0.0.0:11434" "192.0.2.10:80" "192.0.2.256" "192.0.2" "192.0.2.10.5" \
         "example.com" "::1" "192.0.2.10
Environment=\"X=1\"" "192.0.2.10; rm -rf /" "\$(id)" "192.0.2.-1" " 192.0.2.10" ""; do
    check "bind rejects [$v]" "rejected" "$(verdict franken_valid_bind_addr "$v")"
done
for v in "192.0.2.10" "127.0.0.1" "0.0.0.0" "255.255.255.255"; do
    check "bind accepts [$v]" "ok" "$(verdict franken_valid_bind_addr "$v")"
done

# --- hostile values: service user -------------------------------------------
for v in "root; id" "Root" "1abc" "a b" "-lead" "a/b" "\$(id)" "alice
User=root" "$(printf 'a%.0s' {1..33})" ""; do
    check "user rejects [$v]" "rejected" "$(verdict franken_valid_service_user "$v")"
done
for v in "frankenllm" "_svc" "a" "svc-1_x" "$(printf 'a%.0s' {1..32})"; do
    check "user accepts [$v]" "ok" "$(verdict franken_valid_service_user "$v")"
done

# --- hostile values: MemoryMax / TasksMax -----------------------------------
for v in "24GB" "-1G" "0" "1.5G" "24G
TasksMax=infinity" "24G; id" "\$(id)" "G" "24 G" ""; do
    check "memory rejects [$v]" "rejected" "$(verdict franken_valid_memory_max "$v")"
done
for v in "24G" "512M" "1T" "4096" "infinity"; do
    check "memory accepts [$v]" "ok" "$(verdict franken_valid_memory_max "$v")"
done
for v in "0" "-5" "10K" "1e3" "512
MemoryMax=1" "512; id" "\$(id)" ""; do
    check "tasks rejects [$v]" "rejected" "$(verdict franken_valid_tasks_max "$v")"
done
for v in "512" "1" "infinity"; do
    check "tasks accepts [$v]" "ok" "$(verdict franken_valid_tasks_max "$v")"
done

echo "unit-render: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
