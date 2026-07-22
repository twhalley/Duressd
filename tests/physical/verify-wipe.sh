#!/usr/bin/env bash
# duressd physical wipe verifier — run from a LIVE USB after a real wipe.
#
#   sudo bash verify-wipe.sh <disk> [options]
#
# Read-only. Checks that a duressd wipe left nothing recoverable on <disk> and
# emits a Markdown report you can paste back verbatim. Pair it with baseline.sh,
# which captures the pre-wipe state and writes the plaintext marker this script
# hunts for.
#
# Options:
#   --baseline DIR   compare against a baseline captured by baseline.sh
#                    (enables the UEFI-NVRAM-entry and TPM checks)
#   --marker STR     plaintext marker to search raw sectors for
#                    (default: DURESSD-PHYSICAL-TEST-MARKER)
#   --scenario NAME  label for the report (grub-luks|sdboot-luks|qubes)
#   --report FILE    also write the report to FILE (always printed to stdout)
#   --quick          sample the disk for the marker instead of a full scan
set -euo pipefail

DISK=""; BASELINE=""; MARKER="DURESSD-PHYSICAL-TEST-MARKER"
SCENARIO="unspecified"; REPORT=""; QUICK=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --baseline) BASELINE="$2"; shift 2 ;;
        --marker)   MARKER="$2";   shift 2 ;;
        --scenario) SCENARIO="$2"; shift 2 ;;
        --report)   REPORT="$2";   shift 2 ;;
        --quick)    QUICK=1;       shift ;;
        -h|--help)  sed -n '2,20p' "$0"; exit 0 ;;
        -*)         echo "unknown option: $1" >&2; exit 1 ;;
        *)          DISK="$1";     shift ;;
    esac
done

[[ -n "$DISK" ]]    || { echo "usage: verify-wipe.sh <disk> [options]" >&2; exit 1; }
[[ -b "$DISK" ]]    || { echo "not a block device: $DISK" >&2; exit 1; }
[[ $EUID -eq 0 ]]   || { echo "must run as root" >&2; exit 1; }

# ── result accumulation ───────────────────────────────────────────────────────
declare -a ROWS=()
PASS=0; WARN=0; FAILN=0
record() {  # record <PASS|WARN|FAIL> <check> <detail>
    ROWS+=("$1"$'\t'"$2"$'\t'"$3")
    case "$1" in PASS) ((PASS++)) ;; WARN) ((WARN++)) ;; FAIL) ((FAILN++)) ;; esac
}

parts_of() {  # echo partition device nodes of DISK, if any survived
    lsblk -lnpo NAME "$DISK" 2>/dev/null | tail -n +2
}

# ── 1. no LUKS header on the disk or any surviving partition ──────────────────
luks_found=""
for dev in "$DISK" $(parts_of); do
    [[ -b "$dev" ]] || continue
    cryptsetup isLuks "$dev" 2>/dev/null && luks_found+="$dev "
done
if [[ -z "$luks_found" ]]; then
    record PASS "no-luks-header" "no LUKS header on $DISK or any partition"
else
    record FAIL "no-luks-header" "LUKS header SURVIVED on: $luks_found"
fi

# ── 2. no bootable filesystem signatures (ESP/boot) remain ────────────────────
sig_found=""
for dev in "$DISK" $(parts_of); do
    [[ -b "$dev" ]] || continue
    t="$(blkid -o value -s TYPE "$dev" 2>/dev/null || true)"
    [[ "$t" == vfat || "$t" == ext* || "$t" == crypto_LUKS ]] && sig_found+="${dev}:${t} "
done
if [[ -z "$sig_found" ]]; then
    record PASS "no-boot-fs" "no vfat/ext/LUKS filesystem signatures remain"
else
    record WARN "no-boot-fs" "filesystem signatures still present: $sig_found"
fi

# ── 3. plaintext marker absent from raw sectors (proves /boot + ESP scrubbed) ─
if [[ "$QUICK" == 1 ]]; then
    hits=0
    for off in 0 $((1024*1024*1024)) $((8*1024*1024*1024)); do
        dd if="$DISK" bs=1M skip=$((off/1024/1024)) count=512 status=none 2>/dev/null \
            | LC_ALL=C grep -a -c -- "$MARKER" >/tmp/.m 2>/dev/null || true
        hits=$(( hits + $(cat /tmp/.m 2>/dev/null || echo 0) ))
    done
    method="sampled (3×512 MiB windows)"
else
    hits="$(LC_ALL=C grep -a -c -- "$MARKER" "$DISK" 2>/dev/null || echo 0)"
    method="full-disk scan"
fi
if [[ "$hits" -eq 0 ]]; then
    record PASS "marker-absent" "plaintext marker not found ($method)"
else
    record FAIL "marker-absent" "plaintext marker found $hits time(s) ($method)"
fi

# ── 4. UEFI NVRAM boot entries removed (needs baseline) ───────────────────────
if command -v efibootmgr &>/dev/null && [[ -d /sys/firmware/efi ]]; then
    now_entries="$(efibootmgr 2>/dev/null | sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*\? \(.*\)/\2/p' | sort -u)"
    if [[ -n "$BASELINE" && -f "$BASELINE/efibootmgr.txt" ]]; then
        base_entries="$(sed -n 's/^Boot\([0-9A-Fa-f]\{4\}\)\*\? \(.*\)/\2/p' "$BASELINE/efibootmgr.txt" | sort -u)"
        # OS entries that existed pre-wipe but are gone now.
        survived="$(comm -12 <(printf '%s\n' "$base_entries") <(printf '%s\n' "$now_entries") \
                    | grep -viE 'UEFI:|USB|CD/DVD|Network|PXE|Shell' || true)"
        if [[ -z "$survived" ]]; then
            record PASS "nvram-cleared" "no pre-wipe OS boot entries remain"
        else
            record WARN "nvram-cleared" "boot entries still present: $(echo "$survived" | tr '\n' ',')"
        fi
    else
        record WARN "nvram-cleared" "no baseline — current entries: $(echo "$now_entries" | tr '\n' ',' )"
    fi
else
    record WARN "nvram-cleared" "not a UEFI system (or efibootmgr absent) — skipped"
fi

# ── 5. TPM-sealed key evicted (needs baseline + tpm2-tools) ───────────────────
if command -v tpm2_getcap &>/dev/null && [[ -e /dev/tpmrm0 || -e /dev/tpm0 ]]; then
    persist_now="$(tpm2_getcap handles-persistent 2>/dev/null | grep -c 0x || echo 0)"
    if [[ -n "$BASELINE" && -f "$BASELINE/tpm-handles.txt" ]]; then
        persist_base="$(grep -c 0x "$BASELINE/tpm-handles.txt" 2>/dev/null || echo 0)"
        if [[ "$persist_now" -lt "$persist_base" || "$persist_now" -eq 0 ]]; then
            record PASS "tpm-cleared" "persistent handles: baseline=$persist_base now=$persist_now"
        else
            record WARN "tpm-cleared" "persistent handles unchanged ($persist_now) — TPM may not be cleared"
        fi
    else
        record WARN "tpm-cleared" "no baseline — persistent handles now: $persist_now"
    fi
else
    record WARN "tpm-cleared" "no TPM or tpm2-tools — skipped"
fi

# ── 6. partition table status (informational) ─────────────────────────────────
if pt="$(blkid -o value -s PTTYPE "$DISK" 2>/dev/null)" && [[ -n "$pt" ]]; then
    record WARN "partition-table" "a $pt partition table is still present on $DISK"
else
    record PASS "partition-table" "no partition table detected on $DISK"
fi

# ── report ────────────────────────────────────────────────────────────────────
overall=PASS
(( WARN  > 0 )) && overall=WARN
(( FAILN > 0 )) && overall=FAIL
disk_model="$(lsblk -ndo MODEL "$DISK" 2>/dev/null || true)"
kernel="$(uname -srm)"
commit="$(git -C "$(dirname "$0")" rev-parse --short HEAD 2>/dev/null || echo unknown)"

emit() {
    echo "## duressd physical wipe report"
    echo
    echo "| field | value |"
    echo "|---|---|"
    echo "| scenario | \`$SCENARIO\` |"
    echo "| disk | \`$DISK\` ${disk_model:+($disk_model)} |"
    echo "| verifier commit | \`$commit\` |"
    echo "| live env | \`$kernel\` |"
    echo "| baseline | ${BASELINE:-none} |"
    echo "| **overall** | **$overall** — $PASS pass, $WARN warn, $FAILN fail |"
    echo
    echo "| result | check | detail |"
    echo "|---|---|---|"
    local r c d line
    for line in "${ROWS[@]}"; do
        IFS=$'\t' read -r r c d <<<"$line"
        local icon="✅"; [[ "$r" == WARN ]] && icon="⚠️"; [[ "$r" == FAIL ]] && icon="❌"
        echo "| $icon $r | \`$c\` | $d |"
    done
    echo
    echo "> Reboot check (manual): power-cycle the machine with the wiped disk as"
    echo "> the only boot target — it must fail to boot any OS. Record the result."
}

out="$(emit)"
printf '%s\n' "$out"
[[ -n "$REPORT" ]] && { printf '%s\n' "$out" >"$REPORT"; echo "(report written to $REPORT)" >&2; }
[[ "$overall" == FAIL ]] && exit 2 || exit 0
