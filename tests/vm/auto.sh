#!/usr/bin/env bash
# Fully headless VM validation — NO QEMU window, NO typing inside the VM.
#
# Boots the Arch live ISO's own kernel directly with a serial console, drives
# login + tests/vm/inside.sh over that serial line, streams a transcript to a
# host log file, powers the VM off, and exits non-zero if the suite failed.
# Nothing runs as root on the host; the only wipe target is a loopback file
# created inside the VM.
#
#   ISO=/path/to/archlinux-x86_64.iso bash tests/vm/auto.sh
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
trap 'rm -rf "$WORK"; [[ -n "${VM_PID:-}" ]] && kill "$VM_PID" 2>/dev/null || true' EXIT

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

APPEND="archisobasedir=arch archisosearchuuid=${UUID} console=ttyS0,115200 systemd.show_status=false rd.systemd.show_status=false"

echo "Booting headless (serial). Live transcript → $LOG" >&2
# The guest's serial line is this coprocess's stdio: ${VM[0]} read, ${VM[1]} write.
coproc VM { exec qemu-system-x86_64 "${kvm[@]}" \
    -m "${MEM:-4096}" -smp "${SMP:-2}" \
    -kernel "$KERNEL" -initrd "$INITRD" -append "$APPEND" \
    -drive file="$ISO",media=cdrom,if=virtio,readonly=on \
    -virtfs "local,path=$REPO,mount_tag=duressd,security_model=none,readonly=on" \
    -nic user -display none -serial stdio -monitor none 2>>"$LOG"; }
VM_PID=$!
IN=${VM[1]}; OUT=${VM[0]}

# Prober: until the shell is proven live, periodically log in and ask for a
# marker. `root` is a harmless unknown command at an already-open shell and the
# (passwordless) login name at a getty prompt — so this drives BOTH autologin
# and login-prompt images without needing to detect which. The marker (D42Z)
# never appears in the echoed input, only in the shell's output.
probe() {
    local n=0
    exec 2>/dev/null   # subshell-local: silence bad-fd noise once the VM exits
    while [[ ! -e "$WORK/ready" ]]; do
        printf 'root\n'            >&"$IN" || return 0
        printf 'echo D$((6*7))Z\n' >&"$IN" || return 0
        sleep 4
        (( ++n > 60 )) && return 0
    done
}
probe & PROBE=$!

send_payload() {
    {
        printf 'mkdir -p /mnt/repo && mount -t 9p -o trans=virtio,ro duressd /mnt/repo\n'
        printf 'cp -a /mnt/repo /root/duressd && cd /root/duressd\n'
        printf 'bash tests/vm/inside.sh; echo "DZRC=$?=ZD"\n'
        printf 'systemctl poweroff\n'
    } >&"$IN"
}

# Read the serial byte-stream (char at a time so partial prompts are seen),
# tee to the log, and react to the two markers.
buf=""; ready=0; rc=""
while IFS= read -r -t "${TIMEOUT:-900}" -N 1 ch <&"$OUT"; do
    printf '%s' "$ch" | tee -a "$LOG" >/dev/null
    buf+="$ch"
    [[ "$ch" == $'\n' ]] && { printf '%s' "$buf" >&2; }   # mirror full lines to stderr
    if (( ! ready )) && [[ "$buf" == *"D42Z"* ]]; then
        ready=1; touch "$WORK/ready"; kill "$PROBE" 2>/dev/null || true
        send_payload
        buf=""
        continue
    fi
    if [[ "$buf" == *"DZRC="*"=ZD"* ]]; then
        rc="${buf##*DZRC=}"; rc="${rc%%=ZD*}"
        break
    fi
    (( ${#buf} > 8192 )) && buf="${buf: -256}"   # keep the tail, bound memory
done

kill "$PROBE" 2>/dev/null || true
printf '\nWaiting for the VM to power off…\n' >&2
{ printf 'systemctl poweroff\n' >&"$IN"; } 2>/dev/null || true
wait "$VM_PID" 2>/dev/null || true
VM_PID=""

echo "Transcript saved to $LOG" >&2
if [[ "$rc" == 0 ]]; then
    echo -e "\033[1;32m✔  headless VM validation PASSED\033[0m" >&2
    exit 0
fi
echo -e "\033[1;31m✘  headless VM validation FAILED (rc=${rc:-timeout — see $LOG})\033[0m" >&2
exit 1
