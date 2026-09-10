#!/usr/bin/env bats
# Security unit tests for the PAM login duress hook (pam/pam-duress).
#
# It is invoked by pam_exec.so with `expose_authtok` (the entered password on
# stdin). The security-critical properties:
#   • the password reaches duressd via the DURESSD_PASS *environment*, never as a
#     command-line argument (which would leak it in the process list);
#   • the authtok may arrive WITHOUT a trailing newline — the wipe must still fire;
#   • an empty authtok fires nothing;
#   • the hook ALWAYS exits 0, so a normal login is never delayed, blocked, or
#     altered (it is wired in as `auth optional`).
# The password→wipe decision (only the duress passphrase triggers) is the daemon's
# job and is covered by verify_passphrase + the VM pam-e2e; here we test the hook.

load '../lib/common'

HOOK="$REPO_ROOT/pam/pam-duress"

setup() {
    PAMTEST="$(mktemp -d)"
    RECORD="$PAMTEST/record"; : > "$RECORD"
    export DURESSD_CFGDIR="$PAMTEST/cfg"; mkdir -p "$DURESSD_CFGDIR"
    # Stand-in for `duressd`: record how the hook invoked it — argv and the
    # DURESSD_PASS env — so we can prove the password never lands in argv.
    cat > "$PAMTEST/rec" <<'REC'
#!/bin/bash
{ echo "ARGS=[$*]"; echo "PASS=[${DURESSD_PASS-<unset>}]"; } >> "REC_RECORD"
REC
    sed -i "s#REC_RECORD#$RECORD#" "$PAMTEST/rec"
    chmod +x "$PAMTEST/rec"
    # pam-duress sources trigger.env for a DURESSD_BIN override.
    printf 'DURESSD_BIN=%s\n' "$PAMTEST/rec" > "$DURESSD_CFGDIR/trigger.env"
}
teardown() { rm -rf "$PAMTEST"; }

# The hook detaches the trigger with `setsid -f`, so poll for the record.
_wait_record() { local i; for i in $(seq 1 50); do [ -s "$RECORD" ] && return 0; sleep 0.1; done; return 1; }

@test "pam-duress fires trigger-remote with the password in \$DURESSD_PASS (not argv)" {
    printf '%s' 'sup3r-secret-pin' | bash "$HOOK"    # NB: NO trailing newline
    _wait_record || { echo "trigger never fired:"; cat "$RECORD"; return 1; }
    grep -q 'ARGS=\[trigger-remote\]'   "$RECORD"    # locked to trigger-remote
    grep -q 'PASS=\[sup3r-secret-pin\]' "$RECORD"    # password delivered via env
    # …and the password must NEVER appear as a command argument (process-list leak)
    ! grep -q 'ARGS=\[.*sup3r-secret-pin' "$RECORD"
}

@test "pam-duress tolerates an authtok with a trailing newline too" {
    printf '%s\n' 'newline-pin' | bash "$HOOK"
    _wait_record || { echo "trigger never fired"; return 1; }
    grep -q 'PASS=\[newline-pin\]' "$RECORD"
}

@test "pam-duress DRY-RUN mode passes --dry-run (previews, never wipes)" {
    printf 'DURESSD_PAM_DRYRUN=1\n' >> "$DURESSD_CFGDIR/trigger.env"
    printf '%s' 'test-pin' | bash "$HOOK"
    _wait_record || { echo "trigger never fired"; return 1; }
    grep -q 'ARGS=\[trigger-remote --dry-run\]' "$RECORD"   # dry-run flag forwarded
    grep -q 'PASS=\[test-pin\]' "$RECORD"                    # still via env, not argv
}

@test "pam-duress resolves an ABSOLUTE duressd path (PAM's PATH excludes /usr/local/bin)" {
    # Regression: at a real login pam_exec runs with a minimal PATH that does not
    # include /usr/local/bin, so a bare "duressd" is not found and the trigger
    # never fires. Prove the hook finds duressd by absolute path with NO
    # DURESSD_BIN override and with the bare name unreachable via PATH.
    : > "$DURESSD_CFGDIR/trigger.env"        # no DURESSD_BIN pin this time
    fakebin="$PAMTEST/usr/local/bin"; mkdir -p "$fakebin"
    cp "$PAMTEST/rec" "$fakebin/duressd"     # duressd reachable ONLY by absolute path
    # PATH mirrors PAM's real minimal env (has bash, EXCLUDES /usr/local/bin), so a
    # bare "duressd" lookup would fail — only the absolute-path search can succeed.
    run env -u DURESSD_BIN PATH="/usr/bin:/bin" \
        DURESSD_BIN_CANDIDATES="$fakebin/duressd" \
        bash -c 'printf "%s" abs-pin | bash "'"$HOOK"'"'
    [ "$status" -eq 0 ]
    _wait_record || { echo "trigger never fired via absolute path"; return 1; }
    grep -q 'PASS=\[abs-pin\]' "$RECORD"
}

@test "pam-duress does NOT fire on an empty authtok" {
    printf '' | bash "$HOOK"
    sleep 0.3
    [ ! -s "$RECORD" ]
}

@test "pam-duress always exits 0 (never blocks or delays login)" {
    run bash -c "printf 'whatever' | bash '$HOOK'"; [ "$status" -eq 0 ]
    run bash -c "printf ''         | bash '$HOOK'"; [ "$status" -eq 0 ]
}
