#!/usr/bin/env bats
# Unit tests for passphrase verification dispatch.

load '../lib/common'

setup()    { setup_stubs; load_handler; }
teardown() { teardown_stubs; }

@test "verify_passphrase custom: succeeds when cryptsetup accepts the key" {
    export PASSWORD_TYPE=custom
    export STUB_VERIFY_RC=0
    : >"$DURESSD_CFGDIR/passphrase.luks"
    run verify_passphrase "secret"
    assert_ok
}

@test "verify_passphrase custom: fails when cryptsetup rejects the key" {
    export PASSWORD_TYPE=custom
    export STUB_VERIFY_RC=1
    : >"$DURESSD_CFGDIR/passphrase.luks"
    run verify_passphrase "wrong"
    assert_fail
}

@test "verify_passphrase custom: fails when the keyslot container is missing" {
    export PASSWORD_TYPE=custom
    export STUB_VERIFY_RC=0
    rm -f "$DURESSD_CFGDIR/passphrase.luks"
    run verify_passphrase "secret"
    assert_fail
}

@test "verify_passphrase luks: succeeds against the stored verify device" {
    export PASSWORD_TYPE=luks
    export VERIFY_DEVICE=/dev/sda2
    export STUB_VERIFY_OK_DEVICES="/dev/sda2"
    run verify_passphrase "secret"
    assert_ok
}

@test "verify_passphrase luks: fails for a wrong passphrase" {
    export PASSWORD_TYPE=luks
    export VERIFY_DEVICE=/dev/sda2
    export STUB_VERIFY_OK_DEVICES="/dev/other"
    run verify_passphrase "wrong"
    assert_fail
}

@test "verify_passphrase: unknown password type is rejected" {
    export PASSWORD_TYPE=bogus
    run verify_passphrase "whatever"
    assert_fail
}
