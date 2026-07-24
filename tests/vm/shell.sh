#!/usr/bin/env bash
# Interactive archiso shell on THIS terminal (no QEMU window) — so your
# terminal's normal copy/paste works. Boots the Arch live ISO's own kernel with
# a serial console and hands you the live root shell; the repo is shared
# read-only at mount tag `duressd`. Exit the VM with Ctrl-A then X.
#
#   ISO=/path/to/archlinux-x86_64.iso bash tests/vm/shell.sh
#
# Env: ISO (required)  MEM=4096  SMP=2
set -euo pipefail

command -v qemu-system-x86_64 >/dev/null || {
    echo "install qemu first:  sudo pacman -S --needed qemu-full" >&2; exit 1; }
command -v bsdtar >/dev/null || {
    echo "need bsdtar (libarchive) to extract the ISO kernel" >&2; exit 1; }

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ISO="${ISO:-}"
[[ -n "$ISO" && -f "$ISO" ]] || { echo "set ISO=/path/to/archlinux-x86_64.iso" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

UUID="$(blkid -o value -s UUID "$ISO" 2>/dev/null || true)"
[[ -n "$UUID" ]] || { echo "could not read ISO filesystem UUID" >&2; exit 1; }
bsdtar -xf "$ISO" -C "$WORK" \
    arch/boot/x86_64/vmlinuz-linux arch/boot/x86_64/initramfs-linux.img
KERNEL="$WORK/arch/boot/x86_64/vmlinuz-linux"
INITRD="$WORK/arch/boot/x86_64/initramfs-linux.img"

kvm=(); [[ -e /dev/kvm ]] && kvm=(-enable-kvm -cpu host)

cat >&2 <<'EOF'

Booting the Arch live shell in THIS terminal (serial console).
When you reach the shell (log in as `root`, no password, if prompted), paste:

  mkdir -p /mnt/repo && mount -t 9p -o trans=virtio,ro duressd /mnt/repo && cp -a /mnt/repo /root/duressd && cd /root/duressd && bash tests/vm/inside.sh

Your terminal's normal paste (Ctrl-Shift-V) works here.  Quit the VM: Ctrl-A then X.

EOF

exec qemu-system-x86_64 "${kvm[@]}" \
    -m "${MEM:-4096}" -smp "${SMP:-2}" \
    -kernel "$KERNEL" -initrd "$INITRD" \
    -append "archisobasedir=arch archisosearchuuid=${UUID} console=ttyS0,115200" \
    -drive file="$ISO",media=cdrom,if=virtio,readonly=on \
    -virtfs "local,path=$REPO,mount_tag=duressd,security_model=none,readonly=on" \
    -nic user -display none -serial mon:stdio
