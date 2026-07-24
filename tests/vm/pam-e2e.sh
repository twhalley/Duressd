#!/usr/bin/env bash
# PAM login duress trigger — end to end, inside the VM.
#
# Runs the real pam-duress hook exactly as pam_exec would (password on stdin):
# the DURESS passphrase fires a scoped wipe of a scratch encrypted disk; a
# non-duress password does NOT. Also checks install-login-trigger wires the
# pam_exec line. Safe: the daemon is scoped to the scratch loop with poweroff
# suppressed, so the trigger can only ever destroy the throwaway disk.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$REPO" || exit 1
hr()   { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
pass() { printf '  \033[1;32m✔  %s\033[0m\n' "$*"; }
fail() { printf '  \033[1;31m✘  FAIL: %s\033[0m\n' "$*"; exit 1; }

WORK="$(mktemp -d)"; LOOP=""; DPID=""
cleanup() {
    set +e
    [[ -n "$DPID" ]] && kill "$DPID" 2>/dev/null
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

DPASS="wipe-now"; SOCK="$WORK/run/control.sock"

hr "configure the shared duress passphrase + a scoped daemon"
export DURESSD_CFGDIR="$WORK/cfg" DURESSD_LIBDIR="$REPO/src" \
       DURESSD_RUNDIR="$WORK/run" DURESSD_SOCKET="$SOCK" DURESSD_NO_POWEROFF=1
mkdir -p "$WORK/cfg" "$WORK/run"
truncate -s 48M "$WORK/scratch.img"
LOOP="$(losetup -Pf --show "$WORK/scratch.img")"
printf '%s' diskpass | cryptsetup luksFormat --type luks2 --batch-mode \
    --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file=- "$LOOP"
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
export DURESSD_TARGET_DEVICES="$LOOP"
bash src/daemon & DPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$SOCK" ]] && break; sleep 0.5; done
[[ -S "$SOCK" ]] || fail "scoped daemon socket did not come up"
pass "scoped daemon + shared duress passphrase ready"

hr "PAM hook: a NON-duress password must NOT wipe"
printf '%s' "not-the-duress-password" | DURESSD_BIN="$REPO/src/cli" bash pam/pam-duress
sleep 2
cryptsetup isLuks "$LOOP" || fail "a wrong password wiped the disk — it must not"
pass "non-duress password left the disk intact"

hr "PAM hook: the DURESS password fires the wipe"
export DURESSD_DEBUG_LOG="$WORK/trig.log"; : > "$WORK/trig.log"
printf '%s' "$DPASS" | DURESSD_BIN="$REPO/src/cli" bash pam/pam-duress
# pam-duress detaches the trigger (login is never delayed); poll for the wipe.
for _ in 1 2 3 4 5 6 7 8; do cryptsetup isLuks "$LOOP" 2>/dev/null || break; sleep 1; done
if cryptsetup isLuks "$LOOP" 2>/dev/null; then
    echo "  --- DEBUG pam-duress trigger output ---"
    tr -cd '[:print:]\n\t' < "$WORK/trig.log" | tail -20 | sed 's/^/    | /'
    echo "  --- DEBUG daemon alive=$(kill -0 "$DPID" 2>/dev/null && echo yes || echo no) socket=$([[ -S "$SOCK" ]] && echo yes || echo no) setsid=$(command -v setsid || echo MISSING) ---"
    echo "  --- DEBUG direct foreground trigger: ---"
    DURESSD_PASS="$DPASS" bash src/cli trigger-remote </dev/null 2>&1 | tr -cd '[:print:]\n' | tail -8 | sed 's/^/    | /'
    echo "  --- after direct: $(cryptsetup isLuks "$LOOP" 2>/dev/null && echo STILL-LUKS || echo WIPED) ---"
    fail "duress password did not wipe the disk"
fi
pass "duress password fired the wipe (scratch disk destroyed)"

hr "install-login-trigger wires the pam_exec hook into the auth stack"
: > "$WORK/cfg/passphrase.luks.exists" ; : > "$WORK/cfg/passphrase.luks"
printf 'auth required pam_unix.so\n' > "$WORK/pam-test"
DURESSD_PAM_FILE="$WORK/pam-test" DURESSD_PAM_SRC="$REPO/pam" DURESSD_LIBDIR="$WORK/lib" \
    bash src/cli install-login-trigger >/dev/null 2>&1 || fail "install-login-trigger failed"
grep -q 'auth optional pam_exec.so expose_authtok quiet' "$WORK/pam-test" \
    || fail "pam_exec hook was not added to the auth stack"
[[ -x "$WORK/lib/pam-duress" ]] || fail "pam-duress hook was not installed"
pass "install-login-trigger added the optional pam_exec hook"

hr "PAM LOGIN DURESS TRIGGER END-TO-END PASSED"
