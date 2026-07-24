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
