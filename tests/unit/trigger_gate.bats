#!/usr/bin/env bats
# SECURITY: the destructive wipe MUST be gated on passphrase verification.
# run_trigger verifies BEFORE it wipes (handler: `verify_passphrase … || die`),
# so a wrong passphrase must destroy nothing. verify.bats covers the verifier in
# isolation; this covers the whole TRIGGER path — the property that actually
# matters: wrong pass in → nothing wiped.

load '../lib/common'

setup() {
    setup_stubs; load_handler
    export PASSWORD_TYPE=custom
    : > "$DURESSD_CFGDIR/passphrase.luks"
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
}
teardown() { teardown_stubs; }

@test "security: run_trigger REFUSES a wrong passphrase and wipes NOTHING" {
    export STUB_VERIFY_RC=1                          # cryptsetup --test-passphrase rejects
    argv=( "$(printf '%s' wrong-pass | base64 -w0)" )
    run run_trigger
    assert_fail
    assert_output_contains "Passphrase incorrect"
    refute_output_contains "starting destructive wipe"
    # the wipe engine must NEVER have run luksErase
    run grep -E '^cryptsetup'$'\t''.*luksErase' "$DURESSD_STUB_LOG"
    assert_fail
}

@test "security: a wrong passphrase never reaches the lock/countdown/wipe stages" {
    export STUB_VERIFY_RC=1
    argv=( "$(printf '%s' nope | base64 -w0)" )
    run run_trigger
    assert_fail
    refute_output_contains "Passphrase accepted"     # the go-ahead line, post-verify
}

@test "security: run_trigger with the CORRECT passphrase starts the wipe (luksErase runs)" {
    export STUB_VERIFY_RC=0                          # cryptsetup accepts
    export STUB_LSBLK_NAME="/dev/sda2" STUB_LUKS_DEVICES="/dev/sda2"
    export DURESSD_NO_POWEROFF=1                     # don't power off the test host
    argv=( "$(printf '%s' right-pass | base64 -w0)" )
    run run_trigger
    assert_output_contains "starting destructive wipe"
    grep -qE '^cryptsetup'$'\t''.*luksErase' "$DURESSD_STUB_LOG"
}
