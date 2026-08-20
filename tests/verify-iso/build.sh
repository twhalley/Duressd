#!/usr/bin/env bash
# Build a self-contained duressd LIVE VERIFIER ISO from the stock archiso
# `releng` profile: a read-only live Arch environment with NetworkManager
# (interactive `nmtui`), every verify-wipe.sh dependency, and this repo baked
# into /root/Duressd — so you can burn it, boot the machine with the wiped disk
# attached, get on WiFi, and run `duressd-verify /dev/sdX`.
#
#   sudo bash tests/verify-iso/build.sh          # -> out/duressd-verify-*.iso
#
# REQUIRES root (mkarchiso mounts/loop-devices) and the `archiso` package.
# Layers onto releng so the version-matched bootloader config is inherited.
# Env: OUT=<dir>  WORK=<dir>  RELENG=<path>
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
RELENG="${RELENG:-/usr/share/archiso/configs/releng}"
OUT="${OUT:-$REPO/out}"
WORK="${WORK:-$REPO/.verify-iso-work}"

[[ $EUID -eq 0 ]]               || { echo "run as root:  sudo bash tests/verify-iso/build.sh" >&2; exit 1; }
command -v mkarchiso >/dev/null || { echo "install archiso first:  pacman -S archiso" >&2; exit 1; }
[[ -d "$RELENG" ]]             || { echo "releng profile not found at $RELENG (install archiso)" >&2; exit 1; }

PROFILE="$WORK/profile"
echo ">> staging profile from $RELENG"
rm -rf "$PROFILE"; mkdir -p "$PROFILE" "$OUT"
cp -a "$RELENG/." "$PROFILE/"

echo ">> adding verifier packages (NetworkManager + verify-wipe deps)"
cat >> "$PROFILE/packages.x86_64" <<'PKGS'
networkmanager
wpa_supplicant
cryptsetup
tpm2-tools
efibootmgr
gptfdisk
dosfstools
e2fsprogs
util-linux
git
PKGS

echo ">> applying overlay (motd + duressd-verify helper)"
cp -a "$REPO/tests/verify-iso/overlay/." "$PROFILE/"

echo ">> network: enable NetworkManager (interactive nmtui), drop releng's networkd/iwd auto-enable"
# Remove any releng-enabled networkd/iwd so NetworkManager has sole control.
find "$PROFILE/airootfs/etc/systemd/system" -type l \
     \( -name 'systemd-networkd*' -o -name 'iwd.service' -o -name 'systemd-resolved.service' \) \
     -delete 2>/dev/null || true
install -d "$PROFILE/airootfs/etc/systemd/system/multi-user.target.wants"
ln -sf /usr/lib/systemd/system/NetworkManager.service \
       "$PROFILE/airootfs/etc/systemd/system/multi-user.target.wants/NetworkManager.service"
# NetworkManager provides its own resolver via systemd-resolved; enable it so DNS works.
ln -sf /usr/lib/systemd/system/systemd-resolved.service \
       "$PROFILE/airootfs/etc/systemd/system/multi-user.target.wants/systemd-resolved.service"

echo ">> baking the repo (committed HEAD) into /root/Duressd"
install -d -m 0755 "$PROFILE/airootfs/root/Duressd"
# git archive => exactly the committed tree (the merged fix), no .git, no stray
# build artifacts / disk images from the working dir.
git -C "$REPO" archive --format=tar HEAD | tar -C "$PROFILE/airootfs/root/Duressd" -xf -

echo ">> branding + file permissions"
cat >> "$PROFILE/profiledef.sh" <<'PERMS'

# --- duressd verifier ISO additions ---
iso_name="duressd-verify"
iso_label="DURESSD_VERIFY"
iso_publisher="duressd <https://github.com/twhalley/Duressd>"
iso_application="duressd live wipe verifier"
file_permissions+=(
  ["/usr/local/bin/duressd-verify"]="0:0:755"
  ["/root"]="0:0:750"
)
PERMS

# Preserve exec bits on every baked-in repo script (verify-wipe.sh, baseline.sh,
# self-test.sh, src/*). Without an explicit file_permissions entry mkarchiso
# drops the bit and the script is "Permission denied" in the squashfs.
{
    echo 'file_permissions+=('
    while IFS= read -r f; do
        printf '  ["%s"]="0:0:755"\n' "${f#"$PROFILE/airootfs"}"
    done < <(find "$PROFILE/airootfs/root/Duressd" -type f -perm -u+x 2>/dev/null)
    echo ')'
} >> "$PROFILE/profiledef.sh"

echo ">> cleaning previous build outputs"
rm -rf "$WORK/mkarchiso"
rm -f  "$OUT"/duressd-verify-*.iso

echo ">> building ISO (downloads packages; takes a few minutes)…"
mkarchiso -v -w "$WORK/mkarchiso" -o "$OUT" "$PROFILE"

ISO_PATH="$(ls -1t "$OUT"/duressd-verify-*.iso 2>/dev/null | head -1)"
[[ -n "$ISO_PATH" && -f "$ISO_PATH" ]] || { echo "✘  build produced no ISO in $OUT" >&2; exit 1; }
echo
echo "✔  Verifier ISO built: $ISO_PATH"
echo
echo "Burn it to a USB (pick the stick BY MODEL — this ERASES that device):"
echo "  lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN,RM"
echo "  sudo dd if=$ISO_PATH of=/dev/sdX bs=4M conv=fsync oflag=direct status=progress"
echo
echo "Then boot the machine (with the WIPED disk attached), and on the live env:"
echo "  nmtui                       # connect WiFi (interactive)"
echo "  duressd-verify /dev/sdX     # read-only verify of the wiped disk"
