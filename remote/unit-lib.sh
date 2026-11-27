#!/bin/bash
# SPDX-License-Identifier: MPL-2.0
# FrankenLLM - systemd unit rendering and validation for remote/install.sh.
# Pure functions: nothing here touches systemd, the filesystem or the network,
# so tests/test-unit-render.sh can source this file and check the unit text.
# install.sh appends this file to the script it copies to the target server.

# franken_valid_bind_addr ADDR - IPv4 dotted quad, each octet 0-255.
franken_valid_bind_addr() {
    local addr="$1" octet
    local -a octets
    [[ "$addr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    IFS=. read -r -a octets <<< "$addr"
    for octet in "${octets[@]}"; do
        [ "$((10#$octet))" -le 255 ] || return 1
    done
}

# franken_valid_port VALUE - decimal integer 1..65535, no sign, no leading zero.
franken_valid_port() {
    local LC_ALL=C   # byte-wise character classes, not locale ranges
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && [ "$1" -le 65535 ]
}

# franken_valid_model_name NAME - conservative Ollama model reference: letters,
# digits, dot, dash, underscore, colon and slash; must start with a letter or
# digit (so it can never look like an option); at most 255 characters.
franken_valid_model_name() {
    local LC_ALL=C   # byte-wise character classes, not locale ranges
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:/-]{0,254}$ ]]
}

# franken_valid_install_dir PATH - absolute, normalized, conservative characters:
# no "." or ".." components, no empty components, not "/", at most 200 characters.
franken_valid_install_dir() {
    local LC_ALL=C   # byte-wise character classes, not locale ranges
    local p="$1" part
    local -a parts
    [ "${#p}" -le 200 ] || return 1
    [[ "$p" =~ ^/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]] || return 1
    IFS=/ read -r -a parts <<< "${p#/}"
    for part in "${parts[@]}"; do
        if [ "$part" = "." ] || [ "$part" = ".." ]; then
            return 1
        fi
    done
    return 0
}

# franken_valid_service_user NAME - lowercase account name, max 32 characters.
# "root" is refused: it would bypass the installer's non-root guard.
franken_valid_service_user() {
    local LC_ALL=C   # byte-wise character classes, not locale ranges
    [ "$1" = "root" ] && return 1
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

# franken_gpu_groups [GETENT_CMD] - comma list of the video and render groups
# that exist on this server (confirmed with getent), empty when neither does.
franken_gpu_groups() {
    local getent_cmd="${1:-getent}" g list=""
    for g in video render; do
        if "$getent_cmd" group "$g" > /dev/null 2>&1; then
            list="${list:+$list,}$g"
        fi
    done
    printf '%s' "$list"
}

# franken_ready_url BIND PORT - Ollama readiness URL for the warmup service.
# A valid specific BIND address is used; empty, 0.0.0.0 or invalid -> localhost.
franken_ready_url() {
    local host="localhost"
    if [ -n "$1" ] && [ "$1" != "0.0.0.0" ] && franken_valid_bind_addr "$1"; then
        host="$1"
    fi
    printf 'http://%s:%s/api/tags' "$host" "$2"
}

# franken_model_host DEFAULT_HOST BIND - host the model scripts (bin/pull-model.sh
# and friends) use to reach Ollama. A valid specific BIND address is used; empty
# or 0.0.0.0 -> DEFAULT_HOST; invalid -> DEFAULT_HOST plus a one-line warning on
# stderr (the invalid value is never returned or echoed to a command).
franken_model_host() {
    local default_host="$1" bind="${2:-}"
    if [ -z "$bind" ] || [ "$bind" = "0.0.0.0" ]; then
        printf '%s' "$default_host"
    elif franken_valid_bind_addr "$bind"; then
        printf '%s' "$bind"
    else
        echo "WARNING: FRANKEN_BIND_ADDR is not a valid IPv4 address; using $default_host" >&2
        printf '%s' "$default_host"
    fi
}

# franken_valid_memory_max VALUE - positive integer with optional K/M/G/T, or infinity.
franken_valid_memory_max() {
    [[ "$1" =~ ^[1-9][0-9]*[KMGT]?$ || "$1" == "infinity" ]]
}

# franken_valid_tasks_max VALUE - positive integer, or infinity.
franken_valid_tasks_max() {
    [[ "$1" =~ ^[1-9][0-9]*$ || "$1" == "infinity" ]]
}

# franken_valid_ollama_version VALUE - X.Y.Z with optional -rcN (e.g. 0.33.2, 0.34.0-rc1).
franken_valid_ollama_version() {
    [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?$ ]]
}

# franken_valid_sha256 VALUE - 64 lowercase hex characters.
franken_valid_sha256() {
    local LC_ALL=C   # byte-wise character classes, not locale ranges
    [[ "$1" =~ ^[0-9a-f]{64}$ ]]
}

# franken_ollama_asset - release asset name for this machine's architecture
# (the upstream installer's own x86_64 -> amd64, aarch64/arm64 -> arm64 mapping).
franken_ollama_asset() {
    case "$(uname -m)" in
        x86_64) echo "ollama-linux-amd64.tar.zst" ;;
        aarch64|arm64) echo "ollama-linux-arm64.tar.zst" ;;
        *) return 1 ;;
    esac
}

# franken_ollama_asset_url VERSION ASSET - the one place the download URL is
# built: https only, GitHub release of the pinned version, validated pieces.
franken_ollama_asset_url() {
    local LC_ALL=C
    franken_valid_ollama_version "$1" || return 1
    [[ "$2" =~ ^ollama-linux-[a-z0-9]+\.tar\.zst$ ]] || return 1
    printf 'https://github.com/ollama/ollama/releases/download/v%s/%s\n' "$1" "$2"
}

# franken_ollama_checksum_lookup VERSION ASSET TABLE - prints the sha256 recorded
# in TABLE ("version asset sha256" per line, # comments) for exactly this version
# and asset; returns 1 when there is no valid entry.
franken_ollama_checksum_lookup() {
    local version="$1" asset="$2" table="$3" v a h rest
    [ -f "$table" ] || return 1
    while read -r v a h rest; do
        case "$v" in ''|'#'*) continue ;; esac
        if [ "$v" = "$version" ] && [ "$a" = "$asset" ] && [ -z "$rest" ] && franken_valid_sha256 "$h"; then
            printf '%s\n' "$h"
            return 0
        fi
    done < "$table"
    return 1
}

# franken_ollama_download URL OUTFILE - https only, redirects stay on https.
franken_ollama_download() {
    [[ "$1" == https://* ]] || return 1
    curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
        --max-time 1800 --output "$2" -- "$1"
}

# franken_ollama_install_verified VERSION SHA256 ASSET ROOT [PRIVILEGE_CMD...]
# Downloads the pinned release asset, verifies its sha256 BEFORE anything is
# decompressed or extracted, checks the archive member names, extracts into a
# staging directory under ROOT, validates the staged layout and version, and only
# then moves the complete lib/ollama directory and bin/ollama into place (the
# layout of the upstream installer), keeping the old ones in ROOT/.franken-ollama-undo.
# The caller ends with franken_ollama_undo_discard (success) or
# franken_ollama_undo_restore (a later failure). A failure inside this function
# restores the previous install itself. PRIVILEGE_CMD (e.g. sudo) is put in front
# of the commands that write under ROOT. No account or service is created.
# Needs curl, zstd, tar and sha256sum; says so when one is missing.
franken_ollama_install_verified() {
    local version="$1" sha="$2" asset="$3" root="$4" url tool
    shift 4
    local -a priv=("$@")
    url="$(franken_ollama_asset_url "$version" "$asset")" || { echo "❌ Invalid Ollama version or asset name"; return 1; }
    franken_valid_sha256 "$sha" || { echo "❌ The expected checksum is not a sha256 (64 lowercase hex characters)"; return 1; }
    if ! [[ "$root" =~ ^/[A-Za-z0-9/_.-]+$ ]] || [ "$root" = "/" ]; then
        echo "❌ Invalid install root"
        return 1
    fi
    for tool in curl tar sha256sum; do
        command -v "$tool" > /dev/null 2>&1 || { echo "❌ $tool is required to install Ollama but was not found"; return 1; }
    done
    if ! command -v zstd > /dev/null 2>&1; then
        echo "❌ zstd is required to unpack the Ollama release but was not found."
        echo "   Install it first (Debian/Ubuntu: sudo apt-get install zstd; Fedora/RHEL: sudo dnf install zstd)."
        return 1
    fi
    local work undo stage staged_version i
    local -a names=(lib bin) targets staged
    work="$(mktemp -d)" || return 1
    if ! franken_ollama__fetch_verify "$url" "$asset" "$sha" "$work"; then
        rm -rf -- "${work:?}"
        return 1
    fi
    # Extract into a staging directory under ROOT (same filesystem, so the final
    # moves are renames). The live install is not touched until the staged tree
    # has been validated; the old files are moved aside, not deleted.
    undo="$root/.franken-ollama-undo"
    stage="$undo/stage"
    ${priv[@]+"${priv[@]}"} rm -rf -- "$undo" || { rm -rf -- "${work:?}"; return 1; }
    if ! ${priv[@]+"${priv[@]}"} install -d -m 0755 "$undo" "$stage" "$undo/backup" "$root/bin" "$root/lib"; then
        rm -rf -- "${work:?}"
        franken_ollama_undo_restore "$root" ${priv[@]+"${priv[@]}"} > /dev/null
        return 1
    fi
    if ! ${priv[@]+"${priv[@]}"} tar -xf "$work/ollama.tar" -C "$stage" --no-same-owner; then
        echo "❌ Extraction failed; the previous Ollama install was not touched"
        rm -rf -- "${work:?}"
        franken_ollama_undo_restore "$root" ${priv[@]+"${priv[@]}"} > /dev/null
        return 1
    fi
    rm -rf -- "${work:?}"
    staged_version=""
    if ${priv[@]+"${priv[@]}"} test -x "$stage/bin/ollama" && ${priv[@]+"${priv[@]}"} test -d "$stage/lib/ollama"; then
        staged_version="$(franken_ollama__staged_version "$stage")"
    fi
    if [ "$staged_version" != "$version" ]; then
        echo "❌ The staged release does not have the expected layout or version (wanted $version, got '${staged_version:-none}'); the previous install was not touched"
        franken_ollama_undo_restore "$root" ${priv[@]+"${priv[@]}"} > /dev/null
        return 1
    fi
    # Swap complete directories and files into place, keeping the old ones.
    targets=("$root/lib/ollama" "$root/bin/ollama")
    staged=("$stage/lib/ollama" "$stage/bin/ollama")
    for i in 0 1; do
        if ${priv[@]+"${priv[@]}"} test -e "${targets[$i]}" || ${priv[@]+"${priv[@]}"} test -L "${targets[$i]}"; then
            ${priv[@]+"${priv[@]}"} mv -- "${targets[$i]}" "$undo/backup/${names[$i]}" || { echo "❌ Could not move the old ${names[$i]} aside"; franken_ollama_undo_restore "$root" ${priv[@]+"${priv[@]}"}; return 1; }
        fi
        ${priv[@]+"${priv[@]}"} touch "$undo/new-${names[$i]}" || { franken_ollama_undo_restore "$root" ${priv[@]+"${priv[@]}"}; return 1; }
        ${priv[@]+"${priv[@]}"} mv -- "${staged[$i]}" "${targets[$i]}" || { echo "❌ Could not move the new ${names[$i]} into place"; franken_ollama_undo_restore "$root" ${priv[@]+"${priv[@]}"}; return 1; }
    done
    echo "✅ Ollama $version staged, validated and moved into place (previous files kept until the install finishes)"
    return 0
}

# franken_ollama__staged_version STAGE_DIR - version the staged binary reports (a seam
# the tests override; the binary is the checksum-verified one).
franken_ollama__staged_version() {
    franken_ollama_parse_version "$("$1/bin/ollama" --version 2>&1 || true)"
}

# franken_ollama__fetch_verify URL ASSET SHA WORKDIR - download, check the sha256,
# decompress and check the member names into WORKDIR/ollama.tar. Touches nothing else.
franken_ollama__fetch_verify() (
    url="$1" asset="$2" sha="$3" work="$4"
    echo "Downloading $url"
    franken_ollama_download "$url" "$work/$asset" || { echo "❌ Download failed"; exit 1; }
    actual="$(franken_sha256_file "$work/$asset")"
    if [ "$actual" != "$sha" ]; then
        echo "❌ Checksum mismatch for $asset: expected $sha, got $actual. Nothing was extracted."
        exit 1
    fi
    echo "✅ sha256 verified for $asset"
    zstd -d -q -c -- "$work/$asset" > "$work/ollama.tar" || { echo "❌ Could not decompress the archive"; exit 1; }
    # Member names must stay under the root; links must not point outside; no devices.
    members="$(tar -tf "$work/ollama.tar")" || { echo "❌ Could not read the archive"; exit 1; }
    if grep -qE '(^/|(^|/)\.\.(/|$))' <<< "$members"; then
        echo "❌ The archive has absolute or parent-directory member names; refusing to extract"
        exit 1
    fi
    if tar -tvf "$work/ollama.tar" | grep -E -q '^[cbp]|( -> | link to )(/|(.*/)?\.\.(/|$))'; then
        echo "❌ The archive has device nodes or links leaving the install root; refusing to extract"
        exit 1
    fi
)

# franken_ollama_undo_restore ROOT [PRIVILEGE_CMD...] - put the previous Ollama
# files back after a failed or abandoned replacement and remove the staging area.
# Idempotent; does nothing when there is nothing to undo. Returns 1 if any step fails.
franken_ollama_undo_restore() {
    local root="$1" undo rc=0 i
    shift
    local -a priv=("$@") names=(lib bin) targets
    undo="$root/.franken-ollama-undo"
    ${priv[@]+"${priv[@]}"} test -d "$undo" || return 0
    targets=("$root/lib/ollama" "$root/bin/ollama")
    for i in 0 1; do
        # the new item was moved into place: remove it
        if ${priv[@]+"${priv[@]}"} test -e "$undo/new-${names[$i]}" \
            && ! ${priv[@]+"${priv[@]}"} test -e "$undo/stage/${targets[$i]#"$root/"}"; then
            ${priv[@]+"${priv[@]}"} rm -rf -- "${targets[$i]}" || rc=1
        fi
        if ${priv[@]+"${priv[@]}"} test -e "$undo/backup/${names[$i]}" \
            && ! ${priv[@]+"${priv[@]}"} test -e "${targets[$i]}"; then
            ${priv[@]+"${priv[@]}"} mv -- "$undo/backup/${names[$i]}" "${targets[$i]}" || rc=1
        fi
    done
    if [ "$rc" -eq 0 ]; then
        ${priv[@]+"${priv[@]}"} rm -rf -- "$undo" || rc=1
    fi
    return "$rc"
}

# franken_ollama_undo_discard ROOT [PRIVILEGE_CMD...] - the install succeeded:
# drop the backups and the staging area.
franken_ollama_undo_discard() {
    local root="$1"
    shift
    ${@+"$@"} rm -rf -- "$root/.franken-ollama-undo"
}

# franken_ollama_unverified_install [VERSION] - the old behavior, only for an
# explicit FRANKEN_ALLOW_UNVERIFIED_OLLAMA=true: runs the upstream install script
# WITHOUT any integrity check. The script is downloaded to a private file first
# (never piped into a shell); that is not authentication.
franken_ollama_unverified_install() {
    local version="${1:-}" work rc
    if [ -n "$version" ] && ! franken_valid_ollama_version "$version"; then
        return 1
    fi
    echo "⚠️  ⚠️  ⚠️  UNVERIFIED OLLAMA INSTALL (FRANKEN_ALLOW_UNVERIFIED_OLLAMA=true)"
    echo "⚠️  The upstream install script is downloaded and run as is: nothing checks it."
    echo "⚠️  Set FRANKEN_OLLAMA_VERSION plus a checksum for a verified install."
    work="$(mktemp -d)" || return 1
    franken_ollama_download "https://ollama.com/install.sh" "$work/ollama-install.sh" || { rm -rf -- "$work"; return 1; }
    if [ -n "$version" ]; then
        OLLAMA_VERSION="$version" sh "$work/ollama-install.sh"
    else
        sh "$work/ollama-install.sh"
    fi
    rc=$?
    rm -rf -- "$work"
    return $rc
}

# franken_ollama_parse_version TEXT - first X.Y.Z[-rcN] in `ollama --version`
# output (which may carry warning lines); empty when none.
franken_ollama_parse_version() {
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+(-rc[0-9]+)?' <<< "$1" | head -n 1 || true
}

# franken_valid_require_gpu VALUE - exactly true or false (callers treat empty as false).
franken_valid_require_gpu() {
    [ "$1" = "true" ] || [ "$1" = "false" ]
}

# franken_valid_nvidia_smi_path PATH - absolute path, safe characters only
# (no whitespace, quotes, %, $ or shell/systemd specials).
franken_valid_nvidia_smi_path() {
    [[ "$1" =~ ^/[A-Za-z0-9/_.-]+$ ]]
}

# franken_render_unit GPU PORT MODELS_DIR USER BIND MEMORY_MAX TASKS_MAX [REQUIRE_GPU NVIDIA_SMI]
# Prints the unit text. Empty BIND means all interfaces (0.0.0.0); empty
# MEMORY_MAX / TASKS_MAX write no limit line. REQUIRE_GPU=true adds
# ExecStartPre=<NVIDIA_SMI> -L before ExecStart, so the unit fails (and
# restarts, Restart=always) when no GPU is visible instead of running on the
# CPU; true with an invalid NVIDIA_SMI path prints nothing and returns 1.
# Any other REQUIRE_GPU value renders the default unit. Callers validate first.
franken_render_unit() {
    local gpu="$1" port="$2" models="$3" user="$4" bind="${5:-0.0.0.0}" mem="$6" tasks="$7"
    local require_gpu="${8:-}" smi="${9:-}"
    if [ "$require_gpu" = "true" ] && ! franken_valid_nvidia_smi_path "$smi"; then
        return 1
    fi
    cat << UNIT
[Unit]
Description=Ollama Service for GPU $gpu
After=network-online.target

[Service]
Type=simple
User=$user
Environment="CUDA_VISIBLE_DEVICES=$gpu"
Environment="OLLAMA_HOST=$bind:$port"
Environment="OLLAMA_MODELS=$models"
Environment="OLLAMA_KEEP_ALIVE=-1"
UNIT
    [ "$require_gpu" = "true" ] && printf 'ExecStartPre=%s -L\n' "$smi"
    cat << UNIT
ExecStart=/usr/local/bin/ollama serve
Restart=always
RestartSec=3
UNIT
    [ -n "$mem" ] && printf 'MemoryMax=%s\n' "$mem"
    [ -n "$tasks" ] && printf 'TasksMax=%s\n' "$tasks"
    cat << UNIT

[Install]
WantedBy=default.target
UNIT
    return 0
}

# franken_valid_ssh_host VALUE - [user@]host as ssh accepts it, conservative
# characters, never starting with "-" (so it cannot become an ssh option).
franken_valid_ssh_host() {
    local LC_ALL=C   # byte-wise character classes, not locale ranges
    [[ "$1" =~ ^([A-Za-z0-9._-]+@)?[A-Za-z0-9][A-Za-z0-9._:-]*$ ]] && [ "${#1}" -le 255 ]
}

# franken_sha256_file FILE - hex sha256 of FILE (sha256sum, else shasum).
franken_sha256_file() {
    if command -v sha256sum > /dev/null 2>&1; then
        sha256sum -- "$1" | cut -d' ' -f1
    else
        shasum -a 256 -- "$1" | cut -d' ' -f1
    fi
}

# franken_render_warmup_unit DIR USER - prints the warmup unit. Revalidates both
# values (install dir policy, service account name) and prints nothing, return 1,
# when either is unsafe: no newline or other directive can reach the unit.
franken_render_warmup_unit() {
    local dir="$1" user="$2"
    franken_valid_install_dir "$dir" || return 1
    [[ "$user" =~ ^[A-Za-z_][A-Za-z0-9_.-]{0,63}$ ]] || return 1
    cat << UNIT
[Unit]
Description=FrankenLLM Model Warmup
After=ollama-gpu0.service ollama-gpu1.service
Wants=ollama-gpu0.service ollama-gpu1.service

[Service]
Type=oneshot
User=$user
WorkingDirectory=$dir
ExecStart=$dir/bin/warmup-on-boot.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
UNIT
}

# franken_check_service_account NAME UID SHELL HOME GROUPS - policy for an
# EXISTING account that FRANKEN_SERVICE_USER names (the units will run as it and
# it gets GPU group membership). Returns 0 when it is a dedicated system account:
# uid 1..999, a nologin shell, a home under /var/lib, and no supplementary groups
# beyond its own group, video and render. Otherwise prints the reason and returns 1.
franken_check_service_account() {
    local LC_ALL=C
    local name="$1" uid="$2" shell="$3" home="$4" groups="$5" g part
    local -a parts
    if ! [[ "$uid" =~ ^[0-9]+$ ]] || [ "$uid" -lt 1 ] || [ "$uid" -gt 999 ]; then
        echo "Account $name is not a system account (uid '$uid'; need 1-999)"
        return 1
    fi
    case "$shell" in
        /usr/sbin/nologin|/sbin/nologin|/usr/bin/nologin|/bin/false|/usr/bin/false) ;;
        *) echo "Account $name has a login shell ('$shell'); need nologin"; return 1 ;;
    esac
    if ! [[ "$home" =~ ^/var/lib/[A-Za-z0-9._-]+(/[A-Za-z0-9._-]+)*$ ]]; then
        echo "Account $name has home '$home'; need a directory under /var/lib"
        return 1
    fi
    IFS=/ read -r -a parts <<< "${home#/}"
    for part in "${parts[@]}"; do
        if [ "$part" = ".." ] || [ "$part" = "." ]; then
            echo "Account $name has an unnormalized home '$home'"
            return 1
        fi
    done
    for g in $groups; do
        case "$g" in
            "$name"|video|render) ;;
            *) echo "Account $name is in the group '$g'; only its own group, video and render are allowed"; return 1 ;;
        esac
    done
    return 0
}

# franken_wait_unit_ready UNIT URL TRIES - 0 once UNIT is active AND URL answers
# (curl is required; without it this fails); polls up to TRIES times, 2 s apart.
franken_wait_unit_ready() {
    local unit="$1" url="$2" tries="$3" i
    # No curl means no proof the service answers: that is a failure, never a pass.
    command -v curl > /dev/null 2>&1 || return 1
    for ((i = 0; i < tries; i++)); do
        if systemctl is-active --quiet "$unit" \
            && curl --fail --silent --max-time 3 --output /dev/null -- "$url"; then
            return 0
        fi
        if [ "$i" -lt $((tries - 1)) ]; then sleep 2; fi
    done
    return 1
}
