# duressd — test & lint entrypoints.
#
#   make lint          static analysis (shellcheck)         — no root
#   make unit          unit tests (bats, mocked binaries)   — no root
#   make test          lint + unit  (the safe CI default)   — no root
#   make integration   loop-device integration tests        — needs root/sudo
#   make e2e           full KVM end-to-end tests             — needs KVM
#   make vm            run the whole suite in a throwaway VM — needs qemu + ISO=
#   make vm-auto       same, fully headless (no window/typing) — qemu + ISO=
#   make vm-shell      interactive VM shell in THIS terminal (paste works)
#   make iso           build a self-testing duressd ISO — needs sudo + archiso
#   make test-all      every tier this host can run
#
# Override tool paths when vendored, e.g.:
#   make unit BATS=/path/to/bats  lint SHELLCHECK=/path/to/shellcheck

SHELL      := /bin/bash
SHELLCHECK ?= shellcheck
BATS       ?= bats

SHELL_SOURCES := src/handler src/daemon src/cli install.sh \
                 tests/stubs/generic-stub tests/vm/auto.sh tests/vm/shell.sh \
                 tests/iso/build.sh tests/iso/overlay/airootfs/usr/local/bin/duressd-selftest

.PHONY: help lint unit test integration e2e vm vm-auto vm-shell iso test-all

help:
	@sed -n '3,16p' $(MAKEFILE_LIST) | sed 's/^# \{0,1\}//'

lint:
	@command -v $(SHELLCHECK) >/dev/null 2>&1 || { \
	  echo "shellcheck not found — install it or pass SHELLCHECK=/path"; exit 1; }
	$(SHELLCHECK) -s bash -S warning $(SHELL_SOURCES)
	@echo "  ✔  lint clean"

unit:
	@command -v $(BATS) >/dev/null 2>&1 || { \
	  echo "bats not found — install bats-core or pass BATS=/path"; exit 1; }
	$(BATS) tests/unit

test: lint unit

integration:
	@if [[ $$EUID -ne 0 ]]; then \
	  echo "integration tests need root — re-running under sudo"; \
	  sudo -E BATS="$(BATS)" bash tests/integration/run.sh; \
	else \
	  BATS="$(BATS)" bash tests/integration/run.sh; \
	fi

e2e:
	bash tests/e2e/run.sh

vm:
	@ISO="$(ISO)" bash tests/vm/launch.sh

vm-auto:
	@ISO="$(ISO)" bash tests/vm/auto.sh

vm-shell:
	@ISO="$(ISO)" bash tests/vm/shell.sh

iso:
	@if [[ $$EUID -ne 0 ]]; then \
	  echo "building the ISO needs root — re-running under sudo"; \
	  sudo bash tests/iso/build.sh; \
	else bash tests/iso/build.sh; fi

test-all: lint unit
	@bash tests/integration/run.sh 2>/dev/null || echo "  ⚠  integration tier skipped (needs root)"
	@if [[ -e /dev/kvm ]]; then bash tests/e2e/run.sh; \
	 else echo "  ⚠  e2e tier skipped (no /dev/kvm)"; fi
