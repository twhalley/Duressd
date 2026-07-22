#!/usr/bin/env bats
# Unit tests for config file generation via cmd_configure.

load '../lib/common'

setup()    { setup_stubs; load_handler; }
teardown() { teardown_stubs; }

b64() { printf '%s' "$1" | base64 -w0; }

@test "cmd_configure (custom) writes a correct config file" {
    argv=( "$(b64 lukspass)" "$(b64 custom)" "$(b64 duresspass)" false false 5 )
    run cmd_configure
    assert_ok
    [ -f "$DURESSD_CFGDIR/config" ]
    run cat "$DURESSD_CFGDIR/config"
    assert_output_contains "CONFIGURED=true"
    assert_output_contains "PASSWORD_TYPE=custom"
    assert_output_contains "OVERWRITE_LUKS_HEADER=false"
    assert_output_contains "WIPE_FULL_DEVICE=false"
    assert_output_contains "WIPE_COUNTDOWN=5"
    # Custom type creates the Argon2id keyslot container.
    stub_called_with cryptsetup luksFormat
}

@test "cmd_configure (custom) has no VERIFY_DEVICE (no scan needed)" {
    argv=( "$(b64 x)" "$(b64 custom)" "$(b64 secret)" false false 0 )
    run cmd_configure
    assert_ok
    run cat "$DURESSD_CFGDIR/config"
    assert_output_contains "VERIFY_DEVICE="
    refute_output_contains "VERIFY_DEVICE=/dev"
}

@test "cmd_configure (luks) records the device the passphrase unlocks" {
    export STUB_LSBLK_NAME=$'/dev/sda1\n/dev/sda2'
    export STUB_LUKS_DEVICES="/dev/sda2"
    export STUB_VERIFY_OK_DEVICES="/dev/sda2"
    argv=( "$(b64 mylukskey)" "$(b64 luks)" "$(b64 '')" true false 0 )
    run cmd_configure
    assert_ok
    run cat "$DURESSD_CFGDIR/config"
    assert_output_contains "PASSWORD_TYPE=luks"
    assert_output_contains "VERIFY_DEVICE=/dev/sda2"
    assert_output_contains "OVERWRITE_LUKS_HEADER=true"
}

@test "cmd_configure (luks) fails when the passphrase unlocks nothing" {
    export STUB_LSBLK_NAME=$'/dev/sda1\n/dev/sda2'
    export STUB_LUKS_DEVICES="/dev/sda2"
    export STUB_VERIFY_OK_DEVICES="/dev/nonexistent"
    argv=( "$(b64 wrongkey)" "$(b64 luks)" "$(b64 '')" false false 0 )
    run cmd_configure
    assert_fail
    assert_output_contains "did not match"
}
