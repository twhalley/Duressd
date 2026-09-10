#!/usr/bin/env bats
# Unit tests for the passphrase-gated config mutations: cmd_change_passphrase and
# cmd_unconfigure. Both MUST verify the current passphrase before destroying the
# Argon2id oracle — a broken gate would let anyone wipe the duress key or lock the
# owner out.

load '../lib/common'

b64() { printf '%s' "$1" | base64 -w0; }

setup() {
    setup_stubs
    load_handler
    # A configured custom-passphrase system: config + oracle present.
    printf 'CONFIGURED=true\nPASSWORD_TYPE=custom\nVERIFY_DEVICE=\n' > "$DURESSD_CFGDIR/config"
    : > "$DURESSD_CFGDIR/passphrase.luks"
}
teardown() { teardown_stubs; }

# ── cmd_change_passphrase ─────────────────────────────────────────────────────
@test "change_passphrase REFUSES when the current passphrase is wrong (no keyslot touched)" {
    export STUB_VERIFY_RC=1                  # verify_passphrase fails
    argv=( "$(b64 wrongold)" "$(b64 newpassphrase)" )
    run cmd_change_passphrase
    assert_fail
    assert_output_contains "Current passphrase incorrect"
    run grep -E 'luksErase|luksFormat' "$DURESSD_STUB_LOG"
    assert_fail                              # neither destroy nor create ran
}

@test "change_passphrase replaces the keyslot when the current passphrase is correct" {
    export STUB_VERIFY_RC=0
    argv=( "$(b64 oldpass)" "$(b64 newpassphrase)" )
    run cmd_change_passphrase
    assert_ok
    assert_output_contains "changed successfully"
    stub_called_with cryptsetup luksErase     # old keyslot destroyed
    stub_called_with cryptsetup luksFormat    # new keyslot created
}

@test "change_passphrase refuses for password type 'luks' (points at luksChangeKey)" {
    printf 'CONFIGURED=true\nPASSWORD_TYPE=luks\nVERIFY_DEVICE=/dev/sda2\n' > "$DURESSD_CFGDIR/config"
    argv=( "$(b64 a)" "$(b64 bbbbbbbb)" )
    run cmd_change_passphrase
    assert_fail
    assert_output_contains "luksChangeKey"
}

# ── cmd_unconfigure ───────────────────────────────────────────────────────────
@test "unconfigure REFUSES a wrong passphrase and does NOT erase anything" {
    export STUB_VERIFY_RC=1
    argv=( "$(b64 wrong)" )
    run cmd_unconfigure
    assert_fail
    assert_output_contains "Passphrase incorrect"
    [ -f "$DURESSD_CFGDIR/config" ]           # config still present
    run grep -E 'luksErase' "$DURESSD_STUB_LOG"
    assert_fail                               # oracle not erased
}

@test "unconfigure erases the oracle + config when the passphrase is correct" {
    export STUB_VERIFY_RC=0
    argv=( "$(b64 rightpass)" )
    run cmd_unconfigure
    assert_ok
    assert_output_contains "Configuration removed"
    stub_called_with cryptsetup luksErase     # oracle keyslot erased
    [ ! -f "$DURESSD_CFGDIR/config" ]          # config removed
}
