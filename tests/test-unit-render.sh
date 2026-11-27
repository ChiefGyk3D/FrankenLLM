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
for v in "root" "ROOT" "Root" "root " " root" "root
" "root; id" "root:x" "1abc" "a b" "-lead" "a/b" "\$(id)" "alice
User=root" "$(printf 'a%.0s' {1..33})" ""; do
    check "user rejects [$v]" "rejected" "$(verdict franken_valid_service_user "$v")"
done
for v in "rootx" "xroot" "frankenllm" "_svc" "a" "svc-1_x" "$(printf 'a%.0s' {1..32})"; do
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

# --- opt-in GPU guard (FRANKEN_REQUIRE_GPU) ---------------------------------
# Default (false / empty / 8th argument absent) must equal the unit above.
for v in "" false; do
    check "require_gpu [$v] unit unchanged" "$EXPECTED_DEFAULT" \
        "$(franken_render_unit 0 11434 /home/alice/.ollama/models-gpu0 alice '' '' '' "$v" /usr/bin/nvidia-smi)"
done
GUARD=$(franken_render_unit 0 11434 /home/alice/.ollama/models-gpu0 alice '' '' '' true /usr/bin/nvidia-smi)
check "guard: one ExecStartPre line" "ExecStartPre=/usr/bin/nvidia-smi -L" "$(grep '^ExecStartPre=' <<< "$GUARD")"
check "guard: placed right before ExecStart" "ExecStartPre=/usr/bin/nvidia-smi -L
ExecStart=/usr/local/bin/ollama serve" "$(grep -B1 '^ExecStart=' <<< "$GUARD")"
check "guard: only the one line added" "$EXPECTED_DEFAULT" "$(grep -v '^ExecStartPre=' <<< "$GUARD")"
check "guard: Restart=always kept" "1" "$(grep -c '^Restart=always$' <<< "$GUARD")"
franken_render_unit 0 11434 /m alice '' '' '' true '' > /dev/null 2>&1
check "guard on with empty path: render refuses" "1" "$?"
franken_render_unit 0 11434 /m alice '' '' '' true 'x;id' > /dev/null 2>&1
check "guard on with bad path: render refuses" "1" "$?"
check "guard on with bad path: no output" "" \
    "$(franken_render_unit 0 11434 /m alice '' '' '' true 'x;id' 2> /dev/null)"

for v in "TRUE" "True" "yes" "1" "0" "on" "false " " true" "true
ExecStartPre=/bin/evil" "true; id" "\$(id)"; do
    check "require_gpu rejects [$v]" "rejected" "$(verdict franken_valid_require_gpu "$v")"
done
for v in "true" "false"; do
    check "require_gpu accepts [$v]" "ok" "$(verdict franken_valid_require_gpu "$v")"
done
for v in "/usr/bin/nvidia-smi" "/opt/nvidia/bin/nvidia-smi" "/usr/lib/x86_64-linux-gnu/nvidia-smi"; do
    check "nvidia-smi path accepts [$v]" "ok" "$(verdict franken_valid_nvidia_smi_path "$v")"
done
for v in "" "nvidia-smi" "bin/nvidia-smi" "/usr/bin/nvidia smi" "/usr/bin/nvidia-smi
ExecStartPre=/bin/evil" "/usr/bin/x;id" "/usr/bin/\$(id)" "/usr/bin/x\`id\`" "/usr/bin/x%n" "/usr/bin/x\"y" "/usr/bin/x\$HOME"; do
    check "nvidia-smi path rejects [$v]" "rejected" "$(verdict franken_valid_nvidia_smi_path "$v")"
done

# --- warmup readiness URL: bind address when set, localhost otherwise ---------
check "ready url default" "http://localhost:11434/api/tags" "$(franken_ready_url '' 11434)"
check "ready url bind set" "http://192.0.2.10:11435/api/tags" "$(franken_ready_url 192.0.2.10 11435)"
check "ready url 0.0.0.0 -> localhost" "http://localhost:11434/api/tags" "$(franken_ready_url 0.0.0.0 11434)"
check "ready url invalid bind -> localhost" "http://localhost:11434/api/tags" \
    "$(franken_ready_url 'evil;id' 11434)"

# --- GPU group list: only groups confirmed present, comma separated ----------
fake_getent() { [ "$1" = group ] && case "$2" in video|render) return 0 ;; esac; return 1; }
check "gpu groups both" "video,render" "$(franken_gpu_groups fake_getent)"
fake_getent() { [ "$1" = group ] && [ "$2" = render ]; }
check "gpu groups render only" "render" "$(franken_gpu_groups fake_getent)"
fake_getent() { return 1; }
check "gpu groups none" "" "$(franken_gpu_groups fake_getent)"

echo "unit-render: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
