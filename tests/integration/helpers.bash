# Integration-test helpers: real loopback LUKS containers, wiped by the real
# handler functions. A hard safety guard makes it impossible to target anything
# but a loop device backed by a file inside this run's temp workdir.
# shellcheck shell=bash
# shellcheck disable=SC2154  # $output/$status are injected by the bats `run` builtin

INT_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export INT_REPO_ROOT

# Fast KDF for test LUKS containers (argon2id defaults are deliberately slow).
# shellcheck disable=SC2034  # consumed by the .bats files that source this lib
LUKS_FAST=(--type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --batch-mode)

int_setup() {
    [[ $EUID -eq 0 ]] || { echo "integration tests must run as root" >&2; exit 1; }
    INT_WORKDIR="$(mktemp -d /var/tmp/duressd-int.XXXXXX)"
    INT_LOOPS=()
    # Load the real wipe functions (no _is_block override — we want real checks).
    DURESSD_LIB_ONLY=1 source "$INT_REPO_ROOT/src/handler"
}

int_teardown() {
    local d
    for d in "${INT_LOOPS[@]:-}"; do
        [[ -n "$d" ]] || continue
        losetup -d "$d" 2>/dev/null || true
    done
    [[ -n "${INT_WORKDIR:-}" ]] && rm -rf "$INT_WORKDIR"
}

# new_loop <size_MiB> [--partscan]  → echoes the loop device path.
new_loop() {
    local size_mib="$1"; shift || true
    local f; f="$(mktemp "$INT_WORKDIR/backing.XXXXXX.img")"
    truncate -s "${size_mib}M" "$f"
    local loop
    loop="$(losetup --find --show "$@" "$f")"
    INT_LOOPS+=("$loop")
    printf '%s' "$loop"
}

_loop_base() { local d="${1#/dev/}"; d="${d%%p[0-9]*}"; printf '/dev/%s' "$d"; }

# SAFETY RAIL — abort unless every target is a loop device whose backing file
# lives under this run's workdir. Called before any destructive helper runs.
assert_safe_targets() {
    local dev base back
    for dev in "$@"; do
        case "$dev" in
            /dev/loop[0-9]*) ;;
            *) echo "REFUSING destructive op: '$dev' is not a loop device" >&2; return 1 ;;
        esac
        base="$(_loop_base "$dev")"
        # Prefer sysfs (reliable everywhere); fall back to losetup --list.
        back="$(cat "/sys/block/${base#/dev/}/loop/backing_file" 2>/dev/null \
                || losetup -ln -O BACK-FILE "$base" 2>/dev/null || true)"
        if [[ -z "$back" || "$back" != "$INT_WORKDIR"/* ]]; then
            echo "REFUSING destructive op: '$dev' backing '$back' is not under $INT_WORKDIR" >&2
            return 1
        fi
    done
    return 0
}

# Assert a device no longer carries a LUKS header.
refute_is_luks() { ! cryptsetup isLuks "$1" 2>/dev/null; }
# Assert a device still carries a LUKS header (sanity before wiping).
assert_is_luks() { cryptsetup isLuks "$1" 2>/dev/null; }

assert_output_contains() {
    [[ "$output" == *"$1"* ]] || { echo "expected output to contain: $1"; echo "$output"; return 1; }
}
refute_output_contains() {
    [[ "$output" != *"$1"* ]] || { echo "expected output NOT to contain: $1"; echo "$output"; return 1; }
}
