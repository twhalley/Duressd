#!/usr/bin/env bats
# Unit tests for initramfs/duress-install-hook build(): it must bake the correct
# BOOT_WIPE_DEPTH value into /duress-wipe-depth (read from the config), and default
# to `traces` when the key is absent. Previously only the default was ever baked
# (via make vm-golden); header/full were never exercised.

load '../lib/common'

setup() {
    CFG="$(mktemp -d)"
    export DURESSD_CFGDIR="$CFG"
    : > "$CFG/passphrase.luks"                 # oracle present (build() needs it)
    # Stub the mkinitcpio build API; capture what add_file bakes to /duress-wipe-depth.
    BAKED_DEPTH="<unset>"
    add_module()    { :; }
    add_binary()    { :; }
    add_runscript() { :; }
    error()         { printf 'ERROR: %s\n' "$*"; }
    add_file() { [ "$2" = "/duress-wipe-depth" ] && read -r BAKED_DEPTH < "$1"; return 0; }
    # shellcheck disable=SC1090
    source "$REPO_ROOT/initramfs/duress-install-hook"
}
teardown() { rm -rf "$CFG"; }

@test "no BOOT_WIPE_DEPTH in config → bakes the default 'traces'" {
    printf 'CONFIGURED=true\nPASSWORD_TYPE=custom\n' > "$CFG/config"
    build
    [ "$BAKED_DEPTH" = "traces" ]
}

@test "BOOT_WIPE_DEPTH=header is baked verbatim" {
    printf 'BOOT_WIPE_DEPTH=header\n' > "$CFG/config"
    build
    [ "$BAKED_DEPTH" = "header" ]
}

@test "BOOT_WIPE_DEPTH=full is baked verbatim" {
    printf 'BOOT_WIPE_DEPTH=full\n' > "$CFG/config"
    build
    [ "$BAKED_DEPTH" = "full" ]
}

@test "BOOT_WIPE_DEPTH=traces is baked verbatim" {
    printf 'BOOT_WIPE_DEPTH=traces\n' > "$CFG/config"
    build
    [ "$BAKED_DEPTH" = "traces" ]
}

@test "no config file at all → still defaults to 'traces'" {
    rm -f "$CFG/config"
    build
    [ "$BAKED_DEPTH" = "traces" ]
}

@test "build() fails cleanly when the oracle is missing" {
    rm -f "$CFG/passphrase.luks"
    run build
    assert_fail
    assert_output_contains "not found"
}
