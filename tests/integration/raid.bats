#!/usr/bin/env bats
# Loop-device integration: a REAL RAID6 array (mdadm) with LUKS layered on top,
# wiped by the real Phase 1 (crypto destruction) + Phase 3 (full-device overwrite
# + RAID teardown) functions. Proves the LUKS header is destroyed, the array is
# stopped, every member superblock is wiped, and the array cannot be reassembled
# from the raw members — all SCOPED to our loop devices via DURESSD_TARGET_DEVICES,
# so a host's own arrays (e.g. md127) and their member disks are never touched.

load 'helpers'

setup() { int_setup; }
teardown() {
    # Stop any array this test may have left assembled BEFORE detaching the loops,
    # otherwise the members are busy and losetup -d fails.
    [[ -n "${ASSEMBLE_MD:-}" && -e "$ASSEMBLE_MD" ]] && mdadm --stop "$ASSEMBLE_MD" 2>/dev/null || true
    [[ -n "${MD:-}" && -e "$MD" ]] && mdadm --stop "$MD" 2>/dev/null || true
    mdadm --stop /dev/md/duressdtest 2>/dev/null || true
    int_teardown
}

@test "RAID6 + LUKS: phase1 erases the header, phase3 tears the array down" {
    command -v mdadm >/dev/null || skip "mdadm not available"

    # Four loop members — RAID6 needs a minimum of four devices.
    local -a LOOPS=()
    local n
    for n in 1 2 3 4; do LOOPS+=("$(new_loop 64)"); done

    # Build the array under a unique name so we never collide with a host array;
    # --assume-clean skips the initial resync (fast), --run starts it immediately.
    run mdadm --create /dev/md/duressdtest --name=duressdtest \
        --level=6 --raid-devices=4 --metadata=1.2 --assume-clean --run --force "${LOOPS[@]}"
    [ "$status" -eq 0 ] || skip "could not create RAID6 (kernel raid456 unavailable?): $output"
    udevadm settle 2>/dev/null || sleep 0.5
    MD="$(readlink -f /dev/md/duressdtest)"     # resolve /dev/md/NAME → /dev/md12X
    [ -b "$MD" ]

    # Sanity: every member carries a RAID superblock, and the array carries LUKS.
    run mdadm --examine "${LOOPS[0]}"; [ "$status" -eq 0 ]
    printf '%s' raidpass | cryptsetup luksFormat "${LUKS_FAST[@]}" --key-file=- "$MD"
    assert_is_luks "$MD"

    # Scope to OUR devices only. The safety rail vets each loop's backing file is
    # inside this run's workdir (it accepts loop devices; the array is built purely
    # on those vetted loops).
    export DURESSD_TARGET_DEVICES="$MD ${LOOPS[*]}"
    # shellcheck disable=SC2086
    assert_safe_targets ${LOOPS[*]}

    # Phase 1 — crypto destruction on the assembled array device.
    phase1_crypto_destruction "$MD"
    refute_is_luks "$MD"

    # Phase 3 — overwrite the array, stop it, wipe the member superblocks.
    phase3_wipe_full_devices "$MD"

    # The array is stopped — it is no longer an active array. (Assert via --detail
    # rather than node existence, which can trail mdadm --stop under udev.)
    udevadm settle 2>/dev/null || sleep 0.5
    run mdadm --detail "$MD"; [ "$status" -ne 0 ]

    # Every member superblock is wiped — mdadm --examine finds nothing.
    for member in "${LOOPS[@]}"; do
        run mdadm --examine "$member"
        [ "$status" -ne 0 ]
    done

    # And the array can no longer be reassembled from the raw members.
    ASSEMBLE_MD=/dev/md/duressdreasm
    run mdadm --assemble "$ASSEMBLE_MD" "${LOOPS[@]}"
    [ "$status" -ne 0 ]
}
