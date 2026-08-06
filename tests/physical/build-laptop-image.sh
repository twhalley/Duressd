#!/usr/bin/env bash
# Build a bootable, LUKS-encrypted Arch disk image pre-provisioned with a
# standard sudo user, sshd, and duressd (configured + SSH duress trigger) for
# PHYSICAL wipe testing on a laptop.
#
#   sudo LUKS_PASS=... DURESS_PASS=... USER_PASS=... \
#        bash tests/physical/build-laptop-image.sh
#
# Produces:
#   <OUT>                the raw disk image  ->  dd it onto the laptop's disk
#   <OUT>.duress-key     the private SSH key for the remote duress trigger
#
# Env (required): LUKS_PASS DURESS_PASS USER_PASS
# Env (optional): USERNAME=tester HOSTNAME=duressd-test SIZE=12G
#                 OUT=duressd-laptop.raw AUTO_UNLOCK=0 QCOW2=0
#                 WIPE_HARDWARE_KEYS=true WIPE_COUNTDOWN=0
#                 FLASH_DEV=/dev/sdX  (after building, RESET+dd+verify onto this
#                   USB; refuses a non-removable device unless FLASH_FORCE=1, and
#                   never the disk backing this host's root)
#
# Boot model: at power-on you type LUKS_PASS to unlock and boot normally; the
# separate DURESS_PASS fires the wipe (locally `sudo duressd trigger`, or over
# SSH). Set AUTO_UNLOCK=1 to embed a keyfile so the laptop boots headless.
set -euo pipefail

# `--clean` tears down any leftover build state from an interrupted run
# (recursive unmount of the chroot binds, close the build LUKS mapping, detach
# the loop). Safe: only touches /tmp/duressd-build.* and duressd_build_* names.
if [[ "${1:-}" == --clean ]]; then
    [[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0 --clean" >&2; exit 1; }
    echo "  →  tearing down leftover duressd build state"
    for m in /tmp/duressd-build.*; do
        [[ -d "$m" ]] || continue
        if mountpoint -q "$m"; then
            echo "     kill holders + umount -R $m"
            fuser -kM "$m" 2>/dev/null || true; pkill -f "$m" 2>/dev/null || true; sleep 1
            umount -R "$m" 2>/dev/null || umount -Rl "$m" 2>/dev/null || true
        fi
        rmdir "$m" 2>/dev/null || true
    done
    for d in /dev/mapper/duressd_build_*; do
        [[ -e "$d" ]] && { echo "     cryptsetup close $(basename "$d")"; cryptsetup close "$(basename "$d")" 2>/dev/null || true; }
    done
    for l in $(losetup -j "${OUT:-$PWD/duressd-laptop.raw}" 2>/dev/null | cut -d: -f1); do
        echo "     losetup -d $l"; losetup -d "$l" 2>/dev/null || true
    done
    echo "  ✔  cleanup complete"
    exit 0
fi

[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }
for v in LUKS_PASS DURESS_PASS USER_PASS; do
    [[ -n "${!v:-}" ]] || { echo "set $v (e.g. LUKS_PASS=..., DURESS_PASS=..., USER_PASS=...)" >&2; exit 1; }
done
for t in pacstrap sfdisk losetup cryptsetup mkfs.vfat mkfs.ext4 ssh-keygen; do
    command -v "$t" >/dev/null || { echo "missing tool: $t (need arch-install-scripts, dosfstools, openssh)" >&2; exit 1; }
done

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
USERNAME="${USERNAME:-tester}"
HOSTNAME="${HOSTNAME:-duressd-test}"
SIZE="${SIZE:-12G}"
OUT="${OUT:-$PWD/duressd-laptop.raw}"
AUTO_UNLOCK="${AUTO_UNLOCK:-0}"
WIPE_HW="${WIPE_HARDWARE_KEYS:-true}"
COUNTDOWN="${WIPE_COUNTDOWN:-0}"
KEYOUT="${OUT}.duress-key"

# Unique dm-crypt mapping name for THIS build, so we never collide with — or
# accidentally tear down — the host's own mappings (e.g. /dev/mapper/root).
MAPNAME="duressd_build_$$"
# Private throwaway mountpoint — never the conventional /mnt, so we can never
# shadow or unmount whatever the host may have mounted there.
MNT="$(mktemp -d /tmp/duressd-build.XXXXXX)"

LOOP=""
cleanup() {
    set +e
    # Kill any keyring/gpg daemons pacstrap left running with the target open
    # (the usual cause of a "target is busy" unmount), then recursively unmount
    # (lazy fallback) — this also handles arch-chroot API binds (proc/sys/dev/
    # efivars) — close the mapping, and detach the loop. Never leaves a stray
    # mount/mapping/loop on the host, even on an interrupted or failed run.
    if [[ -n "${MNT:-}" ]] && mountpoint -q "$MNT"; then
        fuser -kM "$MNT" 2>/dev/null; pkill -f "$MNT" 2>/dev/null; sleep 1
        umount -R "$MNT" 2>/dev/null || umount -Rl "$MNT" 2>/dev/null
    fi
    if [[ -e "/dev/mapper/$MAPNAME" ]]; then
        cryptsetup close "$MAPNAME" 2>/dev/null || dmsetup remove --force "$MAPNAME" 2>/dev/null
    fi
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
    [[ -n "${MNT:-}" ]] && ! mountpoint -q "$MNT" && rmdir "$MNT" 2>/dev/null
}
trap cleanup EXIT INT TERM HUP

echo "  →  allocating $SIZE raw image at $OUT"
# Detach any stale loop from a previous run and start from a clean file, so
# leftover vfat/LUKS signatures can never trigger an interactive sfdisk prompt.
for l in $(losetup -j "$OUT" 2>/dev/null | cut -d: -f1); do
    losetup -d "$l" 2>/dev/null || true
done
rm -f "$OUT" "$KEYOUT" "$KEYOUT.pub"
truncate -s "$SIZE" "$OUT"
LOOP="$(losetup -P --find --show "$OUT")"
echo "     loop device: $LOOP"

echo "  →  partitioning (ESP + LUKS root)"
# --wipe=always / --wipe-partitions=always: remove any existing signatures
# without prompting (belt-and-suspenders with the fresh file above).
sfdisk --wipe=always --wipe-partitions=always "$LOOP" <<'EOF'
label: gpt
,1G,U
,,L
EOF
udevadm settle 2>/dev/null || sleep 1
ESP="${LOOP}p1"; ROOTP="${LOOP}p2"
echo "     partitions:"
lsblk -o NAME,SIZE,TYPE,FSTYPE "$LOOP" 2>/dev/null || true

echo "  →  filesystems + LUKS root"
mkfs.vfat -F32 "$ESP" >/dev/null
printf '%s' "$LUKS_PASS" | cryptsetup luksFormat --type luks2 --batch-mode --key-file=- "$ROOTP"
printf '%s' "$LUKS_PASS" | cryptsetup open --key-file=- "$ROOTP" "$MAPNAME"
mkfs.ext4 -q "/dev/mapper/$MAPNAME"

mount "/dev/mapper/$MAPNAME" "$MNT"
mkdir -p "$MNT"/boot
mount "$ESP" "$MNT"/boot     # ESP mounted at /boot: systemd-boot reads kernels here

echo "  →  pacstrap base system + duressd deps"
# git + make so you can `git clone` the repo on the laptop and run
# `make phys-selftest` / `git pull` fixes directly over SSH (no scp round-trips).
pacstrap -K "$MNT" base linux linux-firmware mkinitcpio systemd sudo openssh \
    networkmanager cryptsetup socat util-linux openssl coreutils efibootmgr \
    tpm2-tools vim git make

ROOT_UUID="$(blkid -s UUID -o value "$ROOTP")"
genfstab -U "$MNT" >> "$MNT"/etc/fstab

# Optional headless auto-unlock: keyfile embedded in the initramfs.
CRYPTKEY=""
if [[ "$AUTO_UNLOCK" == 1 ]]; then
    echo "  →  embedding LUKS keyfile for headless auto-unlock"
    dd if=/dev/urandom of="$MNT"/crypto_keyfile.bin bs=512 count=8 status=none
    chmod 000 "$MNT"/crypto_keyfile.bin
    printf '%s' "$LUKS_PASS" | cryptsetup luksAddKey --key-file=- "$ROOTP" "$MNT"/crypto_keyfile.bin
    CRYPTKEY="cryptkey=rootfs:/crypto_keyfile.bin"
    sed -i 's|^FILES=.*|FILES=(/crypto_keyfile.bin)|' "$MNT"/etc/mkinitcpio.conf
fi

echo "  →  installing duressd into the image"
install -Dm755 "$REPO_ROOT/src/handler" "$MNT"/usr/local/lib/duressd/handler
install -Dm755 "$REPO_ROOT/src/daemon"  "$MNT"/usr/local/lib/duressd/daemon
install -Dm755 "$REPO_ROOT/src/cli"     "$MNT"/usr/local/bin/duressd
install -Dm644 "$REPO_ROOT/systemd/duressd.service" "$MNT"/etc/systemd/system/duressd.service
install -Dm644 "$REPO_ROOT/src/aliases.sh"   "$MNT"/etc/profile.d/duressd.sh

# Generate the duress SSH keypair on the host so we can hand you the private key.
echo "  →  generating duress SSH key → $KEYOUT"
rm -f "$KEYOUT" "$KEYOUT.pub"
ssh-keygen -t ed25519 -N '' -C duressd-duress -f "$KEYOUT" >/dev/null
install -d -m0700 "$MNT"/root/.ssh
printf 'command="duressd trigger-remote",restrict %s\n' "$(cat "$KEYOUT.pub")" \
    >> "$MNT"/root/.ssh/authorized_keys
chmod 0600 "$MNT"/root/.ssh/authorized_keys

echo "  →  chroot: system config, users, bootloader, duressd config"
# Quoted heredoc: nothing is expanded by THIS shell — every value below comes
# from the environment inside the chroot (arch-chroot inherits exported vars),
# so passwords containing $, backticks, etc. can neither break the script nor
# be injected into it.
export USERNAME HOSTNAME USER_PASS DURESS_PASS ROOT_UUID CRYPTKEY WIPE_HW COUNTDOWN
arch-chroot "$MNT" /bin/bash -euo pipefail <<'CHROOT'
ln -sf /usr/share/zoneinfo/UTC /etc/localtime; hwclock --systohc 2>/dev/null || true
echo 'en_US.UTF-8 UTF-8' > /etc/locale.gen; locale-gen
echo 'LANG=en_US.UTF-8' > /etc/locale.conf
echo "$HOSTNAME" > /etc/hostname

# initramfs with the encrypt hook (+ keyboard/keymap so you can type the passphrase)
sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
mkinitcpio -P

# standard sudo user + root password; enable wheel sudo
useradd -m -G wheel -s /bin/bash "$USERNAME"
printf '%s:%s\n' "$USERNAME" "$USER_PASS" | chpasswd
printf 'root:%s\n' "$USER_PASS" | chpasswd
sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers

# services: network, ssh, duressd
systemctl enable NetworkManager sshd duressd.service
# sshd: allow the user's password login; root only for the forced-command duress key
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin forced-commands-only/' /etc/ssh/sshd_config

# systemd-boot
bootctl --esp-path=/boot install --no-variables
cat > /boot/loader/loader.conf <<LOADER
default arch.conf
timeout 3
LOADER
cat > /boot/loader/entries/arch.conf <<ENTRY
title Arch (duressd test)
linux /vmlinuz-linux
initrd /initramfs-linux.img
options cryptdevice=UUID=${ROOT_UUID}:root root=/dev/mapper/root rw $CRYPTKEY
ENTRY

# pre-configure duressd (custom passphrase, boot-artifact wipe on)
install -d -m0700 /etc/duressd
dd if=/dev/zero of=/etc/duressd/passphrase.luks bs=1M count=24 status=none
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
WIPE_HARDWARE_KEYS=$WIPE_HW
WIPE_COUNTDOWN=$COUNTDOWN
CFG
chmod 0600 /etc/duressd/config
CHROOT

# Kill any keyring daemons pacstrap left holding the mount, sync, then unmount
# (lazy fallback) so the build never dies on a "target is busy" at the finish.
sync
fuser -kM "$MNT" 2>/dev/null || true; pkill -f "$MNT" 2>/dev/null || true; sleep 1
umount -R "$MNT" 2>/dev/null || umount -Rl "$MNT"
cryptsetup close "$MAPNAME"
losetup -d "$LOOP"; LOOP=""

if [[ "${QCOW2:-0}" == 1 ]] && command -v qemu-img >/dev/null; then
    echo "  →  converting to qcow2"
    qemu-img convert -f raw -O qcow2 "$OUT" "${OUT%.raw}.qcow2"
    echo "  ✔  ${OUT%.raw}.qcow2"
fi

# Optional: flash the finished image straight onto a USB and verify it.
#   FLASH_DEV=/dev/sdX   the target (RESET + dd + cmp). REFUSED unless it is a
#                        removable block device (set FLASH_FORCE=1 to override),
#                        and NEVER the disk backing this host's root.
if [[ -n "${FLASH_DEV:-}" ]]; then
    echo
    if [[ ! -b "$FLASH_DEV" ]]; then
        echo "  ✘  FLASH_DEV=$FLASH_DEV is not a block device — not flashing" >&2
    else
        _root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
        _root_disk="/dev/$(lsblk -no PKNAME "$_root_src" 2>/dev/null | head -1)"
        _rm="$(lsblk -ndo RM "$FLASH_DEV" 2>/dev/null || echo 0)"
        if [[ "$FLASH_DEV" == "$_root_disk" ]]; then
            echo "  ✘  REFUSING to flash $FLASH_DEV — it backs this host's root filesystem" >&2
        elif [[ "$_rm" != 1 && "${FLASH_FORCE:-}" != 1 ]]; then
            echo "  ✘  REFUSING to flash $FLASH_DEV — not a removable device (set FLASH_FORCE=1 to override)" >&2
        else
            echo "  →  flashing $OUT onto $FLASH_DEV ($(lsblk -ndo MODEL "$FLASH_DEV" 2>/dev/null || echo '?'))"
            wipefs -a "$FLASH_DEV"           2>/dev/null || true
            sgdisk --zap-all "$FLASH_DEV"    2>/dev/null || true
            dd if="$OUT" of="$FLASH_DEV" bs=4M conv=fsync status=progress
            sync
            if cmp -n "$(stat -c %s "$OUT")" "$OUT" "$FLASH_DEV"; then
                echo "  ✔  flashed + verified — $FLASH_DEV is byte-identical to the image; safe to boot"
            else
                echo "  ✘  verify FAILED — $FLASH_DEV differs from the image (bad/too-small USB?)" >&2
            fi
        fi
    fi
fi

cat <<DONE

  ✔  built $OUT
  ✔  duress SSH private key: $KEYOUT

  Provision a USB / disk — REFORMAT + FLASH + VERIFY (confirm the target first!):
    lsblk -o NAME,SIZE,MODEL,SERIAL,RM      # pick your device, e.g. /dev/sdX (RM=1)
    sudo bash -c 'D=/dev/sdX; \\
      wipefs -a "\$D"; sgdisk --zap-all "\$D" 2>/dev/null || true; \\
      dd if=$OUT of="\$D" bs=4M conv=fsync status=progress; sync; \\
      cmp -n \$(stat -c %s $OUT) $OUT "\$D" && echo "✔ MATCH — safe to boot" || echo "✘ MISMATCH — re-flash"'
    # …or let the build do it next time:  FLASH_DEV=/dev/sdX bash $0

  Log in:
    console/ssh user: $USERNAME   (password you set in USER_PASS)
    at boot, unlock LUKS with the LUKS_PASS you set${CRYPTKEY:+ (or it auto-unlocks)}

  Non-destructive self-test first (OS stays alive — iterate to green over SSH):
    ssh $USERNAME@<laptop-ip>
    git clone <this-repo-url> && cd Duressd
    sudo make phys-selftest ARGS=--tpm          # git + make are pre-installed

  Trigger the duress wipe (the one irreversible step):
    baseline: sudo bash tests/physical/baseline.sh
    local:    sudo duressd trigger       # or:  sudo duressd status / health
    remote:   printf '%s' '<DURESS_PASS>' | ssh -i $KEYOUT -T root@<laptop-ip>

  Then verify from a live USB:
    sudo bash tests/physical/verify-wipe.sh /dev/<laptop-disk>
DONE
