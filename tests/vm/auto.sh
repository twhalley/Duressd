#!/usr/bin/env bash
# Fully headless VM validation — NO QEMU window, NO typing inside the VM.
#
# Designed for the self-testing duressd ISO (`make iso`): boots its kernel with a
# serial console, passes `duressd.poweroff` so the ISO's duressd-selftest service
# runs the suite and shuts the VM down when done. This script is PASSIVE — it
# only mirrors the serial console to a transcript and records the PASS/FAIL
# result. Nothing runs as root on the host; the only wipe target is a loopback
# file created inside the VM.
#
#   ISO=/path/to/duressd-test-*.iso bash tests/vm/auto.sh
#
# Env: ISO (required)  MEM=4096  SMP=2  LOG=<repo>/vm-autorun.log  TIMEOUT=900
set -euo pipefail

command -v qemu-system-x86_64 >/dev/null || {
    echo "install qemu first:  sudo pacman -S --needed qemu-full" >&2; exit 1; }
command -v bsdtar >/dev/null || {
    echo "need bsdtar (libarchive) to extract the ISO kernel" >&2; exit 1; }

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
ISO="${ISO:-}"
[[ -n "$ISO" && -f "$ISO" ]] || { echo "set ISO=/path/to/archlinux-x86_64.iso" >&2; exit 1; }

WORK="$(mktemp -d)"
# Clean up on any exit path — normal, Ctrl-C, or kill. Nothing on the host is
# written regardless (ISO + repo are read-only, the VM disk is RAM); this only
# removes the extracted kernel/initramfs temp dir and the QEMU child.
trap 'rm -rf "$WORK"; [[ -n "${VM_PID:-}" ]] && kill "$VM_PID" 2>/dev/null || true' EXIT INT TERM

# Boot the ISO without its menu: pull the kernel/initramfs out and point the
# archiso initramfs at the CD by its filesystem UUID (stable, no label guess).
UUID="$(blkid -o value -s UUID "$ISO" 2>/dev/null || true)"
[[ -n "$UUID" ]] || { echo "could not read ISO filesystem UUID" >&2; exit 1; }
bsdtar -xf "$ISO" -C "$WORK" \
    arch/boot/x86_64/vmlinuz-linux arch/boot/x86_64/initramfs-linux.img
KERNEL="$WORK/arch/boot/x86_64/vmlinuz-linux"
INITRD="$WORK/arch/boot/x86_64/initramfs-linux.img"

LOG="${LOG:-$REPO/vm-autorun.log}"; : > "$LOG"
kvm=(); [[ -e /dev/kvm ]] && kvm=(-enable-kvm -cpu host)

# `duressd.poweroff`: the ISO's self-test service shuts the VM down when the
# suite finishes, so this script needs to drive nothing.
APPEND="archisobasedir=arch archisosearchuuid=${UUID} console=ttyS0,115200 systemd.show_status=false rd.systemd.show_status=false modprobe.blacklist=floppy duressd.poweroff"

echo "Booting headless (serial). Live transcript → $LOG" >&2
# The guest's serial line is this coprocess's stdout: ${VM[0]}.
coproc VM { exec qemu-system-x86_64 "${kvm[@]}" \
    -m "${MEM:-4096}" -smp "${SMP:-2}" \
    -kernel "$KERNEL" -initrd "$INITRD" -append "$APPEND" \
    -drive file="$ISO",media=cdrom,if=virtio,readonly=on \
    -virtfs "local,path=$REPO,mount_tag=duressd,security_model=none,readonly=on" \
    -nic user -display none -serial stdio -monitor none 2>>"$LOG"; }
VM_PID=$!
OUT=${VM[0]}

# Passive capture: read the serial byte-stream one char at a time, append it to
# the log, mirror whole lines to the terminal, and record the self-test result.
# The VM powers itself off afterwards (duressd.poweroff).
buf=""; line=""; rc=""
while IFS= read -r -t "${TIMEOUT:-900}" -N 1 ch <&"$OUT"; do
    printf '%s' "$ch" >>"$LOG"
    if [[ "$ch" == $'\n' ]]; then printf '%s\n' "$line" >&2; line=""; else line+="$ch"; fi
    buf+="$ch"
    if [[ "$buf" == *"SELF-TEST PASSED"* ]]; then rc=0; break; fi
    if [[ "$buf" == *"SELF-TEST FAILED"* ]]; then rc=1; break; fi
    (( ${#buf} > 4096 )) && buf="${buf: -512}"   # bound memory, keep the tail
done

# Give the VM a moment to power itself off, then make sure it's gone.
printf '\nResult captured; waiting for the VM to power off…\n' >&2
for _ in $(seq 1 15); do kill -0 "$VM_PID" 2>/dev/null || break; sleep 1; done
kill "$VM_PID" 2>/dev/null || true
wait "$VM_PID" 2>/dev/null || true
VM_PID=""

echo "Transcript saved to $LOG" >&2
if [[ "$rc" == 0 ]]; then
    echo -e "\033[1;32m✔  headless VM validation PASSED\033[0m" >&2
    exit 0
fi
echo -e "\033[1;31m✘  headless VM validation FAILED (rc=${rc:-timeout — see $LOG})\033[0m" >&2
exit 1
