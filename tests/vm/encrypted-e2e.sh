#!/usr/bin/env bash
# Full-stack ENCRYPTED-DISK wipe — end to end, entirely inside the VM.
#
# Builds a realistic disk on a loopback file:
#     GPT  ->  ESP (vfat)  +  /boot (ext4)  +  LUKS2 root (ext4 fs w/ a secret)
# writes a plaintext sentinel to the unencrypted ESP and a secret inside the
# encrypted root, then fires a REAL duressd trigger with crypto + boot-artifact
# + full-device wipe SCOPED to that disk, and proves everything is destroyed:
#   * the LUKS header is gone and can no longer be opened with the passphrase,
#   * the ESP/boot filesystems and the GPT table are gone,
#   * the plaintext ESP sentinel is not recoverable from the raw device.
#
# Safe by construction: the ONLY wipe target is the loopback device (enforced by
# DURESSD_TARGET_DEVICES) and poweroff is suppressed. Run inside the VM as root.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "run as root inside the VM" >&2; exit 1; }
REPO="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$REPO"
hr() { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
pass() { printf '  \033[1;32m✔  %s\033[0m\n' "$*"; }
fail() { printf '  \033[1;31m✘  FAIL: %s\033[0m\n' "$*"; exit 1; }

for t in cryptsetup losetup sfdisk mkfs.vfat mkfs.ext4 blkid; do
    command -v "$t" >/dev/null || { echo "missing tool: $t" >&2; exit 1; }
done

WORK="$(mktemp -d)"; LOOP=""; DPID=""; MAP=""
cleanup() {
    set +e
    [[ -n "$DPID" ]] && kill "$DPID" 2>/dev/null
    mountpoint -q "$WORK/mnt" && umount "$WORK/mnt"
    [[ -n "$MAP" ]] && cryptsetup close "$MAP" 2>/dev/null
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

ESP_GUID=C12A7328-F81F-11D2-BA4B-00A0C93EC93B
LINUX_GUID=0FC63DAF-8483-4772-8E79-3D69D8477DE4
DPASS=wipe-now
ESP_SENTINEL="ESP-PLAINTEXT-$(openssl rand -hex 8)"
LUKS_SECRET="LUKS-SECRET-$(openssl rand -hex 8)"

hr "building an encrypted disk (GPT: ESP + ext4 /boot + LUKS2 root)"
truncate -s 320M "$WORK/disk.img"
sfdisk --quiet "$WORK/disk.img" <<SF
label: gpt
size=48M, type=$ESP_GUID,   name=EFI
size=64M, type=$LINUX_GUID, name=boot
type=$LINUX_GUID, name=root
SF
LOOP="$(losetup -Pf --show "$WORK/disk.img")"
ESP="${LOOP}p1"; BOOT="${LOOP}p2"; ROOT="${LOOP}p3"
udevadm settle 2>/dev/null || sleep 0.5

mkfs.vfat -F32 "$ESP" >/dev/null
mkfs.ext4 -qF "$BOOT"
# plaintext sentinel on the UNENCRYPTED ESP — must be unrecoverable after wipe
mkdir -p "$WORK/mnt"; mount "$ESP" "$WORK/mnt"
printf '%s\n' "$ESP_SENTINEL" > "$WORK/mnt/loader.conf"; sync; umount "$WORK/mnt"

printf '%s' "$DPASS" | cryptsetup luksFormat --type luks2 --batch-mode \
    --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file=- "$ROOT"
MAP=e2e_root
printf '%s' "$DPASS" | cryptsetup open --key-file=- "$ROOT" "$MAP"
mkfs.ext4 -qF "/dev/mapper/$MAP"
mount "/dev/mapper/$MAP" "$WORK/mnt"
printf '%s\n' "$LUKS_SECRET" > "$WORK/mnt/secret.txt"; sync
umount "$WORK/mnt"; cryptsetup close "$MAP"; MAP=""

# ── before-state sanity ───────────────────────────────────────────────────────
cryptsetup isLuks "$ROOT"                       || fail "LUKS not present pre-wipe"
printf '%s' "$DPASS" | cryptsetup open --test-passphrase --key-file=- "$ROOT" \
                                                || fail "LUKS won't open pre-wipe"
blkid "$ESP"  | grep -q 'TYPE="vfat"'           || fail "ESP vfat not present pre-wipe"
blkid "$BOOT" | grep -q 'TYPE="ext4"'           || fail "/boot ext4 not present pre-wipe"
grep -aq "$ESP_SENTINEL" "$WORK/disk.img"       || fail "ESP sentinel not on disk pre-wipe"
pass "encrypted disk built: LUKS root + ESP + /boot, secrets written"

hr "configuring duressd (crypto + boot-artifacts + full-device) and firing a REAL trigger"
export DURESSD_RUNDIR="$WORK/run" DURESSD_CFGDIR="$WORK/cfg" \
       DURESSD_LIBDIR="$REPO/src" DURESSD_SOCKET="$WORK/run/control.sock" \
       DURESSD_NO_POWEROFF=1 DURESSD_TARGET_DEVICES="$LOOP $ESP $BOOT $ROOT"
mkdir -p "$DURESSD_RUNDIR" "$DURESSD_CFGDIR"

# custom-passphrase oracle (Argon2id keyslot) + config with every phase on
dd if=/dev/zero of="$DURESSD_CFGDIR/passphrase.luks" bs=1M count=8 status=none
printf '%s' "$DPASS" | cryptsetup luksFormat --type luks2 --batch-mode \
    --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file=- "$DURESSD_CFGDIR/passphrase.luks"
cat > "$DURESSD_CFGDIR/config" <<CFG
CONFIGURED=true
PASSWORD_TYPE=custom
VERIFY_DEVICE=
OVERWRITE_LUKS_HEADER=false
WIPE_FULL_DEVICE=true
WIPE_BOOT_ARTIFACTS=true
WIPE_HARDWARE_KEYS=false
WIPE_COUNTDOWN=0
CFG

bash src/daemon & DPID=$!
sleep 1
echo "  triggering wipe via the real daemon (scoped to $LOOP)…"
DURESSD_PASS="$DPASS" bash src/cli trigger-remote </dev/null || true
sleep 1

hr "verifying the disk is destroyed"
! cryptsetup isLuks "$ROOT" 2>/dev/null \
    || fail "LUKS header survived on $ROOT"
pass "LUKS header destroyed (isLuks fails)"

! printf '%s' "$DPASS" | cryptsetup open --test-passphrase --key-file=- "$ROOT" 2>/dev/null \
    || fail "LUKS can still be opened — keyslots survived"
pass "LUKS can no longer be opened with the passphrase (keyslots gone → data unrecoverable)"

! blkid "$ESP"  2>/dev/null | grep -q 'TYPE="vfat"' || fail "ESP vfat signature survived"
! blkid "$BOOT" 2>/dev/null | grep -q 'TYPE="ext4"' || fail "/boot ext4 signature survived"
pass "ESP and /boot filesystem signatures destroyed"

! blkid "$WORK/disk.img" 2>/dev/null | grep -q 'PTTYPE="gpt"' || fail "GPT partition table survived"
pass "GPT partition table destroyed"

! grep -aq "$ESP_SENTINEL" "$WORK/disk.img" || fail "plaintext ESP sentinel still recoverable from raw disk"
pass "plaintext boot data is unrecoverable from the raw device"

hr "ENCRYPTED-DISK END-TO-END WIPE PASSED — full disk, all phases, real trigger"
