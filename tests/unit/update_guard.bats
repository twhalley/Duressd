#!/usr/bin/env bats
# Unit tests for the pacman update-survival guard (src/duressd-update-guard). It
# runs as a PostTransaction pacman hook after linux/mkinitcpio upgrades and must:
#   • stay silent + exit 0 when the boot hook isn't installed (nothing to guard),
#   • stay silent when the boot hook is installed AND still armed,
#   • WARN when a .pacnew merge dropped 'duress' from HOOKS,
#   • ALWAYS exit 0 — it must never fail or delay a pacman transaction.

load '../lib/common'

GUARD="$REPO_ROOT/src/duressd-update-guard"

setup() {
    WORK="$(mktemp -d)"
    export DURESSD_INITCPIO_INSTALL="$WORK/initcpio-install"; mkdir -p "$DURESSD_INITCPIO_INSTALL"
    export DURESSD_MKINITCPIO_CONF="$WORK/mkinitcpio.conf"
    export DURESSD_INITRAMFS_IMG="$WORK/initramfs.img"   # absent → lsinitcpio check skipped
}
teardown() { rm -rf "$WORK"; }

@test "guard is silent + exits 0 when the boot hook is NOT installed" {
    printf 'HOOKS=(base udev block encrypt filesystems)\n' > "$DURESSD_MKINITCPIO_CONF"
    run bash "$GUARD"
    assert_ok
    [ -z "$output" ]                       # nothing installed → no noise
}

@test "guard is silent when the boot hook is installed AND still armed" {
    : > "$DURESSD_INITCPIO_INSTALL/duress"                 # boot hook installed
    printf 'HOOKS=(base udev block duress encrypt filesystems)\n' > "$DURESSD_MKINITCPIO_CONF"
    run bash "$GUARD"
    assert_ok
    refute_output_contains "DISARMED"
}

@test "guard WARNS (still exits 0) when a .pacnew dropped 'duress' from HOOKS" {
    : > "$DURESSD_INITCPIO_INSTALL/duress"                 # was installed
    printf 'HOOKS=(base udev block encrypt filesystems)\n' > "$DURESSD_MKINITCPIO_CONF"   # duress gone
    run bash "$GUARD"
    assert_ok                              # MUST NOT fail the pacman transaction
    assert_output_contains "DISARMED"
    assert_output_contains "mkinitcpio -P"
}

@test "guard never fails even if mkinitcpio.conf is missing entirely" {
    : > "$DURESSD_INITCPIO_INSTALL/duress"
    rm -f "$DURESSD_MKINITCPIO_CONF"
    run bash "$GUARD"
    assert_ok
    assert_output_contains "DISARMED"
}
