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

### Remote trigger from an Android phone

The kill switch is just an SSH key with a forced command, so **any Android SSH
client works** — no companion app to install on the phone beyond a terminal or
SSH app. Two ways to reach the machine:

#### A. Direct SSH (host reachable on your LAN / VPN / port-forward)

1. **On the machine**, install the trigger. For a phone, the key-only mode is
   easiest — a bare connect fires the wipe, no passphrase to type on a
   touchscreen:
   ```bash
   sudo duressd install-ssh-trigger --embed-passphrase
   #   prints the private key it generated: ~/.ssh/duressd_duress
   ```
2. **Move the private key to the phone** over a trusted channel (USB/`adb push`,
   a one-time encrypted transfer — never leave a copy on the machine you might
   need to wipe). Store it in the app's protected keystore.
3. **Trigger** from any Android SSH app:
   - **Termux** (`pkg install openssh`): `ssh -i duressd_duress -T root@HOST`
   - **JuiceSSH / Termius / ConnectBot**: import `duressd_duress` as the
     identity, set the host user to `root`, connect. The forced command runs the
     wipe automatically — you don't get a shell.

   If you used the default (passphrase) mode instead of `--embed-passphrase`,
   send the duress passphrase on stdin. In Termux:
   ```bash
   printf '%s' 'YOUR-DURESS-PASS' | ssh -i duressd_duress -T root@HOST
   ```

> Protect the phone-side key with the app's biometric/keystore lock. Anyone who
> gets both the phone **and** (for `--embed-passphrase`) can trigger the wipe —
> that's the whole point, but it means the phone is now a live kill switch.

#### B. SSH over Tor (host NOT reachable — no port-forwarding, works anywhere)

This exposes sshd as a **client-authorized v3 onion service**: the machine needs
no public IP or open port, and only someone holding the onion client-auth key
can even see the service (a second auth layer in front of the SSH key).

1. **On the machine:**
   ```bash
   sudo duressd install-ssh-trigger --embed-passphrase --tor
   ```
   It prints the **`.onion` address** and writes the operator client-auth secret
   to `/etc/duressd/tor-client-auth.private`. Move that file off the machine.
2. **On the phone**, use **Termux** (it has real `tor`/`torsocks`):
   ```bash
   pkg install openssh tor torsocks
   mkdir -p ~/.tor/onion_auth
   cp tor-client-auth.private ~/.tor/onion_auth/duressd.auth_private   # from step 1
   echo 'ClientOnionAuthDir ~/.tor/onion_auth' >> $PREFIX/etc/tor/torrc
   tor &            # or run the Orbot app instead of this line
   # then fire the wipe:
   torsocks ssh -i duressd_duress -T xxxxxxxx.onion
   ```
   (Prefer the **Orbot** app for the Tor connection? Put the client-auth key in
   Orbot's onion-auth settings and route the SSH app through Orbot's VPN mode
   instead of `torsocks`.)

Either way, add **`--dry-run`** on the far end first
(`… ssh … root@HOST duressd trigger-remote --dry-run`) to rehearse from the
phone with nothing destroyed.

---

### `duressd install-login-trigger`  ·  PAM login duress passphrase

Installs a PAM hook (`auth optional pam_exec.so`) so that entering your **duress passphrase at any login prompt** fires the wipe. Because it's `optional`, it never blocks or changes a normal login.

> ⚠️ **Remote-wipe footgun — the guard exists for a reason.** The hook runs on **every** auth attempt, including **failed** ones, and sshd uses PAM. So if **SSH `PasswordAuthentication` is enabled**, an SSH login that submits the duress passphrase **fires the wipe even though the login fails** — anyone who can reach port 22 and guess/know the pin could **remote-wipe the machine**.
>
> For this reason `install-login-trigger` **refuses** when `PasswordAuthentication yes` is detected (`sshd -T`). Do one of:
> - **Key-only SSH (recommended):** `PasswordAuthentication no` in `sshd_config` → `systemctl reload sshd`. The trigger then only fires at the *physical console*.
> - **Accept the risk with `--force`** — only with a **strong** duress passphrase, never a short pin. A weak pin + password SSH is a network-reachable self-destruct.
>
> The **key-based** kill switch (`install-ssh-trigger`) is different: it's gated by possession of a dedicated SSH key, so a weak passphrase alone can't trigger it remotely.

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

> ### Which trigger for which disk?
> The **runtime** triggers (`duressd trigger`, the SSH/Tor kill switch, the PAM login hook) reliably and cleanly destroy **any LUKS volume that is *not* the running root** — data disks, external drives, RAID arrays, home/swap. That path is proven end-to-end.
>
> The **running root disk is the hard case**: the wipe runs from userspace on the very disk it is destroying. duressd handles it as robustly as possible — `luksErase` **and** a direct overwrite of the LUKS header (which works even while the mapping is open), the parent-disk partition-table overwrite deferred to the very last step, and a SysRq poweroff with a reboot fallback — so the **data is destroyed**. But finishing cleanly (scrub every boot artifact, guarantee a clean power-off) is inherently fragile there.
>
> **For the root disk, the boot-time hook below is the robust mechanism**: it runs in the initramfs *before* the root is ever mounted, so there is no live-root to saw through. Use the boot hook to wipe the root; use the runtime triggers to wipe everything else (and as a best-effort root wipe when you can't reach the boot prompt).

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

**Arch (mkinitcpio)** — this is the implemented path (`duressd install-luks-trigger`):

```
/etc/initcpio/install/duress   ← build hook (adds cryptsetup + the oracle to the initrd)
/etc/initcpio/hooks/duress     ← runtime hook (tests the passphrase before `encrypt`)
```

**Fedora / Qubes (dracut)** — not yet ported:

```
/etc/dracut.conf.d/duressd.conf       ← install_items += ...
/usr/lib/dracut/modules.d/99duressd/  ← hook module
```

### Security note

The duress passphrase is **not** a LUKS keyslot on your disk — the mkinitcpio hook matches it against a **separate Argon2id oracle** (`/duress-oracle.luks`, baked into the initramfs). So the duress passphrase **cannot decrypt the volume**; it can only *trigger the wipe*. Someone who learns it — or who boots a live OS to bypass the hook — still cannot read your data with it.

The real residual risk is different: the duress passphrase must remain **secret from an adversary who could coerce your *normal* passphrase from you but not the duress one**. Hardening:

- Use a duress passphrase distinct from your normal unlock key (`type=custom`, enforced ≥ 8 chars).
- Combine with a countdown so the wipe cannot be interrupted once started.
- Enable Phase 2 header overwrite / full-device wipe for defence-in-depth beyond the header erase.

**Two limitations you must plan around — the boot oracle is *not* a secret and *not* hidden:**

- **Offline brute-force.** The boot-time oracle (`/duress-oracle.luks`) is baked into the initramfs (`/boot/initramfs-linux.img`), which lives on the **unencrypted, world-readable `/boot`**. An adversary with disk access can copy it and brute-force the duress passphrase **offline**. Argon2id makes each guess expensive but does not make a weak passphrase safe. **Treat the boot-hook duress passphrase like a real key: high-entropy (a long random phrase), not a short human PIN.** The ≥ 8-char floor is a footgun guard, *not* a security level for the boot hook. (The runtime-side oracle `/etc/duressd/passphrase.luks` is mode `0600` and only exposed to a *running* root, so it is not offline-readable the same way — the initramfs copy is the exposed one.)
- **No deniability.** The hook and the oracle file are visible to anyone who inspects the initramfs. The boot trigger is a **wipe mechanism, not a hidden feature** — do not rely on an adversary *not knowing* a duress capability exists. If plausible deniability matters, the boot hook does not provide it.

### Secure Boot

The boot-time trigger lives in the **initramfs**, so under **Secure Boot** the initramfs must be part of a signed boot chain — either a signed **Unified Kernel Image** (`ukify` + `sbctl`/shim) or a signed kernel+initrd. On a machine with Secure Boot **enabled**, install the duress hook and then re-sign the boot chain exactly as you sign your normal kernel; the hook *logic* is unchanged, only the packaging (UKI + signature) differs. With Secure Boot **disabled** (as the golden test image is built), the hook works as-is.

Two clarifications:

- **duressd does not clear Secure Boot keys** (PK/KEK/db/dbx or enrolled MOK). Those are not secret data, and clearing them risks bricking boot — so they are intentionally left alone. The boot-artifact phase still deletes UEFI *boot entries* and scrubs the ESP.
- **The runtime triggers are unaffected by Secure Boot.** `duressd trigger`, the SSH/Tor remote kill switch, and the PAM login trigger are userspace wiping block devices — Secure Boot does not gate them. Only the *boot-prompt* trigger depends on the signed boot chain above.

### Status

**Implemented for mkinitcpio (Arch)** — `duressd install-luks-trigger` adds the duress keyslot and installs the hook; validated end-to-end by the in-VM golden boot test (`make vm-golden`): correct passphrase boots, duress passphrase wipes the header and the disk no longer boots. **dracut** (Fedora/Qubes) still needs a module port (see the Qubes notes). Debian/Ubuntu `initramfs-tools` is sketched above but not yet packaged.

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
