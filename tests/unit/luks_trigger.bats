#!/usr/bin/env bats
# Unit tests for install-luks-trigger — the boot-time LUKS duress hook installer
# (the "hook into an existing Arch system" path) + its BOOT_WIPE_DEPTH wiring.

load '../lib/common'

setup() {
    setup_stubs
    load_cli
    export DURESSD_CFGDIR="$DURESSD_TESTROOT/cfg"
    export DURESSD_INITRAMFS_SRC="$REPO_ROOT/initramfs"     # the real hook templates
    export DURESSD_MKINITCPIO_CONF="$DURESSD_TESTROOT/mkinitcpio.conf"
    export DURESSD_INITCPIO_INSTALL="$DURESSD_TESTROOT/initcpio-install"
    export DURESSD_INITCPIO_HOOKS="$DURESSD_TESTROOT/initcpio-hooks"
    export DURESSD_NO_MKINITCPIO=1                          # skip the real mkinitcpio -P
    install -d "$DURESSD_CFGDIR"
    : > "$DURESSD_CFGDIR/passphrase.luks"                   # pretend configured
    printf 'HOOKS=(base udev autodetect modconf block encrypt filesystems fsck)\n' \
        > "$DURESSD_MKINITCPIO_CONF"
}
teardown() { teardown_stubs; }

@test "install-luks-trigger refuses without a configured custom passphrase" {
    rm -f "$DURESSD_CFGDIR/passphrase.luks"
    run cmd_install_luks_trigger
    assert_fail
    assert_output_contains "No custom duress passphrase"
}

@test "install-luks-trigger installs both hooks and inserts 'duress' before 'encrypt'" {
    run cmd_install_luks_trigger
    assert_ok
    [ -f "$DURESSD_INITCPIO_INSTALL/duress" ]     # build hook
    [ -f "$DURESSD_INITCPIO_HOOKS/duress" ]        # runtime hook
    run grep -E 'HOOKS=.*duress encrypt' "$DURESSD_MKINITCPIO_CONF"
    assert_ok                                       # duress placed immediately before encrypt
}

@test "install-luks-trigger is idempotent on the HOOKS line" {
    cmd_install_luks_trigger >/dev/null 2>&1
    cmd_install_luks_trigger >/dev/null 2>&1
    # 'duress' must appear exactly once in the HOOKS line
    run bash -c "grep -oE 'duress' '$DURESSD_MKINITCPIO_CONF' | wc -l"
    assert_output_contains "1"
}

@test "default depth is 'traces', recorded in the config" {
    run cmd_install_luks_trigger
    assert_ok
    run grep -E '^BOOT_WIPE_DEPTH=traces$' "$DURESSD_CFGDIR/config"
    assert_ok
}

@test "--depth header records BOOT_WIPE_DEPTH=header" {
    run cmd_install_luks_trigger --depth header
    assert_ok
    run grep -E '^BOOT_WIPE_DEPTH=header$' "$DURESSD_CFGDIR/config"
    assert_ok
}

@test "--depth full records BOOT_WIPE_DEPTH=full" {
    run cmd_install_luks_trigger --depth full
    assert_ok
    run grep -E '^BOOT_WIPE_DEPTH=full$' "$DURESSD_CFGDIR/config"
    assert_ok
}

@test "--depth REPLACES an existing BOOT_WIPE_DEPTH line (no duplicate)" {
    printf 'CONFIGURED=true\nBOOT_WIPE_DEPTH=full\n' > "$DURESSD_CFGDIR/config"
    run cmd_install_luks_trigger --depth header
    assert_ok
    run bash -c "grep -c '^BOOT_WIPE_DEPTH=' '$DURESSD_CFGDIR/config'"
    assert_output_contains "1"                      # exactly one line
    run grep -E '^BOOT_WIPE_DEPTH=header$' "$DURESSD_CFGDIR/config"
    assert_ok
}

@test "install-luks-trigger rejects an invalid --depth" {
    run cmd_install_luks_trigger --depth bogus
    assert_fail
    assert_output_contains "must be header|traces|full"
}
