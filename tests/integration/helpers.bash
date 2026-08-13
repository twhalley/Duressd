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

# Base loop device for a partition path: /dev/loop1p3 → /dev/loop1, /dev/loop1 →
# /dev/loop1. NB: a naive %%p[0-9]* is wrong — "loop1" itself contains "p1".
_loop_base() {
    if [[ "$1" =~ ^(/dev/loop[0-9]+)p[0-9]+$ ]]; then
        printf '%s' "${BASH_REMATCH[1]}"
    else
        printf '%s' "$1"
    fi
}

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

# Wait until lsblk actually reports a PARTTYPE for a freshly-created partition.
# The udev/blkid database is populated ASYNCHRONOUSLY after losetup -P / mkfs, and
# wipe_boot_artifacts keys ESP detection off the PARTTYPE column (handler:383).
# `udevadm settle` alone is not enough: it drains the *queued* events, but the
# event for a just-appeared partition may not be queued yet — so we poll the exact
# column the handler reads, re-triggering udev each round. Best-effort: return
# after the deadline regardless so a stuck udevd can't hang the whole suite (the
# test's own assertion then reports the real failure).
# Usage: wait_for_parttype <dev> [expected-guid]
wait_for_parttype() {
    local dev="$1" want="${2:-}" i cur
    for i in $(seq 1 100); do
        udevadm trigger --settle "$dev" 2>/dev/null \
            || udevadm settle 2>/dev/null || true
        cur="$(lsblk -ndo PARTTYPE "$dev" 2>/dev/null || true)"
        if [[ -n "$want" ]]; then
            [[ "${cur,,}" == "${want,,}" ]] && return 0
        else
            [[ -n "$cur" ]] && return 0
        fi
        sleep 0.1
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
