#!/usr/bin/env bats
# Unit tests for install-login-trigger (PAM login duress hook) config plumbing.
# The runtime behaviour (duress password → wipe) is exercised in the VM
# (tests/vm/pam-e2e.sh).

load '../lib/common'

setup() {
    setup_stubs
    load_cli
    export DURESSD_PAM_FILE="$DURESSD_TESTROOT/pam" \
           DURESSD_PAM_SRC="$REPO_ROOT/pam" \
           DURESSD_LIBDIR="$DURESSD_TESTROOT/lib" \
           DURESSD_SSHD_PASSWORD_AUTH=no    # key-only SSH by default (guard allows install)
    printf 'auth required pam_unix.so\n' > "$DURESSD_PAM_FILE"
}
teardown() { teardown_stubs; }

@test "install-login-trigger refuses without a configured custom passphrase" {
    run cmd_install_login_trigger
    assert_fail
    assert_output_contains "No custom duress passphrase"
}

@test "install-login-trigger adds an optional pam_exec hook and installs the script" {
    : > "$DURESSD_CFGDIR/passphrase.luks"     # pretend configured
    run cmd_install_login_trigger
    assert_ok
    run cat "$DURESSD_PAM_FILE"
    assert_output_contains "auth optional pam_exec.so expose_authtok quiet"
    assert_output_contains "pam_unix.so"      # original stack preserved
    [ -x "$DURESSD_TESTROOT/lib/pam-duress" ]
    [ -f "$DURESSD_PAM_FILE.duressd.bak" ]     # backup made
}

@test "install-login-trigger is idempotent" {
    : > "$DURESSD_CFGDIR/passphrase.luks"
    cmd_install_login_trigger >/dev/null 2>&1
    cmd_install_login_trigger >/dev/null 2>&1
    [ "$(grep -c 'pam_exec.so' "$DURESSD_PAM_FILE")" -eq 1 ]
}

@test "install-login-trigger REFUSES when SSH password auth is enabled (remote-wipe footgun)" {
    : > "$DURESSD_CFGDIR/passphrase.luks"
    export DURESSD_SSHD_PASSWORD_AUTH=yes
    run cmd_install_login_trigger
    assert_fail
    assert_output_contains "REFUSING"
    assert_output_contains "remotely typeable"
    run grep -c pam_exec.so "$DURESSD_PAM_FILE"    # no PAM hook was written
    assert_output_contains "0"
}

@test "install-login-trigger --force installs despite SSH password auth (with a warning)" {
    : > "$DURESSD_CFGDIR/passphrase.luks"
    export DURESSD_SSHD_PASSWORD_AUTH=yes
    run cmd_install_login_trigger --force
    assert_ok
    assert_output_contains "REMOTELY TYPEABLE"    # the warning still fires
    run cat "$DURESSD_PAM_FILE"
    assert_output_contains "auth optional pam_exec.so expose_authtok quiet"
}
