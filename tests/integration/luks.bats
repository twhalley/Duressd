#!/usr/bin/env bats
# Loop-device integration: real LUKS destruction by the real handler functions.

load 'helpers'

setup()    { int_setup; }
teardown() { int_teardown; }

luks_format() { printf '%s' "$2" | cryptsetup luksFormat "${LUKS_FAST[@]}" --key-file=- "$1"; }

@test "phase1 destroys a real LUKS2 header (data cryptographically gone)" {
    loop="$(new_loop 48)"
    luks_format "$loop" "unlock-me"
    assert_is_luks "$loop"

    export DURESSD_TARGET_DEVICES="$loop"
    assert_safe_targets "$loop"
    phase1_crypto_destruction "$loop"

    refute_is_luks "$loop"
}

@test "phase2 header overwrite leaves no LUKS signature" {
    loop="$(new_loop 48)"
    luks_format "$loop" "unlock-me"

    export DURESSD_TARGET_DEVICES="$loop"
    assert_safe_targets "$loop"
    phase1_crypto_destruction "$loop"
    phase2_overwrite_headers "$loop"

    refute_is_luks "$loop"
    run wipefs -n "$loop"
    refute_output_contains "crypto_LUKS"
}

@test "phase3 overwrites the whole parent device" {
    loop="$(new_loop 48)"
    luks_format "$loop" "unlock-me"
    # Record a recognizable marker mid-device, then confirm it's gone after wipe.
    printf 'DURESSDMARKER' | dd of="$loop" bs=1 seek=1048576 conv=notrunc status=none

    export DURESSD_TARGET_DEVICES="$loop" WIPE_FULL_DEVICE=true
    assert_safe_targets "$loop"
    phase3_wipe_full_devices "$loop"

    run dd if="$loop" bs=1 skip=1048576 count=13 status=none
    refute_output_contains "DURESSDMARKER"
}

@test "safety rail refuses a non-loop target" {
    run assert_safe_targets /dev/sda
    [ "$status" -ne 0 ]
    [[ "$output" == *"REFUSING"* ]]
}

@test "safety rail refuses a loop device backed outside the workdir" {
    outside="$(mktemp /var/tmp/duressd-outside.XXXXXX.img)"
    truncate -s 8M "$outside"
    stray="$(losetup --find --show "$outside")"
    INT_LOOPS+=("$stray")
    run assert_safe_targets "$stray"
    [ "$status" -ne 0 ]
    rm -f "$outside"
}
