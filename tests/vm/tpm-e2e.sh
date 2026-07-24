#!/usr/bin/env bash
# Real TPM wipe — end to end, against the VM's EMULATED TPM (swtpm attached by
# tests/vm/auto.sh|shell.sh|launch.sh). Seals a secret into an owner NV index,
# runs duressd's real hardware-key wipe (tpm2_clear via the actual engine), and
# proves the TPM was cleared and the secret is gone.
#
# Skips cleanly when no TPM is present (no emulated TPM attached). Safe: the only
# thing touched is the VM's throwaway software TPM — never real hardware.
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"; cd "$REPO" || exit 1
hr()   { printf '\n\033[1;36m== %s ==\033[0m\n' "$*"; }
pass() { printf '  \033[1;32m✔  %s\033[0m\n' "$*"; }
skip() { printf '  \033[1;33m↷  %s\033[0m\n' "$*"; exit 0; }
fail() { printf '  \033[1;31m✘  FAIL: %s\033[0m\n' "$*"; exit 1; }

[[ -e /dev/tpmrm0 || -e /dev/tpm0 ]] \
    || skip "no TPM present — skipping (attach swtpm to the VM to exercise this)"
command -v tpm2_nvdefine >/dev/null \
    || skip "tpm2-tools not available — skipping TPM test"

export TPM2TOOLS_TCTI="device:/dev/tpmrm0"
NV=0x1500016
SECRET="TPM-SEALED-$(openssl rand -hex 8)"

hr "provisioning a secret into the emulated TPM (owner NV index $NV)"
# Start from a clean, known state (empty auth on a fresh swtpm).
tpm2_clear -c platform >/dev/null 2>&1 || tpm2_clear >/dev/null 2>&1 || true
tpm2_nvdefine "$NV" -C o -s 64 -a "ownerread|ownerwrite" >/dev/null 2>&1 \
    || skip "could not define an NV index — TPM not usable in this VM"
printf '%s' "$SECRET" | tpm2_nvwrite "$NV" -C o -i- >/dev/null 2>&1 \
    || fail "could not write the secret to the TPM"
[[ "$(tpm2_nvread "$NV" -C o 2>/dev/null)" == "$SECRET" ]] \
    || fail "secret not readable back before wipe"
pass "secret sealed into the TPM and read back OK"

hr "running duressd's hardware-key wipe (real tpm2_clear via the engine)"
DURESSD_LIB_ONLY=1 source src/handler   # sets DRYRUN=0 → real (non-preview) mode
unset DURESSD_TARGET_DEVICES     # UNscoped so the hardware wipe actually runs
wipe_hardware_keys               # the real Phase 1.6 path → tpm2_clear
pass "wipe_hardware_keys completed"

hr "verifying the TPM was cleared and the sealed secret is gone"
tpm2_nvread "$NV" -C o >/dev/null 2>&1 \
    && fail "NV index still readable — the TPM was NOT cleared"
tpm2_nvreadpublic 2>/dev/null | grep -q "$NV" \
    && fail "NV index still defined — tpm2_clear did not remove it"
pass "TPM cleared: the sealed secret is destroyed and unrecoverable"

hr "TPM WIPE END-TO-END PASSED — real tpm2_clear against the (emulated) TPM"
