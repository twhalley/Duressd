# Physical wipe testing

The highest-confidence validation for a destructive tool is on real hardware —
it's the only way to prove the paths a VM can't emulate (TPM clear, NVMe
Sanitize, real UEFI NVRAM, real bootloader recovery, real Qubes/Xen). This kit
makes each run **repeatable and machine-reported** so results come back in a
consistent form.

Scripts:
- `tests/physical/baseline.sh` — run on the target OS **before** wiping.
- `tests/physical/verify-wipe.sh` — run from a **live USB after** wiping; emits a Markdown report.

## ⚠️ Safety first

A physical wipe is irreversible on that machine. Before every run:

1. **This must be a dedicated test machine** with nothing you need.
2. **Image the disk first** (below) so you can restore it.
3. **Confirm the target disk by model + serial**, not just `/dev/sdX` — device
   names change between boots and between the installed OS and the live USB:
   ```bash
   lsblk -o NAME,SIZE,MODEL,SERIAL,MOUNTPOINT
   ```
4. Never point `dd`/`clonezilla` at the wrong disk — that destroys data with no
   duressd involved.

## Provisioning a test laptop (systemd-boot + LUKS)

`tests/physical/build-laptop-image.sh` builds a ready-to-test image: a bootable,
LUKS-encrypted Arch system with a standard sudo user, `sshd`, and duressd already
configured (custom duress passphrase, boot-artifact wipe on) plus the SSH
duress-trigger key installed. Run it on any Arch box with root:

```bash
sudo LUKS_PASS='unlock-me' DURESS_PASS='wipe-now' USER_PASS='tester-pw' \
     USERNAME=tester HOSTNAME=duressd-test SIZE=12G \
     bash tests/physical/build-laptop-image.sh
```

Outputs a raw image and `<image>.duress-key` (the private SSH key). Provision the
laptop, then boot it (type `LUKS_PASS` at the prompt, or set `AUTO_UNLOCK=1` at
build time for headless boot):

```bash
sudo dd if=duressd-laptop.raw of=/dev/<laptop-disk> bs=64M conv=fsync status=progress
```

Trigger the wipe locally (`sudo duressd trigger`) or remotely:
```bash
printf '%s' 'wipe-now' | ssh -i duressd-laptop.raw.duress-key -T root@<laptop-ip>
```

Requires `arch-install-scripts`, `dosfstools`, `openssh` on the build host. This
image covers the **systemd-boot + LUKS** scenario; for GRUB and Qubes, install
those normally on the laptop and follow the loop below.

## The loop (per scenario)

```
 baseline  →  image  →  configure  →  trigger  →  boot live USB  →  verify  →  restore
```

### 1. Baseline (on the installed OS)
```bash
sudo bash tests/physical/baseline.sh --scenario sdboot-luks
# auto-detects the disk backing /, or pass --disk /dev/nvme0n1
```
Saves partition/LUKS/ESP/NVRAM/TPM state + a LUKS header backup to a
`baseline-*/` dir, and plants a plaintext marker in `/boot` and the ESP.
**Copy the `baseline-*/` dir to external media** — you'll need it for `verify-wipe`.

### 2. Image the disk (for restore)
Boot a live USB (or do it offline) and clone the whole disk to external storage:
```bash
sudo dd if=/dev/nvme0n1 of=/mnt/ext/gold-sdboot.img bs=64M conv=fsync status=progress
# or: clonezilla device-image
```

### 3. Configure duressd for the phases under test
```bash
sudo duressd configure     # enable: boot artifacts = y; hardware keys = y (if TPM)
sudo duressd status        # confirm the flags
sudo duressd health
```

### 4. Trigger the real wipe
```bash
sudo duressd trigger       # type WIPE, enter the duress passphrase
# machine wipes and powers off
```

### 5. Verify from a live USB
Boot a live USB, mount your external media with the baseline, then:
```bash
sudo bash tests/physical/verify-wipe.sh /dev/nvme0n1 \
    --baseline /mnt/ext/baseline-sdboot-luks-* \
    --scenario sdboot-luks \
    --report /mnt/ext/report-sdboot.md
```
Paste the printed report back to me. It checks: no LUKS header, no ESP/`/boot`
filesystem signatures, the plaintext marker is absent from raw sectors, UEFI
boot entries are gone, the TPM sealed-key is evicted, and the partition-table
status. Then **power-cycle the machine** with the wiped disk as the only boot
target and confirm it fails to boot — record that in the report.

### 6. Restore for the next run
```bash
sudo dd if=/mnt/ext/gold-sdboot.img of=/dev/nvme0n1 bs=64M conv=fsync status=progress
```

## Scenario notes

| Scenario | Layout | What to watch |
|---|---|---|
| **systemd-boot + LUKS** | ESP (systemd-boot) + ext4 `/boot` + LUKS root | ESP + `/boot` scrubbed; UEFI entry "Linux Boot Manager" gone |
| **GRUB + LUKS** | (UEFI) ESP + GRUB, or (BIOS) MBR/BIOS-boot + `core.img` + LUKS root | On BIOS: confirm the marker/`core.img` region in the MBR gap is gone; on UEFI: the "GRUB"/distro NVRAM entry is gone |
| **Qubes OS** | ESP + **unencrypted ext4 `/boot`** (Xen + kernels) + LUKS pool (LVM thin `qubes_dom0`) | This is the case Phase 1 alone would miss — verify `/boot` marker is gone and the LUKS pool header is destroyed |

If the machine uses **TPM auto-unlock** (`systemd-cryptenroll --tpm2` / Clevis),
enable *hardware keys* in configure and confirm the `tpm-cleared` check passes
against the baseline.

## Reading the report

`overall` is `FAIL` if any hard check (LUKS header, marker) failed, `WARN` if
only soft checks did (e.g. a partition table survived, or a check was skipped
for lack of a TPM/baseline), else `PASS`. Send me any `FAIL`/`WARN` rows and
I'll trace them back to the wipe code.
