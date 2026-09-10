#!/usr/bin/env bats
# Unit tests for cmd_passgen — the passphrase generator. Interactive `ask` is
# overridden to pick a type. openssl is stubbed (emits deterministic bytes).

load '../lib/common'

setup() { setup_stubs; load_cli; }
teardown() { teardown_stubs; }

@test "passgen base64 emits a passphrase via openssl rand -base64" {
    ask() { printf '1'; }                          # choose Base64
    run cmd_passgen
    assert_ok
    stub_called_with openssl "rand -base64 18"
}

@test "passgen hex emits a passphrase via openssl rand -hex" {
    ask() { printf '2'; }                          # choose Hex
    run cmd_passgen
    assert_ok
    stub_called_with openssl "rand -hex 16"
}

@test "passgen defaults to base64 for an invalid choice" {
    ask() { printf 'x'; }                          # invalid → default 1
    run cmd_passgen
    assert_ok
    stub_called_with openssl "rand -base64 18"
}
