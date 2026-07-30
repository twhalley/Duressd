#!/usr/bin/env bash
# Runs INSIDE the disposable duressd VM when it is booted with `duressd.golden=1`
# (see tests/vm/golden-vm.sh). Builds the LUKS-at-boot golden image and drives
# the full boot test — CONTROL boots, DURESS passphrase wipes + won't boot —
# using a NESTED QEMU. The HOST is never involved: every byte lands on a scratch
# virtio disk that the launcher created and throws away.
#
#   DURESSD_GOLDEN_DISK=/dev/vda bash tests/vm/golden-inside.sh
#
# Requires (baked into the test ISO): qemu-base, edk2-ovmf, arch-install-scripts.
# The nested QEMU uses KVM when the outer VM exposes /dev/kvm (nested virt on),
# otherwise it falls back to slow-but-correct TCG emulation.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$REPO"
DISK="${DURESSD_GOLDEN_DISK:-/dev/vda}"
BUILD="/mnt/golden-build"

hr()   { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
fail() { printf '\n\033[1;41m  ✘  GOLDEN (in-VM) FAILED: %s  \033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || fail "run as root inside the VM"
[[ -b "$DISK" ]]  || fail "scratch disk $DISK not found (launcher must attach one)"

# The build + boot test are heavy on files; keep them ALL on the scratch disk so
# the RAM-backed live root is never filled.
cleanup() {
    set +e
    mountpoint -q "$BUILD" && { umount -R "$BUILD" 2>/dev/null || umount -Rl "$BUILD" 2>/dev/null; }
}
trap cleanup EXIT INT TERM HUP

hr "preparing scratch build disk ($DISK) — throwaway, in-VM only"
mkfs.ext4 -qF "$DISK"
mkdir -p "$BUILD"
mount "$DISK" "$BUILD"

export E2E_IMAGES="$BUILD/images"     # golden qcow2 + raw live here
export E2E_WORKDIR="$BUILD/work"      # pacstrap cache + convert scratch live here
mkdir -p "$E2E_IMAGES" "$E2E_WORKDIR"

# Ensure loop nodes exist inside the VM (the build/test scripts also try, but do
# it up-front so failures are obvious).
modprobe loop 2>/dev/null || true

if [[ -e /dev/kvm ]]; then
    hr "nested KVM available — the boot test will run at native speed"
else
    hr "no /dev/kvm inside the VM — nested boot falls back to TCG (slow but valid)"
fi

hr "building the LUKS-at-boot golden image (pacstrap onto $DISK)"
bash tests/e2e/build-luks-duress.sh || fail "golden image build failed"

hr "boot test — CONTROL boots, DURESS passphrase wipes + won't boot (nested QEMU)"
bash tests/e2e/luks-duress-test.sh || fail "golden boot test failed"

printf '\n\033[1;42m  ✔  GOLDEN LUKS-AT-BOOT TEST PASSED — inside the VM, host untouched  \033[0m\n'
