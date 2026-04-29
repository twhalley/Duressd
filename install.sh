#!/bin/bash
# Install or uninstall the duressd wipe service.
# Usage: ./install.sh [install|uninstall]   (default: install)
# Must be run as root.
set -euo pipefail

LIBDIR=/usr/local/lib/duressd
BINDIR=/usr/local/bin
UNITDIR=/etc/systemd/system
CFGDIR=/etc/duressd
ALIASES=/etc/profile.d/duressd.sh
SRC="$(cd "$(dirname "$0")/src" && pwd)"
SYSTEMD_SRC="$(cd "$(dirname "$0")/systemd" && pwd)"

# ── colours ───────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\033[1;31m' GRN=$'\033[1;32m' YLW=$'\033[1;33m'
    CYN=$'\033[1;36m' BLD=$'\033[1m'    RST=$'\033[0m'
else
    RED='' GRN='' YLW='' CYN='' BLD='' RST=''
fi

step()  { echo -e "${CYN}  →  $*${RST}"; }
good()  { echo -e "${GRN}  ✔  $*${RST}"; }
warn()  { echo -e "${YLW}  ⚠  $*${RST}"; }
bad()   { echo -e "${RED}  ✘  $*${RST}" >&2; }

require_root() {
    [[ $EUID -eq 0 ]] || { bad "Must be run as root."; exit 1; }
}

check_deps() {
    local missing=()
    for cmd in socat cryptsetup wipefs dmsetup lsblk openssl dd blkdiscard; do
        command -v "$cmd" &>/dev/null || missing+=("$cmd")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        bad "Missing required tools: ${missing[*]}"
        echo "  On Debian/Ubuntu:  apt-get install ${missing[*]}" >&2
        exit 1
    fi
    good "All required tools present"
}

# ── install ───────────────────────────────────────────────────────────────────
cmd_install() {
    require_root

    echo -e "\n${BLD}Installing duressd wipe service${RST}\n"

    step "Checking dependencies"
    check_deps

    step "Installing daemon and handler to $LIBDIR/"
    install -d -m 0755 "$LIBDIR"
    install -m 0755 "$SRC/daemon"  "$LIBDIR/daemon"
    install -m 0755 "$SRC/handler" "$LIBDIR/handler"

    step "Installing CLI to $BINDIR/duressd"
    install -m 0755 "$SRC/cli" "$BINDIR/duressd"

    step "Installing shell aliases to $ALIASES"
    install -m 0644 "$SRC/aliases.sh" "$ALIASES"

    step "Installing systemd unit"
    install -m 0644 "$SYSTEMD_SRC/duressd.service" "$UNITDIR/duressd.service"

    step "Creating config directory $CFGDIR/"
    install -d -m 0700 -o root -g root "$CFGDIR"

    step "Enabling and starting duressd.service"
    systemctl daemon-reload
    systemctl enable --now duressd.service

    echo
    good "Installation complete"
    echo
    echo "  Next steps:"
    echo -e "  ${CYN}duressd configure${RST}          — set up your duress passphrase"
    echo -e "  ${CYN}duressd test${RST}  /  ${CYN}dwipe_test${RST}  — dry run (non-destructive)"
    echo -e "  ${CYN}duressd install-shortcuts${RST}  — add desktop launchers"
    echo -e "  ${CYN}duressd status${RST}             — check daemon state"
    echo
}

# ── uninstall ─────────────────────────────────────────────────────────────────
cmd_uninstall() {
    require_root

    echo -e "\n${BLD}Uninstalling duressd wipe service${RST}\n"

    step "Stopping and disabling duressd.service"
    systemctl disable --now duressd.service 2>/dev/null || true

    step "Removing systemd unit"
    rm -f "$UNITDIR/duressd.service"
    systemctl daemon-reload

    step "Removing binaries"
    rm -rf "$LIBDIR"
    rm -f  "$BINDIR/duressd"

    step "Removing shell aliases"
    rm -f "$ALIASES"

    if [[ -d "$CFGDIR" ]]; then
        warn "Configuration directory $CFGDIR/ still exists."
        read -rp "  Remove $CFGDIR/ (including any stored passphrase hash)? [y/N]: " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            # Securely erase the Argon2id keyslot container before deleting
            if [[ -f "$CFGDIR/passphrase.luks" ]]; then
                step "Erasing Argon2id keyslot container"
                cryptsetup luksErase --batch-mode "$CFGDIR/passphrase.luks" 2>/dev/null || true
                shred -u "$CFGDIR/passphrase.luks" 2>/dev/null || true
            fi
            rm -rf "$CFGDIR"
            good "Configuration removed"
        else
            warn "$CFGDIR/ left in place — remove manually if needed"
        fi
    fi

    echo
    good "Uninstallation complete"
    echo
}

# ── status ────────────────────────────────────────────────────────────────────
cmd_status() {
    echo -e "\n${BLD}duressd installation status${RST}\n"
    local all_ok=true

    for f in "$LIBDIR/daemon" "$LIBDIR/handler" "$BINDIR/duressd"; do
        if [[ -x "$f" ]]; then
            echo -e "  ${GRN}✔${RST}  $f"
        else
            echo -e "  ${RED}✘${RST}  $f  ${RED}(missing)${RST}"
            all_ok=false
        fi
    done

    if systemctl is-active duressd.service &>/dev/null; then
        echo -e "  ${GRN}✔${RST}  duressd.service  ${GRN}(active)${RST}"
    else
        echo -e "  ${RED}✘${RST}  duressd.service  ${RED}(not running)${RST}"
        all_ok=false
    fi

    [[ -f "$CFGDIR/config" ]] && \
        echo -e "  ${GRN}✔${RST}  $CFGDIR/config  ${GRN}(configured)${RST}" || \
        echo -e "  ${YLW}⚠${RST}  $CFGDIR/config  ${YLW}(not configured — run: duressd configure)${RST}"

    echo
    $all_ok && good "All components installed" || warn "Some components missing — run: ./install.sh install"
    echo
}

# ── main ──────────────────────────────────────────────────────────────────────
case "${1:-install}" in
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    *)
        echo "Usage: $0 [install|uninstall|status]" >&2
        exit 1
        ;;
esac
