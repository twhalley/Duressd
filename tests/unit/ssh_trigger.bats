#!/usr/bin/env bats
# Unit tests for the SSH / non-interactive duress trigger.

load '../lib/common'

setup() {
    setup_stubs
    load_cli
    # Capture what the CLI would send over the socket instead of hitting socat.
    SENT="$(mktemp)"
    send_cmd() { printf 'SENT\t%s\n' "$*" >> "$SENT"; }
}
teardown() { teardown_stubs; rm -f "${SENT:-}"; }

expect_b64() { printf '%s' "$1" | base64 -w0; }

@test "trigger-remote reads the passphrase from stdin" {
    printf '%s\n' "s3cret" | cmd_trigger_remote
    grep -q "TRIGGER $(expect_b64 s3cret)" "$SENT"
}

@test "trigger-remote reads the passphrase from \$DURESSD_PASS" {
    DURESSD_PASS="envpass" cmd_trigger_remote </dev/null
    grep -q "TRIGGER $(expect_b64 envpass)" "$SENT"
}

@test "trigger-remote reads the passphrase from --passphrase-file" {
    pf="$(mktemp)"; printf '%s\n' "filepass" > "$pf"
    cmd_trigger_remote --passphrase-file "$pf" </dev/null
    grep -q "TRIGGER $(expect_b64 filepass)" "$SENT"
    rm -f "$pf"
}

@test "trigger-remote --dry-run sends the non-destructive TRIGGER_DRYRUN" {
    printf '%s\n' "s3cret" | cmd_trigger_remote --dry-run
    grep -q "TRIGGER_DRYRUN $(expect_b64 s3cret)" "$SENT"
    # and never the destructive TRIGGER on its own
    ! grep -qE "[[:space:]]TRIGGER $(expect_b64 s3cret)" "$SENT"
}

@test "trigger-remote fails with no passphrase source" {
    run cmd_trigger_remote </dev/null
    assert_fail
    assert_output_contains "no passphrase"
    [ ! -s "$SENT" ]   # nothing was sent
}

@test "install-ssh-trigger writes a restricted forced-command entry" {
    pub="$(mktemp)"; echo "ssh-ed25519 AAAAFAKEKEY duressd-test" > "$pub"
    ak="$DURESSD_TESTROOT/authorized_keys"
    run cmd_install_ssh_trigger --pubkey "$pub" --authorized-keys "$ak"
    assert_ok
    run cat "$ak"
    assert_output_contains 'command="duressd trigger-remote",restrict ssh-ed25519 AAAAFAKEKEY'
    rm -f "$pub"
}

@test "install-ssh-trigger honours DURESSD_SSH_AUTHKEYS default" {
    pub="$(mktemp)"; echo "ssh-ed25519 AAAAKEY2 duressd-test" > "$pub"
    export DURESSD_SSH_AUTHKEYS="$DURESSD_TESTROOT/ssh/authorized_keys"
    run cmd_install_ssh_trigger --pubkey "$pub"
    assert_ok
    [ -f "$DURESSD_SSH_AUTHKEYS" ]
    grep -q 'trigger-remote' "$DURESSD_SSH_AUTHKEYS"
    rm -f "$pub"
}

@test "install-ssh-trigger --embed-passphrase stores the key and references it" {
    pub="$(mktemp)"; echo "ssh-ed25519 AAAAKEY3 duressd-test" > "$pub"
    ak="$DURESSD_TESTROOT/authorized_keys"
    printf '%s\n%s\n' "embedpass" "embedpass" \
        | cmd_install_ssh_trigger --embed-passphrase --pubkey "$pub" --authorized-keys "$ak"
    # passphrase stored root-only under the config dir
    [ -f "$DURESSD_CFGDIR/ssh-trigger.pass" ]
    [ "$(cat "$DURESSD_CFGDIR/ssh-trigger.pass")" = "embedpass" ]
    # forced command references the passphrase file
    grep -q 'trigger-remote --passphrase-file' "$ak"
    rm -f "$pub"
}
