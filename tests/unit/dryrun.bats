#!/usr/bin/env bats
# Unit tests for the unified dry-run mode — DRYRUN=1 must run the REAL discovery
# and phase-selection but never invoke a single destructive primitive, emitting
# green PLAN preview lines instead.

load '../lib/common'

ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
LINUX_GUID="0fc63daf-8483-4772-8e79-3d69d8477de4"
LUKS_GUID="ca7d7ccb-63ed-4c53-861c-1742536059cc"

setup() {
    setup_stubs
    load_handler
    # One discoverable LUKS device with a parent disk.
    export STUB_LSBLK_NAME="/dev/sda3"
    export STUB_LUKS_DEVICES="/dev/sda3"
    export STUB_PKNAME="sda"
    export STUB_SIZE=10485760   # 10 MiB
    # A Qubes-style GPT for the boot-artifact preview.
    export STUB_LSBLK_BOOTSCAN="/dev/sda1	${ESP_GUID}	vfat	/boot/efi
/dev/sda2	${LINUX_GUID}	ext4	/boot
/dev/sda3	${LUKS_GUID}	crypto_LUKS	"
}
teardown() { teardown_stubs; }

@test "dry run with every phase enabled invokes NO destructive primitive" {
    export WIPE_BOOT_ARTIFACTS=true WIPE_HARDWARE_KEYS=true \
           OVERWRITE_LUKS_HEADER=true WIPE_FULL_DEVICE=true
    DRYRUN=1
    run wipe_real
    assert_ok
    stub_not_called wipefs
    stub_not_called dd            # rand_write's dd never runs
    stub_not_called blkdiscard
    stub_not_called mdadm
    stub_not_called tpm2_clear
    stub_not_called systemctl     # no poweroff
    # cryptsetup is still used read-only for isLuks, but never for luksErase.
    run grep -E '^cryptsetup'$'\t''.*luksErase' "$DURESSD_STUB_LOG"
    assert_fail
}

@test "dry run emits green PLAN preview lines for the real targets" {
    export WIPE_FULL_DEVICE=true
    DRYRUN=1
    run wipe_real
    assert_ok
    assert_output_contains "PLAN"
    assert_output_contains "Phase 1 — cryptographic destruction"
    assert_output_contains "luksErase + overwrite the LUKS header"
    assert_output_contains "/dev/sda3"
}

@test "dry run marks disabled phases as skipped, not run" {
    export WIPE_BOOT_ARTIFACTS=false WIPE_HARDWARE_KEYS=false \
           OVERWRITE_LUKS_HEADER=false WIPE_FULL_DEVICE=false
    DRYRUN=1
    run wipe_real
    assert_ok
    assert_output_contains "skip"
    assert_output_contains "WIPE_BOOT_ARTIFACTS=false"
    assert_output_contains "WIPE_FULL_DEVICE=false"
}

@test "dry run leaves the state file untouched (set_state is a no-op)" {
    DRYRUN=1
    run wipe_real
    assert_ok
    run get_state
    assert_output_contains "IDLE"    # never advanced to WIPING/DONE
}

@test "dry run does not enter the full-device byte loop" {
    # A huge device would spin the real loop millions of times; the dry run must
    # report the size once and issue no writes.
    export WIPE_FULL_DEVICE=true
    export STUB_SIZE=1099511627776    # 1 TiB
    DRYRUN=1
    run wipe_real
    assert_ok
    assert_output_contains "overwrite the ENTIRE device"
    stub_not_called dd
}

@test "dry run previews a TPM clear without calling tpm2_clear" {
    _tpm_device() { echo /dev/tpmrm0; }   # pretend a TPM is present
    DRYRUN=1
    run wipe_hardware_keys
    assert_ok
    assert_output_contains "clear TPM"
    stub_not_called tpm2_clear
}

@test "regression: a REAL hardware wipe DOES call tpm2_clear (mutate runs)" {
    _tpm_device() { echo /dev/tpmrm0; }
    # DRYRUN defaults to 0 (set at the top of the handler on source).
    run wipe_hardware_keys
    assert_ok
    stub_called tpm2_clear
}

@test "dry run boot-artifact preview lists the ESP but wipes nothing" {
    export DURESSD_TARGET_DEVICES="/dev/sda /dev/sda1 /dev/sda2 /dev/sda3"
    DRYRUN=1
    run wipe_boot_artifacts /dev/sda
    assert_ok
    assert_output_contains "/dev/sda1"
    assert_output_contains "boot wipe"    # PLAN item text (the CLI adds "would")
    stub_not_called wipefs
    stub_not_called dd
    stub_not_called blkdiscard
}

@test "live-root: the parent-disk MBR/GPT overwrite is DEFERRED out of wipe_boot_artifacts" {
    export DURESSD_TARGET_DEVICES="/dev/sda /dev/sda1 /dev/sda2 /dev/sda3"
    DRYRUN=1
    run wipe_boot_artifacts /dev/sda
    assert_ok
    # It must NOT trash the parent table here — that would break the running root
    # mid-wipe. It's moved to wipe_parent_tables(), which wipe_real runs LAST.
    refute_output_contains "MBR + GPT header"
}

@test "live-root: wipe_parent_tables previews the MBR/GPT overwrite (the deferred step)" {
    export DURESSD_TARGET_DEVICES="/dev/sda"
    DRYRUN=1
    run wipe_parent_tables /dev/sda
    assert_ok
    assert_output_contains "MBR + GPT header"
}
