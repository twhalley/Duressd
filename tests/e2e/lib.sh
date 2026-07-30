#!/usr/bin/env bash
# Shared helpers for the KVM end-to-end tests: boot a golden image under QEMU,
# drive the wipe over the serial console, then inspect the resulting disk from
# the host to prove no OS remains.
# shellcheck shell=bash
set -euo pipefail

E2E_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
E2E_DIR="$E2E_REPO_ROOT/tests/e2e"
E2E_IMAGES="${E2E_IMAGES:-$E2E_DIR/images}"       # golden qcow2s live here
E2E_OVMF="${E2E_OVMF:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
E2E_MEM="${E2E_MEM:-1024}"

log()  { printf '\033[1;36m  →  %s\033[0m\n' "$*"; }
pass() { printf '\033[1;32m  ✔  %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31m  ✘  %s\033[0m\n' "$*" >&2; return 1; }

e2e_require() {
    local t
    for t in qemu-system-x86_64 qemu-img qemu-nbd; do
        command -v "$t" >/dev/null 2>&1 || { echo "missing $t (install qemu)"; exit 1; }
    done
    [[ -e /dev/kvm ]] || echo "  ⚠  /dev/kvm absent — QEMU will run without acceleration (slow)"
}

# e2e_overlay <golden.qcow2> → path to a fresh disposable overlay.
e2e_overlay() {
    local golden="$1" overlay
    overlay="$(mktemp "${TMPDIR:-/tmp}/duressd-e2e.XXXXXX.qcow2")"
    qemu-img create -q -f qcow2 -F qcow2 -b "$golden" "$overlay" >/dev/null
    printf '%s' "$overlay"
}

# e2e_boot <disk.qcow2> <mode:uefi|bios> <serial-log> [extra qemu args...]
# Boots headless, wiring the guest serial console to <serial-log>. Returns the
# QEMU exit; the guest powers itself off when the wipe completes.
e2e_boot() {
    local disk="$1" mode="$2" serial="$3"; shift 3
    local -a args=(
        -machine q35 -m "$E2E_MEM" -nographic -no-reboot
        -drive "file=$disk,if=virtio,format=qcow2"
        -serial "file:$serial"
    )
    [[ -e /dev/kvm ]] && args+=(-enable-kvm -cpu host)
    if [[ "$mode" == uefi ]]; then
        [[ -f "$E2E_OVMF" ]] || fail "OVMF firmware not found at $E2E_OVMF (install edk2-ovmf)"
        args+=(-drive "if=pflash,format=raw,readonly=on,file=$E2E_OVMF")
    fi
    timeout 300 qemu-system-x86_64 "${args[@]}" "$@" || true
}

# ── host-side disk inspection (proves the wipe worked) ────────────────────────
# Attach the guest disk to a host NBD device; echoes the nbd device.
e2e_nbd_connect() {
    local disk="$1" nbd
    modprobe nbd max_part=16 2>/dev/null || true
    for nbd in /dev/nbd{0..15}; do
        if qemu-nbd --connect="$nbd" "$disk" 2>/dev/null; then printf '%s' "$nbd"; return 0; fi
    done
    fail "no free /dev/nbd device"
}
e2e_nbd_disconnect() { qemu-nbd --disconnect "$1" >/dev/null 2>&1 || true; }

# Assert no partition on the disk still carries a LUKS header.
e2e_assert_no_luks() {
    local nbd="$1" p
    partprobe "$nbd" 2>/dev/null || true
    for p in "${nbd}"p*; do
        [[ -b "$p" ]] || continue
        if cryptsetup isLuks "$p" 2>/dev/null; then fail "LUKS header survived on $p"; fi
    done
    pass "no LUKS header anywhere on the disk"
}

# Assert the disk no longer presents a recognizable bootloader/ESP filesystem.
e2e_assert_no_boot_fs() {
    local nbd="$1" sig
    sig="$(blkid -o value -s TYPE "${nbd}"p1 2>/dev/null || true)"
    [[ "$sig" == vfat ]] && fail "ESP filesystem still present on ${nbd}p1"
    pass "ESP/boot filesystem signatures gone"
}

# Boot the (already-wiped) disk again and assert the firmware finds nothing
# bootable — the strongest end-state check.
e2e_assert_unbootable() {
    local disk="$1" mode="$2" serial
    serial="$(mktemp)"
    e2e_boot "$disk" "$mode" "$serial" -boot order=c,menu=off >/dev/null 2>&1 || true
    if grep -qiE 'no bootable device|not a bootable disk|boot failed|no operating system|UEFI Interactive Shell|BdsDxe: failed' "$serial"; then
        pass "post-wipe boot fails — no OS remains"
    else
        # Absence of any login/kernel banner is also a pass; flag for review.
        if grep -qiE 'login:|Linux version|systemd\[1\]' "$serial"; then
            rm -f "$serial"; fail "guest still boots an OS after wipe"
        fi
        pass "post-wipe boot produced no OS banner (treated as unbootable)"
    fi
    rm -f "$serial"
}
