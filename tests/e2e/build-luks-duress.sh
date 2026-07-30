#!/usr/bin/env bash
# Build a golden, bootable, LUKS-encrypted image that PROMPTS for the passphrase
# at boot and has the duressd LUKS-at-boot hook installed — so the boot test can
# enter a DURESS passphrase at the unlock prompt and prove it wipes + won't boot.
#
#   sudo bash tests/e2e/build-luks-duress.sh        # -> tests/e2e/images/luks-duress.qcow2
#
# HOST ISOLATION: everything here operates ONLY on a loopback file under
# tests/e2e/images/ (git-ignored). It NEVER partitions, formats, or mounts any
# real disk. It uses a PRIVATE temp mountpoint (not /mnt) and a unique dm-crypt
# mapping name. The trap force-unwinds the mount (lazy fallback), mapping and
# loop device on ANY exit — including SIGINT/SIGTERM — so an interrupted or
# failed build never leaves the host with a stray mount/mapping/loop.
# The pacman package cache is redirected to a temp dir under $WORK, so the host's
# /var/cache/pacman is never written either. Result: zero persistent host trace.
#
# Set E2E_WORKDIR to place the scratch build state (image, pkg cache, mountpoint)
# on a specific filesystem — used by the in-VM runner to keep it off a RAM-backed
# live root. Defaults to /tmp.
#
# Two distinct passphrases:
#   LUKS_PASS   (default e2e-luks) unlocks the disk normally
#   DURESS_PASS (default wipe-now) triggers the wipe at the unlock prompt
#
# REQUIRES an Arch host with root, loop devices, pacstrap, and edk2-ovmf.
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "must run as root: sudo bash tests/e2e/build-luks-duress.sh" >&2; exit 1; }
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTDIR="${E2E_IMAGES:-$REPO_ROOT/tests/e2e/images}"
mkdir -p "$OUTDIR"
RAW="$(mktemp "$OUTDIR/luks-duress.raw.XXXXXX")"
GOLDEN="$OUTDIR/luks-duress.qcow2"
LUKS_PASS="${E2E_LUKS_PASS:-e2e-luks}"
DURESS_PASS="${E2E_DURESS_PASS:-wipe-now}"

# Private, unique names so we never touch host /mnt or a host mapping. All
# scratch state lives under $WORK (honours E2E_WORKDIR) so it can be steered onto
# a real filesystem when the host root is RAM-backed (in-VM runner).
WORKPARENT="${E2E_WORKDIR:-/tmp}"
mkdir -p "$WORKPARENT"
WORK="$(mktemp -d "$WORKPARENT/duressd-golden-work.XXXXXX")"
MNT="$WORK/mnt"; mkdir -p "$MNT"
MAP="duressd_golden_$$"
LOOP=""

cleanup() {
    set +e
    # Force-unwind: try a clean recursive unmount, then a lazy one so a busy
    # mount can never block teardown of the mapping/loop below.
    if [[ -n "${MNT:-}" ]] && mountpoint -q "$MNT"; then
        umount -R "$MNT" 2>/dev/null || umount -Rl "$MNT" 2>/dev/null
    fi
    if [[ -e "/dev/mapper/$MAP" ]]; then
        cryptsetup close "$MAP" 2>/dev/null || dmsetup remove --force "$MAP" 2>/dev/null
    fi
    [[ -n "${LOOP:-}" ]] && losetup -d "$LOOP" 2>/dev/null
    # Remove the scratch tree only once MNT is truly unmounted — never rm -rf a
    # dir that still contains a live mount.
    if [[ -n "${WORK:-}" ]] && ! mountpoint -q "$MNT" 2>/dev/null; then
        rm -rf "$WORK"
    fi
    rm -f "$RAW"
}
trap cleanup EXIT INT TERM HUP

# Loop is built into this kernel (loop-control exists) but the /dev/loopN nodes
# may be absent on a host that has never used a loop device, so `losetup --find`
# allocates a number but can't open the missing node. Ensure some nodes exist.
modprobe loop 2>/dev/null || true
for _n in 0 1 2 3 4 5 6 7; do
    [[ -e "/dev/loop$_n" ]] || mknod -m 0660 "/dev/loop$_n" b 7 "$_n" 2>/dev/null || true
done

echo "  →  allocating 4 GiB raw image (loopback file — no real disk touched)"
truncate -s 4G "$RAW"
LOOP="$(losetup -P --find --show "$RAW")"

echo "  →  partitioning the LOOP file (ESP + /boot + LUKS root)"
sfdisk "$LOOP" >/dev/null <<'EOF'
label: gpt
,256M,U
,512M,L
,,L
EOF
udevadm settle 2>/dev/null || sleep 1
ESP="${LOOP}p1"; BOOT="${LOOP}p2"; ROOT="${LOOP}p3"

echo "  →  filesystems + LUKS root (unlock passphrase = LUKS_PASS)"
mkfs.vfat -F32 "$ESP" >/dev/null
mkfs.ext4 -q "$BOOT"
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$ROOT"
printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOT" "$MAP"
mkfs.ext4 -q "/dev/mapper/$MAP"

mount "/dev/mapper/$MAP" "$MNT"
mkdir -p "$MNT/boot"; mount "$BOOT" "$MNT/boot"
mkdir -p "$MNT/boot/efi"; mount "$ESP" "$MNT/boot/efi"

echo "  →  pacstrap minimal system (isolated package cache — host cache untouched)"
# Redirect pacman's CacheDir into $WORK so downloads never land in the host's
# /var/cache/pacman (and don't bloat the image). Cleaned up by the trap.
install -Dm644 /etc/pacman.conf "$WORK/pacman.conf"
mkdir -p "$WORK/pkgcache"
if grep -qE '^[[:space:]]*CacheDir' "$WORK/pacman.conf"; then
    sed -i "s|^[[:space:]]*CacheDir.*|CacheDir = $WORK/pkgcache|" "$WORK/pacman.conf"
else
    sed -i "/^\[options\]/a CacheDir = $WORK/pkgcache" "$WORK/pacman.conf"
fi
pacstrap -C "$WORK/pacman.conf" -K "$MNT" \
    base linux mkinitcpio socat cryptsetup util-linux openssl coreutils systemd

ROOT_UUID="$(blkid -s UUID -o value "$ROOT")"
genfstab -U "$MNT" >> "$MNT/etc/fstab"

echo "  →  installing duressd + the LUKS-at-boot hook"
install -Dm755 "$REPO_ROOT/src/handler" "$MNT/usr/local/lib/duressd/handler"
install -Dm755 "$REPO_ROOT/src/daemon"  "$MNT/usr/local/lib/duressd/daemon"
install -Dm755 "$REPO_ROOT/src/cli"     "$MNT/usr/local/bin/duressd"
install -Dm644 "$REPO_ROOT/initramfs/duress-install-hook" "$MNT/etc/initcpio/install/duress"
install -Dm755 "$REPO_ROOT/initramfs/duress-runtime-hook" "$MNT/etc/initcpio/hooks/duress"

# HOOKS: prompt-based unlock (NO keyfile), with `duress` BEFORE `encrypt`.
cat > "$MNT/etc/mkinitcpio.conf" <<'MK'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base udev autodetect modconf keyboard block duress encrypt filesystems fsck)
MK

# The guest opens LUKS at boot as the mapping "root"; prompts (no cryptkey=).
CMDLINE="cryptdevice=UUID=${ROOT_UUID}:root root=/dev/mapper/root rw console=ttyS0"

# A boot-success marker the test watches for on a normal unlock.
cat > "$MNT/etc/systemd/system/e2e-bootok.service" <<'EOF'
[Unit]
Description=e2e boot marker
DefaultDependencies=no
After=sysinit.target
[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/bin/sh -c 'echo GOLDEN-BOOT-OK > /dev/console'
[Install]
WantedBy=multi-user.target
EOF

echo "  →  chroot: duress oracle, initramfs, bootloader"
export ROOT_UUID DURESS_PASS CMDLINE
arch-chroot "$MNT" /bin/bash -euo pipefail <<CHROOT
install -d -m0700 /etc/duressd
dd if=/dev/zero of=/etc/duressd/passphrase.luks bs=1M count=24 status=none
chmod 0600 /etc/duressd/passphrase.luks
printf '%s' "$DURESS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode \
    --pbkdf argon2id --key-file=- /etc/duressd/passphrase.luks

systemctl enable e2e-bootok.service
mkinitcpio -P

bootctl --esp-path=/boot/efi install --no-variables
mkdir -p /boot/efi/loader/entries
cat > /boot/efi/loader/loader.conf <<LC
default arch.conf
timeout 0
LC
cat > /boot/efi/loader/entries/arch.conf <<ENTRY
title Arch (duressd luks-at-boot e2e)
linux /vmlinuz-linux
initrd /initramfs-linux.img
options ${CMDLINE}
ENTRY
cp /boot/vmlinuz-linux /boot/efi/vmlinuz-linux
cp /boot/initramfs-linux.img /boot/efi/initramfs-linux.img
CHROOT

echo "  →  converting to golden qcow2: $GOLDEN"
umount "$MNT/boot/efi" "$MNT/boot" "$MNT"
cryptsetup close "$MAP"
losetup -d "$LOOP"; LOOP=""
rm -f "$GOLDEN"
qemu-img convert -f raw -O qcow2 "$RAW" "$GOLDEN"
echo
echo "  ✔  built $GOLDEN"
echo "     boot test:  sudo make golden-test"
