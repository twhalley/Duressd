#!/usr/bin/env bash
# Headless GOLDEN LUKS-at-boot boot test — run ENTIRELY inside a disposable VM so
# the host is never involved. Boots the self-testing duressd ISO with a throwaway
# scratch disk and `duressd.golden=1`; the ISO's self-test service then builds the
# LUKS-at-boot golden image on the scratch disk and drives the full boot test in a
# NESTED QEMU (CONTROL boots, DURESS passphrase wipes + won't boot). This script is
# PASSIVE — it mirrors the serial console and records PASS/FAIL, then the VM powers
# itself off. Nothing on the host is partitioned, mounted, or cached.
#
#   ISO=/path/to/duressd-test-*.iso bash tests/vm/golden-vm.sh
#
# Env: ISO (required)  MEM=6144  SMP=4  SCRATCH_GB=16  LOG=<repo>/vm-golden.log
#      TIMEOUT=2400
set -euo pipefail

command -v qemu-system-x86_64 >/dev/null || {
    echo "install qemu first:  sudo pacman -S --needed qemu-full" >&2; exit 1; }
command -v qemu-img >/dev/null || { echo "need qemu-img" >&2; exit 1; }
command -v bsdtar   >/dev/null || {
    echo "need bsdtar (libarchive) to extract the ISO kernel" >&2; exit 1; }

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ISO="${ISO:-}"
[[ -n "$ISO" && -f "$ISO" ]] || { echo "set ISO=/path/to/duressd-test-*.iso" >&2; exit 1; }

# The golden path needs qemu + edk2-ovmf + arch-install-scripts baked into the
# ISO — those were added to tests/iso/build.sh, so a duressd ISO older than the
# current sources must be rebuilt or the in-VM build will be missing tools.
if [[ "$ISO" == *duressd-test* ]] \
   && [[ -n "$(find "$REPO/src" "$REPO/systemd" "$REPO/initramfs" "$REPO/tests" -type f ! -name auto.sh ! -name shell.sh ! -name launch.sh ! -name golden-vm.sh -newer "$ISO" -print -quit 2>/dev/null)" ]] \
   && [[ "${ALLOW_STALE_ISO:-}" != 1 ]]; then
    echo "✘  STOP: $ISO is OLDER than the current sources." >&2
    echo "   Rebuild it first (adds qemu/ovmf/pacstrap to the ISO):" >&2
    echo "       sudo make iso" >&2
    echo "   Wait for '✔  ISO built', then re-run. (Override: ALLOW_STALE_ISO=1)" >&2
    exit 1
fi

[[ -e /dev/kvm ]] || echo "note: no /dev/kvm on the host — the OUTER VM will be slow (TCG)." >&2

WORK="$(mktemp -d)"
cleanup() {
    set +e
    rm -rf "$WORK"
    [[ -n "${QPID:-}" ]] && kill "$QPID" 2>/dev/null
    return 0
}
trap cleanup EXIT INT TERM

# Throwaway scratch disk for the in-VM build (image + pkg cache + convert). qcow2
# is sparse, so the host only stores what the build actually writes; deleted with
# $WORK. A stable serial makes it addressable as /dev/disk/by-id/virtio-* inside
# the VM regardless of enumeration order.
SCRATCH="$WORK/scratch.qcow2"
qemu-img create -q -f qcow2 "$SCRATCH" "${SCRATCH_GB:-16}G" >/dev/null
SCRATCH_DEV="/dev/disk/by-id/virtio-duressdgolden"

# Boot the ISO without its menu (extract kernel/initramfs, find the CD by UUID).
UUID="$(blkid -o value -s UUID "$ISO" 2>/dev/null || true)"
[[ -n "$UUID" ]] || { echo "could not read ISO filesystem UUID" >&2; exit 1; }
bsdtar -xf "$ISO" -C "$WORK" \
    arch/boot/x86_64/vmlinuz-linux arch/boot/x86_64/initramfs-linux.img
KERNEL="$WORK/arch/boot/x86_64/vmlinuz-linux"
INITRD="$WORK/arch/boot/x86_64/initramfs-linux.img"

LOG="${LOG:-$REPO/vm-golden.log}"; : > "$LOG"
kvm=(); [[ -e /dev/kvm ]] && kvm=(-enable-kvm -cpu host)   # -cpu host exposes nested KVM

APPEND="archisobasedir=arch archisosearchuuid=${UUID} console=ttyS0,115200 systemd.show_status=false rd.systemd.show_status=false modprobe.blacklist=floppy loglevel=3 duressd.golden=1 duressd.golden.disk=${SCRATCH_DEV} duressd.poweroff"

echo "Booting headless golden test (serial). Live transcript → $LOG" >&2
echo "(nested build+boot; this takes several minutes)" >&2
coproc VM { exec qemu-system-x86_64 "${kvm[@]}" \
    -m "${MEM:-6144}" -smp "${SMP:-4}" \
    -kernel "$KERNEL" -initrd "$INITRD" -append "$APPEND" \
    -drive file="$ISO",media=cdrom,if=virtio,readonly=on \
    -drive file="$SCRATCH",if=virtio,format=qcow2,serial=duressdgolden \
    -virtfs "local,path=$REPO,mount_tag=duressd,security_model=none,readonly=on" \
    -nic user -display none -serial stdio -monitor none 2>>"$LOG"; }
QPID=$!
OUT=${VM[0]}

# Strip terminal query/report noise while keeping colour (same as auto.sh).
ESC=$'\033'; BEL=$'\007'
strip_noise() {
    local s="$1" re="${ESC}\[[0-9;?]*[A-Za-ln-z]" osc="${ESC}\][^${BEL}]*${BEL}"
    while [[ "$s" =~ $re  ]]; do s="${s//"${BASH_REMATCH[0]}"/}"; done
    while [[ "$s" =~ $osc ]]; do s="${s//"${BASH_REMATCH[0]}"/}"; done
    printf '%s\n' "$s"
}

rc=""
while IFS= read -r -t "${TIMEOUT:-2400}" line <&"$OUT"; do
    printf '%s\n' "$line" >>"$LOG"
    strip_noise "$line" >&2
    case "$line" in
        *"GOLDEN LUKS-AT-BOOT TEST PASSED"*)         rc=0; break ;;
        *"GOLDEN (in-VM) FAILED"*|*"golden boot test failed"*|*"golden image build failed"*) rc=1; break ;;
    esac
done

printf '\nResult captured; waiting for the VM to power off…\n' >&2
for _ in $(seq 1 15); do kill -0 "$QPID" 2>/dev/null || break; sleep 1; done
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
QPID=""

echo "Transcript saved to $LOG" >&2
if [[ "$rc" == 0 ]]; then
    echo -e "\033[1;32m✔  golden LUKS-at-boot test PASSED (inside the VM, host untouched)\033[0m" >&2
    exit 0
fi
echo -e "\033[1;31m✘  golden test FAILED (rc=${rc:-timeout — see $LOG})\033[0m" >&2
exit 1
