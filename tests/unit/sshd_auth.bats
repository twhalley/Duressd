#!/usr/bin/env bats
# Unit tests for _sshd_password_auth — the detection behind install-login-trigger's
# remote-wipe safety guard (a weak duress pin becomes remotely typeable if SSH
# password auth is on). A mis-detection installs the footgun silently, so the real
# detection paths (sshd -T, sshd_config, fail-safe default) must be correct.

load '../lib/common'

setup() {
    setup_stubs
    load_cli
    unset DURESSD_SSHD_PASSWORD_AUTH          # exercise real detection, not the override
    export DURESSD_SSHD_CONFIG="$DURESSD_TESTROOT/sshd_config"
    export DURESSD_SSHD_CONFIG_D="$DURESSD_TESTROOT/sshd_config.d"
    : > "$DURESSD_SSHD_CONFIG"                 # empty config by default
    install -d "$DURESSD_SSHD_CONFIG_D"
}
teardown() { teardown_stubs; }

@test "env override wins immediately" {
    export DURESSD_SSHD_PASSWORD_AUTH=no
    run _sshd_password_auth
    assert_ok
    assert_output_contains "no"
}

@test "sshd -T reporting 'no' is detected" {
    export STUB_SSHD_T="passwordauthentication no"
    run _sshd_password_auth
    [ "$output" = "no" ]
}

@test "sshd -T reporting 'yes' is detected" {
    export STUB_SSHD_T="passwordauthentication yes"
    run _sshd_password_auth
    [ "$output" = "yes" ]
}

@test "falls back to sshd_config when sshd -T says nothing" {
    export STUB_SSHD_T=""                      # sshd -T yields no line
    printf 'PasswordAuthentication no\n' > "$DURESSD_SSHD_CONFIG"
    run _sshd_password_auth
    [ "$output" = "no" ]
}

@test "a drop-in in sshd_config.d is honoured (last directive wins)" {
    export STUB_SSHD_T=""
    printf 'PasswordAuthentication yes\n' > "$DURESSD_SSHD_CONFIG"
    printf 'PasswordAuthentication no\n'  > "$DURESSD_SSHD_CONFIG_D/50-hardening.conf"
    run _sshd_password_auth
    [ "$output" = "no" ]
}

@test "fails SAFE (yes) when nothing is knowable" {
    export STUB_SSHD_T=""                      # no sshd answer, empty config
    run _sshd_password_auth
    [ "$output" = "yes" ]                       # assume ON → the guard refuses
}
