#!/usr/bin/env bats
# Unit tests for wipe_hardware_keys (TPM clear).

load '../lib/common'

setup()    { setup_stubs; load_handler; }
teardown() { teardown_stubs; }

@test "wipe_hardware_keys clears the TPM when one is present" {
    unset DURESSD_TARGET_DEVICES
    _tpm_device() { printf '/dev/tpmrm0'; }
    run wipe_hardware_keys
    assert_ok
    stub_called tpm2_clear
}

@test "wipe_hardware_keys falls back to a firmware PPI clear when software clear fails" {
    unset DURESSD_TARGET_DEVICES
    _tpm_device() { printf '/dev/tpmrm0'; }
    tpm2_clear() { return 1; }   # TPM the OS can't clear (lockout auth set / DA lockout)
    export _TPM_PPI_REQUEST="$BATS_TMPDIR/ppi_request.$$"; : > "$_TPM_PPI_REQUEST"
    run wipe_hardware_keys
    assert_ok
    assert_output_contains "firmware clear requested"
    run cat "$_TPM_PPI_REQUEST"
    assert_output_contains "5"                 # PPI op 5 = Clear was requested
    rm -f "$_TPM_PPI_REQUEST"; unset _TPM_PPI_REQUEST
}

@test "wipe_hardware_keys warns (no silent success) when it cannot clear at all" {
    unset DURESSD_TARGET_DEVICES
    _tpm_device() { printf '/dev/tpmrm0'; }
    tpm2_clear() { return 1; }                 # software clear fails
    _tpm_ppi()   { return 1; }                 # and no firmware PPI available
    run wipe_hardware_keys
    assert_ok
    assert_output_contains "could not be cleared"   # honest failure, not a claimed success
}

@test "wipe_hardware_keys is a no-op when no TPM is present" {
    unset DURESSD_TARGET_DEVICES
    _tpm_device() { return 1; }
    _tpm_ppi()    { return 1; }   # and no firmware PPI clear interface either
    run wipe_hardware_keys
    assert_ok
    assert_output_contains "no TPM found"
    stub_not_called tpm2_clear
}

@test "wipe_hardware_keys never touches the TPM under a scoped test run" {
    export DURESSD_TARGET_DEVICES="/dev/loop0"
    _tpm_device() { printf '/dev/tpmrm0'; }   # even if a TPM 'exists'
    run wipe_hardware_keys
    assert_ok
    assert_output_contains "skipped (test mode)"
    stub_not_called tpm2_clear
}

@test "wipe_real runs Phase 1.6 when WIPE_HARDWARE_KEYS=true" {
    export STUB_LSBLK_NAME="/dev/sda2"
    export STUB_LUKS_DEVICES="/dev/sda2"
    _tpm_device() { return 1; }               # no real TPM in CI
    export WIPE_HARDWARE_KEYS=true WIPE_BOOT_ARTIFACTS=false \
           OVERWRITE_LUKS_HEADER=false WIPE_FULL_DEVICE=false
    run wipe_real
    assert_ok
    assert_output_contains "Phase 1.6"
}

@test "cmd_configure records WIPE_HARDWARE_KEYS from the 8th argument" {
    b64() { printf '%s' "$1" | base64 -w0; }
    argv=( "$(b64 x)" "$(b64 custom)" "$(b64 secret)" false false 0 true true )
    run cmd_configure
    assert_ok
    run cat "$DURESSD_CFGDIR/config"
    assert_output_contains "WIPE_BOOT_ARTIFACTS=true"
    assert_output_contains "WIPE_HARDWARE_KEYS=true"
}
