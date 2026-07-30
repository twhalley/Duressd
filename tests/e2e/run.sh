#!/usr/bin/env bash
# End-to-end: boot each golden image under KVM, let the guest fire the REAL
# duressd wipe against its own virtual disk, then prove from the host that no
# LUKS header, no ESP filesystem, and no bootable OS remain.
#
#   sudo bash tests/e2e/run.sh [scenario ...]      # default: all built images
#
# Golden images are built once with tests/e2e/build-golden.sh (needs an Arch
# host). Each run here boots a disposable qcow2 overlay, so goldens are reused.
set -euo pipefail
cd "$(dirname "$0")/../.."
# shellcheck source=tests/e2e/lib.sh
source tests/e2e/lib.sh

e2e_require
[[ $EUID -eq 0 ]] || { echo "e2e disk inspection needs root (nbd/partprobe) — use sudo" >&2; exit 1; }

SCENARIOS=("$@")
if [[ ${#SCENARIOS[@]} -eq 0 ]]; then
    SCENARIOS=(sdboot-luks grub-luks qubes-like)
fi

rc=0
for s in "${SCENARIOS[@]}"; do
    golden="$E2E_IMAGES/${s}.qcow2"
    echo
    log "scenario: $s"
    if [[ ! -f "$golden" ]]; then
        echo "  ⚠  golden image missing: $golden"
        echo "     build it first:  sudo bash tests/e2e/build-golden.sh $s"
        rc=1; continue
    fi

    overlay="$(e2e_overlay "$golden")"
    serial="$(mktemp)"
    trap 'rm -f "$overlay" "$serial"' RETURN

    log "booting guest — it will auto-trigger the wipe and power off"
    e2e_boot "$overlay" uefi "$serial"

    log "inspecting wiped disk from the host"
    nbd="$(e2e_nbd_connect "$overlay")"
    trap 'e2e_nbd_disconnect "$nbd"; rm -f "$overlay" "$serial"' RETURN

    e2e_assert_no_luks    "$nbd" || rc=1
    e2e_assert_no_boot_fs "$nbd" || rc=1
    e2e_nbd_disconnect "$nbd"

    e2e_assert_unbootable "$overlay" uefi || rc=1

    rm -f "$overlay" "$serial"
    trap - RETURN
done

echo
if [[ $rc -eq 0 ]]; then pass "all e2e scenarios wiped cleanly"; else fail "one or more e2e scenarios failed"; fi
exit $rc
