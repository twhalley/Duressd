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

# Warn if a duressd-built ISO predates the current sources (this only boots it).
if [[ "$ISO" == *duressd-test* ]] \
   && [[ -n "$(find "$REPO/src" "$REPO/systemd" "$REPO/tests/iso" "$REPO/tests/unit" "$REPO/tests/integration" "$REPO/tests/vm/inside.sh" "$REPO/tests/vm/encrypted-e2e.sh" -newer "$ISO" -print -quit 2>/dev/null)" ]] \
   && [[ "${ALLOW_STALE_ISO:-}" != 1 ]]; then
    echo "✘  STOP: $ISO is OLDER than the current sources. Rebuild it first:" >&2
    echo "       sudo make iso    (wait for '✔  ISO built', then re-run)" >&2
    echo "   (To boot the stale ISO anyway: ALLOW_STALE_ISO=1 make vm-shell ISO=…)" >&2
    exit 1
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"; [[ -n "${SWTPM_PID:-}" ]] && kill "$SWTPM_PID" 2>/dev/null; true' EXIT INT TERM

UUID="$(blkid -o value -s UUID "$ISO" 2>/dev/null || true)"
[[ -n "$UUID" ]] || { echo "could not read ISO filesystem UUID" >&2; exit 1; }
bsdtar -xf "$ISO" -C "$WORK" \
    arch/boot/x86_64/vmlinuz-linux arch/boot/x86_64/initramfs-linux.img
KERNEL="$WORK/arch/boot/x86_64/vmlinuz-linux"
INITRD="$WORK/arch/boot/x86_64/initramfs-linux.img"

kvm=(); [[ -e /dev/kvm ]] && kvm=(-enable-kvm -cpu host)

# Emulated TPM (swtpm) so `duressd` and the TPM test have a /dev/tpmrm0 to use.
tpm=(); SWTPM_PID=""
if command -v swtpm >/dev/null; then
    TPMDIR="$WORK/tpm"; mkdir -p "$TPMDIR"
    swtpm socket --tpm2 --tpmstate "dir=$TPMDIR" \
        --ctrl "type=unixio,path=$TPMDIR/sock" >/dev/null 2>&1 &
    SWTPM_PID=$!
    for _ in $(seq 1 30); do [[ -S "$TPMDIR/sock" ]] && break; sleep 0.1; done
    tpm=(-chardev "socket,id=chrtpm,path=$TPMDIR/sock"
         -tpmdev "emulator,id=tpm0,chardev=chrtpm"
         -device "tpm-tis,tpmdev=tpm0")
fi

cat >&2 <<'EOF'

Booting the Arch live shell in THIS terminal (serial console).
When you reach the shell (log in as `root`, no password, if prompted), paste:

  mkdir -p /mnt/repo && mount -t 9p -o trans=virtio,ro duressd /mnt/repo && cp -a /mnt/repo /root/duressd && cd /root/duressd && bash tests/vm/inside.sh

Your terminal's normal paste (Ctrl-Shift-V) works here.  Quit the VM: Ctrl-A then X.

EOF

# NOT exec: keep bash alive so the EXIT/INT/TERM trap removes $WORK afterward.
qemu-system-x86_64 "${kvm[@]}" \
    -m "${MEM:-4096}" -smp "${SMP:-2}" \
    -kernel "$KERNEL" -initrd "$INITRD" \
    -append "archisobasedir=arch archisosearchuuid=${UUID} console=ttyS0,115200 modprobe.blacklist=floppy" \
    -drive file="$ISO",media=cdrom,if=virtio,readonly=on \
    -virtfs "local,path=$REPO,mount_tag=duressd,security_model=none,readonly=on" \
    "${tpm[@]}" \
    -nic user -display none -serial mon:stdio
