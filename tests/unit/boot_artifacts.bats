#!/usr/bin/env bats
# Unit tests for wipe_boot_artifacts — ESP/boot/BIOS-boot/MBR targeting.

load '../lib/common'

ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
LINUX_GUID="0fc63daf-8483-4772-8e79-3d69d8477de4"
LUKS_GUID="ca7d7ccb-63ed-4c53-861c-1742536059cc"
BIOSBOOT_GUID="21686148-6449-6e6f-744e-656564454649"

setup() {
    setup_stubs
    load_handler
    # A Qubes-style GPT: ESP + ext4 /boot + LUKS root, plus a BIOS-boot part.
    export STUB_LSBLK_BOOTSCAN="/dev/sda1	${ESP_GUID}	vfat	/boot/efi
/dev/sda2	${LINUX_GUID}	ext4	/boot
/dev/sda3	${LUKS_GUID}	crypto_LUKS	"
    export STUB_LSBLK_PARTTYPE="/dev/sda4	${BIOSBOOT_GUID}"
    export DURESSD_TARGET_DEVICES="/dev/sda /dev/sda1 /dev/sda2 /dev/sda3 /dev/sda4"
}
teardown() { teardown_stubs; }

@test "ESP partition is wiped" {
    run wipe_boot_artifacts /dev/sda
    assert_ok
    stub_called_with wipefs "/dev/sda1"
    stub_called_with blkdiscard "/dev/sda1"
}

@test "unencrypted /boot partition is wiped" {
    run wipe_boot_artifacts /dev/sda
    assert_ok
    stub_called_with wipefs "/dev/sda2"
}

@test "the LUKS root partition is NOT a boot-wipe target" {
    run wipe_boot_artifacts /dev/sda
    assert_ok
    run grep -E '^wipefs\b.*/dev/sda3' "$DURESSD_STUB_LOG"
    assert_fail   # sda3 must not appear in any wipefs call
}

@test "BIOS-boot partition (GRUB core.img) is wiped" {
    run wipe_boot_artifacts /dev/sda
    assert_ok
    stub_called_with wipefs "/dev/sda4"
}

@test "MBR / boot-gap of the parent disk is overwritten" {
    run wipe_boot_artifacts /dev/sda
    assert_ok
    # rand_write on the bare parent disk => a dd seek=0 to /dev/sda
    stub_called_with dd "of=/dev/sda "
}

@test "UEFI NVRAM is never touched under a scoped (test) run" {
    run wipe_boot_artifacts /dev/sda
    assert_ok
    stub_not_called efibootmgr
}

@test "wipe_real runs Phase 1.5 when WIPE_BOOT_ARTIFACTS=true" {
    export STUB_LSBLK_NAME="/dev/sda3"
    export STUB_LUKS_DEVICES="/dev/sda3"
    export STUB_PKNAME="sda"
    export WIPE_BOOT_ARTIFACTS=true OVERWRITE_LUKS_HEADER=false WIPE_FULL_DEVICE=false
    run wipe_real
    assert_ok
    assert_output_contains "Phase 1.5"
    stub_called_with wipefs "/dev/sda1"
}

@test "wipe_real skips Phase 1.5 when WIPE_BOOT_ARTIFACTS=false" {
    export STUB_LSBLK_NAME="/dev/sda3"
    export STUB_LUKS_DEVICES="/dev/sda3"
    export WIPE_BOOT_ARTIFACTS=false OVERWRITE_LUKS_HEADER=false WIPE_FULL_DEVICE=false
    run wipe_real
    assert_ok
    refute_output_contains "Phase 1.5"
}
