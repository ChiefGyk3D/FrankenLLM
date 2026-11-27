#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# Test the verified Ollama install helpers in remote/unit-lib.sh against a fake
# release artifact: the checksum is checked BEFORE anything is extracted, a wrong
# hash or a hostile archive leaves the target untouched, the download uses https
# only, and a missing zstd stops with a clear message. curl is a stub that copies
# a local file; nothing touches the network, /usr/local or a real service.
#
# Usage: tests/test-ollama-verify.sh

set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../remote/unit-lib.sh
source "$REPO/remote/unit-lib.sh"
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

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/stub" "$WORK/art/good/bin" "$WORK/art/good/lib/ollama"
ASSET="ollama-linux-amd64.tar.zst"

# --- the checksum table shipped in the repo ----------------------------------------
TABLE="$REPO/remote/ollama-checksums.txt"
check "table: 0.33.2 amd64 entry" "9785247dea264d9072f09f6c9c0eb4b8e666892826a3d8388eba3e8fb9ed1db9" \
    "$(franken_ollama_checksum_lookup 0.33.2 "$ASSET" "$TABLE")"
check "table: unknown version" "none" "$(franken_ollama_checksum_lookup 0.33.3 "$ASSET" "$TABLE" || echo none)"
check "table: other asset" "none" "$(franken_ollama_checksum_lookup 0.33.2 ollama-linux-arm64.tar.zst "$TABLE" || echo none)"
check "table: missing file" "none" "$(franken_ollama_checksum_lookup 0.33.2 "$ASSET" "$WORK/nope" || echo none)"
H64="$(printf 'a%.0s' $(seq 1 64))"
printf '# comment\n\n0.1.0 %s %s\n0.1.1 %s not-a-hash\n0.1.2 %s %s extra\n0.1.3 %s %s\n' \
    "$ASSET" "$H64" "$ASSET" "$ASSET" "$H64" "$ASSET" "${H64^^}" > "$WORK/table"
check "table: good line" "$H64" "$(franken_ollama_checksum_lookup 0.1.0 "$ASSET" "$WORK/table")"
check "table: bad hash line ignored" "none" "$(franken_ollama_checksum_lookup 0.1.1 "$ASSET" "$WORK/table" || echo none)"
check "table: extra field ignored" "none" "$(franken_ollama_checksum_lookup 0.1.2 "$ASSET" "$WORK/table" || echo none)"
check "table: uppercase hash ignored" "none" "$(franken_ollama_checksum_lookup 0.1.3 "$ASSET" "$WORK/table" || echo none)"
check "table: prefix of a version does not match" "none" "$(franken_ollama_checksum_lookup 0.1 "$ASSET" "$WORK/table" || echo none)"

# --- hash / url validators ----------------------------------------------------------
for v in "$H64" "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"; do
    franken_valid_sha256 "$v" && check "sha accepts" ok ok || check "sha accepts [$v]" ok rejected
done
for v in "" "abc" "${H64^^}" "${H64}0" "${H64:1}" "${H64:0:63}g" "$H64 " "$H64
$H64"; do
    franken_valid_sha256 "$v" && check "sha rejects [${v:0:20}]" rejected ok || check "sha rejects" ok ok
done
check "url" "https://github.com/ollama/ollama/releases/download/v0.33.2/ollama-linux-amd64.tar.zst" \
    "$(franken_ollama_asset_url 0.33.2 "$ASSET")"
check "url rc" "https://github.com/ollama/ollama/releases/download/v0.34.0-rc1/ollama-linux-arm64.tar.zst" \
    "$(franken_ollama_asset_url 0.34.0-rc1 ollama-linux-arm64.tar.zst)"
for pair in "0.33.2;id|$ASSET" "0.33.2|../x.tar.zst" "0.33.2|ollama-linux-amd64.tgz" "0.33.2|ollama-linux-a/b.tar.zst" "latest|$ASSET" "|$ASSET"; do
    check "url refuses [$pair]" "none" "$(franken_ollama_asset_url "${pair%%|*}" "${pair#*|}" || echo none)"
done

# --- fake release artifacts -----------------------------------------------------------
printf '#!/bin/sh\necho "ollama version is 0.33.2"\n' > "$WORK/art/good/bin/ollama"
chmod +x "$WORK/art/good/bin/ollama"
echo "lib" > "$WORK/art/good/lib/ollama/libfoo.so"
tar -cf - -C "$WORK/art/good" bin lib | zstd -q -o "$WORK/art/good.tar.zst"
GOOD_SHA="$(sha256sum "$WORK/art/good.tar.zst" | cut -d' ' -f1)"
# hostile archives whose own sha256 is "correct": only the member checks stop them
mkdir -p "$WORK/art/evil1"; echo x > "$WORK/art/evil1/f"
tar -cf - -C "$WORK/art/evil1" --transform 's,^,../,' f | zstd -q -o "$WORK/art/parent.tar.zst"
tar -cf - -P -C "$WORK/art/evil1" --transform 's,^,/tmp/franken-never-,' f | zstd -q -o "$WORK/art/absolute.tar.zst"
mkdir -p "$WORK/art/evil3/bin"; ln -s /etc/passwd "$WORK/art/evil3/bin/ollama"
tar -cf - -C "$WORK/art/evil3" bin | zstd -q -o "$WORK/art/symlink-out.tar.zst"
mkdir -p "$WORK/art/evil4/bin"; ln -s ../../etc/passwd "$WORK/art/evil4/bin/ollama"
tar -cf - -C "$WORK/art/evil4" bin | zstd -q -o "$WORK/art/symlink-parent.tar.zst"
# a different file in the place of the good one (same name, other content)
mkdir -p "$WORK/art/other/bin"; printf '#!/bin/sh\necho evil\n' > "$WORK/art/other/bin/ollama"; chmod +x "$WORK/art/other/bin/ollama"
tar -cf - -C "$WORK/art/other" bin | zstd -q -o "$WORK/art/other.tar.zst"

cat > "$WORK/stub/curl" << 'STUB'
#!/bin/bash
{ printf 'curl'; printf ' [%s]' "$@"; printf '\n'; } >> "$STUB_LOG"
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        --output) out="$2"; shift 2 ;;
        --) shift; break ;;
        *) shift ;;
    esac
done
[ -n "${STUB_CURL_FAIL:-}" ] && exit 22
cp "$STUB_ARTIFACT" "$out"
STUB
chmod +x "$WORK/stub/curl"
LOG="$WORK/curl.log"

# install_with ARTIFACT SHA [VERSION] -> RC, OUT; target in $WORK/root
install_with() {
    : > "$LOG"
    rm -rf "${WORK:?}/root"
    mkdir -p "$WORK/root/lib/ollama"
    echo "old" > "$WORK/root/lib/ollama/OLD"
    OUT=$(PATH="$WORK/stub:$PATH" STUB_LOG="$LOG" STUB_ARTIFACT="$1" \
        franken_ollama_install_verified "${3:-0.33.2}" "$2" "$ASSET" "$WORK/root" 2>&1)
    RC=$?
}

# --- good artifact ------------------------------------------------------------------------
install_with "$WORK/art/good.tar.zst" "$GOOD_SHA"
check "good: rc" "0" "$RC"
check "good: binary extracted" "yes" "$([ -x "$WORK/root/bin/ollama" ] && echo yes || echo no)"
check "good: lib extracted" "lib" "$(cat "$WORK/root/lib/ollama/libfoo.so" 2>/dev/null)"
check "good: old lib dir replaced" "no" "$([ -e "$WORK/root/lib/ollama/OLD" ] && echo yes || echo no)"
check "good: https url, only https allowed, redirects too" "yes" \
    "$(grep -q "^curl .*\[--proto\] \['=https'\] \[--proto-redir\] \['=https'\].*\[-- \]\|^curl .*\[--proto\] \[=https\] \[--proto-redir\] \[=https\]" "$LOG" && echo yes || echo no)"
check "good: exact release URL" "yes" "$(grep -q '\[https://github.com/ollama/ollama/releases/download/v0.33.2/ollama-linux-amd64.tar.zst\]$' "$LOG" && echo yes || echo no)"
check "good: says verified" "yes" "$(grep -q 'sha256 verified' <<< "$OUT" && echo yes || echo no)"
check "good: no upstream script fetched" "0" "$(grep -c 'ollama.com' "$LOG" || true)"

# --- wrong hash: nothing extracted, nothing removed -------------------------------------------
install_with "$WORK/art/good.tar.zst" "$H64"
check "wrong hash: rc" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "wrong hash: message" "yes" "$(grep -q 'Checksum mismatch' <<< "$OUT" && echo yes || echo no)"
check "wrong hash: no binary" "no" "$([ -e "$WORK/root/bin/ollama" ] && echo yes || echo no)"
check "wrong hash: old lib still there" "yes" "$([ -e "$WORK/root/lib/ollama/OLD" ] && echo yes || echo no)"
check "wrong hash: nothing extracted" "OLD" "$(ls "$WORK/root/lib/ollama")"

# --- a different artifact than the one the hash is for (tampered download) -------------------
install_with "$WORK/art/other.tar.zst" "$GOOD_SHA"
check "tampered download: rc" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
check "tampered download: nothing extracted" "no" "$([ -e "$WORK/root/bin/ollama" ] && echo yes || echo no)"
check "tampered download: old lib still there" "yes" "$([ -e "$WORK/root/lib/ollama/OLD" ] && echo yes || echo no)"

# --- hostile archive with a matching hash: member checks stop it -------------------------------
for name in parent absolute symlink-out symlink-parent; do
    sha="$(sha256sum "$WORK/art/$name.tar.zst" | cut -d' ' -f1)"
    install_with "$WORK/art/$name.tar.zst" "$sha"
    check "hostile archive [$name]: refused" "yes" "$([ "$RC" -ne 0 ] && echo yes || echo no)"
    check "hostile archive [$name]: old lib kept" "yes" "$([ -e "$WORK/root/lib/ollama/OLD" ] && echo yes || echo no)"
    check "hostile archive [$name]: nothing written outside" "no" "$([ -e "$WORK/f" ] || [ -e /tmp/franken-never-f ] && echo yes || echo no)"
done

# --- download failure, bad inputs ----------------------------------------------------------------
: > "$LOG"
check "curl failure: rc" "yes" "$(STUB_CURL_FAIL=1 PATH="$WORK/stub:$PATH" STUB_LOG="$LOG" STUB_ARTIFACT="$WORK/art/good.tar.zst" \
    franken_ollama_install_verified 0.33.2 "$GOOD_SHA" "$ASSET" "$WORK/root" > /dev/null 2>&1 || echo yes)"
check "bad sha input refused before any download" "0" "$( : > "$LOG"; PATH="$WORK/stub:$PATH" STUB_LOG="$LOG" STUB_ARTIFACT="$WORK/art/good.tar.zst" \
    franken_ollama_install_verified 0.33.2 "nothex" "$ASSET" "$WORK/root" > /dev/null 2>&1; grep -c '^curl' "$LOG" || true)"
check "bad root refused" "yes" "$(PATH="$WORK/stub:$PATH" STUB_LOG="$LOG" STUB_ARTIFACT="$WORK/art/good.tar.zst" \
    franken_ollama_install_verified 0.33.2 "$GOOD_SHA" "$ASSET" "/" > /dev/null 2>&1 || echo yes)"
check "download refuses a non-https URL" "yes" "$(franken_ollama_download http://example.invalid/x "$WORK/x" > /dev/null 2>&1 || echo yes)"

# --- zstd missing: clear message, nothing fetched -------------------------------------------------
mkdir -p "$WORK/nozstd"
for t in bash sh cat cut grep tar sha256sum mktemp rm install mkdir uname command; do
    p="$(command -v "$t" 2> /dev/null)"
    case "$p" in /*) ln -sf "$p" "$WORK/nozstd/$t" ;; esac
done
: > "$LOG"
OUT=$(PATH="$WORK/stub:$WORK/nozstd" STUB_LOG="$LOG" STUB_ARTIFACT="$WORK/art/good.tar.zst" \
    franken_ollama_install_verified 0.33.2 "$GOOD_SHA" "$ASSET" "$WORK/root" 2>&1)
check "no zstd: rc" "yes" "$([ $? -ne 0 ] && echo yes || echo no)"
check "no zstd: clear message" "yes" "$(grep -q 'zstd is required' <<< "$OUT" && echo yes || echo no)"
check "no zstd: nothing downloaded" "0" "$(grep -c '^curl' "$LOG" || true)"

# --- unverified path: downloaded to a file first, never piped; version is validated ------------------
cat > "$WORK/stub/sh" << 'STUB'
#!/bin/bash
echo "sh $* OLLAMA_VERSION=${OLLAMA_VERSION:-}" >> "$STUB_LOG"
STUB
chmod +x "$WORK/stub/sh"
: > "$LOG"
OUT=$(PATH="$WORK/stub:$PATH" STUB_LOG="$LOG" STUB_ARTIFACT="$WORK/art/good.tar.zst" franken_ollama_unverified_install 0.33.2 2>&1)
check "unverified: loud warning" "yes" "$(grep -q 'UNVERIFIED OLLAMA INSTALL' <<< "$OUT" && echo yes || echo no)"
check "unverified: fetched with https-only flags to a file" "yes" "$(grep -q "^curl .*--output.*https://ollama.com/install.sh\]$" "$LOG" && echo yes || echo no)"
check "unverified: script run as a file argument with the pin" "yes" "$(grep -qE '^sh .*ollama-install.sh OLLAMA_VERSION=0.33.2$' "$LOG" && echo yes || echo no)"
check "unverified: hostile version refused" "yes" "$(franken_ollama_unverified_install '0.33.2; id' > /dev/null 2>&1 || echo yes)"

check "repo root has no untracked files" "" "$(git -C "$REPO" status --porcelain --untracked-files=all 2>/dev/null | grep '^??' | grep -v 'tests/test-\|ollama-checksums')"

echo "ollama-verify: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
