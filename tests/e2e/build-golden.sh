#!/usr/bin/env bash
# Build a golden, bootable, LUKS-encrypted disk image for the E2E tests.
#
#   sudo bash tests/e2e/build-golden.sh <sdboot-luks|grub-luks|qubes-like>
#
# Layout (all scenarios): GPT = ESP (vfat) + /boot (ext4) + LUKS root (ext4).
# The image contains a minimal Arch userspace, a real bootloader, and duressd
# with an e2e auto-trigger unit that fires the REAL wipe when the guest is
# booted with `duressd.e2e=trigger` on the kernel command line.
#
# NOTE: This builder targets an Arch host (uses pacstrap). It must be run on a
# machine with root, loop devices, and an Arch toolchain. It is the one piece of
# the pipeline that has to be validated on real KVM hardware.
set -euo pipefail

SCENARIO="${1:?usage: build-golden.sh <sdboot-luks|grub-luks|qubes-like>}"
[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUTDIR="${E2E_IMAGES:-$REPO_ROOT/tests/e2e/images}"
mkdir -p "$OUTDIR"
RAW="$(mktemp "$OUTDIR/${SCENARIO}.raw.XXXXXX")"
GOLDEN="$OUTDIR/${SCENARIO}.qcow2"

LUKS_PASS="${E2E_LUKS_PASS:-e2e-luks}"
DURESS_PASS="${E2E_DURESS_PASS:-wipe-now}"

cleanup() {
    set +e
    mountpoint -q /mnt/boot/efi && umount /mnt/boot/efi
    mountpoint -q /mnt/boot     && umount /mnt/boot
    mountpoint -q /mnt          && umount /mnt
    [[ -e /dev/mapper/e2eroot ]] && cryptsetup close e2eroot
    [[ -n "${LOOP:-}" ]] && losetup -d "$LOOP"
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

echo "  →  creating filesystems + LUKS root"
mkfs.vfat -F32 "$ESP" >/dev/null
mkfs.ext4 -q "$BOOT"
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$ROOT"
printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOT" e2eroot
mkfs.ext4 -q /dev/mapper/e2eroot

echo "  →  mounting target"
mount /dev/mapper/e2eroot /mnt
mkdir -p /mnt/boot; mount "$BOOT" /mnt/boot
mkdir -p /mnt/boot/efi; mount "$ESP" /mnt/boot/efi

echo "  →  pacstrap minimal system"
pacstrap -K /mnt base linux mkinitcpio socat cryptsetup util-linux openssl coreutils systemd

ROOT_UUID="$(blkid -s UUID -o value "$ROOT")"

echo "  →  embedding a keyfile so the guest unlocks LUKS without a prompt"
dd if=/dev/urandom of=/mnt/crypto_keyfile.bin bs=512 count=8 status=none
chmod 000 /mnt/crypto_keyfile.bin
printf '%s' "$LUKS_PASS" | cryptsetup luksAddKey --key-file=- "$ROOT" /mnt/crypto_keyfile.bin

echo "  →  configuring initramfs (encrypt hook) + fstab"
genfstab -U /mnt >> /mnt/etc/fstab
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf keyboard block encrypt filesystems fsck)/' \
    /mnt/etc/mkinitcpio.conf
sed -i 's|^FILES=.*|FILES=(/crypto_keyfile.bin)|' /mnt/etc/mkinitcpio.conf

# Kernel cmdline shared by both bootloaders: unlock via keyfile + fire the E2E
# wipe trigger + serial console.
CMDLINE="cryptdevice=UUID=${ROOT_UUID}:e2eroot root=/dev/mapper/e2eroot rw \
cryptkey=rootfs:/crypto_keyfile.bin duressd.e2e=trigger console=ttyS0"

# Install duressd into the image.
echo "  →  installing duressd"
install -Dm755 "$REPO_ROOT/src/handler" /mnt/usr/local/lib/duressd/handler
install -Dm755 "$REPO_ROOT/src/daemon"  /mnt/usr/local/lib/duressd/daemon
install -Dm755 "$REPO_ROOT/src/cli"     /mnt/usr/local/bin/duressd
install -Dm644 "$REPO_ROOT/systemd/duressd.service" /mnt/etc/systemd/system/duressd.service

# Pre-seed duressd config (custom passphrase) so no interactive setup is needed.
# The Argon2id container is created inside the chroot below.
install -d -m0700 /mnt/etc/duressd

# E2E auto-trigger: on `duressd.e2e=trigger`, send TRIGGER straight to the socket.
cat > /mnt/usr/local/bin/duressd-e2e-trigger <<EOF
#!/bin/bash
grep -q 'duressd.e2e=trigger' /proc/cmdline || exit 0
for i in \$(seq 1 30); do [[ -S /run/duressd/control.sock ]] && break; sleep 1; done
pass=\$(printf '%s' "$DURESS_PASS" | base64 -w0)
printf 'TRIGGER\t%s\n' "\$pass" | socat - UNIX-CONNECT:/run/duressd/control.sock || true
EOF
chmod +x /mnt/usr/local/bin/duressd-e2e-trigger
cat > /mnt/etc/systemd/system/duressd-e2e.service <<'EOF'
[Unit]
Description=duressd E2E auto-trigger
After=duressd.service
Wants=duressd.service
[Service]
Type=oneshot
ExecStart=/usr/local/bin/duressd-e2e-trigger
[Install]
WantedBy=multi-user.target
EOF

# Bootloader install differs per scenario.
install_bootloader() {
    case "$SCENARIO" in
        sdboot-luks|qubes-like)
            bootctl --esp-path=/boot/efi install
            mkdir -p /boot/efi/loader/entries
            cat > /boot/efi/loader/entries/arch.conf <<EOF
title Arch (duressd e2e)
linux /vmlinuz-linux
initrd /initramfs-linux.img
options ${CMDLINE}
EOF
            cp /boot/vmlinuz-linux /boot/efi/vmlinuz-linux
            cp /boot/initramfs-linux.img /boot/efi/initramfs-linux.img
            ;;
        grub-luks)
            pacman -S --noconfirm grub efibootmgr
            sed -i 's|^#\?GRUB_CMDLINE_LINUX=.*|GRUB_CMDLINE_LINUX="'"${CMDLINE}"'"|' /etc/default/grub
            sed -i 's/^#\?GRUB_ENABLE_CRYPTODISK=.*/GRUB_ENABLE_CRYPTODISK=y/' /etc/default/grub
            grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=GRUB
            grub-mkconfig -o /boot/grub/grub.cfg
            ;;
    esac
}

echo "  →  chroot: initramfs, bootloader, duressd config"
export SCENARIO ROOT_UUID DURESS_PASS CMDLINE
export -f install_bootloader
arch-chroot /mnt /bin/bash -euo pipefail <<CHROOT
mkinitcpio -P
# Pre-seed the Argon2id duress keyslot + config (type=custom).
dd if=/dev/zero of=/etc/duressd/passphrase.luks bs=1M count=8 status=none
chmod 0600 /etc/duressd/passphrase.luks
printf '%s' "$DURESS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode \
    --pbkdf argon2id --key-file=- /etc/duressd/passphrase.luks
cat > /etc/duressd/config <<CFG
CONFIGURED=true
PASSWORD_TYPE=custom
VERIFY_DEVICE=
OVERWRITE_LUKS_HEADER=false
WIPE_FULL_DEVICE=false
WIPE_BOOT_ARTIFACTS=true
WIPE_HARDWARE_KEYS=false
WIPE_COUNTDOWN=0
CFG
chmod 0600 /etc/duressd/config
systemctl enable duressd.service duressd-e2e.service
install_bootloader
CHROOT

echo "  →  converting to golden qcow2: $GOLDEN"
umount /mnt/boot/efi /mnt/boot /mnt
cryptsetup close e2eroot
losetup -d "$LOOP"; LOOP=""
qemu-img convert -f raw -O qcow2 "$RAW" "$GOLDEN"
echo "  ✔  built $GOLDEN"
