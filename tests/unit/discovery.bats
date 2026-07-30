#!/usr/bin/env bats
# Unit tests for LUKS device discovery and the DURESSD_TARGET_DEVICES safety rail.

load '../lib/common'

setup()    { setup_stubs; load_handler; }
teardown() { teardown_stubs; }

@test "discover_luks_devices returns only devices carrying a LUKS header" {
    export STUB_LSBLK_NAME=$'/dev/sda1\n/dev/sda2\n/dev/sdb1'
    export STUB_LUKS_DEVICES="/dev/sda2 /dev/sdb1"
    run discover_luks_devices
    assert_ok
    assert_output_contains "/dev/sda2"
    assert_output_contains "/dev/sdb1"
    refute_output_contains "/dev/sda1"
}

@test "discover_luks_devices returns nothing when no device is LUKS" {
    export STUB_LSBLK_NAME=$'/dev/sda1\n/dev/sda2'
    export STUB_LUKS_DEVICES=""
    run discover_luks_devices
    assert_ok
    [ -z "$output" ]
}

@test "DURESSD_TARGET_DEVICES restricts discovery to the target list" {
    export STUB_LSBLK_NAME=$'/dev/sda2\n/dev/loop0\n/dev/loop1'
    export STUB_LUKS_DEVICES="/dev/sda2 /dev/loop0 /dev/loop1"
    export DURESSD_TARGET_DEVICES="/dev/loop0 /dev/loop1"
    run discover_luks_devices
    assert_ok
    refute_output_contains "/dev/sda2"
    assert_output_contains "/dev/loop0"
    assert_output_contains "/dev/loop1"
}

@test "_in_scope: everything in scope when target list is unset" {
    unset DURESSD_TARGET_DEVICES
    run _in_scope /dev/sda
    assert_ok
}

@test "_in_scope: host device rejected when scoped to loop devices" {
    export DURESSD_TARGET_DEVICES="/dev/loop0"
    run _in_scope /dev/sda
    assert_fail
    run _in_scope /dev/loop0
    assert_ok
}
