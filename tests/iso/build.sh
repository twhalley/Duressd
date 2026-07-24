#!/usr/bin/env bash
# Build a self-contained duressd TEST ISO from the stock archiso `releng`
# profile: bakes in duressd + every test dependency + a vendored bats +
# spice-vdagent, autologins root, and runs the offline self-test on boot
# (PASS/FAIL on screen, then an interactive shell).
#
#   sudo bash tests/iso/build.sh          # -> out/duressd-test-*.iso
#
# REQUIRES root (mkarchiso mounts/loop-devices) and the `archiso` package.
# It layers our changes onto releng so the (version-matched) bootloader config
# is inherited rather than hand-authored. Env: OUT=<dir>  WORK=<dir>
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
RELENG="${RELENG:-/usr/share/archiso/configs/releng}"
OUT="${OUT:-$REPO/out}"
WORK="${WORK:-$REPO/.iso-work}"

[[ $EUID -eq 0 ]]              || { echo "run as root:  sudo bash tests/iso/build.sh" >&2; exit 1; }
command -v mkarchiso >/dev/null || { echo "install archiso first:  pacman -S archiso" >&2; exit 1; }
[[ -d "$RELENG" ]]            || { echo "releng profile not found at $RELENG (install archiso)" >&2; exit 1; }

PROFILE="$WORK/profile"
echo ">> staging profile from $RELENG"
rm -rf "$PROFILE"; mkdir -p "$PROFILE" "$OUT"
cp -a "$RELENG/." "$PROFILE/"

echo ">> adding test/runtime packages"
cat >> "$PROFILE/packages.x86_64" <<'PKGS'
make
shellcheck
socat
cryptsetup
util-linux
dosfstools
e2fsprogs
mdadm
efibootmgr
tpm2-tools
openssl
spice-vdagent
PKGS

echo ">> applying overlay (self-test entrypoint + tty1/serial autologin hooks)"
cp -a "$REPO/tests/iso/overlay/." "$PROFILE/"

echo ">> baking the repo into /root/duressd"
install -d -m 0755 "$PROFILE/airootfs/root/duressd"
tar -C "$REPO" \
    --exclude=.git --exclude=out --exclude=.iso-work \
    --exclude='*.iso' --exclude=vm-autorun.log \
    -cf - . | tar -C "$PROFILE/airootfs/root/duressd" -xf -

echo ">> vendoring bats-core (not in the official repos)"
BATS_DST="$PROFILE/airootfs/usr/local/lib/bats-core"
install -d "$(dirname "$BATS_DST")"
if [[ -d "$REPO/tests/vendor/bats-core" ]]; then
    cp -a "$REPO/tests/vendor/bats-core" "$BATS_DST"
else
    git clone --depth 1 https://github.com/bats-core/bats-core.git "$BATS_DST"
    rm -rf "$BATS_DST/.git"
fi
install -d "$PROFILE/airootfs/usr/local/bin"
ln -sf /usr/local/lib/bats-core/bin/bats "$PROFILE/airootfs/usr/local/bin/bats"

echo ">> installing duressd (so \`duressd\` works live on the ISO)"
# Mirror install.sh's layout exactly, so the ISO behaves like a real install:
# CLI on PATH, daemon+handler in LIBDIR, and the daemon running as a service.
install -Dm755 "$REPO/src/daemon"  "$PROFILE/airootfs/usr/local/lib/duressd/daemon"
install -Dm755 "$REPO/src/handler" "$PROFILE/airootfs/usr/local/lib/duressd/handler"
install -Dm755 "$REPO/src/cli"     "$PROFILE/airootfs/usr/local/bin/duressd"
install -Dm644 "$REPO/systemd/duressd.service" \
    "$PROFILE/airootfs/etc/systemd/system/duressd.service"

echo ">> enabling services (duressd, duressd-selftest, spice-vdagentd)"
install -d "$PROFILE/airootfs/etc/systemd/system/multi-user.target.wants"
ln -sf /etc/systemd/system/duressd.service \
    "$PROFILE/airootfs/etc/systemd/system/multi-user.target.wants/duressd.service"
ln -sf /etc/systemd/system/duressd-selftest.service \
    "$PROFILE/airootfs/etc/systemd/system/multi-user.target.wants/duressd-selftest.service"
ln -sf /usr/lib/systemd/system/spice-vdagentd.service \
    "$PROFILE/airootfs/etc/systemd/system/multi-user.target.wants/spice-vdagentd.service"

echo ">> fixing file permissions + branding"
# Append (not edit) to the sourced profiledef so exec bits survive mkarchiso.
cat >> "$PROFILE/profiledef.sh" <<'PERMS'

# --- duressd test ISO additions ---
iso_name="duressd-test"
iso_label="DURESSD_TEST"
iso_publisher="duressd <https://github.com/>"
iso_application="duressd self-testing ISO"
file_permissions+=(
  ["/usr/local/bin/duressd-selftest"]="0:0:755"
  ["/usr/local/bin/duressd"]="0:0:755"
  ["/usr/local/lib/duressd/daemon"]="0:0:755"
  ["/usr/local/lib/duressd/handler"]="0:0:755"
)
PERMS

# mkarchiso only makes files executable if they're listed in file_permissions,
# so generate a 755 entry for every vendored bats script (bin/ + libexec/).
# Without this `bats` is "Permission denied" (exit 126) in the squashfs.
{
    echo 'file_permissions+=('
    while IFS= read -r f; do
        printf '  ["%s"]="0:0:755"\n' "${f#"$PROFILE/airootfs"}"
    done < <(find "$PROFILE/airootfs/usr/local/lib/bats-core/bin" \
                  "$PROFILE/airootfs/usr/local/lib/bats-core/libexec" -type f 2>/dev/null)
    echo ')'
} >> "$PROFILE/profiledef.sh"

# Preserve the exec bits on every baked-in repo file that carries one (the
# PATH-stub harness execs tests/stubs/generic-stub; without its exec bit the
# shell falls through to the REAL system binaries and the unit tests fail).
{
    echo 'file_permissions+=('
    while IFS= read -r f; do
        printf '  ["%s"]="0:0:755"\n' "${f#"$PROFILE/airootfs"}"
    done < <(find "$PROFILE/airootfs/root/duressd" -type f -perm -u+x 2>/dev/null)
    echo ')'
} >> "$PROFILE/profiledef.sh"

echo ">> cleaning previous build outputs (stale work dir / old ISO)"
rm -rf "$WORK/mkarchiso"                 # mkarchiso wants a clean work dir
rm -f  "$OUT"/duressd-test-*.iso         # remove the old image so this one wins

echo ">> building ISO (downloads packages; takes a few minutes)…"
mkarchiso -v -w "$WORK/mkarchiso" -o "$OUT" "$PROFILE"

ISO_PATH="$(ls -1t "$OUT"/*.iso 2>/dev/null | head -1)"
[[ -n "$ISO_PATH" && -f "$ISO_PATH" ]] || { echo "✘  build produced no ISO in $OUT" >&2; exit 1; }
echo
echo "✔  ISO built: $ISO_PATH  ($(date -r "$ISO_PATH" '+%H:%M:%S'))"
if [[ -n "$ISO_PATH" ]]; then
    echo
    echo "Boot it to auto-run the suite (copy-paste):"
    echo "  make vm ISO=$ISO_PATH"
    echo "  make vm-auto ISO=$ISO_PATH   # headless, transcript to vm-autorun.log"
fi
