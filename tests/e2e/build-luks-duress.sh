#!/usr/bin/env bash
# Build a golden, bootable, LUKS-encrypted image that PROMPTS for the passphrase
# at boot and has the duressd LUKS-at-boot hook installed — so the boot test can
# enter a DURESS passphrase at the unlock prompt and prove it wipes + won't boot.
#
#   sudo bash tests/e2e/build-luks-duress.sh        # -> tests/e2e/images/luks-duress.qcow2
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

LOOP=""
cleanup() {
    set +e
    mountpoint -q /mnt/boot/efi && umount /mnt/boot/efi
    mountpoint -q /mnt/boot     && umount /mnt/boot
    mountpoint -q /mnt          && umount /mnt
    [[ -e /dev/mapper/e2eroot ]] && cryptsetup close e2eroot
    [[ -n "$LOOP" ]] && losetup -d "$LOOP"
    rm -f "$RAW"
}
trap cleanup EXIT

echo "  →  allocating 4 GiB raw image"
truncate -s 4G "$RAW"
LOOP="$(losetup -P --find --show "$RAW")"

echo "  →  partitioning (ESP + /boot + LUKS root)"
sfdisk "$LOOP" >/dev/null <<'EOF'
label: gpt
,256M,U
,512M,L
,,L
EOF
udevadm settle 2>/dev/null || sleep 1
ESP="${LOOP}p1"; BOOT="${LOOP}p2"; ROOT="${LOOP}p3"

echo "  →  filesystems + LUKS root (passphrase = LUKS_PASS)"
mkfs.vfat -F32 "$ESP" >/dev/null
mkfs.ext4 -q "$BOOT"
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$ROOT"
printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOT" e2eroot
mkfs.ext4 -q /dev/mapper/e2eroot

mount /dev/mapper/e2eroot /mnt
mkdir -p /mnt/boot; mount "$BOOT" /mnt/boot
mkdir -p /mnt/boot/efi; mount "$ESP" /mnt/boot/efi

echo "  →  pacstrap minimal system"
pacstrap -K /mnt base linux mkinitcpio socat cryptsetup util-linux openssl coreutils systemd

ROOT_UUID="$(blkid -s UUID -o value "$ROOT")"
genfstab -U /mnt >> /mnt/etc/fstab

echo "  →  installing duressd + the LUKS-at-boot hook"
install -Dm755 "$REPO_ROOT/src/handler" /mnt/usr/local/lib/duressd/handler
install -Dm755 "$REPO_ROOT/src/daemon"  /mnt/usr/local/lib/duressd/daemon
install -Dm755 "$REPO_ROOT/src/cli"     /mnt/usr/local/bin/duressd
install -Dm644 "$REPO_ROOT/initramfs/duress-install-hook" /mnt/etc/initcpio/install/duress
install -Dm755 "$REPO_ROOT/initramfs/duress-runtime-hook" /mnt/etc/initcpio/hooks/duress

# HOOKS: prompt-based unlock (NO keyfile), with `duress` BEFORE `encrypt`.
cat > /mnt/etc/mkinitcpio.conf <<'MK'
MODULES=()
BINARIES=()
FILES=()
HOOKS=(base udev autodetect modconf keyboard block duress encrypt filesystems fsck)
MK

# Prompt for the passphrase (no cryptkey=), serial console for the driver.
CMDLINE="cryptdevice=UUID=${ROOT_UUID}:e2eroot root=/dev/mapper/e2eroot rw console=ttyS0"

# A boot-success marker the test watches for on a normal unlock.
cat > /mnt/etc/systemd/system/e2e-bootok.service <<'EOF'
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
arch-chroot /mnt /bin/bash -euo pipefail <<CHROOT
# The DURESS passphrase oracle the hook tests against (baked into the initramfs).
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
umount /mnt/boot/efi /mnt/boot /mnt
cryptsetup close e2eroot
losetup -d "$LOOP"; LOOP=""
rm -f "$GOLDEN"
qemu-img convert -f raw -O qcow2 "$RAW" "$GOLDEN"
echo
echo "  ✔  built $GOLDEN"
echo "     boot test:  sudo bash tests/e2e/luks-duress-test.sh"
