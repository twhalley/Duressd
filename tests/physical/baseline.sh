#!/usr/bin/env bash
# duressd physical baseline capturer — run on the TARGET OS *before* wiping.
#
#   sudo bash baseline.sh [--disk DISK] [--scenario NAME] [--outdir DIR]
#
# Captures the pre-wipe state (partition/LUKS/ESP/NVRAM/TPM) and plants a
# plaintext marker in the unencrypted /boot and ESP so verify-wipe.sh can later
# prove those regions were scrubbed. Read-only except for the marker files and
# a LUKS header backup.
set -euo pipefail

DISK=""; SCENARIO="unspecified"; OUTDIR=""
MARKER="${DURESSD_MARKER:-DURESSD-PHYSICAL-TEST-MARKER}"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --disk)     DISK="$2";     shift 2 ;;
        --scenario) SCENARIO="$2"; shift 2 ;;
        --outdir)   OUTDIR="$2";   shift 2 ;;
        -h|--help)  sed -n '2,12p' "$0"; exit 0 ;;
        *)          echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done
[[ $EUID -eq 0 ]] || { echo "must run as root" >&2; exit 1; }

# Default DISK = the whole disk backing / (parent of the root source).
if [[ -z "$DISK" ]]; then
    root_src="$(findmnt -no SOURCE / 2>/dev/null || true)"
    pk="$(lsblk -no PKNAME "$root_src" 2>/dev/null | head -1 || true)"
    [[ -n "$pk" ]] && DISK="/dev/$pk"
fi
[[ -b "$DISK" ]] || { echo "could not determine target disk — pass --disk /dev/…" >&2; exit 1; }

echo "  Target disk : $DISK  ($(lsblk -ndo MODEL "$DISK" 2>/dev/null || echo '?'))"
echo "  Scenario    : $SCENARIO"
read -rp "  Capture baseline for this disk? [y/N]: " ans
[[ "$ans" =~ ^[Yy]$ ]] || { echo "aborted."; exit 1; }

OUTDIR="${OUTDIR:-baseline-${SCENARIO}-$(date +%Y%m%d-%H%M%S)}"
mkdir -p "$OUTDIR"
echo "  →  writing baseline to $OUTDIR/"

# ── state capture ─────────────────────────────────────────────────────────────
{ echo "disk=$DISK"; echo "scenario=$SCENARIO"; echo "marker=$MARKER";
  echo "date=$(date -Is)"; } > "$OUTDIR/meta.txt"
lsblk -f        "$DISK"            >"$OUTDIR/lsblk.txt"        2>/dev/null || true
blkid                             >"$OUTDIR/blkid.txt"        2>/dev/null || true
sfdisk -d       "$DISK"            >"$OUTDIR/parttable.txt"    2>/dev/null || true
cat /proc/cmdline                 >"$OUTDIR/cmdline.txt"      2>/dev/null || true
cat /etc/os-release               >"$OUTDIR/os-release.txt"   2>/dev/null || true

# LUKS: dump headers + back them up (also documents the pool for Qubes).
: >"$OUTDIR/luks-devices.txt"
while IFS= read -r dev; do
    [[ -b "$dev" ]] || continue
    if cryptsetup isLuks "$dev" 2>/dev/null; then
        echo "$dev" >>"$OUTDIR/luks-devices.txt"
        cryptsetup luksDump "$dev" >"$OUTDIR/luksdump-$(basename "$dev").txt" 2>/dev/null || true
        cryptsetup luksHeaderBackup "$dev" \
            --header-backup-file "$OUTDIR/luksheader-$(basename "$dev").img" 2>/dev/null || true
    fi
done < <(lsblk -lnpo NAME "$DISK" 2>/dev/null)

# UEFI + TPM state.
command -v efibootmgr &>/dev/null && efibootmgr -v >"$OUTDIR/efibootmgr.txt" 2>/dev/null || true
if command -v tpm2_getcap &>/dev/null; then
    tpm2_getcap handles-persistent  >"$OUTDIR/tpm-handles.txt" 2>/dev/null || true
    tpm2_getcap properties-variable >"$OUTDIR/tpm-props.txt"   2>/dev/null || true
fi

# duressd's own view, if installed.
if command -v duressd &>/dev/null; then
    duressd status >"$OUTDIR/duressd-status.txt" 2>&1 || true
    duressd health >"$OUTDIR/duressd-health.txt" 2>&1 || true
    duressd scan   >"$OUTDIR/duressd-scan.txt"   2>&1 || true
fi

# ── plant the marker in unencrypted regions (/boot and the ESP) ───────────────
planted=""
for mp in /boot /boot/efi /efi; do
    if mountpoint -q "$mp" 2>/dev/null; then
        if printf '%s\n' "$MARKER" >"$mp/.duressd-marker" 2>/dev/null; then
            sync; planted+="$mp "
        fi
    fi
done
if [[ -n "$planted" ]]; then
    echo "  →  marker planted in: $planted"
else
    echo "  ⚠  no /boot or ESP mountpoint found to plant the marker — the raw-sector"
    echo "     marker check in verify-wipe will be inconclusive for this run."
fi

echo
echo "  ✔  baseline captured: $OUTDIR/"
echo "     Next: image this disk (for restore), configure + trigger duressd,"
echo "     boot a live USB, then run:"
echo "       sudo bash tests/physical/verify-wipe.sh $DISK --baseline $OUTDIR --scenario $SCENARIO"
