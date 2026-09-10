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

# ── require_systemd: refuse cleanly on the WRONG system ──────────────────────
@test "require_systemd errors when systemd is not the init (no /run/systemd/system)" {
    export DURESSD_SYSTEMD_DIR="$DURESSD_TESTROOT/no-systemd"     # does not exist
    run require_systemd
    assert_fail
    assert_output_contains "requires systemd"
}

@test "require_systemd passes when systemd is present" {
    export DURESSD_SYSTEMD_DIR="$DURESSD_TESTROOT/systemd"; install -d "$DURESSD_SYSTEMD_DIR"
    run require_systemd                                            # systemctl is stubbed
    assert_ok
}

# ── check_deps: error on a missing required tool, with a package hint ─────────
@test "check_deps errors (with a package name) when a required tool is missing" {
    rm -f "$STUB_BIN/socat"                                       # drop one required tool
    PATH="$STUB_BIN" run check_deps                                # builtins only; no sub-bash
    assert_fail
    assert_output_contains "Missing required tools"
    assert_output_contains "socat"
}

# ── cmd_install: full flow into a temp root ──────────────────────────────────
@test "cmd_install ABORTS on a non-systemd host BEFORE copying anything" {
    export DURESSD_SKIP_PRIVCHECK=1
    export DURESSD_SYSTEMD_DIR="$DURESSD_TESTROOT/no-systemd"      # not systemd
    export BINDIR="$DURESSD_TESTROOT/bin"
    run cmd_install
    assert_fail
    assert_output_contains "requires systemd"
    [ ! -e "$BINDIR/duressd" ]                                     # nothing installed
}

@test "cmd_install installs all components with correct modes and enables the service" {
    export DURESSD_SKIP_PRIVCHECK=1
    export DURESSD_SYSTEMD_DIR="$DURESSD_TESTROOT/sd"; install -d "$DURESSD_SYSTEMD_DIR"
    export LIBDIR="$DURESSD_TESTROOT/lib/duressd" BINDIR="$DURESSD_TESTROOT/bin" \
           UNITDIR="$DURESSD_TESTROOT/unit" CFGDIR="$DURESSD_TESTROOT/cfg" \
           ALIASES="$DURESSD_TESTROOT/aliases.sh" FISH_ALIASES="$DURESSD_TESTROOT/fish.fish"
    run cmd_install
    assert_ok
    [ -x "$LIBDIR/daemon" ] && [ -x "$LIBDIR/handler" ] && [ -x "$BINDIR/duressd" ]
    [ -f "$UNITDIR/duressd.service" ]
    [ -x "$LIBDIR/initramfs/duress-runtime-hook" ]     # boot-hook templates shipped
    [ "$(stat -c %a "$CFGDIR")" = 700 ]                # config dir root-only
    stub_called_with systemctl "enable --now duressd.service"
}
