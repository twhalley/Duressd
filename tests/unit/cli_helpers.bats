#!/usr/bin/env bats
# Unit tests for pure CLI helper functions.

load '../lib/common'

setup()    { setup_stubs; load_cli; }
teardown() { teardown_stubs; }

@test "b64 round-trips through base64 -d" {
    encoded="$(b64 'hello world')"
    run bash -c "printf '%s' '$encoded' | base64 -d"
    assert_ok
    [ "$output" = "hello world" ]
}

@test "b64 preserves special characters" {
    encoded="$(b64 'p@ss:w=rd	tab')"
    decoded="$(printf '%s' "$encoded" | base64 -d)"
    [ "$decoded" = "p@ss:w=rd	tab" ]
}

@test "yn_bool maps y/Y to true, everything else to false" {
    [ "$(yn_bool y)" = true ]
    [ "$(yn_bool Y)" = true ]
    [ "$(yn_bool n)" = false ]
    [ "$(yn_bool '')" = false ]
    [ "$(yn_bool yes)" = false ]   # only a bare y/Y counts
}
