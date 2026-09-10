#!/usr/bin/env bats
# Unit tests for install.sh — previously ZERO automated coverage. Focus on the
# security-critical secure_erase_oracle() (uninstall must erase the Argon2id KDF
# material, not just delete the file) and the pure _pkg_for() dependency map.

load '../lib/common'

setup() {
    setup_stubs
    export DURESSD_LIB_ONLY=1
    # shellcheck disable=SC1090
    source "$REPO_ROOT/install.sh"
}
teardown() { teardown_stubs; }

# ── secure_erase_oracle (security-critical) ──────────────────────────────────
@test "secure_erase_oracle erases the LUKS keyslots THEN shreds the oracle" {
    d="$(mktemp -d)"; : > "$d/passphrase.luks"
    run secure_erase_oracle "$d"
    assert_ok
    stub_called_with cryptsetup "luksErase --batch-mode $d/passphrase.luks"
    stub_called_with shred "-u $d/passphrase.luks"
    rm -rf "$d"
}

@test "secure_erase_oracle is a safe no-op when no oracle is present" {
    d="$(mktemp -d)"
    run secure_erase_oracle "$d"
    assert_ok
    run grep -E 'luksErase' "$DURESSD_STUB_LOG"
    assert_fail                              # nothing erased, no error
    rm -rf "$d"
}

# ── _pkg_for dependency map (pure) ───────────────────────────────────────────
@test "_pkg_for maps same-named tools to themselves" {
    [ "$(_pkg_for cryptsetup debian)" = cryptsetup ]
    [ "$(_pkg_for socat arch)"        = socat ]
}

@test "_pkg_for maps util-linux tools correctly per family" {
    [ "$(_pkg_for wipefs debian)" = util-linux ]
    [ "$(_pkg_for lsblk arch)"    = util-linux ]
}

@test "_pkg_for knows the dmsetup package differs by family" {
    [ "$(_pkg_for dmsetup debian)" = dmsetup ]          # own package on Debian
    [ "$(_pkg_for dmsetup arch)"   = device-mapper ]    # device-mapper on Arch
    [ "$(_pkg_for dmsetup alpine)" = lvm2 ]             # lvm2 on Alpine
}

@test "_pkg_for uses Gentoo atoms" {
    [ "$(_pkg_for cryptsetup gentoo)" = sys-fs/cryptsetup ]
    [ "$(_pkg_for dd gentoo)"         = sys-apps/coreutils ]
}
