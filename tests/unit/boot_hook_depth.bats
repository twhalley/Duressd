#!/usr/bin/env bats
# Unit tests for the boot hook's depth-selected wipe (_duress_depth_wipe). The
# boot prompt itself can't be unit-tested, but the depth branching — header (no
# extra writes), full (whole disk), traces (dynamic head+tail), and the
# geometry-unknown fallback — is the security-critical part and IS testable.

load '../lib/common'

# Capture dd invocations into a log via a shim on PATH.
setup() {
    DDLOG="$(mktemp)"
    SHIM="$(mktemp -d)"
    cat > "$SHIM/dd" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$DDLOG"
exit 0
EOF
    chmod +x "$SHIM/dd"
    PATH="$SHIM:$PATH"
    # shellcheck disable=SC1090
    source "$REPO_ROOT/initramfs/duress-runtime-hook"
}
teardown() { rm -rf "$SHIM"; rm -f "$DDLOG"; }

# geometry: LUKS partition starts at 2,099,200 sectors (1 GiB) and is 22 GiB.
PSTART=2099200
PSIZE=46137344

@test "header depth issues NO further writes" {
    _duress_depth_wipe /dev/sda header "$PSTART" "$PSIZE"
    [ ! -s "$DDLOG" ]                                   # empty — nothing written
}

@test "full depth overwrites the ENTIRE disk (no seek/count)" {
    _duress_depth_wipe /dev/sda full "$PSTART" "$PSIZE"
    run grep -E 'of=/dev/sda bs=4M conv=fsync' "$DDLOG"
    assert_ok
    run grep -E 'seek=|count=' "$DDLOG"
    assert_fail                                         # whole-disk, not bounded
}

@test "traces depth writes HEAD (count) AND TAIL (seek)" {
    _duress_depth_wipe /dev/sda traces "$PSTART" "$PSIZE"
    # HEAD: count = pstart/2048 + 1 = 1026 MiB
    run grep -E 'of=/dev/sda bs=1M count=1026 ' "$DDLOG"
    assert_ok
    # TAIL: seek = (pstart+psize)/2048 = 23553 MiB
    run grep -E 'of=/dev/sda bs=1M seek=23553 ' "$DDLOG"
    assert_ok
}

@test "traces with unreadable geometry falls back to a full overwrite" {
    _duress_depth_wipe /dev/sda traces 0 0
    run grep -E 'of=/dev/sda bs=4M conv=fsync' "$DDLOG"
    assert_ok                                           # full fallback
    run grep -E 'count=|seek=' "$DDLOG"
    assert_fail
}

@test "an unknown depth string is treated as traces (default branch)" {
    _duress_depth_wipe /dev/sda bogus "$PSTART" "$PSIZE"
    run grep -E 'count=1026 ' "$DDLOG"
    assert_ok
}
