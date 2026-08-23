#!/usr/bin/env bats
# Unit tests for wipe_boot_artifacts — ESP/boot/BIOS-boot/MBR targeting.
# Fixtures use lsblk's -P (key="value") format — the same empty-safe format the
# handler parses, and what real lsblk emits (its -o columns are space-padded, not
# tab-delimited, so a tab-based fixture would not exercise the real parse path).

load '../lib/common'

ESP_GUID="c12a7328-f81f-11d2-ba4b-00a0c93ec93b"
LINUX_GUID="0fc63daf-8483-4772-8e79-3d69d8477de4"
LUKS_GUID="ca7d7ccb-63ed-4c53-861c-1742536059cc"
BIOSBOOT_GUID="21686148-6449-6e6f-744e-656564454649"

setup() {
    setup_stubs
    load_handler
    # A Qubes-style GPT: ESP + ext4 /boot + LUKS root, plus a BIOS-boot part.
    export STUB_LSBLK_BOOTSCAN="NAME=\"/dev/sda1\" PARTTYPE=\"${ESP_GUID}\" FSTYPE=\"vfat\" MOUNTPOINT=\"/boot/efi\"
NAME=\"/dev/sda2\" PARTTYPE=\"${LINUX_GUID}\" FSTYPE=\"ext4\" MOUNTPOINT=\"/boot\"
NAME=\"/dev/sda3\" PARTTYPE=\"${LUKS_GUID}\" FSTYPE=\"crypto_LUKS\" MOUNTPOINT=\"\""
    export STUB_LSBLK_PARTTYPE="NAME=\"/dev/sda4\" PARTTYPE=\"${BIOSBOOT_GUID}\""
    export DURESSD_TARGET_DEVICES="/dev/sda /dev/sda1 /dev/sda2 /dev/sda3 /dev/sda4"
}
teardown() { teardown_stubs; }

@test "ESP partition is wiped" {
    run wipe_boot_artifacts /dev/sda
    assert_ok
    stub_called_with wipefs "/dev/sda1"
    stub_called_with blkdiscard "/dev/sda1"
}

@test "boot-artifact scrub sizes the overwrite to the WHOLE partition, not a 32 MiB head" {
    # Regression for a gap a PHYSICAL test caught: a head-only (32 MiB) scrub left
    # a /boot marker recoverable at ~116 MiB because blkdiscard is non-
    # deterministic on USB. The rand_write must cover the full partition size.
    # 128 MiB ESP => 32 × 4 MiB blocks (count=32), not the old fixed count=8.
    export STUB_SIZE=134217728        # 128 MiB, reported for every partition
    # / is NOT on these devices (STUB_FINDMNT unset → findmnt / empty), so the
    # live-root guard does not engage and the full scrub applies.
    run wipe_boot_artifacts /dev/sda
    assert_ok
    stub_called_with dd "of=/dev/sda1 bs=4M seek=0 count=32"    # full ESP overwrite
    stub_called_with dd "of=/dev/sda2 bs=4M seek=0 count=32"    # full /boot overwrite
}

@test "live-root guard: a boot partition on the running-root disk gets a 32 MiB head, not a full scrub" {
    # A physical test showed a full same-device scrub starves the live root's I/O
    # on slow media and crashes the wipe. When / is on the same disk as the boot
    # partition, the scrub must stay light (count=8); the boot hook does the rest.
    export STUB_SIZE=134217728        # 128 MiB ESP → would be count=32 if unguarded
    export STUB_FINDMNT="/dev/mapper/root"   # findmnt -no SOURCE /  → the live root (dm-crypt)
    export STUB_LSBLK_NAMETYPE="sda disk"    # lsblk -nrso NAME,TYPE → disk ancestor = sda
    run wipe_boot_artifacts /dev/sda
    assert_ok
    stub_called_with dd "of=/dev/sda1 bs=4M seek=0 count=8"     # HEAD only on root disk
    run grep -E '^dd\b.*of=/dev/sda1 .*count=32' "$DURESSD_STUB_LOG"
    assert_fail                                                  # never the full scrub HERE
}

@test "finishing scrub: the deferred live-root ESP gets a FULL overwrite last" {
    export STUB_SIZE=134217728        # 128 MiB
    export STUB_FINDMNT="/dev/mapper/root"
    export STUB_LSBLK_NAMETYPE="sda disk"
    # Call directly (not via `run`) so _DEFERRED_BOOT_SCRUB persists across the two.
    wipe_boot_artifacts /dev/sda >/dev/null 2>&1
    [ "${#_DEFERRED_BOOT_SCRUB[@]}" -ge 1 ]                     # sda1 was recorded for deferral
    finish_boot_scrub >/dev/null 2>&1
    stub_called_with dd "of=/dev/sda1 bs=4M seek=0 count=32"    # now the FULL overwrite
}

@test "finishing scrub is a no-op when nothing was deferred (off-root disks)" {
    _DEFERRED_BOOT_SCRUB=()
    run finish_boot_scrub
    assert_ok
    stub_not_called dd
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

@test "MBR / boot-gap of the parent disk is overwritten (deferred to wipe_parent_tables)" {
    # The parent-disk MBR/GPT overwrite is deliberately NOT part of
    # wipe_boot_artifacts (it would break the running root mid-wipe) — it lives in
    # wipe_parent_tables(), which wipe_real runs LAST, just before poweroff.
    run wipe_parent_tables /dev/sda
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
