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
         cmp tr sed awk sort dirname basename env uname tar sha256sum chmod touch ls readlink realpath zstd true false \
         expr test printf; do
    p="$(command -v "$t" 2> /dev/null || true)"
    case "$p" in /*) ln -sf "$p" "$TOOLS/$t" ;; esac
done
# "test" is a shell builtin for command -v, but sudo stub needs a real program
ln -sf "$(type -P test)" "$TOOLS/test"
mkdir -p "$TOOLS/nozstd"

# --- fake release artifact -----------------------------------------------------------------
mkdir -p "$WORK/art/bin" "$WORK/art/lib/ollama"
printf '#!/bin/sh\necho "ollama version is 0.33.2"\n' > "$WORK/art/bin/ollama"
chmod +x "$WORK/art/bin/ollama"
echo lib > "$WORK/art/lib/ollama/libfoo.so"
tar -cf - -C "$WORK/art" bin lib | zstd -q -o "$WORK/good.tar.zst"
GOOD_SHA="$(sha256sum "$WORK/good.tar.zst" | cut -d' ' -f1)"
mkdir -p "$WORK/art2/bin" "$WORK/art2/lib/ollama"
printf '#!/bin/sh\necho "ollama version is 9.9.9"\n' > "$WORK/art2/bin/ollama"
chmod +x "$WORK/art2/bin/ollama"
echo lib2 > "$WORK/art2/lib/ollama/libfoo.so"
tar -cf - -C "$WORK/art2" bin lib | zstd -q -o "$WORK/wrongver.tar.zst"
WRONGVER_SHA="$(sha256sum "$WORK/wrongver.tar.zst" | cut -d' ' -f1)"
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
    mkdir|install|mv|tee|rm|tar|cp|chmod|test|touch|cmp|ls|readlink|systemctl|systemd-analyze) exec "${args[@]}" ;;
    useradd)
        echo "useradd ${args[*]}" >> "$STUB_LOG"
        name="${args[${#args[@]}-1]}"
        echo "$name:x:998:998::/var/lib/$name:/usr/sbin/nologin" >> "$STUB_PASSWD"
        echo "$name:$name" >> "$STUB_GROUPS"
        exit 0 ;;
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
case " ${STUB_FAIL_CMDS:-} " in *" $cmd: "*) exit 1 ;; esac
for u in "${units[@]}"; do
    case " ${STUB_FAIL_CMDS:-} " in *" $cmd:$u "*) rc=1; continue ;; esac
    case "$cmd" in
        start|restart)
            if [ "$u" = "${STUB_FAIL_START:-}" ]; then rc=1; else touch "$STUB_STATE/active.$u"; fi ;;
        stop) rm -f "$STUB_STATE/active.$u" ;;
        enable) touch "$STUB_STATE/enabled.$u" ;;
        disable) rm -f "$STUB_STATE/enabled.$u" ;;
        mask)
            if [ -n "${STUB_MASK_NOOP:-}" ]; then :
            elif [ -n "${STUB_MASK_NOOP_ONCE:-}" ] && [ ! -e "$STUB_STATE/masknoop.done" ]; then touch "$STUB_STATE/masknoop.done"
            else
                touch "$STUB_STATE/masked.$u"
                # like systemd: a mask is a symlink to /dev/null (never over a real unit file)
                [ -e "$STUB_ROOT/etc/systemd/system/$u.service" ] || [ -L "$STUB_ROOT/etc/systemd/system/$u.service" ] \
                    || ln -s /dev/null "$STUB_ROOT/etc/systemd/system/$u.service"
            fi ;;
        unmask)
            rm -f "$STUB_STATE/masked.$u"
            [ ! -L "$STUB_ROOT/etc/systemd/system/$u.service" ] || rm -f "$STUB_ROOT/etc/systemd/system/$u.service" ;;
        is-active)
            if [ "$u" = "${STUB_FAIL_ACTIVE:-}" ] || [ ! -f "$STUB_STATE/active.$u" ]; then rc=3; fi ;;
        is-enabled)
            if [ -L "$STUB_ROOT/etc/systemd/system/$u.service" ] && [ "$(readlink "$STUB_ROOT/etc/systemd/system/$u.service")" = /dev/null ]; then echo masked; rc=1
            elif [ -f "$STUB_STATE/enabled.$u" ]; then echo enabled
            else echo disabled; rc=1; fi ;;
        *) ;;
    esac
done
exit $rc
STUB
cat > "$STUB/nvidia-smi" << 'STUB'
#!/bin/bash
[ -n "${STUB_SMI_FAIL:-}" ] && exit 1
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
if [ "$out" = /dev/null ] && [ -n "${STUB_HEALTH_FAIL:-}" ]; then exit 22; fi
if [ -z "$out" ] || [ "$out" = /dev/null ]; then exit 0; fi      # health probes and friends
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

# the same stubs minus curl, for the "curl is not installed" cases
STUBNC="$WORK/stub-nocurl"
mkdir -p "$STUBNC"
for f in "$STUB"/*; do
    [ "$(basename "$f")" = curl ] || ln -s "$f" "$STUBNC/$(basename "$f")"
done
STUBDIR="$STUB"

PAYLOAD="$WORK/payload.sh"
{
    echo '#!/bin/bash'
    cat "$REPO/remote/unit-lib.sh"
    # seam: the staged binary lives under the fake /usr/local
    echo 'franken_ollama__staged_version() { franken_ollama_parse_version "$("$STUB_ROOT$1/bin/ollama" --version 2>&1 || true)"; }'
    cat "$REPO/remote/server-install.sh"
} > "$PAYLOAD"

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
    OUT=$(cd "$WORK/home" && env -i PATH="$STUBDIR:$FAKE/usr/local/bin:$TOOLS" HOME="$WORK/home" USER=tester \
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
# (the one sudo call allowed is the read-only probe for a leftover undo area)
check "unpinned: no mutating sudo call" "0" "$(grep '^sudo' <<< "$LOGTXT" | grep -vc '^sudo test ' || true)"
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
check "existing install kept: nothing downloaded" "0" "$(grep -c '^curl .*\(github\.com\|ollama\.com\)' <<< "$LOGTXT" || true)"
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

seed_ollama() { mkdir -p "$FAKE/usr/local/bin"; cp "$WORK/art/bin/ollama" "$FAKE/usr/local/bin/ollama"; }
UNITDIR="$FAKE/etc/systemd/system"
# a pre-existing default service: unit file, active, enabled
seed_default() {
    printf '[Service]\nExecStart=/usr/local/bin/ollama serve\n# ORIGINAL-DEFAULT\n' > "$UNITDIR/ollama.service"
    touch "$STATE/active.ollama" "$STATE/enabled.ollama"
}
state_of() { [ -f "$STATE/$1.$2" ] && echo yes || echo no; }
line_of() { grep -n -m1 -F -- "$1" <<< "$LOGTXT" | cut -d: -f1; }

echo "--- F7: staged install, health check, rollback ---"
# success: replacements started and healthy BEFORE the default service is retired
reset_root; seed_ollama; seed_default
run_server -- "${A[@]}"
check "success: rc" "0" "$RC"
check "success: gpu0 active+enabled" "yes yes" "$(state_of active ollama-gpu0) $(state_of enabled ollama-gpu0)"
check "success: gpu1 active+enabled" "yes yes" "$(state_of active ollama-gpu1) $(state_of enabled ollama-gpu1)"
check "success: default masked, stopped, unit file gone" "yes no no" "$(state_of masked ollama) $(state_of active ollama) $([ -f "$UNITDIR/ollama.service" ] && echo yes || echo no)"
check "success: unit text installed (User line)" "User=tester" "$(grep '^User=' "$UNITDIR/ollama-gpu0.service")"
check "success: no staging files left in the unit dir" "" "$(find "$UNITDIR" -mindepth 1 -maxdepth 1 -name '.*' -printf '%f\n')"
check "success: units verified before any unit was installed" "yes" \
    "$([ "$(line_of 'systemd-analyze verify')" -lt "$(line_of '.ollama-gpu0.service.new')" ] && echo yes || echo no)"
check "success: replacement started before the default is masked" "yes" \
    "$([ "$(line_of 'systemctl start ollama-gpu1.service')" -lt "$(line_of 'systemctl mask ollama.service')" ] && echo yes || echo no)"
check "success: default only disabled after the replacements are enabled" "yes" \
    "$([ "$(line_of 'systemctl enable ollama-gpu1.service')" -lt "$(line_of 'systemctl disable ollama.service')" ] && echo yes || echo no)"
check "success: health probed on the unit port" "yes" "$(grep -q 'http://localhost:11434/api/tags' <<< "$LOGTXT" && echo yes || echo no)"

# a replacement fails to start: everything is put back
reset_root; seed_ollama; seed_default
run_server STUB_FAIL_START=ollama-gpu1 -- "${A[@]}"
check "start fails: rc" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "start fails: says it restores" "yes" "$(grep -q 'restoring the previous service state' <<< "$OUT" && echo yes || echo no)"
check "start fails: default unit file restored byte for byte" "yes" "$(grep -q 'ORIGINAL-DEFAULT' "$UNITDIR/ollama.service" 2> /dev/null && echo yes || echo no)"
check "start fails: default active+enabled again, not masked" "yes yes no" "$(state_of active ollama) $(state_of enabled ollama) $(state_of masked ollama)"
check "start fails: no replacement unit files left" "" "$(find "$UNITDIR" -mindepth 1 -maxdepth 1 ! -name ollama.service -printf '%f\n')"
check "start fails: no replacement left running or enabled" "no no no no" "$(state_of active ollama-gpu0) $(state_of active ollama-gpu1) $(state_of enabled ollama-gpu0) $(state_of enabled ollama-gpu1)"

# a replacement starts but never answers: same
reset_root; seed_ollama; seed_default
run_server STUB_FAIL_ACTIVE=ollama-gpu0 -- "${A[@]}"
check "unhealthy: rc" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "unhealthy: default restored and running" "yes yes no" "$(state_of active ollama) $(state_of enabled ollama) $(state_of masked ollama)"
check "unhealthy: no replacement unit files left" "" "$(find "$UNITDIR" -mindepth 1 -maxdepth 1 ! -name ollama.service -printf '%f\n')"

# earlier replacement units (an upgrade): their old text and state come back
reset_root; seed_ollama
printf '[Service]\n# OLD-GPU0\n' > "$UNITDIR/ollama-gpu0.service"
touch "$STATE/active.ollama-gpu0" "$STATE/enabled.ollama-gpu0"
run_server STUB_FAIL_START=ollama-gpu1 -- "${A[@]}"
check "upgrade fails: old gpu0 unit text back" "yes" "$(grep -q 'OLD-GPU0' "$UNITDIR/ollama-gpu0.service" && echo yes || echo no)"
check "upgrade fails: old gpu0 running+enabled again" "yes yes" "$(state_of active ollama-gpu0) $(state_of enabled ollama-gpu0)"
check "upgrade fails: no gpu1 unit file" "no" "$([ -e "$UNITDIR/ollama-gpu1.service" ] && echo yes || echo no)"

# a unit that does not verify: nothing is touched
reset_root; seed_ollama; seed_default
run_server STUB_VERIFY_FAIL=1 -- "${A[@]}"
check "verify fails: rc" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "verify fails: default untouched" "yes yes no" "$(state_of active ollama) $(state_of enabled ollama) $(state_of masked ollama)"
check "verify fails: no systemctl mutation" "0" "$(grep -c '^sudo systemctl' <<< "$LOGTXT" || true)"
check "verify fails: no unit written" "ORIGINAL-DEFAULT-only" "$(ls -A "$UNITDIR" | tr '\n' ' ' | sed 's/^ollama.service $/ORIGINAL-DEFAULT-only/')"

# set -euo pipefail: a failing nvidia-smi inside the GPU count pipeline stops the install
reset_root; seed_ollama; seed_default
run_server STUB_SMI_FAIL=1 -- "${A[@]}"
check "pipefail: failing nvidia-smi stops the install" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "pipefail: nothing changed" "0" "$(grep -c '^sudo' <<< "$LOGTXT" || true)"
check "server script runs with errexit, nounset and pipefail" "yes" "$(grep -q '^set -euo pipefail$' "$REPO/remote/server-install.sh" && echo yes || echo no)"

# no network bytes are piped into a shell anywhere in the remote installer
PIPE_RE='(curl|wget)[^#]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh'
check "guard bites: the pattern matches a piped install" "yes" "$(grep -qE "$PIPE_RE" <<< 'curl -fsSL https://x.invalid/install.sh | sh' && echo yes || echo no)"
check "no curl|sh in the remote installer files" "" "$(grep -nE "$PIPE_RE" "$REPO/remote/install.sh" "$REPO/remote/server-install.sh" "$REPO/remote/unit-lib.sh" || true)"

echo "--- F8: service account policy ---"
set_account() {  # set_account NAME UID SHELL HOME "GROUPS"
    echo "$1:x:$2:$2::$4:$3" > "$WORK/stubdata/passwd"
    echo "$1:$5" > "$WORK/stubdata/groups"
}
# shellcheck source=../remote/unit-lib.sh
source "$REPO/remote/unit-lib.sh"
for case_ in "ci 1001 /bin/bash /home/ci ci@uid" \
             "svc 998 /bin/bash /var/lib/svc svc@login shell" \
             "svc 998 /usr/sbin/nologin /home/svc svc@var/lib" \
             "svc 998 /usr/sbin/nologin /var/lib/svc svc docker@docker" \
             "svc 998 /usr/sbin/nologin /var/lib/svc svc sudo@sudo" \
             "svc 1000 /usr/sbin/nologin /var/lib/svc svc@uid" \
             "svc 0 /usr/sbin/nologin /var/lib/svc svc@uid" \
             "svc 998 /usr/sbin/nologin /var/lib/../../home/x svc@var/lib" \
             "svc 998 /usr/sbin/nologin /var/libx/svc svc@var/lib"; do
    spec="${case_%%@*}"; want="${case_#*@}"
    read -r n u sh h _ <<< "$spec"
    # shellcheck disable=SC2086  # the group list is a space separated word list
    set_account "$n" "$u" "$sh" "$h" "${spec#"$n $u $sh $h "}"
    why="$(franken_check_service_account "$n" "$u" "$sh" "$h" "${spec#"$n $u $sh $h "}")"
    check "policy refuses [$spec]" "refused" "$([ -n "$why" ] && echo refused || echo accepted)"
    check "policy says why [$spec]" "yes" "$(grep -qiE "$want" <<< "$why" && echo yes || echo no)"
done
for spec in "svc 998 /usr/sbin/nologin /var/lib/svc svc" "svc 1 /usr/sbin/nologin /var/lib/svc/x svc video render" \
            "svc 999 /bin/false /var/lib/svc svc video" "svc 150 /sbin/nologin /var/lib/svc svc"; do
    read -r n u sh h _ <<< "$spec"
    check "policy accepts [$spec]" "ok" "$(franken_check_service_account "$n" "$u" "$sh" "$h" "${spec#"$n $u $sh $h "}" > /dev/null && echo ok || echo refused)"
done

# end to end: an existing login account is refused before anything changes
reset_root; seed_ollama; seed_default
set_account ci 1001 /bin/bash /home/ci "ci docker sudo"
mapfile -t U < <(args 11434 11435 "" ci)
run_server -- "${U[@]}"
check "existing login account: refused" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "existing login account: message" "yes" "$(grep -q 'not a system account' <<< "$OUT" && echo yes || echo no)"
check "existing login account: no usermod, no sudo at all" "0" "$(grep -c '^sudo\|^usermod' <<< "$LOGTXT" || true)"
check "existing login account: default untouched" "yes yes no" "$(state_of active ollama) $(state_of enabled ollama) $(state_of masked ollama)"
# an existing account with an extra group
reset_root; seed_ollama; seed_default
set_account svc 998 /usr/sbin/nologin /var/lib/svc "svc video docker"
mapfile -t U < <(args 11434 11435 "" svc)
run_server -- "${U[@]}"
check "existing account with extra group: refused" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "existing account with extra group: no usermod" "0" "$(grep -c '^usermod' <<< "$LOGTXT" || true)"
# a proper existing dedicated account is accepted and used
reset_root; seed_ollama; seed_default
set_account svc 998 /usr/sbin/nologin /var/lib/svc "svc video"
mapfile -t U < <(args 11434 11435 "" svc)
run_server -- "${U[@]}"
check "dedicated account: rc" "0" "$RC"
check "dedicated account: units run as it" "User=svc" "$(grep '^User=' "$UNITDIR/ollama-gpu0.service")"
check "dedicated account: models under its home" "yes" "$(grep -q "^Environment=\"OLLAMA_MODELS=/var/lib/svc/.ollama/models-gpu0\"" "$UNITDIR/ollama-gpu0.service" && echo yes || echo no)"
# a missing account is created as a system account with nologin
reset_root; seed_ollama; seed_default
mapfile -t U < <(args 11434 11435 "" newsvc)
run_server -- "${U[@]}"
check "missing account: created as a system nologin account" "yes" "$(grep -q '^sudo useradd --system --create-home --home-dir /var/lib/newsvc --shell /usr/sbin/nologin newsvc$' <<< "$LOGTXT" && echo yes || echo no)"
check "missing account: units run as it" "User=newsvc" "$(grep '^User=' "$UNITDIR/ollama-gpu0.service")"

echo "--- F9: rollback failures are reported ---"
reset_root; seed_ollama; seed_default
run_server STUB_FAIL_START=ollama-gpu1 -- "${A[@]}"
check "rollback ok: says restored and verified" "yes" "$(grep -q 'restored and verified' <<< "$OUT" && echo yes || echo no)"
check "rollback ok: not reported as incomplete" "no" "$(grep -q 'ROLLBACK INCOMPLETE' <<< "$OUT" && echo yes || echo no)"
check "rollback ok: exit code is the install failure, not 70" "no" "$([ "$RC" -eq 70 ] && echo yes || echo no)"
# the default service cannot be restarted during rollback
reset_root; seed_ollama; seed_default
run_server STUB_FAIL_START=ollama-gpu1 "STUB_FAIL_CMDS=start:ollama" -- "${A[@]}"
check "rollback start fails: ROLLBACK INCOMPLETE" "yes" "$(grep -q 'ROLLBACK INCOMPLETE' <<< "$OUT" && echo yes || echo no)"
check "rollback start fails: names the step" "yes" "$(grep -q 'restart ollama.service' <<< "$OUT" && echo yes || echo no)"
check "rollback start fails: read-back notices the service is down" "yes" "$(grep -q 'read-back: active state of ollama.service' <<< "$OUT" && echo yes || echo no)"
check "rollback start fails: never claims success" "no" "$(grep -q 'restored and verified' <<< "$OUT" && echo yes || echo no)"
check "rollback start fails: exit 70" "70" "$RC"
# unmask fails during rollback
reset_root; seed_ollama; seed_default
run_server STUB_FAIL_START=ollama-gpu1 "STUB_FAIL_CMDS=unmask:ollama" -- "${A[@]}"
check "rollback unmask fails: ROLLBACK INCOMPLETE and exit 70" "yes 70" "$(grep -q 'unmask ollama.service' <<< "$OUT" && grep -q 'ROLLBACK INCOMPLETE' <<< "$OUT" && echo yes) $RC"
# every daemon-reload fails (the install step and the rollback step)
reset_root; seed_ollama; seed_default
run_server "STUB_FAIL_CMDS=daemon-reload:" -- "${A[@]}"
check "failing daemon-reload in rollback: listed, exit 70" "yes 70" "$(grep -q 'systemd daemon-reload' <<< "$OUT" && grep -q 'ROLLBACK INCOMPLETE' <<< "$OUT" && echo yes) $RC"

echo "--- F10: the retired default service must really end up masked ---"
reset_root; seed_ollama; seed_default
run_server "STUB_FAIL_CMDS=mask:ollama" -- "${A[@]}"
check "mask fails: install fails" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "mask fails: no success claim" "no" "$(grep -q 'masked (permanently' <<< "$OUT" && echo yes || echo no)"
check "mask fails: rollback ran and verified" "yes" "$(grep -q 'restored and verified' <<< "$OUT" && echo yes || echo no)"
check "mask fails: default back (file, active, enabled, not masked)" "yes yes yes no" "$([ -e "$UNITDIR/ollama.service" ] && echo yes || echo no) $(state_of active ollama) $(state_of enabled ollama) $(state_of masked ollama)"
check "mask fails: replacements removed" "" "$(find "$UNITDIR" -mindepth 1 -maxdepth 1 ! -name ollama.service -printf '%f\n')"
reset_root; seed_ollama; seed_default
run_server "STUB_FAIL_CMDS=disable:ollama" -- "${A[@]}"
check "disable fails: install fails and rolls back" "yes yes" "$([ "$RC" -ne 0 ] && echo yes || echo no) $(grep -q 'restored and verified' <<< "$OUT" && echo yes || echo no)"
# mask reports success but the unit is not masked: the read-back stops it
reset_root; seed_ollama; seed_default
run_server STUB_MASK_NOOP=1 -- "${A[@]}"
check "mask is a no-op: install fails (read-back)" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "mask is a no-op: says it is not masked" "yes" "$(grep -q 'is not masked' <<< "$OUT" && echo yes || echo no)"
check "mask is a no-op: default restored and running" "yes yes" "$(state_of active ollama) $(state_of enabled ollama)"

echo "--- F11: readiness needs curl ---"
STUBDIR="$STUBNC"
reset_root; seed_ollama; seed_default
run_server -- "${A[@]}"
STUBDIR="$STUB"
check "no curl: install refuses" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "no curl: message" "yes" "$(grep -q 'curl is required' <<< "$OUT" && echo yes || echo no)"
check "no curl: nothing mutated (no sudo at all)" "0" "$(grep -c '^sudo' <<< "$LOGTXT" || true)"
check "no curl: default untouched" "yes yes no" "$(state_of active ollama) $(state_of enabled ollama) $(state_of masked ollama)"
# the readiness function itself: active service, no curl, nothing answered
check "readiness without curl fails (active but unprobed)" "1" "$( ( PATH="$TOOLS"; export STUB_LOG=/dev/null; systemctl() { return 0; }; franken_wait_unit_ready ollama-gpu0.service http://localhost:11434/api/tags 1; echo $? ) )"
check "guard bites: with curl and an answer it passes" "0" "$( ( PATH="$STUB:$TOOLS"; export STUB_LOG=/dev/null; systemctl() { return 0; }; franken_wait_unit_ready ollama-gpu0.service http://localhost:11434/api/tags 1; echo $? ) )"
# curl present but the service does not answer: the install rolls back
reset_root; seed_ollama; seed_default
run_server STUB_HEALTH_FAIL=1 -- "${A[@]}"
check "active but unreachable: install fails" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "active but unreachable: default restored and running" "yes yes no" "$(state_of active ollama) $(state_of enabled ollama) $(state_of masked ollama)"

echo "--- F12: the Ollama replacement is transactional ---"
UNDO="$FAKE/usr/local/.franken-ollama-undo"
seed_old_install() {  # an older Ollama: binary reporting 0.30.0 and a lib directory
    mkdir -p "$FAKE/usr/local/bin" "$FAKE/usr/local/lib/ollama"
    printf '#!/bin/sh\necho "ollama version is 0.30.0"\n' > "$FAKE/usr/local/bin/ollama"
    chmod +x "$FAKE/usr/local/bin/ollama"
    echo OLDLIB > "$FAKE/usr/local/lib/ollama/OLD"
}
# success: new files in place, backups dropped
reset_root; seed_old_install; seed_default
run_server -- "${C[@]}"
check "swap ok: rc" "0" "$RC"
check "swap ok: new lib, old lib gone" "lib no" "$(cat "$FAKE/usr/local/lib/ollama/libfoo.so" 2> /dev/null) $([ -e "$FAKE/usr/local/lib/ollama/OLD" ] && echo yes || echo no)"
check "swap ok: new binary" "0.33.2" "$("$FAKE/usr/local/bin/ollama" --version | grep -o '[0-9.]*$')"
check "swap ok: backup area removed" "no" "$([ -e "$UNDO" ] && echo yes || echo no)"
# a later installer failure (replacement service will not start): old Ollama comes back
reset_root; seed_old_install; seed_default
run_server STUB_FAIL_START=ollama-gpu1 -- "${C[@]}"
check "late failure: install fails" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "late failure: old binary back" "0.30.0" "$("$FAKE/usr/local/bin/ollama" --version | grep -o '[0-9.]*$')"
check "late failure: old lib back, new lib gone" "OLDLIB no" "$(cat "$FAKE/usr/local/lib/ollama/OLD" 2> /dev/null) $([ -e "$FAKE/usr/local/lib/ollama/libfoo.so" ] && echo yes || echo no)"
check "late failure: backup area removed" "no" "$([ -e "$UNDO" ] && echo yes || echo no)"
check "late failure: services restored too" "yes yes no" "$(state_of active ollama) $(state_of enabled ollama) $(state_of masked ollama)"
# a fresh install (nothing before) that fails later leaves no Ollama files behind
reset_root; seed_default
run_server STUB_FAIL_START=ollama-gpu1 -- "${C[@]}"
check "late failure, fresh install: no new files left" "no no" "$([ -e "$FAKE/usr/local/bin/ollama" ] && echo yes || echo no) $([ -e "$FAKE/usr/local/lib/ollama" ] && echo yes || echo no)"
# the staged release reports another version than the pin: refused, old install intact
reset_root; seed_old_install; seed_default
mapfile -t W < <(args 11434 11435 "" "" "" "" 0.33.2 "" "$WRONGVER_SHA" ollama-linux-amd64.tar.zst)
run_server STUB_ARTIFACT="$WORK/wrongver.tar.zst" -- "${W[@]}"
check "wrong staged version: refused" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "wrong staged version: message" "yes" "$(grep -q 'expected layout or version' <<< "$OUT" && echo yes || echo no)"
check "wrong staged version: old install intact" "0.30.0 OLDLIB" "$("$FAKE/usr/local/bin/ollama" --version | grep -o '[0-9.]*$') $(cat "$FAKE/usr/local/lib/ollama/OLD")"
check "wrong staged version: staging removed" "no" "$([ -e "$UNDO" ] && echo yes || echo no)"
check "wrong staged version: services untouched" "0" "$(grep -c '^sudo systemctl' <<< "$LOGTXT" || true)"

echo "--- M1: a previously masked default unit is masked again after a rollback ---"
# a masked unit is a symlink to /dev/null plus the masked state
seed_masked() { ln -s /dev/null "$UNITDIR/ollama.service"; touch "$STATE/masked.ollama"; }
masked_ok() { echo "$([ "$(readlink "$UNITDIR/ollama.service" 2> /dev/null)" = /dev/null ] && echo link || echo nolink) $(state_of masked ollama) $(state_of active ollama) $(state_of enabled ollama)"; }
# failure BEFORE the retirement step (a replacement will not start)
reset_root; seed_ollama; seed_masked
run_server STUB_FAIL_START=ollama-gpu1 -- "${A[@]}"
check "masked before, early failure: install fails" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "masked before, early failure: restored and verified, not 70" "yes no" "$(grep -q 'restored and verified' <<< "$OUT" && echo yes || echo no) $([ "$RC" -eq 70 ] && echo yes || echo no)"
check "masked before, early failure: still the /dev/null symlink and masked" "link yes no no" "$(masked_ok)"
check "masked before, early failure: no replacement unit files left" "" "$(find "$UNITDIR" -mindepth 1 -maxdepth 1 ! -name ollama.service -printf '%f\n')"
# failure AFTER the retirement step (the mask did not take effect the first time)
reset_root; seed_ollama; seed_masked
run_server STUB_MASK_NOOP_ONCE=1 -- "${A[@]}"
check "masked before, late failure: install fails" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "masked before, late failure: restored and verified, not 70" "yes no" "$(grep -q 'restored and verified' <<< "$OUT" && echo yes || echo no) $([ "$RC" -eq 70 ] && echo yes || echo no)"
check "masked before, late failure: masked again as a /dev/null symlink" "link yes no no" "$(masked_ok)"
check "masked before, late failure: the default was masked again explicitly" "yes" "$([ "$(grep -c '^systemctl mask ollama.service' <<< "$LOGTXT")" -ge 2 ] && echo yes || echo no)"
# the success path from a masked start still ends masked, with no stray files
reset_root; seed_ollama; seed_masked
run_server -- "${A[@]}"
check "masked before, success: rc and masked symlink" "0 link yes no no" "$RC $(masked_ok)"
# the mask cannot be put back during the rollback: reported, not claimed
reset_root; seed_ollama; seed_masked
run_server STUB_FAIL_START=ollama-gpu1 "STUB_FAIL_CMDS=mask:ollama" -- "${A[@]}"
check "masked before, re-mask fails: ROLLBACK INCOMPLETE, exit 70" "yes 70" "$(grep -q 'mask ollama.service again' <<< "$OUT" && grep -q 'ROLLBACK INCOMPLETE' <<< "$OUT" && echo yes) $RC"
# any other symlink is not understood: refused before anything changes
reset_root; seed_ollama; ln -s /usr/lib/systemd/system/other.service "$UNITDIR/ollama.service"
run_server -- "${A[@]}"
check "foreign symlink: refused, nothing mutated" "yes 0" "$(grep -q 'symlink to something other than /dev/null' <<< "$OUT" && echo yes) $(grep -c '^sudo systemctl' <<< "$LOGTXT" || true)"

echo "--- M2: a stale Ollama undo area is recovered, never deleted ---"
# the old install is in the undo area after the first swap (lib moved, bin not yet)
seed_stale_first_swap() {
    seed_old_install
    mkdir -p "$UNDO/backup" "$UNDO/stage/bin"
    mv "$FAKE/usr/local/lib/ollama" "$UNDO/backup/lib"
    mkdir -p "$FAKE/usr/local/lib/ollama"; echo NEWLIB > "$FAKE/usr/local/lib/ollama/libfoo.so"
    touch "$UNDO/new-lib"
    printf '#!/bin/sh\necho "ollama version is 0.33.2"\n' > "$UNDO/stage/bin/ollama"; chmod +x "$UNDO/stage/bin/ollama"
}
seed_stale_second_swap() {
    seed_stale_first_swap
    mkdir -p "$UNDO/stage"
    rm -rf "${UNDO:?}/stage/bin"
    mv "$FAKE/usr/local/bin/ollama" "$UNDO/backup/bin"
    printf '#!/bin/sh\necho "ollama version is 0.33.2"\n' > "$FAKE/usr/local/bin/ollama"; chmod +x "$FAKE/usr/local/bin/ollama"
    touch "$UNDO/new-bin"
}
old_back() { echo "$("$FAKE/usr/local/bin/ollama" --version 2> /dev/null | grep -o '[0-9.]*$') $(cat "$FAKE/usr/local/lib/ollama/OLD" 2> /dev/null) $([ -e "$FAKE/usr/local/lib/ollama/libfoo.so" ] && echo newlib || echo nonew) $([ -e "$UNDO" ] && echo undo || echo noundo)"; }
for stage_ in first second; do
    # the existing install satisfies the request: the interrupted swap is still undone
    reset_root; "seed_stale_${stage_}_swap"; seed_default
    run_server -- "${A[@]}"
    check "stale undo after $stage_ swap, no pin: old install restored first" "0.30.0 OLDLIB nonew noundo" "$(old_back)"
    check "stale undo after $stage_ swap, no pin: says it recovered" "yes" "$(grep -q 'Previous Ollama files restored and verified' <<< "$OUT" && echo yes || echo no)"
    # a new transaction after the recovery that then fails: the old install still comes back
    reset_root; "seed_stale_${stage_}_swap"; seed_default
    run_server STUB_FAIL_START=ollama-gpu1 -- "${C[@]}"
    check "stale undo after $stage_ swap, later failure: install fails" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
    check "stale undo after $stage_ swap, later failure: the OLD install is back" "0.30.0 OLDLIB nonew noundo" "$(old_back)"
done
# an interrupted run that had not swapped anything yet (only staged files)
reset_root; seed_old_install; seed_default
mkdir -p "$UNDO/stage/bin" "$UNDO/backup"; echo staged > "$UNDO/stage/bin/ollama"
run_server -- "${A[@]}"
check "stale undo, nothing swapped: old install untouched, area removed" "0.30.0 OLDLIB nonew noundo" "$(old_back)"
# an ambiguous layout: the backup AND a live item exist, no marker says which is which
reset_root; seed_old_install; seed_default
mkdir -p "$UNDO/backup/lib"; echo PRECIOUS > "$UNDO/backup/lib/OLD"
run_server STUB_FAIL_START=ollama-gpu1 -- "${C[@]}"
check "ambiguous undo: install refused" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "ambiguous undo: message names the left-untouched area" "yes" "$(grep -q 'left untouched' <<< "$OUT" && echo yes || echo no)"
check "ambiguous undo: the backup is still there, byte for byte" "PRECIOUS" "$(cat "$UNDO/backup/lib/OLD" 2> /dev/null)"
check "ambiguous undo: the live install is untouched" "0.30.0 OLDLIB" "$("$FAKE/usr/local/bin/ollama" --version | grep -o '[0-9.]*$') $(cat "$FAKE/usr/local/lib/ollama/OLD")"
check "ambiguous undo: nothing downloaded, no service touched" "0 0" "$(grep -c '^curl' <<< "$LOGTXT" || true) $(grep -c '^sudo systemctl' <<< "$LOGTXT" || true)"
# an unknown entry in the undo area is also not understood
reset_root; seed_old_install; seed_default
mkdir -p "$UNDO/backup"; echo mystery > "$UNDO/something-else"
run_server -- "${A[@]}"
check "unknown entry in the undo area: refused, kept" "yes yes" "$([ "$RC" -ne 0 ] && echo yes || echo no) $([ -e "$UNDO/something-else" ] && echo yes || echo no)"

check "repo root has no untracked files" "" "$(git -C "$REPO" status --porcelain --untracked-files=all 2>/dev/null | grep '^??' | grep -v 'tests/test-\|ollama-checksums')"

echo "install-flow: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
