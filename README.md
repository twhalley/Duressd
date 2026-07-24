# duressd

A Linux system service that destroys every LUKS-encrypted volume on the machine and powers off immediately when a duress passphrase is entered.

Runs as a root `systemd` service. All control goes through a Unix socket served by `socat`. The CLI (`duressd`) speaks to the daemon over that socket and can be driven interactively or by script.

---

## How it works

```
duressd configure        ← store passphrase, choose wipe depth
         │
         ▼
  /etc/duressd/config    ← root-only, 0600

duressd trigger          ← enter duress passphrase
         │
         ▼
  daemon verifies pass   ← LUKS --test-passphrase OR Argon2id LUKS2 container
         │
         ├─ Phase 1 (always)
         │    lsblk → find all LUKS devices (partitions, md RAID, LVM, loop…)
         │    close all dm-crypt mappings
         │    wipefs + luksErase on every device found
         │
         ├─ Phase 1.5 (optional: wipe_boot_artifacts=true)
         │    scrub ESP + unencrypted /boot (Qubes, GRUB, systemd-boot)
         │    overwrite MBR / BIOS-boot gap (GRUB core.img)
         │    clear UEFI NVRAM boot entries
         │
         ├─ Phase 1.6 (optional: wipe_hardware_keys=true)
         │    tpm2_clear → evict TPM-sealed FDE keys
         │
         ├─ Phase 2 (optional: overwrite_luks_header=true)
         │    openssl rand | dd  →  40 MiB over each LUKS header
         │    blkdiscard
         │
         ├─ Phase 3 (optional: wipe_full_device=true)
         │    overwrite entire parent block device(s) with random data
         │    stop RAID arrays (mdadm --stop)
         │    wipefs on RAID member superblocks
         │
         └─ Phase 4 (always)
              sync
              systemctl poweroff --force --force
              echo o > /proc/sysrq-trigger  ← last resort
```

**After Phase 1 the data is cryptographically irrecoverable** — the LUKS volume key is gone. Phases 2 and 3 add forensic deniability and physical overwrite, not additional secrecy.

---

## Requirements

| Tool | Package (Debian/Ubuntu) | Package (Arch) | Purpose |
|------|------------------------|----------------|---------|
| `socat` | `socat` | `socat` | Unix socket IPC |
| `cryptsetup` | `cryptsetup` | `cryptsetup` | LUKS verify + erase |
| `wipefs` | `util-linux` | `util-linux` | Remove filesystem signatures |
| `dmsetup` | `dmsetup` | `device-mapper` | Tear down dm-crypt mappings |
| `lsblk` | `util-linux` | `util-linux` | Enumerate block devices |
| `blkdiscard` | `util-linux` | `util-linux` | TRIM/UNMAP after wipe |
| `openssl` | `openssl` | `openssl` | Fast random data (AES-NI) |
| `findmnt` | `util-linux` | `util-linux` | Locate mountpoints |
| `shred` | `coreutils` | `coreutils` | Secure-erase passphrase file |
| `mdadm` *(optional)* | `mdadm` | `mdadm` | RAID teardown (Phase 3 only) |
| `efibootmgr` *(optional)* | `efibootmgr` | `efibootmgr` | Clear UEFI NVRAM entries (Phase 1.5) |
| `tpm2_clear` *(optional)* | `tpm2-tools` | `tpm2-tools` | Evict TPM-sealed FDE keys (Phase 1.6) |

`install.sh` checks for all required tools and prints the correct install command for your distro before aborting.

---

## Installation

### One-liner (recommended)

```bash
curl -sSL https://raw.githubusercontent.com/twhalley/Duressd/main/install.sh | sudo bash
```

Or with `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/twhalley/Duressd/main/install.sh | sudo bash
```

When run this way `install.sh` detects that the `src/` tree is absent, downloads the full archive from GitHub automatically, and proceeds with the normal install. No separate bootstrap script needed.

### Manual install

```bash
git clone https://github.com/twhalley/Duressd.git
cd Duressd
sudo ./install.sh install
```

`install.sh` copies binaries, installs the systemd unit, enables and starts the service, and installs shell aliases for bash, zsh, and fish.

```
sudo ./install.sh install     # install everything
sudo ./install.sh uninstall   # remove everything (prompts before wiping config)
sudo ./install.sh status      # check all components are present and running
```

---

## Quick start

```bash
# 1. Configure your duress passphrase and wipe options
sudo duressd configure

# 2. Verify the passphrase was stored correctly
duressd verify

# 3. Preflight check — confirm everything is ready
duressd health

# 4. Dry run — exercise the full wipe chain on a throwaway container
duressd test

# 5. (Optional) Install shortcuts for your desktop
duressd install-shortcuts
duressd install-keybindings
```

---

## Configuration

Run `duressd configure` and answer the prompts. Settings are stored in `/etc/duressd/config` (root-only, mode `0600`).

### Password type

| Type | How it works | When to use |
|------|-------------|-------------|
| `luks` | The duress passphrase **is** your LUKS passphrase. Verified with `cryptsetup --test-passphrase` against your encrypted volume. | Simplest — one key. |
| `custom` | A separate passphrase hashed with **Argon2id** (stored as a LUKS2 keyslot in `/etc/duressd/passphrase.luks`). Zero extra dependencies — `cryptsetup` already does the KDF. | Recommended. Lets you give a different key under duress without revealing the main LUKS passphrase. |

### Wipe options

| Option | What it does | Speed |
|--------|-------------|-------|
| Phase 1 (always) | `wipefs` + `luksErase` on every LUKS container found | Fast — seconds |
| Wipe boot artifacts | Scrubs the ESP, unencrypted `/boot`, MBR / BIOS-boot gap, and UEFI NVRAM entries so **no bootable OS remains**. Essential for Qubes (unencrypted `/boot`). | Fast — seconds |
| Wipe hardware keys | `tpm2_clear` evicts TPM-sealed FDE keys so a TPM-auto-unlock key can never be reused | Instant |
| Overwrite LUKS header | 40 MiB `openssl rand` over each LUKS partition head + `blkdiscard` | ~1–2 s per device |
| Wipe full device(s) | Chunked random overwrite of entire parent block device(s), then stops RAID arrays and wipes member superblocks | Slow — minutes per GB |

### Countdown

Set a countdown (e.g. `5` seconds) to allow aborting a real wipe by pressing `Ctrl-C` before the countdown expires. Disabled when set to `0`.

---

## CLI Reference

Run `duressd` with no arguments to open the interactive menu.

---

### `duressd status`

Shows the daemon state and the active configuration.

```
State:                         IDLE
Configured:                    yes
Password type:                 custom
Verify device:                 /dev/sda2
Overwrite LUKS header:         false
Wipe boot artifacts:           true
Wipe hardware keys:            false
Wipe full device(s):           false
Countdown (s):                 5
```

State values: `IDLE` · `WIPING` · `TESTING` · `PREP_WIPING` · `DONE`

---

### `duressd health`

Single-command preflight check. Reports pass/warn/fail for each component:

| Check | What is verified |
|-------|-----------------|
| `service_running` | `duressd.service` is active |
| `config_file` | `/etc/duressd/config` exists |
| `auth_backend` | LUKS device accessible (type=luks) or `passphrase.luks` present (type=custom) |
| `required_tools` | All wipe-chain binaries are on PATH |
| `luks_devices` | At least one LUKS container is discoverable |

```bash
duressd health
```

---

### `duressd verify`

**Non-destructive.** Tests that the stored passphrase is correct and that the authentication backend can validate it — without touching any real device. Run this after `configure` or `change-passphrase` to confirm authentication works.

```bash
duressd verify
```

---

### `duressd configure`

Interactive wizard. Sets up the duress passphrase, wipe depth, and countdown. Safe to re-run — it overwrites the existing config.

```
Your LUKS passphrase: ••••••••
Choice [1/2]: 2
Duress passphrase: ••••••••
Confirm duress passphrase: ••••••••
Phase 2 — overwrite LUKS header regions? [y/N]: n
Phase 3 — overwrite full block device(s)? [y/N]: n
Countdown before real wipe (0 = disabled): 5
```

The daemon scans all block devices to find which one your LUKS passphrase unlocks. That device path is stored as `VERIFY_DEVICE` so future authentication is O(1).

---

### `duressd change-passphrase`

Atomically replaces the duress passphrase for `type=custom` configurations. Verifies the old passphrase, destroys the old Argon2id keyslot, creates a new one, then verifies the new one before reporting success.

For `type=luks` configurations use `cryptsetup luksChangeKey <device>` directly.

```bash
duressd change-passphrase
```

---

### `duressd unconfigure`

Erases the Argon2id keyslot container (`shred`), removes `/etc/duressd/config`. Requires the duress passphrase (or LUKS passphrase for `type=luks`).

---

### `duressd passgen`

Generates a strong random passphrase. Three modes:

| Mode | Example length | Source |
|------|---------------|--------|
| Base64 | 24 chars | `openssl rand -base64 18` |
| Hex | 32 chars | `openssl rand -hex 16` |
| Words | 4 words | `/usr/share/dict/words` via `openssl rand` indices |

```bash
duressd passgen
```

The passphrase is printed once and not stored — copy it before continuing.

---

### `duressd logs [N]`

Shows the last *N* lines (default 50) of the `duressd` service journal with colour-highlighted output — errors in red, warnings in yellow, start/stop events in green.

```bash
duressd logs
duressd logs 100
```

---

### `duressd dry-run`

**Non-destructive preview of a *real* trigger.** Runs the exact same discovery,
device scoping and phase-selection that a real wipe would — against your actual
configured targets — then lists precisely what each phase *would* destroy
(LUKS containers, ESP/`/boot`, MBR, BIOS-boot, UEFI NVRAM entries, TPM clear,
poweroff) **without touching anything**. Every line is shown in **green** and
the machine is never modified, discovered mappings are never closed, and the
state file is left untouched.

Because it reuses the real engine (only the destructive primitives are
neutered), the preview can never drift from what a real trigger does — it is the
best way to confirm a machine is configured to wipe what you expect.

```bash
duressd dry-run
```

It also works over SSH, so you can rehearse the remote kill switch harmlessly:

```bash
printf '%s' "$DURESS_PASS" | ssh -i duressd_duress -T root@host duressd trigger-remote --dry-run
```

> **`dry-run` vs `test`:** `dry-run` previews your *real* targets and changes
> nothing; `test` (below) actually wipes a *throwaway scratch container* to prove
> the wipe chain executes end-to-end. Both are safe and shown in green.

---

### `duressd test`  ·  alias: `dwipe_test`

**Non-destructive.** Allocates a 10 MiB throwaway LUKS2 file, runs `luksErase → wipefs` on it, and reports pass/fail. Your real data is never touched.

Displayed in **green** throughout. Use this regularly to confirm the wipe chain still works.

```bash
duressd test
# or
dwipe_test
```

---

### `duressd trigger`  ·  alias: `dwipe_real`

**Destructive — cannot be undone.**

Prompts for `WIPE` confirmation, then the duress passphrase. If a countdown is configured, it counts down on-screen. Pressing `Ctrl-C` during the countdown aborts cleanly without wiping.

Displayed in **red** throughout.

```bash
duressd trigger
# or
dwipe_real
```

---

### `duressd trigger-remote`  ·  `duressd install-ssh-trigger`

**Remote / non-interactive wipe** — a duress kill switch over SSH.

`trigger-remote` is `trigger` without prompts or the `WIPE` confirmation: it
takes the duress passphrase from `--passphrase-file`, `$DURESSD_PASS`, or stdin,
then fires the wipe. It needs root because the control socket is root-only, so
the SSH key must live in **root's** `authorized_keys`.

`install-ssh-trigger` sets that up for you — it generates an ed25519 keypair (or
takes `--pubkey`) and appends a `restrict`ed forced-command entry:

```bash
sudo duressd install-ssh-trigger
#   command="duressd trigger-remote",restrict ssh-ed25519 AAAA… duressd-duress
```

Then trigger the wipe from anywhere you can reach the host — the passphrase
travels over the encrypted SSH channel and is never stored on the machine:

```bash
printf '%s' "$DURESS_PASS" | ssh -i duressd_duress -T root@host
```

For a **key-only** kill switch (no passphrase needed at trigger time), use
`--embed-passphrase` — the passphrase is stored root-only on the machine and a
bare `ssh -i duressd_duress root@host` fires the wipe. Trade-off: anyone who
obtains that private key can wipe the machine.

> If a countdown is configured, keep the SSH session open during it — closing
> the connection aborts the wipe (the same abort that `Ctrl-C` gives locally).

Add **`--dry-run`** to `trigger-remote` to rehearse the remote path without
touching anything — the daemon streams a green preview of exactly what a real
remote trigger would destroy (see `duressd dry-run` above).

---

### `duressd wipe-unused`

Fills unallocated sectors on every **currently mounted** LUKS volume with zeros, then deletes the fill file. Makes deleted files unrecoverable without triggering a full wipe.

Requires the duress passphrase.

---

### `duressd scan`

Walks the full block device tree via `lsblk` and runs `cryptsetup isLuks` on each node. Reports every device carrying a LUKS header — partitions, RAID arrays (`/dev/md*`), LVM logical volumes, loop devices, NVMe namespaces.

```bash
duressd scan
# Found 3 LUKS container(s): /dev/sda2 /dev/sdb1 /dev/md0
```

No passphrase required.

---

### `duressd install-shortcuts`

Writes two `.desktop` launchers to `~/Desktop/`:

| File | Colour | Action |
|------|--------|--------|
| `duressd-test.desktop` | Green icon | Opens terminal → `duressd test` |
| `duressd-wipe.desktop` | Red icon | Opens terminal → `duressd trigger` |

---

### `duressd install-keybindings`

Detects the running desktop environment and registers keyboard shortcuts:

| Shortcut | Action |
|----------|--------|
| `Super + Shift + T` | Open terminal → `duressd test` (non-destructive) |
| `Super + Shift + W` | Open terminal → `duressd trigger` (destructive) |

> The real-wipe shortcut (`Super+Shift+W`) is intentionally skipped on GNOME and KDE — add it manually if you want it, to prevent accidental triggers from muscle memory.

**Supported desktop environments:**

| DE | Method | Notes |
|----|--------|-------|
| GNOME | `gsettings` custom keybinding | Takes effect immediately |
| KDE Plasma | `kwriteconfig5` → `kglobalshortcutsrc` | May need `kglobalaccel5 &` |
| XFCE | `xfconf-query` → `xfce4-keyboard-shortcuts` | Log out/in to activate |
| i3 | Appended `bindsym` lines to `~/.config/i3/config` | `Mod+Shift+R` to reload |
| sway | Appended `bindsym` lines to `~/.config/sway/config` | `Mod+Shift+C` to reload |
| xbindkeys | Appended entries to `~/.xbindkeysrc` | Restart xbindkeys |

---

### `duressd service <action>`

Thin wrapper around `systemctl`:

```bash
duressd service status
duressd service restart
duressd service stop
```

---

## Shell aliases

Installed automatically during `install.sh install`. Active for all login shells after re-login or shell restart.

| Shell | Location | Notes |
|-------|----------|-------|
| bash | `/etc/profile.d/duressd.sh` | Sourced by all login shells |
| zsh | `/etc/profile.d/duressd.sh` | Sourced when zsh reads `/etc/profile` (default on most distros) |
| fish | `/etc/fish/conf.d/duressd.fish` | Installed automatically if `fish` is on PATH |

```bash
alias dwipe_test='duressd test'    # non-destructive dry run
alias dwipe_real='duressd trigger' # destructive real wipe
```

---

## Desktop shortcuts

Installed by `duressd install-shortcuts`. Double-click from any file manager or desktop:

- **duressd-test.desktop** — launches terminal in green test mode (safe)
- **duressd-wipe.desktop** — launches terminal in red real-wipe mode (destructive)

---

## The wipe chain in detail

### Phase 1 — Cryptographic destruction (always)

1. `dmsetup ls --target crypt` → list every active dm-crypt mapping
2. For each: `findmnt` → `umount --lazy` → `dmsetup remove --force`
   - `--force` bypasses "device still in use" that would occur after a lazy unmount
3. `lsblk -lnpo NAME` + `cryptsetup isLuks` → discover every LUKS device
   - Covers all device types: `sda1`, `nvme0n1p2`, `/dev/md0`, `/dev/mapper/vg-home`, `/dev/loop0` …
4. For each LUKS device:
   - `wipefs -a` — zeroes out filesystem and LUKS magic signatures
   - `cryptsetup luksErase` — overwrites all keyslots (destroys the volume key)

**After step 4 the data is cryptographically irrecoverable**, even if every raw sector on disk is forensically intact.

### Phase 1.5 — Boot-artifact wipe (optional)

Cryptographic destruction removes the *data*; this phase removes the *bootable OS and its traces* — important because much of the boot chain lives **outside** the LUKS container:

1. **ESP** — every EFI System Partition (`systemd-boot`, GRUB EFI, shim) is overwritten and its signatures cleared.
2. **`/boot`** — the unencrypted boot partition (kernels, initramfs, and Xen on Qubes) is overwritten. **Qubes and many LUKS setups keep `/boot` in the clear**, so Phase 1 alone leaves it intact.
3. **MBR / BIOS-boot gap** — legacy GRUB `stage1` and its embedded `core.img` in LBA0 and the alignment gap, plus any BIOS-boot partition, are overwritten.
4. **UEFI NVRAM** — boot entries are removed via `efibootmgr` (real EFI systems only).

### Phase 1.6 — Hardware-key eviction (optional)

`tpm2_clear` clears the TPM's storage hierarchy, rotating the SRK so any key sealed to the TPM (e.g. `systemd-cryptenroll --tpm2`, Clevis) can never be unsealed again — removing the auto-unlock path. Falls back to the firmware Physical Presence Interface if `tpm2-tools` is absent.

### Phase 2 — Header overwrite (optional)

For each LUKS partition, writes 40 MiB of `openssl rand` output (AES-CTR via AES-NI, 5–10× faster than `/dev/urandom`) over the header region, then issues a `blkdiscard` TRIM command so the flash controller erases the cells.

### Phase 3 — Full device + RAID teardown (optional)

1. For each LUKS container, `lsblk -ndo PKNAME` finds the parent block device (`sda`, `nvme0n1` …)
2. Deduplicates parent devices so a multi-partition disk is only written once
3. Chunked `openssl rand | dd … conv=fdatasync` in 128 MiB blocks with per-chunk progress
4. `blkdiscard` on each full device
5. `lsblk -lnpo NAME,TYPE | awk '$2 ~ /^raid/'` → `mdadm --stop` + `wipefs` on each array
6. Re-scan for `linux_raid_member` FSTYPE → `wipefs` on each member drive

Without step 6, `mdadm --assemble --scan` can reconstruct the RAID array from raw member drives after reboot.

### Phase 4 — Power off (always)

```bash
sync
systemctl poweroff --force --force   # calls reboot(RB_POWER_OFF) directly
sleep 3
echo o > /proc/sysrq-trigger          # immediate hardware power-off, no userspace
```

The double `--force` bypasses systemd's graceful shutdown sequence, which would try to stop this running daemon — a deadlock. SysRq `o` is the last resort if `systemctl` itself hangs.

---

## Security model

| Concern | Mitigation |
|---------|------------|
| Who can trigger a wipe? | Anyone who knows the duress passphrase — no sudo, no polkit |
| Passphrase storage | `custom` type: Argon2id LUKS2 keyslot in `/etc/duressd/passphrase.luks` (root `0600`). `luks` type: no stored secret — verified live against your LUKS volume |
| Wire security | Unix socket `0600` in `/run/duressd/` (`0700`). Only root can connect |
| Passphrase in memory | Passed as `--key-file=-` to cryptsetup stdin; never written to disk or the config file |
| Config file | `/etc/duressd/config` — root `0600`. Contains only boolean flags and the verify-device path, never the passphrase |
| SIGPIPE / client disconnect | `trap '' SIGPIPE` in handler ensures a client crash never leaves the daemon in an inconsistent state. During countdown, `printf || exit 0` aborts a wipe if the client disconnects |

---

## Testing

duressd has a layered test pipeline — most of it runs with no privileges, and
the destructive tiers run only against throwaway loop devices or VMs, never the
host's disks. See **[docs/TESTING.md](docs/TESTING.md)** for details.

```bash
make test          # lint + unit tests (safe, no root) — the CI default
make lint          # shellcheck (static analysis)
make unit          # bats unit tests, all wipe binaries mocked
sudo make integration   # real LUKS on loopback devices — headers actually destroyed
sudo make e2e           # KVM: a booted encrypted OS wipes itself and won't reboot
make test-all      # every tier this host supports (skips KVM if no /dev/kvm)
```

Safety rail: every wipe phase honours `DURESSD_TARGET_DEVICES`, which the
integration harness sets to its loop devices, and a second guard refuses any
target that is not a loop device backed by the test's temp workdir.

For real-hardware acceptance testing (TPM, NVMe, real bootloaders, Qubes), see
**[docs/PHYSICAL-TESTING.md](docs/PHYSICAL-TESTING.md)** — a baseline/verify kit
that images the disk, runs the real wipe, then emits a pass/fail report.

CI runs lint + unit and the loop-device integration tests on every push
(`.github/workflows/`); the KVM end-to-end suite is opt-in.

---

## Triggering via LUKS passphrase at boot

It is possible to fire a wipe when the duress passphrase is typed at the **full-disk-encryption boot prompt** — no terminal, no desktop, no login required — without patching or rebuilding cryptsetup.

### How it works (initramfs hook)

LUKS2 supports up to 32 keyslots. The trick is to:

1. Add the duress passphrase as a real LUKS keyslot on your encrypted volume with `cryptsetup luksAddKey`.
2. Install a custom **initramfs hook** that runs *before* the standard `cryptroot` script.
3. The hook tests the typed passphrase against the duress keyslot using `cryptsetup open --test-passphrase`.
4. If it matches → the hook destroys every LUKS header on the system, scrubs the passphrase from memory, and calls `echo o > /proc/sysrq-trigger` to halt — the filesystem is never mounted.
5. If it doesn't match → the hook exits cleanly and `cryptroot` proceeds as normal.

No cryptsetup source changes are needed. The hook uses cryptsetup as shipped.

### Implementation sketch

**Debian/Ubuntu** (initramfs-tools):

```
/etc/initramfs-tools/hooks/duressd          ← copies binaries into initrd
/etc/initramfs-tools/scripts/local-top/duressd  ← runs at passphrase time
```

The `local-top` script runs before `cryptroot`, has access to block devices, and can call cryptsetup freely.

**Arch / dracut**:

```
/etc/dracut.conf.d/duressd.conf    ← install_items += ...
/usr/lib/dracut/modules.d/99duressd/  ← hook module
```

### Security note

Because the duress passphrase is a real LUKS keyslot, someone who obtains the passphrase *and* physically blocks the hook from running (e.g. boots a live OS) could decrypt the volume. Mitigations:

- Combine with a countdown so the wipe cannot be interrupted.
- Use a passphrase that differs from your normal unlock key (`type=custom` is already recommended for this).
- Phase 2 header overwrite makes forensic recovery significantly harder even if the raw sectors survive.

### Status

Not yet implemented — tracked as a roadmap item below.

---

## Potential improvements

### Trigger mechanisms

| Feature | Difficulty | Description |
|---------|-----------|-------------|
| **initramfs hook** | Medium | Intercept the LUKS passphrase at the boot prompt — wipe before the OS ever mounts. No cryptsetup patch needed (see section above). Requires generating a custom initrd on install. |
| **PAM module** | Medium | Trigger wipe when a "honeypot" username is entered at a login prompt via `pam_exec`. Works without unlocking a desktop session. |
| ~~**Duress SSH key**~~ | ✅ Done | `duressd install-ssh-trigger` installs a forced-command key; `duressd trigger-remote` is the non-interactive wipe. See below. |
| **Network kill-switch** | Medium | A lightweight UDP/HTTP listener that triggers wipe on receipt of a cryptographically signed token from a remote server. Useful when the machine goes missing. |
| **Dead man's switch** | Medium | Wipe if a heartbeat ping is not received within a configurable window. Pair with a mobile app or cron job on another machine — if you stop checking in, the machine wipes itself. |
| **USB kill key** | Easy | Monitor `udev` events; wipe when a specific USB device (identified by vendor/product ID or a secret file on the device) is inserted or *removed*. |
| **Bluetooth proximity** | Medium | Wipe when a paired Bluetooth device (phone) goes out of range for longer than N seconds. Acts as a passive dead man's switch. |
| **Browser trigger** | Easy | Tiny `socat`/`nc` HTTP listener on localhost only — visit a specific URL path to trigger wipe. Useful for bookmarks or scripts that can open URLs. |
| **TOTP / OTP code** | Medium | Support a time-based one-time password as the duress passphrase. Every 30 s the valid code changes — reduces replay risk if someone observes you typing it. |

### Wipe depth & hardware

| Feature | Difficulty | Description |
|---------|-----------|-------------|
| **SED / OPAL** | Hard | Issue a hardware `PSID revert` or `ATA Secure Erase` command to self-encrypting drives. Cryptographically instantaneous — the drive's internal key is gone in milliseconds. Falls back to software wipe if unsupported. |
| ~~**UEFI variable wipe**~~ | ✅ Done | Implemented in Phase 1.5 — UEFI NVRAM boot entries cleared via `efibootmgr`. |
| ~~**TPM key eviction**~~ | ✅ Done | Implemented in Phase 1.6 (`wipe_hardware_keys=true`) — `tpm2_clear` evicts TPM-sealed FDE keys. |
| **RAM scrub** | Hard | Write random patterns to all accessible RAM before poweroff. Mitigates cold-boot attacks. Requires a custom kernel module or early-exit userspace loop before the MMU shuts down. |
| **Multi-pass overwrite** | Easy | Option to run DoD 5220.22-M (3-pass) or Gutmann (35-pass) instead of single-pass random. Mainly useful for rotational HDDs. |
| **NVMe Sanitize** | Easy | Issue `nvme sanitize` (crypto-erase or block-erase mode) to NVMe drives in addition to software wipe. Faster and more thorough than overwriting sectors. |

### Operational

| Feature | Difficulty | Description |
|---------|-----------|-------------|
| **Auto-test on boot** | Easy | Run a silent `TRIGGER_TEST` at service startup; write result and timestamp to the state file. `duressd health` reports whether the last boot-time test passed. |
| **`duressd schedule`** | Easy | Register a systemd timer that runs `duressd health` daily and writes failures to the journal. Optionally sends a desktop notification or email alert. |
| **`duressd export-key`** | Easy | Serialise the Argon2id container to a base64 blob (stdout or QR code). `duressd import-key` restores it. Lets you back up authentication without exposing the passphrase. |
| **Audit log** | Easy | Append a tamper-evident log entry (timestamp, command, outcome) for every authentication attempt and wipe event. Stored in `/var/log/duressd.log` (root-only). |
| **Encrypted config** | Medium | Wrap `/etc/duressd/config` in its own LUKS2 container so configuration (verify device path, wipe flags) is not readable without the duress passphrase. |
| **Multi-machine wipe** | Medium | After wiping locally, SSH to a list of configured hosts and run `duressd trigger` there too. Useful for setups where sensitive data lives on multiple machines. |
| **Config sync** | Medium | Encrypt and push the config to a remote endpoint (S3, SFTP, git) after each configure. Pull and restore on a fresh install without manual re-configuration. |

### UX / output

| Feature | Difficulty | Description |
|---------|-----------|-------------|
| **JSON output** | Easy | `--json` flag on `status`, `health`, and `scan` for scripting and monitoring integrations. |
| **systemd-notify** | Easy | Call `systemd-notify READY=1` from the daemon so the service shows a proper `active (running)` status in `systemctl status` rather than just `active`. |
| **`duressd lock`** | Easy | Require passphrase re-entry before any duressd command runs for N minutes — prevents an attacker with a logged-in terminal from running `duressd unconfigure`. |
| **TUI menu** | Medium | Replace the plain-text interactive menu with a `dialog`/`whiptail` TUI for a more polished experience on headless servers. |
| **Quiet / script mode** | Easy | `--quiet` flag that suppresses all output except the final OK/ERROR line. Makes duressd composable in larger scripts. |
| **Notification hooks** | Easy | `POST_WIPE_HOOK` config key — a shell command run just before Phase 4 (e.g. send a push notification, POST to a webhook, or write to a remote log). |

---

## Troubleshooting

**`daemon socket not found`**
```bash
systemctl status duressd
journalctl -u duressd -n 30
```

**`Verification device '/dev/sdX' not found`**
The device path stored at configure time no longer exists (USB unplugged, renamed after kernel update). Re-run `duressd configure`.

**`Passphrase did not match any LUKS container`**
During configure with `type=luks`, the passphrase was tested against every LUKS device and failed all of them. Check you are using the correct LUKS passphrase, not the duress passphrase.

**RAID not wiped**
Phase 3 must be enabled (`wipe_full_device=true` in configure). `mdadm` must be installed (optional dep — `install.sh` warns if missing).

**`luksErase` fails silently**
Expected if `wipefs` already zeroed the LUKS magic. The data is already unrecoverable — luksErase is belt-and-suspenders.

**Countdown does not abort when I press Ctrl-C in a script**
Send `SIGINT` to the `socat` process that holds the socket connection. Closing the socket is what triggers the abort on the daemon side.

**One-liner installer fails with "extraction failed"**
The GitHub archive download was interrupted or the layout changed. Fall back to:
```bash
git clone https://github.com/twhalley/Duressd.git && cd Duressd && sudo bash install.sh
```
