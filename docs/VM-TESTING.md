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

A green run proves lint + unit + integration + the real daemon/CLI/trigger path
all pass, against real encrypted disks, with zero host exposure.

## Cleanup

Close the QEMU window. Nothing persists — the repo was mounted read-only and the
VM's disk was RAM/ephemeral. Delete the ISO if you don't want to keep it.

## Notes

- The repo share is **read-only**, so the VM copies it to `/root/duressd` before
  running (tests write only inside the VM).
- To also test a full *bootable-OS* self-wipe (bootloader + `/boot` + LUKS root)
  rather than a scratch disk, use the host-side KVM e2e flow in
  [TESTING.md](TESTING.md) (`tests/e2e/`), which builds a golden encrypted image
  and boots it — that path runs QEMU on the host but still confines the wipe to
  the VM's virtual disk.
- For real-hardware-only paths (TPM clear, NVMe Sanitize), see
  [PHYSICAL-TESTING.md](PHYSICAL-TESTING.md).
