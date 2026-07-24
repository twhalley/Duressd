#!/usr/bin/env bash
# Launch a disposable Arch VM (the official live ISO) with this repo shared in
# read-only, so the whole duressd suite + a real wipe can run INSIDE the VM with
# nothing executed as root on the host. Close the VM window to discard it.
#
#   ISO=/path/to/archlinux-x86_64.iso bash tests/vm/launch.sh
#
# Env: ISO (required, the Arch live ISO)  MEM=4096  SMP=2  QEMU_KVM=1
set -euo pipefail

command -v qemu-system-x86_64 >/dev/null || {
    echo "install qemu first:  sudo pacman -S --needed qemu-full" >&2; exit 1; }

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ISO="${ISO:-}"
if [[ -z "$ISO" || ! -f "$ISO" ]]; then
    echo "Set ISO to the Arch live image, e.g.:" >&2
    echo "  curl -LO https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso" >&2
    echo "  ISO=\$PWD/archlinux-x86_64.iso bash tests/vm/launch.sh" >&2
    exit 1
fi

# Warn if a duressd-built ISO predates the current sources (this only boots it).
if [[ "$ISO" == *duressd-test* ]] \
   && [[ -n "$(find "$REPO/src" "$REPO/systemd" "$REPO/initramfs" "$REPO/tests" -type f ! -name auto.sh ! -name shell.sh ! -name launch.sh -newer "$ISO" -print -quit 2>/dev/null)" ]] \
   && [[ "${ALLOW_STALE_ISO:-}" != 1 ]]; then
    echo "✘  STOP: $ISO is OLDER than the current sources. Rebuild it first:" >&2
    echo "       sudo make iso    (wait for '✔  ISO built', then re-run)" >&2
    echo "   (To boot the stale ISO anyway: ALLOW_STALE_ISO=1 make vm ISO=…)" >&2
    exit 1
fi

kvm=()
[[ "${QEMU_KVM:-1}" == 1 && -e /dev/kvm ]] && kvm=(-enable-kvm -cpu host)

echo "Booting Arch live ISO. Inside the VM's root shell, run:"
echo "  mkdir -p /mnt/repo && mount -t 9p -o trans=virtio,ro duressd /mnt/repo"
echo "  cp -a /mnt/repo /root/duressd && cd /root/duressd"
echo "  bash tests/vm/inside.sh"
echo

exec qemu-system-x86_64 \
    "${kvm[@]}" \
    -m "${MEM:-4096}" -smp "${SMP:-2}" \
    -cdrom "$ISO" -boot d \
    -virtfs "local,path=$REPO,mount_tag=duressd,security_model=none,readonly=on" \
    -nic user \
    "$@"
