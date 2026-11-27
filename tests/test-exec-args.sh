#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Test that model names, ports and other data reach commands as arguments,
# never as shell syntax: franken_sh_quote round trip, franken_exec over a stub
# ssh that runs the command line through a real shell, the validators, and the
# model scripts with hostile model names. Everything runs in a scratch copy.
#
# Usage: tests/test-exec-args.sh

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
verdict() { if "$@"; then echo ok; else echo rejected; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin" "$WORK/remote" "$WORK/stub" "$WORK/cwd"
cp "$REPO/config.sh" "$WORK/"
cp "$REPO"/bin/pull-model.sh "$REPO"/bin/add-model.sh "$REPO"/bin/pull-dual-models.sh "$WORK/bin/"
cp "$REPO/remote/unit-lib.sh" "$WORK/remote/"

# --- validators ----------------------------------------------------------------
for v in "gemma4:12b" "llama3.2" "library/qwen:7b-q4_0" "hf.co/org/repo:Q4_K_M" "a" "A_b-c.d"; do
    check "model accepts [$v]" "ok" "$(verdict franken_valid_model_name "$v")"
done
for v in "" "-x" ".x" "m; touch /x" "m'x" 'm"x' 'm$(id)' 'm`id`' "m x" "m
x" "m|x" "m&x" "m>x" "m<x" "m\\x" "m*" "m?" "m{x}" "m(x)" "m#" "m%" "m@" "m!" "$(printf 'a%.0s' $(seq 1 256))"; do
    check "model rejects [${v//$'\n'/NL}]" "rejected" "$(verdict franken_valid_model_name "$v")"
done
for v in 1 80 11434 65535; do
    check "port accepts [$v]" "ok" "$(verdict franken_valid_port "$v")"
done
for v in "" 0 65536 99999 100000 -1 +1 011 1.5 "1 " " 1" "1;id" '$(id)' "1
2" "11434; sudo touch /x; #" abc; do
    check "port rejects [${v//$'\n'/NL}]" "rejected" "$(verdict franken_valid_port "$v")"
done

# --- franken_sh_quote round trip through a real shell --------------------------
HOSTILE=("plain" "a b" "it's" "'" "''" "a'b'c" '$(touch PWNED)' '`touch PWNED`' "x; touch PWNED" \
         "x && touch PWNED" 'x | touch PWNED' '"quoted"' '\' '\n' '*' '?[a]' '~' '$HOME' '${IFS}' \
         "line1
line2" "-n" "--" "")
source <(sed -n '/^franken_sh_quote()/,/^}/p' "$REPO/config.sh")
for h in "${HOSTILE[@]}"; do
    rm -f "$WORK/cwd/PWNED"
    got=$(cd "$WORK/cwd" && sh -c "printf '%s|' $(franken_sh_quote "$h" second)")
    check "quote round trip [${h//$'\n'/NL}]" "$h|second|" "$got"
    check "quote runs nothing [${h//$'\n'/NL}]" "no" "$([ -e "$WORK/cwd/PWNED" ] && echo yes || echo no)"
done
# negative control: naive double quoting of the same value DOES run code
rm -f "$WORK/cwd/PWNED"
(cd "$WORK/cwd" && sh -c "printf '%s' x; $(printf '%s' 'x; touch PWNED')" > /dev/null 2>&1)
check "negative control: unquoted splice executes" "yes" "$([ -e "$WORK/cwd/PWNED" ] && echo yes || echo no)"

# --- franken_exec: remote mode over a stub ssh that runs a real shell ----------
cat > "$WORK/stub/ssh" << 'STUB'
#!/bin/bash
# log, then behave like the remote login shell: skip options and the host, run the rest
echo "ssh $*" >> "$STUB_LOG"
while [ $# -gt 0 ]; do
    case "$1" in
        --) shift; break ;;
        -*) shift ;;
        *) break ;;
    esac
done
shift   # host
cd "$STUB_REMOTE_CWD" && exec sh -c "$*"
STUB
chmod +x "$WORK/stub/ssh"
printf '#!/bin/sh\nprintf "%%s|" "$@"\n' > "$WORK/stub/showargs"
chmod +x "$WORK/stub/showargs"

for h in "${HOSTILE[@]}"; do
    rm -f "$WORK/cwd/PWNED"
    got=$(env -i PATH="$WORK/stub:$PATH" STUB_LOG="$WORK/ssh.log" STUB_REMOTE_CWD="$WORK/cwd" \
        FRANKEN_SERVER_IP=remote-host FRANKEN_IS_LOCAL=false \
        bash -c "source <(sed -n '/^franken_sh_quote()/,/^}/p;/^franken_exec()/,/^}/p' '$REPO/config.sh'); franken_exec showargs \"\$1\" second" _ "$h")
    check "franken_exec remote preserves [${h//$'\n'/NL}]" "$h|second|" "$got"
    check "franken_exec remote runs nothing [${h//$'\n'/NL}]" "no" "$([ -e "$WORK/cwd/PWNED" ] && echo yes || echo no)"
done
got=$(env -i PATH="$PATH" FRANKEN_IS_LOCAL=true \
    bash -c "source <(sed -n '/^franken_exec()/,/^}/p' '$REPO/config.sh'); franken_exec printf '%s|' 'a b' \"x; touch $WORK/cwd/PWNED\"")
check "franken_exec local preserves" "a b|x; touch $WORK/cwd/PWNED|" "$got"
check "franken_exec local runs nothing" "no" "$([ -e "$WORK/cwd/PWNED" ] && echo yes || echo no)"
check "franken_exec with no command fails" "2" "$(env -i PATH="$PATH" FRANKEN_IS_LOCAL=true bash -c "source <(sed -n '/^franken_exec()/,/^}/p' '$REPO/config.sh'); franken_exec 2>/dev/null; echo \$?")"

# --- the model scripts with hostile model names ---------------------------------
cat > "$WORK/stub/ollama" << 'STUB'
#!/bin/bash
echo "ollama $*" >> "$STUB_LOG"
STUB
chmod +x "$WORK/stub/ollama"
BADMODELS=("m; touch PWNED" "m'; touch PWNED; #" 'm$(touch PWNED)' '-rf' 'm`touch PWNED`' "m
touch PWNED")
for envset in "FRANKEN_SERVER_IP=localhost" "FRANKEN_SERVER_IP=remote-host"; do
    for h in "${BADMODELS[@]}"; do
        for script in pull-model.sh "pull-dual-models.sh|m1" "add-model.sh|0" "add-model.sh|all"; do
            name="${script%%|*}"
            pre=""
            [ "$script" != "$name" ] && pre="${script#*|}"
            : > "$WORK/calls.log"
            rm -f "$WORK/cwd/PWNED"
            if [ "$name" = "pull-dual-models.sh" ]; then
                args=("$h" "m2")
            elif [ -n "$pre" ]; then
                args=("$pre" "$h")
            else
                args=("$h")
            fi
            (cd "$WORK/cwd" && env -i PATH="$WORK/stub:$PATH" HOME="$WORK" STUB_LOG="$WORK/calls.log" \
                STUB_REMOTE_CWD="$WORK/cwd" "$envset" FRANKEN_GPU_COUNT=2 \
                bash "$WORK/bin/$name" "${args[@]}" > /dev/null 2>&1)
            check "$name [$envset] hostile model [${h//$'\n'/NL}]: no command ran" "" "$(cat "$WORK/calls.log")"
            check "$name [$envset] hostile model [${h//$'\n'/NL}]: nothing created" "no" "$([ -e "$WORK/cwd/PWNED" ] && echo yes || echo no)"
        done
    done
done

# hostile port from the configuration is refused, not spliced
: > "$WORK/calls.log"
(cd "$WORK/cwd" && env -i PATH="$WORK/stub:$PATH" HOME="$WORK" STUB_LOG="$WORK/calls.log" \
    FRANKEN_SERVER_IP=localhost FRANKEN_GPU0_PORT='11434; touch PWNED' bash "$WORK/bin/pull-model.sh" m1 > /dev/null 2>&1)
check "pull-model hostile port: no command ran" "" "$(cat "$WORK/calls.log")"
check "pull-model hostile port: nothing created" "no" "$([ -e "$WORK/cwd/PWNED" ] && echo yes || echo no)"

# a valid name still goes through as ONE argument over ssh
: > "$WORK/calls.log"
(cd "$WORK/cwd" && env -i PATH="$WORK/stub:$PATH" HOME="$WORK" STUB_LOG="$WORK/calls.log" STUB_REMOTE_CWD="$WORK/cwd" \
    FRANKEN_SERVER_IP=remote-host FRANKEN_GPU_COUNT=1 bash "$WORK/bin/pull-model.sh" 'library/qwen:7b' > /dev/null 2>&1)
check "valid model over ssh: one quoted argument" "ssh -- remote-host 'env' 'OLLAMA_HOST=http://localhost:11434' 'ollama' 'pull' 'library/qwen:7b'
ollama pull library/qwen:7b" "$(cat "$WORK/calls.log")"

check "repo root has no untracked files" "" "$(git -C "$REPO" status --porcelain --untracked-files=all 2>/dev/null | grep '^??')"

echo "exec-args: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
