#!/usr/bin/env bats
# Unit tests for wipe_real phase selection — which phases fire for each flag
# combination. Poweroff is suppressed by DURESSD_NO_POWEROFF (set in setup_stubs).

load '../lib/common'

setup() {
    setup_stubs
    load_handler
    # One discoverable LUKS device with a parent disk, for every case.
    export STUB_LSBLK_NAME="/dev/sda2"
    export STUB_LUKS_DEVICES="/dev/sda2"
    export STUB_PKNAME="sda"
    export STUB_LSBLK_NAMETYPE="sda disk"   # _disk_of walks /dev/sda2 → /dev/sda
    export STUB_SIZE=10485760   # 10 MiB → a single overwrite chunk
}
teardown() { teardown_stubs; }

@test "default flags: only Phase 1 runs (crypto destruction)" {
    export OVERWRITE_LUKS_HEADER=false WIPE_FULL_DEVICE=false
    run wipe_real
    assert_ok
    assert_output_contains "Phase 1"
    refute_output_contains "Phase 2 — overwriting"
    refute_output_contains "Phase 3 — wiping full"
    stub_called wipefs
    stub_called_with cryptsetup luksErase
    stub_called dd              # Phase 1 now overwrites the LUKS header region (rand_write)
    stub_not_called blkdiscard  # blkdiscard is Phase 3 only
}

@test "overwrite-header flag: Phase 2 runs, Phase 3 does not" {
    export OVERWRITE_LUKS_HEADER=true WIPE_FULL_DEVICE=false
    run wipe_real
    assert_ok
    assert_output_contains "Phase 2 — overwriting"
    refute_output_contains "Phase 3 — wiping full"
    stub_called dd
    stub_called blkdiscard
}

@test "wipe-full flag: Phase 3 runs, Phase 2 is skipped" {
    export OVERWRITE_LUKS_HEADER=false WIPE_FULL_DEVICE=true
    run wipe_real
    assert_ok
    assert_output_contains "Phase 3 — wiping full"
    refute_output_contains "Phase 2 — overwriting"
    stub_called dd
    stub_called blkdiscard
}

@test "both flags: Phase 3 supersedes Phase 2" {
    export OVERWRITE_LUKS_HEADER=true WIPE_FULL_DEVICE=true
    run wipe_real
    assert_ok
    assert_output_contains "Phase 3 — wiping full"
    refute_output_contains "Phase 2 — overwriting"
}

@test "poweroff is suppressed in test mode" {
    export OVERWRITE_LUKS_HEADER=false WIPE_FULL_DEVICE=false
    run wipe_real
    assert_ok
    assert_output_contains "poweroff suppressed"
    stub_not_called systemctl   # phase4 never calls systemctl poweroff here
}

@test "no LUKS devices: Phase 1 reports nothing to wipe, still no poweroff crash" {
    export STUB_LUKS_DEVICES=""
    export OVERWRITE_LUKS_HEADER=false WIPE_FULL_DEVICE=false
    run wipe_real
    assert_ok
    assert_output_contains "no LUKS containers found"
}
