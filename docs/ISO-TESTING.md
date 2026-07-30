# Self-testing duressd ISO

Build a custom Arch ISO that boots straight into the duressd test suite —
**offline, deterministic, zero typing** — and prints PASS/FAIL on screen, then
drops to a ready root shell. It bakes in duressd, every test dependency, a
vendored `bats`, and `spice-vdagent` (clipboard for manual poking).

Because it self-tests on boot, you don't need to paste or type anything — this
sidesteps the QEMU-clipboard problem entirely.

## Build

```bash
sudo make iso
# or: sudo bash tests/iso/build.sh   ->   out/duressd-test-*.iso
```

Requirements: the `archiso` package and **root** (`mkarchiso` uses loop devices
and mounts). The builder layers our changes onto the stock `releng` profile, so
the bootloader config is inherited from your installed archiso, not hand-rolled.
It downloads packages into the image, so the *build* host needs network; the
resulting ISO runs fully offline.

## Run

The ISO **self-tests on its own** at boot, so pick the launcher by what you want:

```bash
# Interactive — a native terminal you can debug in (recommended):
make vm ISO=out/duressd-test-*.iso          # graphical QEMU window
make vm-shell ISO=out/duressd-test-*.iso    # serial shell in THIS terminal (paste works)

# Unattended — runs, captures a transcript, powers off, exits non-zero on failure:
make vm-auto ISO=out/duressd-test-*.iso
```

On boot it autologins root, runs `tests/vm/inside.sh` with `DURESSD_SKIP_PACMAN=1`
(lint → unit → loop-device integration → dry-run-then-real scoped wipe), shows a
green **✔ PASSED** / red **✘ FAILED** banner, then drops you at an interactive
root shell. Re-run the suite any time with `duressd-selftest --force`.

**`duressd` is installed and running as a service** in the image, so the shell is
a real playground:

```bash
duressd status      duressd health      duressd dry-run
duressd test        duressd configure   systemctl status duressd
```

> Use `make vm` or `make vm-shell` for hands-on debugging — `make vm-auto` powers
> the VM off when the suite finishes, so it's for CI/capture, not interactive use.

## What's inside

| Layer | Contents |
|-------|----------|
| Packages | `make shellcheck socat cryptsetup util-linux dosfstools mdadm efibootmgr tpm2-tools openssl spice-vdagent` (+ releng base) |
| `bats` | `bats-core` vendored to `/usr/local/lib/bats-core`, symlinked on `PATH` |
| Repo | this working tree baked at `/root/duressd` |
| Autorun | `/usr/local/bin/duressd-selftest`, invoked from root's `.bash_profile` / `.zprofile` (run-once via `/run/duressd-selftest.done`) |

## Notes

- The build is the only step that needs host root; the produced ISO confines
  every wipe to a loopback file inside the VM, exactly like `make vm`.
- To also use this image for **physical** provisioning, it already contains a
  working duressd — see [PHYSICAL-TESTING.md](PHYSICAL-TESTING.md).
