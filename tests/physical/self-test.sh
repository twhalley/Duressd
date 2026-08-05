#!/usr/bin/env bash
# duressd PHYSICAL self-test — run ON the test machine (over SSH) to prove the
# real-hardware paths WITHOUT destroying the OS. Non-destructive and recoverable
# by design: scoped to loopback scratch files, poweroff suppressed, and the TPM
# is verified via a RUNTIME unseal (no reboot). Iterate freely — the OS and your
# SSH session stay alive. Only the SEPARATE final full-machine wipe (baseline.sh
# + a real unscoped trigger + verify-wipe.sh) is irreversible.
#
#   sudo bash tests/physical/self-test.sh [--tpm] [--scratch-dev /dev/sdX]
#
#   --tpm            run the TPM clear stage. NB: tpm2_clear is TPM-WIDE — it
#                    clears the whole machine's TPM (recoverable by re-enrolling).
#                    Safe only if this machine's root does NOT auto-unlock via TPM.
#   --scratch-dev D  use a real spare block device D as the scoped wipe target
#                    (real-SSD path). D IS WIPED. Default: a loopback file.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
DUR="${DURESSD_BIN:-duressd}"
HANDLER="${DURESSD_LIBDIR:-/usr/local/lib/duressd}/handler"
[[ -f "$HANDLER" ]] || HANDLER="$REPO/src/handler"
[[ -f "$HANDLER" ]] || HANDLER=""   # TPM stage will skip if missing

WANT_TPM=0; SCRATCH_DEV=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --tpm)         WANT_TPM=1; shift ;;
        --scratch-dev) SCRATCH_DEV="$2"; shift 2 ;;
        -h|--help)     grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
    esac
done

hr()   { printf '\n\033[1;36m══ %s ══\033[0m\n' "$*"; }
pass() { printf '  \033[1;32m✔  %s\033[0m\n' "$*"; }
warn() { printf '  \033[1;33m↷  %s\033[0m\n' "$*"; }
bad()  { printf '  \033[1;31m✘  %s\033[0m\n' "$*"; FAILS=$((FAILS+1)); }
FAILS=0

[[ $EUID -eq 0 ]] || { echo "run as root: sudo bash $0" >&2; exit 1; }
DPASS="${PHYS_DURESS_PASS:-wipe-now}"

WORK="$(mktemp -d)"; LOOP=""; DPID=""; SCRATCH_LOOP=""
cleanup() {
    set +e
    [[ -n "$DPID" ]] && kill "$DPID" 2>/dev/null
    for m in tpmtest phys-scratch; do [[ -e "/dev/mapper/$m" ]] && cryptsetup close "$m" 2>/dev/null; done
    [[ -n "$SCRATCH_LOOP" ]] && losetup -d "$SCRATCH_LOOP" 2>/dev/null
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT
modprobe loop 2>/dev/null || true
for _n in 0 1 2 3 4 5 6 7; do [[ -e "/dev/loop$_n" ]] || mknod -m0660 "/dev/loop$_n" b 7 "$_n" 2>/dev/null || true; done

# Start a duressd daemon on a private socket with a scratch custom-passphrase
# config. $1 = DURESSD_TARGET_DEVICES ("" = unscoped, dry-run only!).
SOCK="$WORK/run/control.sock"
start_daemon() {
    [[ -n "$DPID" ]] && { kill "$DPID" 2>/dev/null; DPID=""; }
    rm -f "$SOCK"; mkdir -p "$WORK/run" "$WORK/cfg"
    if [[ ! -f "$WORK/cfg/passphrase.luks" ]]; then
        dd if=/dev/zero of="$WORK/cfg/passphrase.luks" bs=1M count=24 status=none
        printf '%s' "$DPASS" | cryptsetup luksFormat --type luks2 --batch-mode \
            --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file=- "$WORK/cfg/passphrase.luks"
        cat > "$WORK/cfg/config" <<CFG
CONFIGURED=true
PASSWORD_TYPE=custom
VERIFY_DEVICE=
OVERWRITE_LUKS_HEADER=false
WIPE_FULL_DEVICE=false
WIPE_BOOT_ARTIFACTS=false
WIPE_HARDWARE_KEYS=false
WIPE_COUNTDOWN=0
CFG
    fi
    DURESSD_CFGDIR="$WORK/cfg" DURESSD_RUNDIR="$WORK/run" DURESSD_SOCKET="$SOCK" \
    DURESSD_LIBDIR="$(dirname "$HANDLER")" DURESSD_TARGET_DEVICES="$1" DURESSD_NO_POWEROFF=1 \
        bash "$(dirname "$HANDLER")/daemon" & DPID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$SOCK" ]] && return 0; sleep 0.5; done
    return 1
}
trig() { DURESSD_PASS="$DPASS" DURESSD_SOCKET="$SOCK" "$DUR" trigger-remote "$@" </dev/null; }

hr "0 · preflight"
for t in "$DUR" cryptsetup losetup; do command -v "$t" >/dev/null && pass "found $t" || bad "missing $t"; done
if [[ -e /dev/tpmrm0 || -e /dev/tpm0 ]]; then pass "TPM present ($(ls /dev/tpmrm0 /dev/tpm0 2>/dev/null | head -1))"
else warn "no TPM device — TPM stage will be skipped"; fi
[[ -n "$HANDLER" ]] && pass "duressd handler: $HANDLER" || warn "duressd handler not found — TPM stage skips"

hr "1 · duressd health (real machine)"
"$DUR" health 2>&1 | sed 's/^/  /' || true

hr "2 · DRY-RUN against the REAL machine (non-destructive targeting check)"
if start_daemon ""; then
    echo "  what a REAL trigger WOULD destroy on this machine (nothing is touched):"
    trig --dry-run 2>&1 | sed 's/^/    /'
    pass "dry-run completed — review the targets above (real disks/ESP/TPM/NVRAM)"
else bad "could not start the scratch daemon for the dry-run"; fi

hr "3 · SCOPED real wipe of a scratch encrypted disk (real engine, OS untouched)"
if [[ -n "$SCRATCH_DEV" ]]; then
    [[ -b "$SCRATCH_DEV" ]] || bad "scratch device $SCRATCH_DEV is not a block device"
    warn "using REAL device $SCRATCH_DEV as the scratch target — it WILL be wiped"
    TARGET="$SCRATCH_DEV"
else
    truncate -s 64M "$WORK/scratch.img"
    SCRATCH_LOOP="$(losetup -Pf --show "$WORK/scratch.img")"; TARGET="$SCRATCH_LOOP"
    pass "scratch loopback target: $TARGET"
fi
if [[ -n "${TARGET:-}" ]]; then
    printf 'diskpass' | cryptsetup luksFormat --type luks2 --batch-mode \
        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file=- "$TARGET" 2>/dev/null
    cryptsetup isLuks "$TARGET" && pass "scratch LUKS header present" || bad "could not format scratch LUKS"
    if start_daemon "$TARGET"; then
        trig >/dev/null 2>&1 || true
        sleep 1
        if cryptsetup isLuks "$TARGET" 2>/dev/null; then bad "scoped wipe did NOT destroy the scratch LUKS header"
        else pass "scoped real wipe destroyed the scratch LUKS header (engine works on this hardware)"; fi
    else bad "could not start the scoped daemon"; fi
fi

hr "4 · TPM enroll → clear → verify (real TPM)"
SCS=""; for c in /usr/lib/systemd/systemd-cryptsetup /lib/systemd/systemd-cryptsetup; do [[ -x "$c" ]] && SCS="$c"; done
if (( ! WANT_TPM )); then
    warn "skipped — pass --tpm to run it (clears the machine's TPM; recoverable)"
elif [[ ! -e /dev/tpmrm0 && ! -e /dev/tpm0 ]]; then warn "skipped — no TPM device"
elif ! command -v systemd-cryptenroll >/dev/null || [[ -z "$SCS" ]]; then warn "skipped — systemd-cryptenroll / systemd-cryptsetup not available"
elif [[ -z "$HANDLER" ]]; then warn "skipped — duressd handler not found"
else
    truncate -s 64M "$WORK/tpm.img"
    LOOP="$(losetup -f --show "$WORK/tpm.img")"
    printf 'unlockpass' > "$WORK/uk"; chmod 600 "$WORK/uk"
    cryptsetup luksFormat --type luks2 --batch-mode \
        --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file="$WORK/uk" "$LOOP"
    if systemd-cryptenroll --unlock-key-file="$WORK/uk" \
            --tpm2-device=auto --tpm2-pcrs=7 "$LOOP" >/dev/null 2>&1; then
        pass "enrolled a real TPM2 key (SRK-sealed, PCR 7)"
        if "$SCS" attach tpmtest "$LOOP" - tpm2-device=auto >/dev/null 2>&1; then
            "$SCS" detach tpmtest >/dev/null 2>&1; pass "BEFORE: the TPM unseals the key (runtime, no reboot)"
        else bad "the freshly-enrolled TPM key did not unseal — enrollment problem"; fi

        echo "  firing duressd's hardware-key wipe (real TPM clear)…"
        _ppireq="/sys/class/tpm/tpm0/ppi/request"
        # shellcheck disable=SC1090,SC2034  # dynamic source; DRYRUN read by the handler
        ( DURESSD_LIB_ONLY=1 source "$HANDLER"; unset DURESSD_TARGET_DEVICES; DRYRUN=0; wipe_hardware_keys ) \
            2>&1 | sed 's/^/    /'
        _ppiafter=""; [[ -r "$_ppireq" ]] && _ppiafter="$(cat "$_ppireq" 2>/dev/null)"

        # Three real-hardware outcomes:
        #  • the OS cleared the TPM directly  → the sealed key no longer unseals;
        #  • the OS can't clear this TPM (lockout auth set / DA lockout) but duressd
        #    scheduled a FIRMWARE clear via the PPI (op 5, applied on next boot) —
        #    a runtime unseal can't observe that, so treat it as a pass-with-note;
        #  • neither → the hardware-key wipe genuinely failed.
        if ! "$SCS" attach tpmtest "$LOOP" - tpm2-device=auto >/dev/null 2>&1; then
            pass "AFTER: the TPM can no longer unseal — the sealed key is destroyed (immediate clear)"
        elif [[ "$_ppiafter" == 5* ]]; then
            "$SCS" detach tpmtest >/dev/null 2>&1
            warn "AFTER: the OS can't clear this TPM directly (lockout auth / DA lockout) — a FIRMWARE clear (PPI op 5) is queued for next boot; verify after reboot"
            warn "data is safe regardless: Phase 1 erases the LUKS header the sealed key unlocks"
            echo 0 > "$_ppireq" 2>/dev/null || true   # keep the self-test non-destructive: cancel the queued clear
        else
            "$SCS" detach tpmtest >/dev/null 2>&1
            bad "AFTER: the TPM still unseals AND no clear was scheduled — the hardware-key wipe failed"
        fi
        warn "the machine's TPM was targeted — re-enroll any real TPM unlocks you rely on"
    else
        bad "systemd-cryptenroll --tpm2 failed — cannot test the TPM path here"
    fi
fi

hr "result"
if (( FAILS == 0 )); then printf '\033[1;42m  ✔  PHYSICAL SELF-TEST PASSED  \033[0m\n'
else printf '\033[1;41m  ✘  PHYSICAL SELF-TEST FAILED — %d issue(s)  \033[0m\n' "$FAILS"; fi
printf 'OS untouched — this was non-destructive. The final full-machine wipe is separate.\n\n'
exit $(( FAILS > 0 ? 1 : 0 ))
