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

# ── security properties of the public-key forced-command entry ────────────────

@test "security: the forced-command entry is RESTRICTED and locked to trigger-remote" {
    pub="$(mktemp)"; echo "ssh-ed25519 AAAAKEYR duressd-test" > "$pub"
    ak="$DURESSD_TESTROOT/authorized_keys"
    run cmd_install_ssh_trigger --pubkey "$pub" --authorized-keys "$ak"
    assert_ok
    run cat "$ak"
    # a matching key can ONLY run trigger-remote — no arbitrary command, no shell
    assert_output_contains 'command="duressd trigger-remote"'
    # restrict disables pty, agent/port/X11 forwarding and user rc (OpenSSH 7.2+)
    assert_output_contains 'restrict'
    rm -f "$pub"
}

@test "security: authorized_keys is written mode 0600" {
    pub="$(mktemp)"; echo "ssh-ed25519 AAAAKEY6 duressd-test" > "$pub"
    ak="$DURESSD_TESTROOT/authorized_keys"
    run cmd_install_ssh_trigger --pubkey "$pub" --authorized-keys "$ak"
    assert_ok
    [ "$(stat -c %a "$ak")" = "600" ]
    rm -f "$pub"
}

@test "security: default (no --embed) NEVER persists the passphrase to disk" {
    pub="$(mktemp)"; echo "ssh-ed25519 AAAAKEYN duressd-test" > "$pub"
    ak="$DURESSD_TESTROOT/authorized_keys"
    run cmd_install_ssh_trigger --pubkey "$pub" --authorized-keys "$ak"
    assert_ok
    [ ! -e "$DURESSD_CFGDIR/ssh-trigger.pass" ]    # no stored secret on disk
    run cat "$ak"
    refute_output_contains 'passphrase-file'        # key alone can't trigger
    rm -f "$pub"
}

@test "security: --embed-passphrase stores the secret root-only (0600)" {
    pub="$(mktemp)"; echo "ssh-ed25519 AAAAKEYE duressd-test" > "$pub"
    ak="$DURESSD_TESTROOT/authorized_keys"
    printf '%s\n%s\n' "embedpass" "embedpass" \
        | cmd_install_ssh_trigger --embed-passphrase --pubkey "$pub" --authorized-keys "$ak"
    [ "$(stat -c %a "$DURESSD_CFGDIR/ssh-trigger.pass")" = "600" ]
    rm -f "$pub"
}

# ── uninstall ─────────────────────────────────────────────────────────────────
@test "install then --uninstall removes the forced-command entry, keeps other keys" {
    pub="$(mktemp)"; echo "ssh-ed25519 AAAAFAKEKEY duressd-test" > "$pub"
    ak="$DURESSD_TESTROOT/authorized_keys"
    install -d "$(dirname "$ak")"
    echo 'ssh-ed25519 AAAANORMALKEY my-laptop' > "$ak"      # a pre-existing normal key
    cmd_install_ssh_trigger --pubkey "$pub" --authorized-keys "$ak" >/dev/null 2>&1
    grep -q 'command="duressd trigger-remote' "$ak"          # sanity: added
    run cmd_install_ssh_trigger --uninstall --authorized-keys "$ak"
    assert_ok
    run grep -c 'duressd trigger-remote' "$ak"
    assert_output_contains "0"                               # forced-command line gone
    grep -q 'AAAANORMALKEY' "$ak"                            # the normal key survives
    rm -f "$pub"
}

@test "ssh --uninstall securely erases the embedded passphrase file" {
    ak="$DURESSD_TESTROOT/authorized_keys"; : > "$ak"
    install -d "$DURESSD_CFGDIR"
    printf 'topsecret' > "$DURESSD_CFGDIR/ssh-trigger.pass"
    run cmd_install_ssh_trigger --uninstall --authorized-keys "$ak"
    assert_ok
    # secure erase: shred -u on the passfile (the stub records but doesn't unlink)
    stub_called_with shred "-u $DURESSD_CFGDIR/ssh-trigger.pass"
}

@test "ssh --uninstall is idempotent (no entry → clean no-op)" {
    ak="$DURESSD_TESTROOT/authorized_keys"
    echo 'ssh-ed25519 AAAANORMALKEY only-normal' > "$ak"
    run cmd_install_ssh_trigger --uninstall --authorized-keys "$ak"
    assert_ok
    assert_output_contains "nothing to remove"
    grep -q 'AAAANORMALKEY' "$ak"
}
