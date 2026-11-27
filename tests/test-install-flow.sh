#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Run the real server-side installer (remote/unit-lib.sh + remote/server-install.sh,
# joined exactly as remote/install.sh joins them) against stubs, in a scratch
# directory: the Ollama install policy (verified download, fail closed, explicit
# unverified opt-in), the service account policy, and rollback when a replacement
# service fails to start. sudo is a stub that maps /etc/systemd/system, /usr/local
# and /var/lib into the scratch "root" and fails closed on anything it does not
# emulate; systemctl, nvidia-smi, curl and friends are stubs. Nothing real is
# installed, started or written outside the scratch directory.
#
# Usage: tests/test-install-flow.sh

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
command -v zstd > /dev/null || { echo "zstd is required for this test"; exit 2; }

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
yn() { if "$@"; then echo yes; else echo no; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAKE="$WORK/root"           # stands in for / (etc/systemd/system, usr/local, var/lib)
STATE="$WORK/state"         # fake systemd state
TOOLS="$WORK/tools"         # the only real programs the script may find
STUB="$WORK/stub"
mkdir -p "$TOOLS" "$STUB" "$WORK/home"

# real tools the server script needs, by symlink (no ollama, no nvidia-smi, no real sudo)
for t in bash sh cat cut grep egrep head tail wc seq tee mktemp rm mkdir install cp mv ln id getent stat sleep date \
         tr sed awk sort dirname basename env uname tar sha256sum chmod touch ls readlink realpath zstd true false \
         expr test printf; do
    p="$(command -v "$t" 2> /dev/null || true)"
    case "$p" in /*) ln -sf "$p" "$TOOLS/$t" ;; esac
done
mkdir -p "$TOOLS/nozstd"

# --- fake release artifact -----------------------------------------------------------------
mkdir -p "$WORK/art/bin" "$WORK/art/lib/ollama"
printf '#!/bin/sh\necho "ollama version is 0.33.2"\n' > "$WORK/art/bin/ollama"
chmod +x "$WORK/art/bin/ollama"
echo lib > "$WORK/art/lib/ollama/libfoo.so"
tar -cf - -C "$WORK/art" bin lib | zstd -q -o "$WORK/good.tar.zst"
GOOD_SHA="$(sha256sum "$WORK/good.tar.zst" | cut -d' ' -f1)"
WRONG_SHA="$(printf 'b%.0s' $(seq 1 64))"

# --- stubs -----------------------------------------------------------------------------------
cat > "$STUB/sudo" << 'STUB'
#!/bin/bash
echo "sudo $*" >> "$STUB_LOG"
[ -n "${STUB_SUDO_FAIL:-}" ] && exit 1
args=()
skip=0
for a in "$@"; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$a" in
        -o|-g|-u) skip=1; continue ;;
        --system|--create-home) ;;
        /etc/systemd/system*|/usr/local*|/var/lib*) a="$STUB_ROOT$a" ;;
    esac
    args+=("$a")
done
case "${args[0]}" in
    mkdir|install|mv|tee|rm|tar|cp|chmod|systemctl|systemd-analyze) exec "${args[@]}" ;;
    useradd) echo "useradd ${args[*]}" >> "$STUB_LOG"; exit 0 ;;
    usermod) echo "usermod ${args[*]}" >> "$STUB_LOG"; exit 0 ;;
    *) echo "sudo: unsupported ${args[*]}" >> "$STUB_LOG"; exit 1 ;;
esac
STUB
cat > "$STUB/systemctl" << 'STUB'
#!/bin/bash
echo "systemctl $*" >> "$STUB_LOG"
quiet=0
while [ "${1:-}" = "--quiet" ] || [ "${1:-}" = "-q" ] || [ "${1:-}" = "--no-pager" ]; do shift; done
cmd="${1:-}"; shift
units=()
for u in "$@"; do case "$u" in -*) ;; *) units+=("${u%.service}") ;; esac; done
rc=0
for u in "${units[@]}"; do
    case "$cmd" in
        start|restart)
            if [ "$u" = "${STUB_FAIL_START:-}" ]; then rc=1; else touch "$STUB_STATE/active.$u"; fi ;;
        stop) rm -f "$STUB_STATE/active.$u" ;;
        enable) touch "$STUB_STATE/enabled.$u" ;;
        disable) rm -f "$STUB_STATE/enabled.$u" ;;
        mask) touch "$STUB_STATE/masked.$u" ;;
        unmask) rm -f "$STUB_STATE/masked.$u" ;;
        is-active) [ -f "$STUB_STATE/active.$u" ] || rc=3 ;;
        is-enabled) [ -f "$STUB_STATE/enabled.$u" ] || rc=1 ;;
        is-masked) [ -f "$STUB_STATE/masked.$u" ] || rc=1 ;;
        *) ;;
    esac
done
exit $rc
STUB
cat > "$STUB/nvidia-smi" << 'STUB'
#!/bin/bash
echo "GPU 0: Stub A (UUID: GPU-0)"
echo "GPU 1: Stub B (UUID: GPU-1)"
STUB
cat > "$STUB/curl" << 'STUB'
#!/bin/bash
{ printf 'curl'; printf ' [%s]' "$@"; printf '\n'; } >> "$STUB_LOG"
out=""
url=""
while [ $# -gt 0 ]; do
    case "$1" in
        --output) out="$2"; shift 2 ;;
        --) shift; url="$1"; break ;;
        *) shift ;;
    esac
done
if [ -z "$out" ]; then exit 0; fi      # health probes and friends
case "$url" in
    https://ollama.com/install.sh) printf '#!/bin/sh\necho upstream-script-ran >> "$STUB_LOG"\n' > "$out" ;;
    *) cp "$STUB_ARTIFACT" "$out" ;;
esac
STUB
cat > "$STUB/systemd-analyze" << 'STUB'
#!/bin/bash
echo "systemd-analyze $*" >> "$STUB_LOG"
[ -n "${STUB_VERIFY_FAIL:-}" ] && exit 1
exit 0
STUB
cat > "$STUB/getent" << 'STUB'
#!/bin/bash
# getent passwd NAME reads $STUB_PASSWD; getent group video/render exist
case "$1" in
    passwd) grep "^$2:" "$STUB_PASSWD" ;;
    group) case "$2" in video|render) echo "$2:x:44:" ;; *) exit 2 ;; esac ;;
    *) exit 2 ;;
esac
STUB
cat > "$STUB/id" << 'STUB'
#!/bin/bash
# id -u NAME / id -Gn NAME come from $STUB_PASSWD and $STUB_GROUPS; plain id is the real one
real=/usr/bin/id
if [ "$#" -ge 1 ] && [ "$1" != "${1#-}" ] && [ "$#" -eq 2 ]; then
    name="$2"
    line="$(grep "^$name:" "$STUB_PASSWD")" || exit 1
    case "$1" in
        -u) cut -d: -f3 <<< "$line" ;;
        -Gn) grep "^$name:" "$STUB_GROUPS" | cut -d: -f2 ;;
        *) exit 1 ;;
    esac
    exit 0
fi
if [ "$#" -eq 1 ] && [ "$1" != "${1#-}" ]; then exec "$real" "$@"; fi
if [ "$#" -eq 1 ]; then grep -q "^$1:" "$STUB_PASSWD" || exit 1; exit 0; fi
exec "$real" "$@"
STUB
printf '#!/bin/sh\nexit 0\n' > "$STUB/sleep"
chmod +x "$STUB"/*

PAYLOAD="$WORK/payload.sh"
{ echo '#!/bin/bash'; cat "$REPO/remote/unit-lib.sh" "$REPO/remote/server-install.sh"; } > "$PAYLOAD"

# run_server [VAR=value ...] -- ARGS...  -> RC, OUT, LOGTXT. Resets the fake root first.
reset_root() {
    rm -rf "${FAKE:?}" "${STATE:?}" "${WORK:?}/home" "${WORK:?}/stubdata"
    mkdir -p "$FAKE/etc/systemd/system" "$FAKE/usr/local" "$FAKE/var/lib" "$STATE" "$WORK/home" "$WORK/stubdata"
    : > "$WORK/stubdata/passwd"
    : > "$WORK/stubdata/groups"
    : > "$WORK/calls.log"
}
run_server() {
    local -a envs=()
    while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
    shift
    OUT=$(cd "$WORK/home" && env -i PATH="$STUB:$FAKE/usr/local/bin:$TOOLS" HOME="$WORK/home" USER=tester \
        STUB_LOG="$WORK/calls.log" STUB_ROOT="$FAKE" STUB_STATE="$STATE" STUB_ARTIFACT="$WORK/good.tar.zst" \
        STUB_PASSWD="$WORK/stubdata/passwd" STUB_GROUPS="$WORK/stubdata/groups" \
        "${envs[@]}" bash "$PAYLOAD" "$@" 2>&1 < /dev/null)
    RC=$?
    LOGTXT=$(cat "$WORK/calls.log")
}
# default positional args: ports bind user mem tasks pin req sha asset allow
args() { printf '%s\n' "${1:-11434}" "${2:-11435}" "${3:-}" "${4:-}" "${5:-}" "${6:-}" "${7:-}" "${8:-}" "${9:-}" "${10:-}" "${11:-}"; }
mapfile -t A < <(args)

echo "--- F5: Ollama install policy ---"
# a. no pin, no checksum, nothing installed: fail closed, nothing fetched, nothing touched
reset_root
run_server -- "${A[@]}"
check "unpinned: refuses" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "unpinned: message names the opt-out" "yes" "$(grep -q 'FRANKEN_ALLOW_UNVERIFIED_OLLAMA' <<< "$OUT" && echo yes || echo no)"
check "unpinned: nothing fetched" "0" "$(grep -c '^curl' <<< "$LOGTXT" || true)"
check "unpinned: no sudo at all" "0" "$(grep -c '^sudo' <<< "$LOGTXT" || true)"
# b. pin but no checksum
reset_root
mapfile -t B < <(args 11434 11435 "" "" "" "" 0.33.2)
run_server -- "${B[@]}"
check "pin without checksum: refuses" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "pin without checksum: nothing fetched" "0" "$(grep -c '^curl' <<< "$LOGTXT" || true)"
# c. pin + checksum (as install.sh sends them): verified install, same layout as upstream
reset_root
mapfile -t C < <(args 11434 11435 "" "" "" "" 0.33.2 "" "$GOOD_SHA" ollama-linux-amd64.tar.zst)
run_server -- "${C[@]}"
check "verified: binary in place" "yes" "$([ -x "$FAKE/usr/local/bin/ollama" ] && echo yes || echo no)"
check "verified: lib in place" "lib" "$(cat "$FAKE/usr/local/lib/ollama/libfoo.so" 2>/dev/null)"
check "verified: version reported" "yes" "$(grep -q 'Ollama version: 0.33.2' <<< "$OUT" && echo yes || echo no)"
check "verified: https-only release download, exact URL" "yes" \
    "$(grep -q "^curl .*\[--proto\] \[=https\] \[--proto-redir\] \[=https\].*\[https://github.com/ollama/ollama/releases/download/v0.33.2/ollama-linux-amd64.tar.zst\]$" <<< "$LOGTXT" && echo yes || echo no)"
check "verified: no upstream script" "0" "$(grep -c 'ollama.com' <<< "$LOGTXT" || true)"
check "verified: no account or service created for ollama" "0" "$(grep -c '^useradd' <<< "$LOGTXT" || true)"
# d. wrong checksum: fails before anything changes
reset_root
mapfile -t D < <(args 11434 11435 "" "" "" "" 0.33.2 "" "$WRONG_SHA" ollama-linux-amd64.tar.zst)
run_server -- "${D[@]}"
check "wrong checksum: refuses" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "wrong checksum: message" "yes" "$(grep -q 'Checksum mismatch' <<< "$OUT" && echo yes || echo no)"
check "wrong checksum: binary not installed" "no" "$([ -e "$FAKE/usr/local/bin/ollama" ] && echo yes || echo no)"
check "wrong checksum: default service untouched" "0" "$(grep -c 'systemctl' <<< "$LOGTXT" || true)"
check "wrong checksum: no unit written" "" "$(ls -A "$FAKE/etc/systemd/system")"
# e. checksum recorded for another architecture's asset
reset_root
mapfile -t E < <(args 11434 11435 "" "" "" "" 0.33.2 "" "$GOOD_SHA" ollama-linux-someotherarch.tar.zst)
run_server -- "${E[@]}"
check "asset mismatch: refuses" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "asset mismatch: message" "yes" "$(grep -q 'FRANKEN_OLLAMA_SHA256' <<< "$OUT" && echo yes || echo no)"
check "asset mismatch: nothing fetched" "0" "$(grep -c '^curl' <<< "$LOGTXT" || true)"
# f. explicit opt-out: loud warning, upstream script fetched to a file (never piped)
reset_root
mapfile -t F < <(args 11434 11435 "" "" "" "" "" "" "" "" true)
run_server -- "${F[@]}"
check "unverified opt-in: loud warning" "yes" "$(grep -q 'UNVERIFIED OLLAMA INSTALL' <<< "$OUT" && echo yes || echo no)"
check "unverified opt-in: upstream script fetched" "yes" "$(grep -q 'https://ollama.com/install.sh\]$' <<< "$LOGTXT" && echo yes || echo no)"
check "unverified opt-in: script ran as a file" "yes" "$(grep -q 'upstream-script-ran' <<< "$LOGTXT" && echo yes || echo no)"
# g. an existing install that satisfies the request is kept without any checksum
reset_root
mkdir -p "$FAKE/usr/local/bin"
cp "$WORK/art/bin/ollama" "$FAKE/usr/local/bin/ollama"
run_server -- "${A[@]}"
check "existing install kept" "yes" "$(grep -q 'Ollama already installed' <<< "$OUT" && echo yes || echo no)"
check "existing install kept: nothing fetched" "0" "$(grep -c '^curl' <<< "$LOGTXT" || true)"
# h. bad values reaching the server script are refused
for bad in "nothex" "${GOOD_SHA^^}"; do
    reset_root
    mapfile -t H < <(args 11434 11435 "" "" "" "" 0.33.2 "" "$bad" "")
    run_server -- "${H[@]}"
    check "bad checksum value [${bad:0:8}] refused" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
done
reset_root
mapfile -t H < <(args 11434 11435 "" "" "" "" "" "" "$GOOD_SHA" "")
run_server -- "${H[@]}"
check "checksum without a pinned version refused" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
reset_root
mapfile -t H < <(args "11434; touch $WORK/PWNED" 11435)
run_server -- "${H[@]}"
check "hostile port refused on the server" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "hostile port: nothing executed" "no" "$([ -e "$WORK/PWNED" ] && echo yes || echo no)"

check "repo root has no untracked files" "" "$(git -C "$REPO" status --porcelain --untracked-files=all 2>/dev/null | grep '^??' | grep -v 'tests/test-\|ollama-checksums')"

echo "install-flow: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
