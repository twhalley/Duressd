#!/usr/bin/env bats
# Unit tests for wipe_test — the non-destructive `duressd test` path. It must
# exercise the real primitives (luksFormat → luksErase → wipefs) on a THROWAWAY
# /tmp scratch container ONLY, never a real block device, and always return the
# daemon to IDLE.

load '../lib/common'

setup() { setup_stubs; load_handler; }
teardown() { teardown_stubs; }

@test "wipe_test scrubs a /tmp scratch container and completes" {
    run wipe_test
    assert_ok
    assert_output_contains "TEST_COMPLETE"
    # luksErase + wipefs ran against the /tmp scratch file
    run grep -E '^cryptsetup'$'\t''.*luksErase.*/tmp/duressd-test' "$DURESSD_STUB_LOG"
    assert_ok
    run grep -E '^wipefs'$'\t''.*/tmp/duressd-test' "$DURESSD_STUB_LOG"
    assert_ok
}

@test "wipe_test NEVER targets a real block device (/dev/...)" {
    run wipe_test
    assert_ok
    # /dev/zero is a legit dd SOURCE; assert nothing WRITES to a /dev device.
    run bash -c "grep -aE '/dev/' '$DURESSD_STUB_LOG' | grep -avE '/dev/(zero|urandom|null)'"
    assert_fail                                   # every op stayed on the /tmp scratch file
}

@test "wipe_test returns the daemon to IDLE" {
    run wipe_test
    assert_ok
    run get_state
    assert_output_contains "IDLE"
}
