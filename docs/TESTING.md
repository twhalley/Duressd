# Testing duressd

The test pipeline is layered so most of it runs anywhere with no privileges, and
the destructive parts run only against throwaway loop devices or VMs — never the
host's real disks.

| Tier | Command | Needs | What it proves |
|------|---------|-------|----------------|
| 0 — Static | `make lint` | shellcheck | No shell bugs/smells (fails on warnings+) |
| 1 — Unit | `make unit` | bats | Every handler/CLI function's logic, with all wipe binaries mocked |
| 2 — Integration | `sudo make integration` | root, losetup, cryptsetup | Real LUKS on loop devices is actually destroyed |
| 3 — E2E | `sudo make e2e` | KVM, qemu, OVMF | A booted encrypted OS wipes itself and no longer boots |

`make test` runs tiers 0+1 (the safe CI default). `make test-all` runs every
tier this host supports (auto-skips the KVM tier when `/dev/kvm` is absent).

## The safety model

Nothing outside a loop device or a disposable VM is ever a wipe target:

- **`DURESSD_TARGET_DEVICES`** — when set, every phase in `src/handler`
  (discovery, parent collection, dm-crypt teardown, RAID teardown, boot-artifact
  and hardware-key wipes) restricts itself to the listed devices. Integration
  tests set it to the loop devices they created. Unset in production → normal
  whole-system behavior.
- **`assert_safe_targets`** (`tests/integration/helpers.bash`) — refuses to run
  a destructive helper unless every target is a `/dev/loop*` device whose backing
  file lives under the test's temp workdir.
- **`DURESSD_NO_POWEROFF` / scoped runs** — `phase4_poweroff` and
  `wipe_hardware_keys` never power off or touch a TPM under a test.

## Tier 1 — unit tests

`tests/unit/*.bats` source the handler with `DURESSD_LIB_ONLY=1` (loads the
functions, runs no dispatcher) and put PATH stubs (`tests/stubs/generic-stub`,
symlinked per command by `tests/lib/common.bash`) ahead of the real binaries.
Each stub records its calls to `$DURESSD_STUB_LOG` and returns canned output
driven by `STUB_*` env vars, so tests assert *which* commands fire and with what
arguments. `_is_block`/`_tpm_device` are overridden so fake device paths and a
"present" TPM can be simulated.

## Tier 2 — loop-device integration

`sudo make integration` builds real LUKS2 containers (fast pbkdf2 KDF) on
loopback files and runs the real phase functions against them, asserting the
LUKS header is gone, filesystem signatures are cleared, and out-of-scope
partitions on the same disk survive. Requires `bats`, `losetup`, `cryptsetup`;
`sfdisk` + `dosfstools` enable the Qubes-representative fixture (ESP + ext4
`/boot` + LUKS pool), otherwise it's skipped.

## Tier 3 — KVM end-to-end

1. **Build golden images once** (Arch host, root):
   ```bash
   sudo bash tests/e2e/build-golden.sh sdboot-luks
   sudo bash tests/e2e/build-golden.sh grub-luks
   sudo bash tests/e2e/build-golden.sh qubes-like
   ```
   Each produces a bootable qcow2 with GPT = ESP + ext4 `/boot` + LUKS root, a
   real bootloader, a keyfile-in-initramfs for passwordless unlock, and a
   pre-seeded duressd (custom passphrase, `WIPE_BOOT_ARTIFACTS=true`) plus an
   auto-trigger unit keyed on `duressd.e2e=trigger`.
2. **Run** (`sudo make e2e`): each scenario boots a disposable qcow2 overlay; the
   guest fires the real wipe against its own virtual disk and powers off; the
   host then attaches the disk via `qemu-nbd` and asserts (1) no LUKS header,
   (2) no ESP filesystem, (3) the disk no longer boots any OS.

> **Status:** the E2E builder (`build-golden.sh`) targets an Arch host and has
> not yet been validated on live KVM hardware — it's the one tier that needs a
> real run to shake out environment-specific details (OVMF path, initramfs
> unlock, serial capture). The run/verify harness and all lower tiers are
> validated. On Debian/Ubuntu CI, either port the builder to `debootstrap` or
> supply pre-built golden images (see `.github/workflows/e2e.yml`).

## CI

- `.github/workflows/ci.yml` — tiers 0+1 on every push/PR.
- `.github/workflows/integration.yml` — tier 2 (privileged) on every push/PR.
- `.github/workflows/e2e.yml` — tier 3, opt-in (`workflow_dispatch` / tags).

## Local tooling without root

`bats` and `shellcheck` can be vendored without installing system packages:
```bash
git clone --depth 1 https://github.com/bats-core/bats-core
make unit BATS=./bats-core/bin/bats
make lint SHELLCHECK=/path/to/shellcheck
```
