#!/usr/bin/env bats
# Loop-device integration: a Qubes-representative disk (GPT: ESP + ext4 /boot +
# LUKS pool) wiped by the real boot-artifact and crypto-destruction functions.

load 'helpers'

setup()    { int_setup; }
teardown() { int_teardown; }

@test "boot-artifact wipe scrubs the ESP and phase1 destroys the LUKS pool" {
    command -v sfdisk    >/dev/null || skip "sfdisk not available"
    command -v mkfs.vfat >/dev/null || skip "dosfstools (mkfs.vfat) not available"

    f="$(mktemp "$INT_WORKDIR/qubes.XXXXXX.img")"
    truncate -s 200M "$f"
    # GPT: p1 = EFI System (U), p2 = Linux /boot (L), p3 = Linux LUKS pool (L)
    sfdisk "$f" >/dev/null <<'EOF'
label: gpt
,48M,U
,48M,L
,,L
EOF

    loop="$(losetup -P --find --show "$f")"; INT_LOOPS+=("$loop")
    udevadm settle 2>/dev/null || sleep 0.3
    esp="${loop}p1"; boot="${loop}p2"; root="${loop}p3"
    [ -b "$esp" ] || skip "partition devices did not appear (need loop -P support)"

    mkfs.vfat "$esp" >/dev/null 2>&1
    printf '%s' pool-unlock | cryptsetup luksFormat "${LUKS_FAST[@]}" --key-file=- "$root"
    assert_is_luks "$root"

    export DURESSD_TARGET_DEVICES="$loop $esp $boot $root"
    # shellcheck disable=SC2086
    assert_safe_targets $loop $esp $boot $root

    # mkfs.vfat + luksFormat above trigger a udev re-scan; wait for it to settle so
    # `lsblk PARTTYPE` reliably reports the ESP GUID (else the ESP goes undetected).
    udevadm settle 2>/dev/null || sleep 0.5
    wipe_boot_artifacts "$loop"
    phase1_crypto_destruction "$root"

    # ESP filesystem signature is gone …
    run wipefs -n "$esp"
    refute_output_contains "vfat"
    # … and the LUKS pool header is gone.
    refute_is_luks "$root"
}

@test "scoping protects out-of-scope partitions on the same disk" {
    command -v sfdisk >/dev/null || skip "sfdisk not available"

    f="$(mktemp "$INT_WORKDIR/twopart.XXXXXX.img")"
    truncate -s 96M "$f"
    sfdisk "$f" >/dev/null <<'EOF'
label: gpt
,32M,L
,,L
EOF
    loop="$(losetup -P --find --show "$f")"; INT_LOOPS+=("$loop")
    udevadm settle 2>/dev/null || sleep 0.3
    p1="${loop}p1"; p2="${loop}p2"
    [ -b "$p1" ] || skip "partition devices did not appear"

    printf '%s' k | cryptsetup luksFormat "${LUKS_FAST[@]}" --key-file=- "$p1"
    printf '%s' k | cryptsetup luksFormat "${LUKS_FAST[@]}" --key-file=- "$p2"

    # Only p1 is in scope; p2 must survive.
    export DURESSD_TARGET_DEVICES="$p1"
    local -a devs=()
    while IFS= read -r d; do devs+=("$d"); done < <(discover_luks_devices)
    phase1_crypto_destruction "${devs[@]}"

    refute_is_luks "$p1"     # in-scope: destroyed
    assert_is_luks "$p2"     # out-of-scope: untouched
}
