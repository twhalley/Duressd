#!/usr/bin/env bash
# Loop-device integration tests.
#
# Runs the REAL duressd wipe functions (cryptsetup, wipefs, blkdiscard, …)
# against throwaway loopback devices. The host's real disks are never a target:
#   • every phase honours DURESSD_TARGET_DEVICES (set to the loop devices), and
#   • assert_safe_targets refuses anything not a loop device backed by this
#     run's temp workdir.
#
# Requires root (loop devices) and: losetup, cryptsetup, wipefs. sfdisk +
# dosfstools enable the Qubes-representative test (skipped if absent).
set -euo pipefail
cd "$(dirname "$0")/../.."

if [[ $EUID -ne 0 ]]; then
    echo "  integration tests require root (loop devices) — re-run with: sudo make integration" >&2
    exit 1
fi

BATS="${BATS:-bats}"
command -v "$BATS" >/dev/null 2>&1 || { echo "bats not found — install bats-core or pass BATS=/path" >&2; exit 1; }
for t in losetup cryptsetup wipefs; do
    command -v "$t" >/dev/null 2>&1 || { echo "required tool missing: $t" >&2; exit 1; }
done

exec "$BATS" tests/integration
