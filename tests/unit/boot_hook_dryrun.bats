#!/usr/bin/env bats
# Unit tests for the boot hook's DRY-RUN mode: `duressd.dryrun` on the kernel
# cmdline makes the duress passphrase PREVIEW the wipe in green and destroy
# nothing (so you can verify the passphrase is recognised before relying on it).

load '../lib/common'

setup() {
    # Shim cryptsetup + dd + sync so we can assert what runs. All log to $CMDLOG.
    CMDLOG="$(mktemp)"
    SHIM="$(mktemp -d)"
    for c in cryptsetup dd sync; do
        cat > "$SHIM/$c" <<EOF
#!/usr/bin/env bash
printf '%s %s\n' "$c" "\$*" >> "$CMDLOG"
exit 0
EOF
        chmod +x "$SHIM/$c"
    done
    PATH="$SHIM:$PATH"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/initramfs/duress-runtime-hook"
    CMDLINE="$(mktemp)"
    export DURESS_CMDLINE="$CMDLINE"
}
teardown() { rm -rf "$SHIM"; rm -f "$CMDLOG" "$CMDLINE"; }

# ── _duress_is_dryrun detection ──────────────────────────────────────────────
@test "is_dryrun: bare 'duressd.dryrun' on the cmdline → yes" {
    echo 'root=/dev/x quiet duressd.dryrun rw' > "$CMDLINE"
    run _duress_is_dryrun
    assert_ok
}

@test "is_dryrun: 'duressd.dryrun=1' → yes" {
    echo 'root=/dev/x duressd.dryrun=1' > "$CMDLINE"
    run _duress_is_dryrun
    assert_ok
}

@test "is_dryrun: absent → no" {
    echo 'root=/dev/x quiet rw' > "$CMDLINE"
    run _duress_is_dryrun
    assert_fail
}

@test "is_dryrun: a lookalike token (duressd.dryruns) does NOT match" {
    echo 'root=/dev/x duressd.dryruns=1' > "$CMDLINE"
    run _duress_is_dryrun
    assert_fail
}

@test "is_dryrun: missing cmdline file → no (fail safe: real wipe stays armed)" {
    export DURESS_CMDLINE=/nonexistent/cmdline
    run _duress_is_dryrun
    assert_fail
}

# ── _duress_destroy dry-run vs real ──────────────────────────────────────────
@test "dry run PREVIEWS in green and destroys NOTHING" {
    run _duress_destroy /dev/sdX 1
    assert_output_contains "DRY RUN"
    assert_output_contains "NOTHING was wiped"
    assert_output_contains $'\033[1;32m'                 # bright-green
    # not a single destructive command ran
    [ ! -s "$CMDLOG" ]
}

@test "real run erases the LUKS keyslots and overwrites the disk" {
    run _duress_destroy /dev/sdX 0
    run grep -E '^cryptsetup luksErase' "$CMDLOG"
    assert_ok
    run grep -E '^dd ' "$CMDLOG"
    assert_ok
    # the real path shows the generic error, never the green DRY RUN banner
    run grep -a 'DRY RUN' "$CMDLOG"
    assert_fail
}
