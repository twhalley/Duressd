#!/usr/bin/env bats
# Unit tests for the SSH-over-Tor onion setup plumbing (install-ssh-trigger
# --tor). The x25519 client-auth crypto is exercised for real in the VM
# (tests/vm/tor-e2e.sh); here openssl is stubbed, so we assert the config and
# file plumbing — the onion service block, the authorized_clients entry, and the
# operator's client-auth private file.

load '../lib/common'

setup() {
    setup_stubs
    load_cli
    export DURESSD_TOR_HSDIR="$DURESSD_TESTROOT/hs" \
           DURESSD_TORRC="$DURESSD_TESTROOT/torrc" \
           DURESSD_CFGDIR="$DURESSD_TESTROOT/cfg" \
           DURESSD_SSH_PORT=2222 DURESSD_TOR_USER="" DURESSD_NO_TOR_RESTART=1
    # --tor now refuses when SSH password auth is on (it exposes the whole sshd);
    # the realistic precondition for using --tor is password auth OFF.
    export DURESSD_SSHD_PASSWORD_AUTH=no
    # Pin the forced-command binary so the "command=..." assertion is deterministic
    # whether or not a real duressd is installed (in the VM it IS → absolute path).
    export DURESSD_SELF_BIN=duressd
    PUB="$(mktemp)"; echo "ssh-ed25519 AAAAFAKEKEY duress" > "$PUB"
}
teardown() { rm -f "${PUB:-}"; teardown_stubs; }

@test "install-ssh-trigger --tor writes a v3 onion service config" {
    run cmd_install_ssh_trigger --pubkey "$PUB" \
        --authorized-keys "$DURESSD_TESTROOT/ak" --tor
    assert_ok
    run cat "$DURESSD_TORRC"
    assert_output_contains "HiddenServiceDir $DURESSD_TESTROOT/hs"
    assert_output_contains "HiddenServiceVersion 3"
    assert_output_contains "HiddenServicePort 22 127.0.0.1:2222"
}

@test "install-ssh-trigger --tor installs a client-authorization entry" {
    run cmd_install_ssh_trigger --pubkey "$PUB" \
        --authorized-keys "$DURESSD_TESTROOT/ak" --tor
    assert_ok
    run cat "$DURESSD_TESTROOT/hs/authorized_clients/duress.auth"
    assert_output_contains "descriptor:x25519:"
    [ -f "$DURESSD_CFGDIR/tor-client-auth.private" ]
}

@test "install-ssh-trigger --tor still installs the SSH forced-command key" {
    run cmd_install_ssh_trigger --pubkey "$PUB" \
        --authorized-keys "$DURESSD_TESTROOT/ak" --tor
    assert_ok
    run cat "$DURESSD_TESTROOT/ak"
    assert_output_contains 'command="duressd trigger-remote",restrict'
}

@test "install-ssh-trigger without --tor writes no onion config" {
    run cmd_install_ssh_trigger --pubkey "$PUB" --authorized-keys "$DURESSD_TESTROOT/ak"
    assert_ok
    [ ! -e "$DURESSD_TORRC" ]
}

# ── security properties of the onion service ─────────────────────────────────

@test "onion forwards ONLY the configured port, and ONLY to localhost" {
    run cmd_install_ssh_trigger --pubkey "$PUB" \
        --authorized-keys "$DURESSD_TESTROOT/ak" --tor
    assert_ok
    # Exactly one forwarded port — nothing else is reachable via the onion.
    [ "$(grep -c '^HiddenServicePort' "$DURESSD_TORRC")" -eq 1 ]
    # ssh (22) → the LOCAL sshd only; never bound to a routable address.
    run cat "$DURESSD_TORRC"
    assert_output_contains "HiddenServicePort 22 127.0.0.1:2222"
    refute_output_contains "0.0.0.0"
}

@test "onion is v3 and REQUIRES client authorization" {
    run cmd_install_ssh_trigger --pubkey "$PUB" \
        --authorized-keys "$DURESSD_TESTROOT/ak" --tor
    assert_ok
    # v3 (client-auth is a v3 feature; v2 is insecure/removed).
    run cat "$DURESSD_TORRC"
    assert_output_contains "HiddenServiceVersion 3"
    # A populated authorized_clients/ dir makes Tor ENFORCE client auth: only a
    # holder of the matching x25519 private key can reach the service at all.
    [ -s "$DURESSD_TESTROOT/hs/authorized_clients/duress.auth" ]
    run cat "$DURESSD_TESTROOT/hs/authorized_clients/duress.auth"
    assert_output_contains "descriptor:x25519:"
    # Exactly one authorized client entry (no stray/extra authorizations).
    [ "$(find "$DURESSD_TESTROOT/hs/authorized_clients" -name '*.auth' | wc -l)" -eq 1 ]
}

@test "onion client-auth PRIVATE key is stored 0600" {
    run cmd_install_ssh_trigger --pubkey "$PUB" \
        --authorized-keys "$DURESSD_TESTROOT/ak" --tor
    assert_ok
    [ -f "$DURESSD_CFGDIR/tor-client-auth.private" ]
    [ "$(stat -c '%a' "$DURESSD_CFGDIR/tor-client-auth.private")" = "600" ]
}
