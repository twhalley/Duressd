#!/usr/bin/env bats
# SECURITY: load_config must PARSE /etc/duressd/config, never `source` it.
# Arbitrary shell in the config must never execute (it would be root RCE if the
# file's integrity were ever lost).

load '../lib/common'

setup()    { setup_stubs; load_handler; }
teardown() { teardown_stubs; }

@test "security: load_config parses KEY=value and NEVER executes config contents" {
    marker="$DURESSD_TESTROOT/pwned"; rm -f "$marker" "$marker.2"
    {
        echo 'CONFIGURED=true'
        echo 'PASSWORD_TYPE=custom'
        echo "EVIL=\$(touch $marker)"                # command substitution — must NOT run
        echo "INJECT=x; touch $marker.2"             # command chaining — must NOT run
        echo 'VERIFY_DEVICE=/dev/sda2'
        echo 'WIPE_COUNTDOWN=0'
    } > "$DURESSD_CFGDIR/config"
    load_config
    [ "$PASSWORD_TYPE" = custom ]                     # allowlisted keys parsed…
    [ "$VERIFY_DEVICE" = /dev/sda2 ]                  # …with literal values
    [ -z "${EVIL:-}" ]                                # non-allowlisted keys ignored
    [ -z "${INJECT:-}" ]
    [ ! -e "$marker" ]                                # and NOTHING from the config ran
    [ ! -e "$marker.2" ]
}

@test "security: a config value with shell metacharacters is taken literally" {
    {
        echo 'CONFIGURED=true'
        echo 'PASSWORD_TYPE=custom'
        echo 'VERIFY_DEVICE=/dev/sda2; rm -rf /'      # nasty value
        echo 'WIPE_COUNTDOWN=0'
    } > "$DURESSD_CFGDIR/config"
    load_config
    [ "$VERIFY_DEVICE" = '/dev/sda2; rm -rf /' ]       # literal string, never executed
}
