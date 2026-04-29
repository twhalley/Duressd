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

`install.sh` checks for all required tools and prints the correct install command for your distro before aborting.

---

## Installation

```bash
git clone https://github.com/twhalley/Duressd.git
cd Duressd
sudo ./install.sh install
```

`install.sh` copies binaries, installs the systemd unit, enables and starts the service, and drops shell aliases into `/etc/profile.d/duressd.sh`.

```
sudo ./install.sh install     # install everything
sudo ./install.sh uninstall   # remove everything (prompts before wiping config)
sudo ./install.sh status      # check all components are present and running
```

---

## Quick start

```bash
# 1. Configure
sudo duressd configure

# 2. Dry run — confirm everything works
duressd test

# 3. (Optional) Install shortcuts for your desktop
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
| Overwrite LUKS header | 40 MiB `openssl rand` over each LUKS partition head + `blkdiscard` | ~1–2 s per device |
| Wipe full device(s) | Chunked random overwrite of entire parent block device(s), then stops RAID arrays and wipes member superblocks | Slow — minutes per GB |

### Countdown

Set a countdown (e.g. `5` seconds) to allow aborting a real wipe by pressing `Ctrl-C` before the countdown expires. Disabled when set to `0`.

---

## CLI Reference

Run `duressd` with no arguments to open the interactive menu.

### `duressd status`

Shows the daemon state and the active configuration.

```
State:                         IDLE
Configured:                    yes
Password type:                 custom
Verify device:                 /dev/sda2
Overwrite LUKS header:         false
Wipe full device(s):           false
Countdown (s):                 5
```

State values: `IDLE` · `WIPING` · `TESTING` · `PREP_WIPING` · `DONE`

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

### `duressd unconfigure`

Erases the Argon2id keyslot container (`shred`), removes `/etc/duressd/config`. Requires the duress passphrase (or LUKS passphrase for `type=luks`).

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

Installed to `/etc/profile.d/duressd.sh` (active for all login shells after re-login):

```bash
alias dwipe_test='duressd test'
alias dwipe_real='duressd trigger'
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

## Suggested improvements

The following features are not yet implemented:

| Feature | Description |
|---------|-------------|
| `duressd verify` | Test that the stored passphrase still works right now (`--test-passphrase`) without doing any wipe. Essential sanity check after configuring |
| `duressd health` | Preflight: service running, config valid, verify_device accessible, all tools on PATH, `passphrase.luks` intact — single-command go/no-go |
| `duressd change-passphrase` | Atomically update the duress passphrase (add new LUKS2 keyslot, remove old) without full reconfigure |
| `duressd passgen` | Generate and print a strong random passphrase (`openssl rand -base64 18` or diceware) |
| `duressd logs` | `journalctl -u duressd -n 100` with coloured output |
| PAM module | Trigger wipe when a "decoy" username logs in via PAM `pam_exec` |
| Network kill-switch | UDP/HTTP listener that triggers wipe on receipt of a signal from a remote server |
| Auto-test on boot | Silent `TRIGGER_TEST` at startup; alert or log if it fails |
| Encrypted config | Wrap `/etc/duressd/config` itself in a LUKS2 container |

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
