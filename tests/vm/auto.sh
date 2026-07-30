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

# Warn if a duressd-built ISO predates the current sources — a rebuild is needed
# to pick up recent changes (this script only BOOTS the ISO, it never rebuilds).
if [[ "$ISO" == *duressd-test* ]] \
   && [[ -n "$(find "$REPO/src" "$REPO/systemd" "$REPO/initramfs" "$REPO/tests" -type f ! -name auto.sh ! -name shell.sh ! -name launch.sh -newer "$ISO" -print -quit 2>/dev/null)" ]] \
   && [[ "${ALLOW_STALE_ISO:-}" != 1 ]]; then
    echo "✘  STOP: $ISO is OLDER than the current sources." >&2
    echo "   Rebuild it first (needs your sudo password, ~a few minutes):" >&2
    echo "       sudo make iso" >&2
    echo "   Wait for '✔  ISO built', then re-run this command." >&2
    echo "   (To boot the stale ISO anyway: ALLOW_STALE_ISO=1 make vm-auto ISO=…)" >&2
    exit 1
fi

WORK="$(mktemp -d)"
# Clean up on any exit path — normal, Ctrl-C, or kill. Nothing on the host is
# written regardless (ISO + repo are read-only, the VM disk is RAM); this only
# removes the extracted kernel/initramfs temp dir and the QEMU child.
cleanup() {
    set +e   # never let a failing kill (e.g. swtpm already gone) flip the exit code
    rm -rf "$WORK"
    [[ -n "${QPID:-}" ]]      && kill "$QPID"      2>/dev/null
    [[ -n "${SWTPM_PID:-}" ]] && kill "$SWTPM_PID" 2>/dev/null
    return 0
}
trap cleanup EXIT INT TERM

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

# Attach an emulated TPM (swtpm) so the in-VM TPM wipe test can actually run
# tpm2_clear against a throwaway software TPM. Skips gracefully if swtpm is
# absent (the guest test then skips too).
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
else
    echo "note: swtpm not installed — the VM's TPM wipe test will skip (install: sudo pacman -S swtpm)" >&2
fi

# `duressd.poweroff`: the ISO's self-test service shuts the VM down when the
# suite finishes, so this script needs to drive nothing.
# `cow_spacesize=2G`: the live root's writable overlay (cowspace) defaults to
# 256M — too small for the integration tests' loopback backing files under
# /var/tmp (esp. the RAID6 test, whose Phase 3 overwrites ~256M across members).
# Enlarge it; MEM is raised to 6144 so the RAM-backed overlay has headroom.
APPEND="archisobasedir=arch archisosearchuuid=${UUID} cow_spacesize=2G console=ttyS0,115200 systemd.show_status=false rd.systemd.show_status=false modprobe.blacklist=floppy loglevel=3 duressd.poweroff"

echo "Booting headless (serial). Live transcript → $LOG" >&2
# The guest's serial line is this coprocess's stdout: ${VM[0]}.
coproc VM { exec qemu-system-x86_64 "${kvm[@]}" \
    -m "${MEM:-6144}" -smp "${SMP:-2}" \
    -kernel "$KERNEL" -initrd "$INITRD" -append "$APPEND" \
    -drive file="$ISO",media=cdrom,if=virtio,readonly=on \
    -virtfs "local,path=$REPO,mount_tag=duressd,security_model=none,readonly=on" \
    "${tpm[@]}" \
    -nic user -display none -serial stdio -monitor none 2>>"$LOG"; }
QPID=$!            # our own name — bash unsets the coproc-managed VM_PID on exit
OUT=${VM[0]}

# Strip terminal query/report noise (cursor-position "…R", window-size "…t",
# etc.) while KEEPING colour (SGR "…m"), so the mirrored console stays readable.
ESC=$'\033'; BEL=$'\007'
strip_noise() {
    local s="$1" re="${ESC}\[[0-9;?]*[A-Za-ln-z]" osc="${ESC}\][^${BEL}]*${BEL}"
    while [[ "$s" =~ $re  ]]; do s="${s//"${BASH_REMATCH[0]}"/}"; done
    while [[ "$s" =~ $osc ]]; do s="${s//"${BASH_REMATCH[0]}"/}"; done
    printf '%s\n' "$s"
}

# Passive capture: read the serial console line by line, log it verbatim, mirror
# a cleaned copy, and record the self-test result. The VM powers itself off
# afterwards (duressd.poweroff).
rc=""
while IFS= read -r -t "${TIMEOUT:-900}" line <&"$OUT"; do
    printf '%s\n' "$line" >>"$LOG"
    strip_noise "$line" >&2
    case "$line" in
        *"SELF-TEST PASSED"*) rc=0; break ;;
        *"SELF-TEST FAILED"*) rc=1; break ;;
    esac
done

# Give the VM a moment to power itself off, then make sure it's gone.
printf '\nResult captured; waiting for the VM to power off…\n' >&2
for _ in $(seq 1 15); do kill -0 "$QPID" 2>/dev/null || break; sleep 1; done
kill "$QPID" 2>/dev/null || true
wait "$QPID" 2>/dev/null || true
QPID=""

echo "Transcript saved to $LOG" >&2
if [[ "$rc" == 0 ]]; then
    echo -e "\033[1;32m✔  headless VM validation PASSED\033[0m" >&2
    exit 0
fi
echo -e "\033[1;31m✘  headless VM validation FAILED (rc=${rc:-timeout — see $LOG})\033[0m" >&2
exit 1
