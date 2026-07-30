#!/usr/bin/env bash
# SSH duress trigger — end to end over a REAL sshd, inside the VM.
#
# Installs the duressd SSH forced-command key with the real `install-ssh-trigger`,
# starts sshd on 127.0.0.1, then connects with the duress key (passphrase over
# stdin) so the forced command `duressd trigger-remote` fires a REAL wipe of a
# scratch encrypted disk through the daemon — proving the remote kill switch.
#
# Safe: the daemon is SCOPED to the scratch loop and poweroff is suppressed, so
# even a fully successful trigger only destroys the throwaway disk. Skips cleanly
# if openssh is not installed.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$REPO" || exit 1
hr()   { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
pass() { printf '  \033[1;32m✔  %s\033[0m\n' "$*"; }
skip() { printf '  \033[1;33m↷  %s\033[0m\n' "$*"; exit 0; }
fail() { printf '  \033[1;31m✘  FAIL: %s\033[0m\n' "$*"; exit 1; }

SSHD=""
for c in /usr/bin/sshd /usr/sbin/sshd; do [[ -x "$c" ]] && { SSHD="$c"; break; }; done
[[ -n "$SSHD" ]]           || skip "sshd not installed — skipping SSH test (needs openssh)"
command -v ssh >/dev/null  || skip "ssh client not available"
command -v ssh-keygen >/dev/null || skip "ssh-keygen not available"

WORK="$(mktemp -d)"; LOOP=""; DPID=""; SSHDPID=""
cleanup() {
    set +e
    [[ -n "$SSHDPID" ]] && kill "$SSHDPID" 2>/dev/null
    [[ -n "$DPID" ]]    && kill "$DPID"    2>/dev/null
    [[ -n "$LOOP" ]]    && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

DPASS="wipe-now"; PORT="${SSH_E2E_PORT:-2022}"

hr "scratch encrypted disk + a SCOPED daemon on a private socket"
# Run a daemon SCOPED to the scratch loop on a PRIVATE socket (not the systemd-
# managed /run/duressd, whose RuntimeDirectory systemd removes out from under us
# on stop). The forced command is patched to target this socket, so it can only
# ever wipe the throwaway disk, never the VM.
truncate -s 48M "$WORK/scratch.img"
LOOP="$(losetup -Pf --show "$WORK/scratch.img")"
printf '%s' diskpass | cryptsetup luksFormat --type luks2 --batch-mode \
    --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file=- "$LOOP"
cryptsetup isLuks "$LOOP" || fail "scratch disk has no LUKS header"

SOCK="$WORK/run/control.sock"
export DURESSD_CFGDIR="$WORK/cfg" DURESSD_LIBDIR="$REPO/src" \
       DURESSD_RUNDIR="$WORK/run" DURESSD_SOCKET="$SOCK" \
       DURESSD_TARGET_DEVICES="$LOOP" DURESSD_NO_POWEROFF=1
mkdir -p "$DURESSD_CFGDIR" "$WORK/run"
dd if=/dev/zero of="$DURESSD_CFGDIR/passphrase.luks" bs=1M count=24 status=none
printf '%s' "$DPASS" | cryptsetup luksFormat --type luks2 --batch-mode \
    --pbkdf pbkdf2 --pbkdf-force-iterations 1000 --key-file=- "$DURESSD_CFGDIR/passphrase.luks"
cat > "$DURESSD_CFGDIR/config" <<CFG
CONFIGURED=true
PASSWORD_TYPE=custom
VERIFY_DEVICE=
OVERWRITE_LUKS_HEADER=false
WIPE_FULL_DEVICE=false
WIPE_BOOT_ARTIFACTS=false
WIPE_HARDWARE_KEYS=false
WIPE_COUNTDOWN=0
CFG
bash src/daemon & DPID=$!
for _ in 1 2 3 4 5 6 7 8 9 10; do [[ -S "$SOCK" ]] && break; sleep 0.5; done
[[ -S "$SOCK" ]] || fail "scoped daemon socket did not come up"
pass "scratch LUKS disk + scoped daemon ready (target: $LOOP, poweroff suppressed)"

hr "installing the duressd SSH forced-command key (real install-ssh-trigger)"
ssh-keygen -t ed25519 -N '' -C duress -f "$WORK/duresskey" >/dev/null
bash src/cli install-ssh-trigger --pubkey "$WORK/duresskey.pub" \
    --authorized-keys "$WORK/authorized_keys" >/dev/null 2>&1 \
    || fail "install-ssh-trigger failed"
grep -q 'command="duressd trigger-remote",restrict' "$WORK/authorized_keys" \
    || fail "forced-command entry was not installed"
# Point the forced command at our private scoped socket (test accommodation).
sed -i "s#command=\"duressd trigger-remote\"#command=\"env DURESSD_SOCKET=$SOCK duressd trigger-remote\"#" \
    "$WORK/authorized_keys"
pass "forced-command duress key installed in authorized_keys"

hr "starting sshd and firing the remote trigger over ssh"
ssh-keygen -t ed25519 -N '' -f "$WORK/ssh_host_ed25519_key" >/dev/null
cat > "$WORK/sshd_config" <<SSHD
Port $PORT
ListenAddress 127.0.0.1
HostKey $WORK/ssh_host_ed25519_key
PidFile $WORK/sshd.pid
AuthorizedKeysFile $WORK/authorized_keys
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
UsePAM no
StrictModes no
SSHD
"$SSHD" -f "$WORK/sshd_config" -D & SSHDPID=$!
sleep 1

# The duress key's forced command reads the passphrase from stdin and wipes.
printf '%s' "$DPASS" | ssh -i "$WORK/duresskey" -p "$PORT" -T \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=10 root@127.0.0.1 || true
sleep 1

hr "verifying the remote SSH trigger destroyed the scratch disk"
if cryptsetup isLuks "$LOOP" 2>/dev/null; then
    fail "scratch disk still carries a LUKS header — the SSH trigger did not wipe it"
fi
pass "SSH duress trigger wiped the scratch disk over a real ssh connection"

hr "SSH DURESS TRIGGER END-TO-END PASSED — forced-command key → sshd → real wipe"
