#!/usr/bin/env bats
# Unit tests for cmd_health output and overall status roll-up.

load '../lib/common'

setup()    { setup_stubs; load_handler; }
teardown() { teardown_stubs; }

write_config() {
    cat >"$DURESSD_CFGDIR/config" <<EOF
CONFIGURED=true
PASSWORD_TYPE=custom
VERIFY_DEVICE=
OVERWRITE_LUKS_HEADER=false
WIPE_FULL_DEVICE=false
WIPE_COUNTDOWN=0
EOF
}

@test "cmd_health: all green when service up, configured, devices present" {
    export STUB_SYSTEMCTL_ISACTIVE_RC=0
    export STUB_LSBLK_NAME="/dev/sda2"
    export STUB_LUKS_DEVICES="/dev/sda2"
    write_config
    : >"$DURESSD_CFGDIR/passphrase.luks"
    run cmd_health
    assert_ok
    assert_output_contains "CHECK	ok	service_running"
    assert_output_contains "CHECK	ok	config_file"
    assert_output_contains "CHECK	ok	auth_backend"
    assert_output_contains "health=ok"
}

@test "cmd_health: fails when service down and unconfigured" {
    export STUB_SYSTEMCTL_ISACTIVE_RC=1
    export STUB_LUKS_DEVICES=""
    rm -f "$DURESSD_CFGDIR/config"
    run cmd_health
    assert_output_contains "CHECK	fail	service_running"
    assert_output_contains "CHECK	fail	config_file"
    assert_output_contains "health=fail"
}

@test "cmd_health: warns (not fails) when configured but no LUKS devices" {
    export STUB_SYSTEMCTL_ISACTIVE_RC=0
    export STUB_LUKS_DEVICES=""
    write_config
    : >"$DURESSD_CFGDIR/passphrase.luks"
    run cmd_health
    assert_output_contains "CHECK	warn	luks_devices"
    assert_output_contains "health=warn"
}
