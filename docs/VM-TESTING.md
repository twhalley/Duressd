# Testing in a disposable VM (max isolation)

Run the entire duressd suite — including a **real wipe of a real encrypted
disk** — inside a throwaway Arch VM, so **nothing executes as root on your
host** and cleanup is just "close the VM". This is the safest way to exercise
the destructive paths.

## Why do this

A real `duressd trigger` on your host would find and destroy your actual LUKS
volumes — that's the tool working as designed. Running everything in a VM means
the only disks in reach are the VM's. Bonus: no leftover host loop devices,
mappings, or mounts to clean up — you discard the VM.

## One-time host setup

```bash
sudo pacman -S --needed qemu-full          # only host root action needed
curl -LO https://geo.mirror.pkgbuild.com/iso/latest/archlinux-x86_64.iso
```

## Run

```bash
make vm ISO=$PWD/archlinux-x86_64.iso
# equivalent to: ISO=$PWD/archlinux-x86_64.iso bash tests/vm/launch.sh
```

`launch.sh` boots the Arch live ISO with this repo shared in **read-only** (9p),
KVM-accelerated if `/dev/kvm` is present. A QEMU window opens to the live root
shell. Inside it, one line runs everything:

```bash
mkdir -p /mnt/repo && mount -t 9p -o trans=virtio,ro duressd /mnt/repo && cp -a /mnt/repo /root/duressd && cd /root/duressd && bash tests/vm/inside.sh
```

## Fully headless (no window, no typing)

```bash
make vm-auto ISO=$PWD/archlinux-x86_64.iso
# equivalent to: ISO=… bash tests/vm/auto.sh
```

`auto.sh` extracts the ISO's own kernel/initramfs, boots it with a **serial
console** (no graphical window), logs in and runs `tests/vm/inside.sh` over that
serial line, streams a live transcript to `vm-autorun.log`, powers the VM off,
and exits non-zero if the suite failed. Use this for CI or an unattended run;
use `make vm` when you want to watch/interact. Both confine every wipe to a
loopback file inside the VM.

## Golden LUKS-at-boot boot test — fully in-VM (`make vm-golden`)

The one path that needs a *real bootable OS* — proving the duress passphrase
entered at the **boot-time LUKS prompt** wipes the disk and stops it booting —
now runs entirely inside the disposable VM, so the host is never involved:

```bash
make vm-golden ISO=$PWD/out/duressd-test-*.iso
# equivalent to: ISO=… bash tests/vm/golden-vm.sh
```

Requires the **duressd test ISO** (`sudo make iso`), which bakes in
`qemu-base`, `edk2-ovmf`, and `arch-install-scripts`. `golden-vm.sh` boots that
ISO headless with a throwaway scratch disk attached (addressed by a stable
serial → `/dev/disk/by-id/virtio-duressdgolden`) and `duressd.golden=1`. Inside,
the self-test service:

1. builds a real bootable, LUKS-encrypted Arch image **on the scratch disk**
   (`tests/e2e/build-luks-duress.sh`), with the duressd LUKS-at-boot hook and a
   distinct duress passphrase baked in;
2. runs the boot test in a **nested QEMU** (KVM speed when the host enables
   nested virt, else TCG): **CONTROL** — the real passphrase boots normally
   (`GOLDEN-BOOT-OK`, so the hook doesn't break boot); **DURESS** — the duress
   passphrase wipes the LUKS header at the prompt and powers off; then it
   verifies the header is gone and the disk **no longer boots**.

A live transcript streams to `vm-golden.log`; the VM powers itself off and the
command exits non-zero on any failure. Every byte — image, package cache, nested
overlays — lands on the throwaway scratch disk, so `/var/cache/pacman`, host loop
devices, and real disks are all untouched.

## What `inside.sh` does

All inside the VM, in order:

1. `pacman -Sy` the test deps (bats, shellcheck, cryptsetup, socat, …).
2. **lint** (`make lint`) and **unit tests** (`make unit`).
3. **loop-device integration** (`make integration`) — real LUKS containers on
   loopback are actually destroyed.
4. **full-stack trigger** — creates a scratch LUKS disk on a loop device, starts
   the real duressd daemon, and fires the wipe over the socket exactly as the
   SSH trigger would; then asserts the scratch disk's LUKS header is gone. The
   wipe is scoped to the scratch loop (`DURESSD_TARGET_DEVICES`) and poweroff is
   suppressed so the VM survives for the assertion.
5. **encrypted-disk end-to-end** (`tests/vm/encrypted-e2e.sh`) — builds a
   realistic disk (GPT: **ESP + ext4 `/boot` + LUKS2 root** with a filesystem and
   secrets), writes a plaintext sentinel to the unencrypted ESP and a secret
   inside the encrypted root, then fires a **real trigger with every phase**
   (crypto + boot-artifacts + full-device). It proves the LUKS header is gone
   and **can no longer be opened with the passphrase**, the ESP/`/boot`
   filesystems and GPT table are destroyed, and the plaintext boot data is
   unrecoverable from the raw device — all scoped to the loopback disk.

A green run proves lint + unit + integration + the real daemon/CLI/trigger path
+ a full encrypted-disk wipe all pass, against real encrypted disks, with zero
host exposure.

## Cleanup

Close the QEMU window. Nothing persists — the repo was mounted read-only and the
VM's disk was RAM/ephemeral. Delete the ISO if you don't want to keep it.

## Notes

- The repo share is **read-only**, so the VM copies it to `/root/duressd` before
  running (tests write only inside the VM).
- To test a full *bootable-OS* self-wipe (bootloader + `/boot` + LUKS root)
  rather than a scratch disk, prefer **`make vm-golden`** above — it runs the
  whole build+boot inside the disposable VM. The host-side equivalents
  (`make golden` + `make golden-test`, documented in [TESTING.md](TESTING.md))
  build and boot the same golden image but run QEMU **on the host** (they still
  confine the wipe to a loopback file, but they use host loop devices).
- For real-hardware-only paths (TPM clear, NVMe Sanitize), see
  [PHYSICAL-TESTING.md](PHYSICAL-TESTING.md).
