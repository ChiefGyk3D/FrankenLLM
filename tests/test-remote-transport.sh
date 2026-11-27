#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Test the transport of remote/install.sh and remote/setup-warmup.sh: what the
# ssh and scp command lines carry, how the private remote directory is created,
# verified and removed, and that hostile ports, install directories and hosts
# are refused before anything is sent. ssh, scp, sudo, systemctl and
# systemd-analyze are stubs on PATH; the "remote" side is a scratch directory.
# Nothing is written into the repo and no network or real service is touched.
#
# Usage: tests/test-remote-transport.sh

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
verdict() { if "$@" > /dev/null 2>&1; then echo ok; else echo rejected; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
R="$WORK/repo"            # scratch copy of the repo (no .env)
mkdir -p "$R/bin" "$R/remote" "$WORK/stub" "$WORK/localtmp" "$WORK/remotetmp" "$WORK/etc" "$WORK/cwd"
cp "$REPO/config.sh" "$R/"
cp "$REPO"/remote/install.sh "$REPO"/remote/server-install.sh "$REPO"/remote/unit-lib.sh "$REPO"/remote/setup-warmup.sh "$R/remote/"
cp "$REPO"/bin/warmup-models.sh "$REPO"/bin/warmup-lib.sh "$REPO"/bin/warmup-on-boot.sh "$R/bin/"
: > "$R/.env"

# --- stubs ---------------------------------------------------------------------
cat > "$WORK/stub/ssh" << 'STUB'
#!/bin/bash
# log the full command line, then act as the remote login shell
{ printf 'ssh'; printf ' [%s]' "$@"; printf '\n'; } >> "$STUB_LOG"
while [ $# -gt 0 ]; do
    case "$1" in
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done
shift   # host
cd "$STUB_REMOTE_CWD" || exit 1
TMPDIR="$STUB_REMOTE_TMP" exec sh -c "$*"
STUB
cat > "$WORK/stub/scp" << 'STUB'
#!/bin/bash
{ printf 'scp'; printf ' [%s]' "$@"; printf '\n'; } >> "$STUB_LOG"
args=()
for a in "$@"; do
    case "$a" in -q|--) ;; *) args+=("$a") ;; esac
done
src="${args[0]}"
dest="${args[1]#*:}"
cp "$src" "$dest" || exit 1
if [ -n "${STUB_DIRMODE:-}" ]; then chmod "$STUB_DIRMODE" "$(dirname "$dest")"; fi
echo "dirmode $(stat -c %a "$(dirname "$dest")")" >> "$STUB_LOG"
if [ -n "${STUB_TAMPER:-}" ]; then echo 'touch "$STUB_REMOTE_CWD/TAMPERED"' >> "$dest"; fi
if [ -n "${STUB_SYMLINK:-}" ]; then
    cp "$dest" "$dest.real" && rm -f "$dest" && ln -s "$dest.real" "$dest"
fi
exit 0
STUB
# sudo: never real. Record, map system paths into the scratch etc, drop owner flags.
cat > "$WORK/stub/sudo" << 'STUB'
#!/bin/bash
echo "sudo $*" >> "$STUB_LOG"
[ -n "${STUB_SUDO_FAIL:-}" ] && exit 1
args=()
skip=0
for a in "$@"; do
    if [ "$skip" -eq 1 ]; then skip=0; continue; fi
    case "$a" in
        -o|-g) skip=1; continue ;;
        /etc/systemd/system*) a="$STUB_ETC${a#/etc/systemd/system}" ;;
    esac
    args+=("$a")
done
# only a few commands are emulated; anything else fails closed
case "${args[0]}" in
    mkdir|chown|install|mv|tee|rm) exec "${args[@]}" ;;
    systemctl) exit 0 ;;
    *) exit 1 ;;
esac
STUB
printf '#!/bin/sh\necho "systemctl $*" >> "$STUB_LOG"\nexit 0\n' > "$WORK/stub/systemctl"
printf '#!/bin/sh\necho "systemd-analyze $*" >> "$STUB_LOG"\nexit 0\n' > "$WORK/stub/systemd-analyze"
chmod +x "$WORK"/stub/*

# run_install [VAR=value ...]  -> RC, OUT, LOGTXT
run_install() {
    : > "$WORK/calls.log"
    rm -rf "${WORK:?}/remotetmp" "${WORK:?}/localtmp" "$WORK/cwd/TAMPERED" "$WORK/cwd/PWNED"
    mkdir -p "$WORK/remotetmp" "$WORK/localtmp"
    OUT=$(cd "$WORK/cwd" && echo | env -i PATH="$WORK/stub:$PATH" HOME="$WORK" TMPDIR="$WORK/localtmp" \
        STUB_LOG="$WORK/calls.log" STUB_REMOTE_CWD="$WORK/cwd" STUB_REMOTE_TMP="$WORK/remotetmp" STUB_ETC="$WORK/etc" \
        FRANKEN_SERVER_IP=test-host STUB_SUDO_FAIL=1 "$@" bash "$R/remote/install.sh" 2>&1)
    RC=$?
    LOGTXT=$(cat "$WORK/calls.log")
}
count_calls() { grep -c -E '^(ssh|scp) ' <<< "$LOGTXT" || true; }

# --- validators ----------------------------------------------------------------
for v in "/opt/frankenllm" "/srv/a-b_c.d/e" "/a" "/opt/frank.llm/x"; do
    check "install dir accepts [$v]" "ok" "$(verdict franken_valid_install_dir "$v")"
done
for v in "" "/" "opt/frank" "./x" "/opt/../etc" "/opt/./x" "/opt//x" "/opt/x/" "/opt/x y" "/opt/x;id" '/opt/$(id)' '/opt/`id`' "/opt/x'y" '/opt/x"y' \
         "/opt/x
ExecStartPost=/bin/true" "/opt/x#" "/opt/x&y" "/opt/x|y" "/opt/x\\y" "/opt/é" "/$(printf 'a%.0s' $(seq 1 201))"; do
    check "install dir rejects [${v//$'\n'/NL}]" "rejected" "$(verdict franken_valid_install_dir "$v")"
done
for v in "host" "192.0.2.10" "user@host.example" "h-1.example.net" "fe80::1"; do
    check "ssh host accepts [$v]" "ok" "$(verdict franken_valid_ssh_host "$v")"
done
for v in "" "-oProxyCommand=id" "-x" "host;id" "host name" 'a$(id)' "user@" "@host" "host
x"; do
    check "ssh host rejects [${v//$'\n'/NL}]" "rejected" "$(verdict franken_valid_ssh_host "$v")"
done

# --- warmup unit rendering ---------------------------------------------------------
UNIT="$(franken_render_warmup_unit /opt/frankenllm alice)"
check "warmup unit: user line" "User=alice" "$(grep '^User=' <<< "$UNIT")"
check "warmup unit: exec line" "ExecStart=/opt/frankenllm/bin/warmup-on-boot.sh" "$(grep '^ExecStart=' <<< "$UNIT")"
check "warmup unit: workdir line" "WorkingDirectory=/opt/frankenllm" "$(grep '^WorkingDirectory=' <<< "$UNIT")"
for d in "/opt/x
ExecStartPost=/bin/true" "/opt/x;id" "/opt/../x" "x"; do
    check "warmup unit refuses dir [${d//$'\n'/NL}]" "rejected:" "$(franken_render_warmup_unit "$d" alice > "$WORK/u.out" 2>&1 && echo ok || echo rejected):$(cat "$WORK/u.out")"
done
for u in "a
b" "a;id" "" 'a$(id)' "a b"; do
    check "warmup unit refuses user [${u//$'\n'/NL}]" "rejected:" "$(franken_render_warmup_unit /opt/x "$u" > "$WORK/u.out" 2>&1 && echo ok || echo rejected):$(cat "$WORK/u.out")"
done

# --- install.sh: hostile values refused before anything is sent -----------------
for kv in "FRANKEN_GPU0_PORT=11434; touch PWNED; #" "FRANKEN_GPU1_PORT=\$(touch PWNED)" "FRANKEN_GPU0_PORT=0" \
          "FRANKEN_GPU1_PORT=70000" "FRANKEN_GPU0_PORT=11434 11435" \
          "FRANKEN_SERVER_IP=-oProxyCommand=touch PWNED" "FRANKEN_SERVER_IP=host;touch PWNED" \
          "FRANKEN_BIND_ADDR=192.0.2.10; touch PWNED" "FRANKEN_SERVICE_USER=a;touch PWNED"; do
    run_install "$kv"
    check "install refuses [$kv]: rc" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
    check "install refuses [$kv]: no ssh/scp" "0" "$(count_calls)"
    check "install refuses [$kv]: nothing created" "no" "$([ -e "$WORK/cwd/PWNED" ] && echo yes || echo no)"
done

# --- install.sh: normal path, private directory, quoted arguments ----------------
run_install FRANKEN_GPU0_PORT=11500 FRANKEN_GPU1_PORT=11501 FRANKEN_BIND_ADDR=192.0.2.10
check "install runs the server script" "yes" "$(grep -q 'Remote Installation Starting' <<< "$OUT" && echo yes || echo no)"
RUNLINE="$(grep "^ssh \[-t\]" <<< "$LOGTXT")"
check "run command: ssh -t -- host, then ONE quoted word" "yes" "$([[ "$RUNLINE" =~ ^ssh\ \[-t\]\ \[--\]\ \[test-host\]\ \[\'bash\'\ \'-c\'\ \'.*\'\ \'_\'\ \'$WORK/remotetmp/tmp\.[A-Za-z0-9]+\'\ \'11500\'\ \'11501\'\ \'192\.0\.2\.10\'\ \'\'\ \'\'\ \'\'\ \'\'\ \'\'\]$ ]] && echo yes || echo no)"
check "never the fixed /tmp path" "0" "$(grep -c '/tmp/frankenllm-remote-install' <<< "$LOGTXT" || true)"
check "remote dir is private (0700) at copy time" "dirmode 700" "$(grep '^dirmode' <<< "$LOGTXT")"
check "remote dir removed afterwards" "" "$(ls -A "$WORK/remotetmp")"
check "local payload removed afterwards" "" "$(ls -A "$WORK/localtmp")"
check "scp goes into the remote dir" "yes" "$([[ "$(grep '^scp' <<< "$LOGTXT")" =~ \[test-host:$WORK/remotetmp/tmp\.[A-Za-z0-9]+/install\.sh\] ]] && echo yes || echo no)"

# --- install.sh: the copy is verified before it is run ---------------------------
run_install STUB_TAMPER=1
check "tampered copy: rc" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "tampered copy: not run" "no" "$(grep -q 'Remote Installation Starting' <<< "$OUT" && echo yes || echo no)"
check "tampered copy: says verification failed" "yes" "$(grep -q 'failed verification' <<< "$OUT" && echo yes || echo no)"
check "tampered copy: remote dir removed" "" "$(ls -A "$WORK/remotetmp")"
run_install STUB_SYMLINK=1
check "symlinked copy: not run" "no" "$(grep -q 'Remote Installation Starting' <<< "$OUT" && echo yes || echo no)"
check "symlinked copy: refused" "yes" "$(grep -q 'failed verification' <<< "$OUT" && echo yes || echo no)"
run_install STUB_DIRMODE=755
check "group-readable dir: not run" "no" "$(grep -q 'Remote Installation Starting' <<< "$OUT" && echo yes || echo no)"
check "group-readable dir: refused" "yes" "$(grep -q 'failed verification' <<< "$OUT" && echo yes || echo no)"
# a wrong hash alone (content differs from what was hashed) is refused too: tamper
# changes content only, nothing else about the copy
check "no side effect from tampered content" "no" "$([ -e "$WORK/cwd/TAMPERED" ] && echo yes || echo no)"

# --- setup-warmup.sh ----------------------------------------------------------------
run_warmup() {
    : > "$WORK/calls.log"
    rm -rf "${WORK:?}/etc" "$WORK/cwd/PWNED"
    mkdir -p "$WORK/etc"
    OUT=$(cd "$WORK/cwd" && echo y | env -i PATH="$WORK/stub:$PATH" HOME="$WORK" TMPDIR="$WORK/localtmp" \
        STUB_LOG="$WORK/calls.log" STUB_REMOTE_CWD="$WORK/cwd" STUB_REMOTE_TMP="$WORK/localtmp" STUB_ETC="$WORK/etc" \
        FRANKEN_SERVER_IP=test-host "$@" bash "$R/remote/setup-warmup.sh" 2>&1)
    RC=$?
    LOGTXT=$(cat "$WORK/calls.log")
}
for d in "/tmp/x; touch $WORK/cwd/PWNED; #" "/tmp/x
ExecStartPost=/bin/touch $WORK/cwd/PWNED" '/tmp/$(touch PWNED)' "/tmp/../x" "relative/dir" "/tmp/a b" "/tmp/x'y"; do
    run_warmup "FRANKEN_INSTALL_DIR=$d"
    check "warmup refuses dir [${d//$'\n'/NL}]: rc" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
    check "warmup refuses dir [${d//$'\n'/NL}]: no ssh/scp" "0" "$(count_calls)"
    check "warmup refuses dir [${d//$'\n'/NL}]: nothing created" "no" "$([ -e "$WORK/cwd/PWNED" ] && echo yes || echo no)"
done
run_warmup "FRANKEN_INSTALL_DIR=$WORK/opt-frank" FRANKEN_SERVER_IP=-oProxyCommand=id
check "warmup refuses option-like host" "0" "$(count_calls)"
check "warmup refuses option-like host: rc" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"

run_warmup "FRANKEN_INSTALL_DIR=$WORK/opt-frank"
check "warmup valid dir: rc" "0" "$RC"
check "warmup: dir created" "yes" "$([ -d "$WORK/opt-frank/bin" ] && echo yes || echo no)"
check "warmup: unit installed" "yes" "$([ -f "$WORK/etc/frankenllm-warmup.service" ] && echo yes || echo no)"
check "warmup: unit User line" "User=$(id -un)" "$(grep '^User=' "$WORK/etc/frankenllm-warmup.service")"
check "warmup: unit ExecStart line" "ExecStart=$WORK/opt-frank/bin/warmup-on-boot.sh" "$(grep '^ExecStart=' "$WORK/etc/frankenllm-warmup.service")"
check "warmup: unit has exactly one ExecStart and one WorkingDirectory" "2" "$(grep -c -E '^(ExecStart|WorkingDirectory)=' "$WORK/etc/frankenllm-warmup.service")"
check "warmup: unit verified before install" "yes" "$(grep -q '^systemd-analyze verify' <<< "$LOGTXT" && echo yes || echo no)"
check "warmup: staged name then atomic rename" "yes" "$(grep -q 'sudo mv -f .*\.frankenllm-warmup\.service\.new' <<< "$LOGTXT" && echo yes || echo no)"
check "warmup: dir passed as one quoted word" "yes" "$(grep -q "^ssh \[-t\] \[--\] \[test-host\] \['bash' '-c' '.*' '_' '$WORK/opt-frank'\]$" <<< "$LOGTXT" && echo yes || echo no)"

check "repo root has no untracked files" "" "$(git -C "$REPO" status --porcelain --untracked-files=all 2>/dev/null | grep '^??' | grep -v 'tests/test-' )"

echo "remote-transport: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
