# Shared bats helpers for duressd unit tests.
# shellcheck shell=bash

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REPO_ROOT
STUBS_SRC="$REPO_ROOT/tests/stubs/generic-stub"

# All binaries the handler/CLI may invoke, backed by the generic stub.
STUB_COMMANDS=(cryptsetup lsblk wipefs dmsetup blkdiscard findmnt openssl dd
               mdadm efibootmgr systemctl shred umount sync blockdev partprobe sfdisk
               tpm2_clear nvme swapoff)

# setup_stubs — build a temp bindir of symlinks to the generic stub, prepend it
# to PATH, point the paths/state at a private temp dir, and start a call log.
setup_stubs() {
    STUB_BIN="$(mktemp -d)"
    local c
    for c in "${STUB_COMMANDS[@]}"; do ln -s "$STUBS_SRC" "$STUB_BIN/$c"; done
    PATH="$STUB_BIN:$PATH"; export PATH

    DURESSD_STUB_LOG="$(mktemp)";        export DURESSD_STUB_LOG
    DURESSD_TESTROOT="$(mktemp -d)";     export DURESSD_TESTROOT
    DURESSD_RUNDIR="$DURESSD_TESTROOT/run";  mkdir -p "$DURESSD_RUNDIR"
    DURESSD_CFGDIR="$DURESSD_TESTROOT/cfg";  mkdir -p "$DURESSD_CFGDIR"
    export DURESSD_RUNDIR DURESSD_CFGDIR
    DURESSD_NO_POWEROFF=1;               export DURESSD_NO_POWEROFF
}

teardown_stubs() {
    [[ -n "${STUB_BIN:-}" ]]          && rm -rf "$STUB_BIN"
    [[ -n "${DURESSD_STUB_LOG:-}" ]]  && rm -f  "$DURESSD_STUB_LOG"
    [[ -n "${DURESSD_TESTROOT:-}" ]]  && rm -rf "$DURESSD_TESTROOT"
}

# Load the handler's functions without running its dispatcher, and neutralise
# the block-device check so fake device paths are accepted.
load_handler() {
    DURESSD_LIB_ONLY=1 source "$REPO_ROOT/src/handler"
    _is_block() { return 0; }
}

load_cli() {
    DURESSD_LIB_ONLY=1 source "$REPO_ROOT/src/cli"
}

# ── call-log assertions ───────────────────────────────────────────────────────
stub_log() { cat "$DURESSD_STUB_LOG"; }
stub_called()      { grep -qE "^$1"$'\t' "$DURESSD_STUB_LOG"; }
stub_not_called()  { ! grep -qE "^$1"$'\t' "$DURESSD_STUB_LOG"; }
# stub_called_with CMD SUBSTRING — CMD invoked with args containing SUBSTRING.
stub_called_with() { grep -qE "^$1"$'\t'".*${2}" "$DURESSD_STUB_LOG"; }
stub_count()       { grep -cE "^$1"$'\t' "$DURESSD_STUB_LOG" || true; }

# ── generic assertions (avoid a bats-assert dependency) ───────────────────────
assert_ok()       { [[ "$status" -eq 0 ]] || { echo "expected rc=0, got $status"; echo "$output"; return 1; }; }
assert_fail()     { [[ "$status" -ne 0 ]] || { echo "expected rc!=0, got 0"; echo "$output"; return 1; }; }
assert_output_contains() {
    [[ "$output" == *"$1"* ]] || { echo "expected output to contain: $1"; echo "--- got ---"; echo "$output"; return 1; }
}
refute_output_contains() {
    [[ "$output" != *"$1"* ]] || { echo "expected output NOT to contain: $1"; echo "--- got ---"; echo "$output"; return 1; }
}
