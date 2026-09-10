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

@test "install-luks-trigger refuses cleanly on a non-mkinitcpio system (wrong distro)" {
    rm -f "$STUB_BIN/mkinitcpio"                # simulate a system without mkinitcpio
    PATH="$STUB_BIN" run cmd_install_luks_trigger
    assert_fail
    assert_output_contains "mkinitcpio not found"
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

# ── uninstall ─────────────────────────────────────────────────────────────────
@test "--uninstall removes 'duress' from HOOKS wherever it sits + deletes the hook files" {
    # duress placed in the MIDDLE (not next to encrypt) — position-independent removal.
    printf 'HOOKS=(base udev duress autodetect block encrypt filesystems fsck)\n' \
        > "$DURESSD_MKINITCPIO_CONF"
    install -Dm755 /dev/null "$DURESSD_INITCPIO_INSTALL/duress"
    install -Dm755 /dev/null "$DURESSD_INITCPIO_HOOKS/duress"
    run cmd_install_luks_trigger --uninstall
    assert_ok
    # 'duress' gone, the other hooks intact and in order
    run grep -E '^HOOKS=\(base udev autodetect block encrypt filesystems fsck\)$' "$DURESSD_MKINITCPIO_CONF"
    assert_ok
    [ ! -e "$DURESSD_INITCPIO_INSTALL/duress" ]
    [ ! -e "$DURESSD_INITCPIO_HOOKS/duress" ]
}

@test "--uninstall is idempotent (no duress in HOOKS → clean no-op)" {
    printf 'HOOKS=(base udev block encrypt filesystems fsck)\n' > "$DURESSD_MKINITCPIO_CONF"
    run cmd_install_luks_trigger --uninstall
    assert_ok
    assert_output_contains "nothing to remove"
    run grep -E '^HOOKS=\(base udev block encrypt filesystems fsck\)$' "$DURESSD_MKINITCPIO_CONF"
    assert_ok                                   # HOOKS line unchanged
}

@test "install then --uninstall round-trips the HOOKS line back to the original" {
    printf 'HOOKS=(base udev autodetect modconf block encrypt filesystems fsck)\n' \
        > "$DURESSD_MKINITCPIO_CONF"
    orig="$(cat "$DURESSD_MKINITCPIO_CONF")"
    cmd_install_luks_trigger            >/dev/null 2>&1   # adds duress before encrypt
    cmd_install_luks_trigger --uninstall >/dev/null 2>&1  # removes it
    [ "$(cat "$DURESSD_MKINITCPIO_CONF")" = "$orig" ]
}
