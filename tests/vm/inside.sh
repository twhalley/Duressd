#!/usr/bin/env bash
# Run this INSIDE a disposable Arch VM (e.g. the Arch live ISO booted by
# tests/vm/launch.sh). It exercises the whole duressd suite AND performs a real
# wipe of a scratch encrypted disk through the actual daemon + CLI — with zero
# risk to any real machine, because everything here happens inside the VM.
#
#   bash tests/vm/inside.sh
#
# Steps: install deps -> lint -> unit -> loop-device integration -> a full-stack
# trigger that wipes a scratch LUKS disk via the real socket protocol.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root inside the VM" >&2; exit 1; }
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$REPO"

hr() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }

hr "installing test dependencies (pacman)"
pacman -Sy --needed --noconfirm \
    bats shellcheck cryptsetup util-linux socat openssl coreutils dosfstools >/dev/null
echo "  ✔  deps ready"

hr "tier 0 — lint"
make lint

hr "tier 1 — unit tests"
make unit

hr "tier 2 — loop-device integration (real LUKS destroyed on loopback)"
make integration

hr "full-stack trigger — real daemon wipes a scratch encrypted disk"
WORK="$(mktemp -d)"
LOOP=""; DPID=""
cleanup_demo() {
    set +e
    [[ -n "$DPID" ]] && kill "$DPID" 2>/dev/null
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup_demo EXIT

# scratch encrypted disk (the ONLY wipe target, via DURESSD_TARGET_DEVICES)
truncate -s 48M "$WORK/scratch.img"
LOOP="$(losetup -Pf --show "$WORK/scratch.img")"
printf 'diskpass' | cryptsetup luksFormat --type luks2 --batch-mode \
    --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file=- "$LOOP"
cryptsetup isLuks "$LOOP" && echo "  scratch disk carries a LUKS header: yes"

# point duressd at a temp state dir, scope the wipe to the scratch disk only,
# and suppress poweroff so the VM survives for the assertion.
export DURESSD_RUNDIR="$WORK/run" DURESSD_CFGDIR="$WORK/cfg" \
       DURESSD_LIBDIR="$REPO/src" DURESSD_SOCKET="$WORK/run/control.sock" \
       DURESSD_TARGET_DEVICES="$LOOP" DURESSD_NO_POWEROFF=1
mkdir -p "$DURESSD_RUNDIR" "$DURESSD_CFGDIR"

# pre-seed a custom duress passphrase (Argon2id keyslot oracle) + config
dd if=/dev/zero of="$DURESSD_CFGDIR/passphrase.luks" bs=1M count=8 status=none
printf 'wipe-now' | cryptsetup luksFormat --type luks2 --batch-mode \
    --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file=- "$DURESSD_CFGDIR/passphrase.luks"
cat > "$DURESSD_CFGDIR/config" <<CFG
CONFIGURED=true
PASSWORD_TYPE=custom
VERIFY_DEVICE=
OVERWRITE_LUKS_HEADER=false
WIPE_FULL_DEVICE=false
WIPE_BOOT_ARTIFACTS=false
WIPE_HARDWARE_KEYS=false
WIPE_COUNTDOWN=0
CFG

# start the real daemon and fire the wipe over the socket, exactly like SSH would
bash src/daemon & DPID=$!
sleep 1
echo "  triggering wipe via the real daemon (scoped to $LOOP)…"
DURESSD_PASS=wipe-now bash src/cli trigger-remote </dev/null || true

if cryptsetup isLuks "$LOOP" 2>/dev/null; then
    echo -e "  \033[1;31m✘  FAIL: scratch disk still carries a LUKS header\033[0m"
    exit 1
fi
echo -e "  \033[1;32m✔  PASS: duressd destroyed the scratch disk's LUKS header\033[0m"

hr "all tiers passed — inside a disposable VM, host untouched"
