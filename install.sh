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

# Map a binary name to its package name for a given distro family.
# Prints the package name, or nothing if unknown.
_pkg_for() {
    local cmd="$1" family="$2"
    # Most tools live in util-linux or their own same-named package across distros;
    # the exceptions are called out explicitly per family below.
    case "$family" in
        debian)
            case "$cmd" in
                socat|cryptsetup|openssl|mdadm) echo "$cmd" ;;
                wipefs|lsblk|blkdiscard|findmnt) echo util-linux ;;
                dmsetup)  echo dmsetup ;;   # own package on Debian/Ubuntu
                dd|shred) echo coreutils ;;
            esac ;;
        arch)
            case "$cmd" in
                socat|cryptsetup|openssl|mdadm) echo "$cmd" ;;
                wipefs|lsblk|blkdiscard|findmnt) echo util-linux ;;
                dmsetup)  echo device-mapper ;; # part of device-mapper on Arch
                dd|shred) echo coreutils ;;
            esac ;;
        fedora)
            case "$cmd" in
                socat|openssl|mdadm) echo "$cmd" ;;
                cryptsetup) echo cryptsetup ;;
                wipefs|lsblk|blkdiscard|findmnt) echo util-linux ;;
                dmsetup)  echo device-mapper ;;
                dd|shred) echo coreutils ;;
            esac ;;
        opensuse)
            case "$cmd" in
                socat|cryptsetup|mdadm) echo "$cmd" ;;
                openssl)  echo libopenssl-devel ;; # CLI lives here on openSUSE
                wipefs|lsblk|blkdiscard|findmnt) echo util-linux ;;
                dmsetup)  echo device-mapper ;;
                dd|shred) echo coreutils ;;
            esac ;;
        alpine)
            case "$cmd" in
                socat|cryptsetup|openssl|mdadm) echo "$cmd" ;;
                wipefs|lsblk|findmnt) echo util-linux ;;
                blkdiscard) echo util-linux-misc ;;
                dmsetup)  echo lvm2 ;;
                dd|shred) echo coreutils ;;
            esac ;;
        void)
            case "$cmd" in
                socat|cryptsetup|openssl|mdadm) echo "$cmd" ;;
                wipefs|lsblk|blkdiscard|findmnt) echo util-linux ;;
                dmsetup)  echo device-mapper ;;
                dd|shred) echo coreutils ;;
            esac ;;
        gentoo)
            # Gentoo uses atoms; give the most direct one
            case "$cmd" in
                socat)      echo net-misc/socat ;;
                cryptsetup) echo sys-fs/cryptsetup ;;
                wipefs|lsblk|blkdiscard|findmnt|dmsetup) echo sys-apps/util-linux ;;
                openssl)    echo dev-libs/openssl ;;
                mdadm)      echo sys-fs/mdadm ;;
                dd|shred)   echo sys-apps/coreutils ;;
            esac ;;
    esac
}

check_deps() {
    # Required: wipe chain cannot run without these.
    local required=(socat cryptsetup wipefs dmsetup lsblk blkdiscard openssl dd findmnt shred)
    # Optional: only needed when WIPE_ALL_LUKS=true targets RAID arrays.
    local optional=(mdadm)

    local missing=() missing_opt=()
    for cmd in "${required[@]}";  do command -v "$cmd" &>/dev/null || missing+=("$cmd");     done
    for cmd in "${optional[@]}";  do command -v "$cmd" &>/dev/null || missing_opt+=("$cmd"); done

    [[ ${#missing_opt[@]} -gt 0 ]] && \
        warn "Optional (RAID wipe) tools not found: ${missing_opt[*]}"

    if [[ ${#missing[@]} -eq 0 ]]; then
        good "All required tools present"
        return 0
    fi

    bad "Missing required tools: ${missing[*]}"

    # ── distro detection ──────────────────────────────────────────────────────
    local id="" id_like="" family="" pm=""
    if [[ -f /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        id="${ID:-}"
        id_like="${ID_LIKE:-}"
    fi

    # Resolve to a family, checking ID then ID_LIKE (space-separated list)
    _resolve_family() {
        local token="$1"
        case "$token" in
            debian|ubuntu|linuxmint|pop|elementary|kali|parrot|tails|raspbian)
                echo debian ;;
            arch|manjaro|endeavouros|garuda|artix|cachyos|blackarch)
                echo arch ;;
            fedora|rhel|centos|rocky|almalinux|ol|scientific)
                echo fedora ;;
            opensuse*|sles|sled)
                echo opensuse ;;
            alpine)
                echo alpine ;;
            void)
                echo void ;;
            gentoo)
                echo gentoo ;;
        esac
    }

    family=$(_resolve_family "$id")
    if [[ -z "$family" ]]; then
        # Walk ID_LIKE tokens left-to-right until we get a match
        for token in $id_like; do
            family=$(_resolve_family "$token")
            [[ -n "$family" ]] && break
        done
    fi

    # ── package manager map ───────────────────────────────────────────────────
    case "$family" in
        debian)  pm="apt-get install" ;;
        arch)    pm="pacman -S" ;;
        fedora)  pm="dnf install" ;;
        opensuse) pm="zypper install" ;;
        alpine)  pm="apk add" ;;
        void)    pm="xbps-install -S" ;;
        gentoo)  pm="emerge" ;;
        *)
            echo -e "${YLW}  Install the missing tools with your system package manager.${RST}" >&2
            exit 1
            ;;
    esac

    # ── collect unique package names for missing tools ────────────────────────
    local pkgs=()
    for cmd in "${missing[@]}"; do
        local pkg
        pkg=$(_pkg_for "$cmd" "$family")
        [[ -n "$pkg" ]] && pkgs+=("$pkg")
    done
    # Deduplicate while preserving order
    local seen="" unique_pkgs=()
    for p in "${pkgs[@]}"; do
        [[ "$seen" == *"|${p}|"* ]] && continue
        seen+="|${p}|"; unique_pkgs+=("$p")
    done

    echo -e "  ${YLW}Install with:${RST}  ${BLD}${pm} ${unique_pkgs[*]}${RST}" >&2
    exit 1
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
