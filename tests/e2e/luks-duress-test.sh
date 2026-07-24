#!/usr/bin/env bash
# LUKS-at-boot duress trigger — full boot test against the golden image built by
# tests/e2e/build-luks-duress.sh. Drives the boot-time LUKS unlock prompt over
# serial and proves:
#   1. CONTROL — the correct passphrase unlocks and the system boots normally
#      (the duress hook does not break normal boot);
#   2. DURESS  — the duress passphrase destroys the LUKS header and powers off,
#      verified from the HOST via qemu-nbd (isLuks fails);
#   3. NO-BOOT — the wiped disk no longer boots.
#
#   sudo bash tests/e2e/luks-duress-test.sh
#
# Each boot runs on a fresh qcow2 overlay, so the golden image is never mutated.
set -euo pipefail
cd "$(dirname "$0")/../.."

REPO_ROOT="$(pwd)"
IMAGES="${E2E_IMAGES:-$REPO_ROOT/tests/e2e/images}"
GOLDEN="$IMAGES/luks-duress.qcow2"
LUKS_PASS="${E2E_LUKS_PASS:-e2e-luks}"
DURESS_PASS="${E2E_DURESS_PASS:-wipe-now}"
OVMF_CODE="${E2E_OVMF:-/usr/share/edk2/x64/OVMF_CODE.4m.fd}"
OVMF_VARS="${E2E_OVMF_VARS:-/usr/share/edk2/x64/OVMF_VARS.4m.fd}"
MEM="${E2E_MEM:-1536}"
NBD="${E2E_NBD:-/dev/nbd7}"

log()  { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
pass() { printf '  \033[1;32m✔  %s\033[0m\n' "$*"; }
fail() { printf '  \033[1;31m✘  FAIL: %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || { echo "needs root (qemu-nbd/partprobe): sudo bash $0" >&2; exit 1; }
for t in qemu-system-x86_64 qemu-img qemu-nbd cryptsetup; do
    command -v "$t" >/dev/null || { echo "missing $t (install qemu)" >&2; exit 1; }
done
[[ -f "$GOLDEN" ]]   || { echo "golden image missing — build it: sudo bash tests/e2e/build-luks-duress.sh" >&2; exit 1; }
[[ -f "$OVMF_CODE" ]] || { echo "OVMF not found at $OVMF_CODE (install edk2-ovmf); set E2E_OVMF=" >&2; exit 1; }

WORK="$(mktemp -d)"
NBD_UP=""
cleanup() {
    set +e
    [[ -n "$NBD_UP" ]] && qemu-nbd --disconnect "$NBD" >/dev/null 2>&1
    rm -rf "$WORK"
}
trap cleanup EXIT
modprobe nbd max_part=8 2>/dev/null || true

fresh_overlay() {
    local ov; ov="$(mktemp "$WORK/overlay.XXXXXX.qcow2")"
    qemu-img create -q -f qcow2 -F qcow2 -b "$GOLDEN" "$ov" >/dev/null
    printf '%s' "$ov"
}

# boot_drive <overlay> <passphrase> <want: bootok|wipe> → 0 on the wanted outcome.
# Boots headless, enters <passphrase> at the LUKS prompt, and waits for the
# outcome (GOLDEN-BOOT-OK, or the guest powering off after the wipe).
boot_drive() {
    local overlay="$1" pass="$2" want="$3"
    local vars; vars="$(mktemp "$WORK/vars.XXXXXX.fd")"; cp "$OVMF_VARS" "$vars"
    local kvm=(); [[ -e /dev/kvm ]] && kvm=(-enable-kvm -cpu host)

    coproc VM { exec qemu-system-x86_64 "${kvm[@]}" -m "$MEM" \
        -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE" \
        -drive "if=pflash,format=raw,file=$vars" \
        -drive "file=$overlay,format=qcow2,if=virtio" \
        -nic none -display none -serial stdio -monitor none 2>>"$WORK/qemu.log"; }
    local qpid=$!
    local line="" buf="" sent=0 rc=1
    while IFS= read -r -t "${E2E_BOOT_TIMEOUT:-180}" -N 1 ch <&"${VM[0]}"; do
        [[ "$ch" == $'\n' ]] && { line=""; } || line+="$ch"
        buf+="$ch"; (( ${#buf} > 4096 )) && buf="${buf: -512}"
        if (( ! sent )) && [[ "$buf" == *"Enter passphrase"* ]]; then
            printf '%s\n' "$pass" >&"${VM[1]}"; sent=1; buf=""
        fi
        if [[ "$want" == bootok && "$buf" == *"GOLDEN-BOOT-OK"* ]]; then rc=0; break; fi
        if [[ "$want" == wipe && "$buf" == *"unable to access the disk"* ]]; then rc=0; break; fi
    done
    if [[ "$want" == wipe ]]; then
        # wait for the guest to power itself off (the hook does poweroff -f)
        for _ in $(seq 1 30); do kill -0 "$qpid" 2>/dev/null || { rc=0; break; }; sleep 1; done
    fi
    kill "$qpid" 2>/dev/null; wait "$qpid" 2>/dev/null
    return $rc
}

# assert the LUKS root partition on <overlay> no longer carries a header.
luks_destroyed() {
    local overlay="$1" rc=0
    qemu-nbd --connect="$NBD" -f qcow2 "$overlay"; NBD_UP=1
    partprobe "$NBD" 2>/dev/null || true; udevadm settle 2>/dev/null || sleep 1
    cryptsetup isLuks "${NBD}p3" 2>/dev/null && rc=1
    qemu-nbd --disconnect "$NBD" >/dev/null 2>&1; NBD_UP=""
    return $rc
}

log "CONTROL — the correct passphrase boots normally (hook must not break boot)"
ctl="$(fresh_overlay)"
boot_drive "$ctl" "$LUKS_PASS" bootok \
    || fail "correct passphrase did NOT boot — the duress hook broke normal unlock"
pass "correct passphrase unlocked and the system booted (GOLDEN-BOOT-OK)"

log "DURESS — the duress passphrase wipes the LUKS header at the prompt"
dur="$(fresh_overlay)"
boot_drive "$dur" "$DURESS_PASS" wipe \
    || fail "duress passphrase did not trigger the wipe / poweroff"
pass "duress passphrase triggered the wipe and the machine powered off"

log "verifying from the HOST that the LUKS header is gone (qemu-nbd)"
luks_destroyed "$dur" || fail "LUKS header still present on the wiped disk"
pass "LUKS header destroyed — the disk is cryptographically unrecoverable"

log "NO-BOOT — the wiped disk no longer boots"
if boot_drive "$dur" "$LUKS_PASS" bootok; then
    fail "the wiped disk still booted — it must not"
fi
pass "the wiped disk no longer boots"

log "LUKS-AT-BOOT DURESS TRIGGER END-TO-END PASSED — boot, duress passphrase, wipe, no-boot"
