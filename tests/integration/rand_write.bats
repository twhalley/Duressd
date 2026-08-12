#!/usr/bin/env bats
# Regression for the wipe-abort bug (deep-review #1/#2): rand_write MUST return 0
# even when dd runs PAST the end of the device (ENOSPC). This happens by design
# on the last block of a full-device wipe (the chunk count is a ceil) and on a
# fixed-size head write against an undersized device. Under the handler's
# `set -euo pipefail`, a non-zero return there would abort the *committed* wipe
# before poweroff — the SSH/boot kill switch would leave the disk half-wiped and
# still running. rand_write swallows the status with `|| true`; the bytes up to
# EOF are still overwritten, which is exactly what we want.

load 'helpers'

setup()    { int_setup; }
teardown() { int_teardown; }

@test "rand_write returns 0 and overwrites to EOF when the write overshoots the device" {
    command -v openssl >/dev/null || skip "openssl not available"
    # 10 MiB is deliberately NOT a 4-MiB multiple, so a 4-MiB-chunked write must
    # overshoot the end.
    loop="$(new_loop 10)"
    assert_safe_targets "$loop"

    # Ask for 3 × 4 MiB = 12 MiB starting at block 0 → 2 MiB past the 10 MiB end.
    run rand_write "$loop" 0 3
    [ "$status" -eq 0 ]          # MUST NOT abort — this is the whole point

    # And the device really was overwritten right up to EOF: the last MiB is not
    # still zeros (the loop backing file started sparse/zeroed).
    run cmp -s <(dd if="$loop" bs=1M skip=9 count=1 2>/dev/null) \
               <(head -c 1048576 /dev/zero)
    [ "$status" -ne 0 ]          # NOT all-zero → the tail got written
}
