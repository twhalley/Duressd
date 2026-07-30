#!/usr/bin/env bash
# SSH-over-Tor duress trigger — FULL over-Tor end to end, inside the VM.
#
# Uses the real `install-ssh-trigger --tor` to configure a v3, client-authorized
# onion service for the local sshd, boots tor, waits for the onion address +
# network bootstrap, then fires the wipe of a scratch encrypted disk OVER TOR
# (torsocks ssh + onion client auth). Proves the covert remote kill switch.
#
# Needs network (Tor). SKIPS cleanly (exit 0) if tor/torsocks/sshd are absent or
# Tor can't bootstrap. Safe: the daemon is scoped to the scratch loop and
# poweroff is suppressed, so the trigger can only ever destroy the throwaway disk.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$REPO" || exit 1
hr()   { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
pass() { printf '  \033[1;32m✔  %s\033[0m\n' "$*"; }
skip() { printf '  \033[1;33m↷  %s\033[0m\n' "$*"; exit 0; }
fail() { printf '  \033[1;31m✘  FAIL: %s\033[0m\n' "$*"; exit 1; }

SSHD=""
for c in /usr/bin/sshd /usr/sbin/sshd; do [[ -x "$c" ]] && { SSHD="$c"; break; }; done
[[ -n "$SSHD" ]]              || skip "sshd not installed — skipping SSH-over-Tor test"
command -v tor      >/dev/null || skip "tor not installed — skipping SSH-over-Tor test"
command -v torsocks >/dev/null || skip "torsocks not installed — skipping SSH-over-Tor test"
command -v ssh      >/dev/null || skip "ssh client not available"

WORK="$(mktemp -d)"; LOOP=""; DPID=""; SSHDPID=""; TORPID=""
cleanup() {
    set +e
    for p in "$TORPID" "$SSHDPID" "$DPID"; do [[ -n "$p" ]] && kill "$p" 2>/dev/null; done
    [[ -n "$LOOP" ]] && losetup -d "$LOOP" 2>/dev/null
    rm -rf "$WORK"
}
trap cleanup EXIT

DPASS="wipe-now"; SSHPORT=2022; SOCKS=9050

hr "scratch encrypted disk + a SCOPED daemon on a private socket"
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

hr "configuring the onion service + client auth (real install-ssh-trigger --tor)"
ssh-keygen -t ed25519 -N '' -C duress -f "$WORK/duresskey" >/dev/null
export DURESSD_TOR_HSDIR="$WORK/hs" DURESSD_TORRC="$WORK/torrc" \
       DURESSD_SSH_PORT="$SSHPORT" DURESSD_TOR_USER="" DURESSD_NO_TOR_RESTART=1
bash src/cli install-ssh-trigger --pubkey "$WORK/duresskey.pub" \
    --authorized-keys "$WORK/authorized_keys" --tor >/dev/null 2>&1 \
    || fail "install-ssh-trigger --tor failed"
grep -q "HiddenServiceDir $WORK/hs" "$WORK/torrc"                  || fail "onion config not written"
grep -q "descriptor:x25519:" "$WORK/hs/authorized_clients/duress.auth" || fail "client-auth pubkey missing"
[[ -s "$DURESSD_CFGDIR/tor-client-auth.private" ]]                 || fail "client-auth private not produced"
# Point the forced command at our private scoped socket (test accommodation).
sed -i "s#command=\"duressd trigger-remote\"#command=\"env DURESSD_SOCKET=$SOCK duressd trigger-remote\"#" \
    "$WORK/authorized_keys"
pass "onion service + v3 client authorization configured"

hr "starting sshd on 127.0.0.1:$SSHPORT"
ssh-keygen -t ed25519 -N '' -f "$WORK/ssh_host_ed25519_key" >/dev/null
cat > "$WORK/sshd_config" <<SSHD
Port $SSHPORT
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
pass "sshd up"

hr "booting tor + publishing the onion service (needs network)"
install -d -m 0700 "$WORK/onion_auth" "$WORK/tordata"
cat >> "$WORK/torrc" <<TORRC
SocksPort 127.0.0.1:$SOCKS
DataDirectory $WORK/tordata
ClientOnionAuthDir $WORK/onion_auth
Log notice file $WORK/tor.log
TORRC
tor --hush -f "$WORK/torrc" >/dev/null 2>&1 & TORPID=$!

onion=""
for _ in $(seq 1 30); do
    [[ -s "$WORK/hs/hostname" ]] && { onion="$(cat "$WORK/hs/hostname")"; break; }; sleep 1
done
[[ -n "$onion" ]] || skip "tor did not generate an onion address (tor failed to start?)"

# The onion address is only known now, so write the CLIENT auth_private with it
# and reload tor so it can decrypt the (client-authorized) descriptor.
priv="$(awk -F: '{print $NF}' "$DURESSD_CFGDIR/tor-client-auth.private")"
printf '%s:descriptor:x25519:%s\n' "${onion%.onion}" "$priv" \
    > "$WORK/onion_auth/${onion%.onion}.auth_private"
chmod 600 "$WORK/onion_auth/${onion%.onion}.auth_private"
kill -HUP "$TORPID" 2>/dev/null; sleep 2

booted=0
for _ in $(seq 1 150); do
    grep -q "Bootstrapped 100%" "$WORK/tor.log" 2>/dev/null && { booted=1; break; }; sleep 1
done
[[ "$booted" == 1 ]] || skip "tor did not bootstrap (no network / Tor blocked) — over-Tor trigger skipped"
pass "tor bootstrapped; onion = $onion"

hr "firing the duress trigger OVER TOR (torsocks ssh + onion client auth)"
export TORSOCKS_TOR_ADDRESS=127.0.0.1 TORSOCKS_TOR_PORT="$SOCKS"
printf '%s' "$DPASS" | torsocks ssh -i "$WORK/duresskey" -T \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ConnectTimeout=90 "root@$onion" || true
sleep 2

hr "verifying the over-Tor SSH trigger destroyed the scratch disk"
if cryptsetup isLuks "$LOOP" 2>/dev/null; then
    fail "scratch disk still carries a LUKS header — the over-Tor trigger did not wipe it"
fi
pass "over-Tor SSH duress trigger wiped the scratch disk"

hr "SSH-OVER-TOR DURESS TRIGGER END-TO-END PASSED — client-authed onion → real wipe"
