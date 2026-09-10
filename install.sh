#!/bin/bash
# Install / uninstall / status the duressd wipe service.
# Usage: sudo bash install.sh [install|uninstall|status]
# One-liner: curl -sSL https://raw.githubusercontent.com/twhalley/Duressd/main/install.sh | sudo bash
set -euo pipefail

# ── bootstrap ─────────────────────────────────────────────────────────────────
# When piped via curl/wget the src/ tree is absent. Download the full archive
# from GitHub and re-exec from the extracted directory automatically.
_self="${BASH_SOURCE[0]:-}"
_dir="$(cd "$(dirname "${_self:-/}")" 2>/dev/null && pwd)" || _dir=""
if [[ -z "$_dir" ]] || [[ ! -d "${_dir}/src" ]]; then
    if [[ -t 1 ]]; then CYN=$'\033[1;36m' RED=$'\033[1;31m' YLW=$'\033[1;33m' RST=$'\033[0m'
    else CYN='' RED='' YLW='' RST=''; fi
    [[ $EUID -eq 0 ]] || { printf '%s\n' "${RED}  ✘  Must be run as root — use: curl ... | sudo bash${RST}" >&2; exit 1; }
    # SECURITY: `curl … | sudo bash` runs unverified remote code AS ROOT. There is
    # no signature/checksum here. For a security tool the safer path is to clone,
    # review, then run:  git clone …/Duressd && sudo bash Duressd/install.sh
    printf '%s\n' "${YLW}  ⚠  Installing code fetched over the network as root, unverified.${RST}" >&2
    printf '%s\n' "${YLW}     Safer: git clone the repo, review it, then run sudo bash install.sh.${RST}" >&2
    # DURESSD_REF lets you pin a reviewed tag/branch instead of the moving 'main'.
    _ref="${DURESSD_REF:-main}"
    printf '%s\n' "${CYN}  →  Downloading duressd (${_ref}) from GitHub${RST}"
    _work=$(mktemp -d)
    _url="https://github.com/twhalley/Duressd/archive/refs/heads/${_ref}.tar.gz"
    if   command -v curl &>/dev/null; then curl -fsSL "$_url" -o "$_work/s.tar.gz"
    elif command -v wget &>/dev/null; then wget  -q    "$_url" -O "$_work/s.tar.gz"
    else printf '%s\n' "${RED}  ✘  curl or wget required${RST}" >&2; exit 1; fi
    tar -xzf "$_work/s.tar.gz" -C "$_work"
    _src=$(find "$_work" -maxdepth 1 -type d -name "Duressd-*" | head -1)
    [[ -n "$_src" ]] || { printf '%s\n' "${RED}  ✘  Extraction failed${RST}" >&2; exit 1; }
    exec bash "$_src/install.sh" "${1:-install}"
fi

# Paths are overridable via env so the unit tests can install into a temp root.
# In production these are unset → the real system paths apply.
LIBDIR="${LIBDIR:-/usr/local/lib/duressd}"
BINDIR="${BINDIR:-/usr/local/bin}"
UNITDIR="${UNITDIR:-/etc/systemd/system}"
CFGDIR="${CFGDIR:-/etc/duressd}"
ALIASES="${ALIASES:-/etc/profile.d/duressd.sh}"
FISH_ALIASES="${FISH_ALIASES:-/etc/fish/conf.d/duressd.fish}"
SRC="${_dir}/src"
SYSTEMD_SRC="${_dir}/systemd"

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
    [[ -n "${DURESSD_SKIP_PRIVCHECK:-}" ]] && return 0   # test seam
    [[ $EUID -eq 0 ]] || { bad "Must be run as root."; exit 1; }
}

# The daemon is a systemd service. Refuse cleanly on a system without systemd —
# BEFORE we copy anything — rather than failing half-way through `systemctl`.
# The systemd runtime dir is the canonical "is systemd the init" signal
# (overridable for tests via DURESSD_SYSTEMD_DIR).
require_systemd() {
    local sd="${DURESSD_SYSTEMD_DIR:-/run/systemd/system}"
    if ! command -v systemctl >/dev/null 2>&1 || [[ ! -d "$sd" ]]; then
        bad "duressd's daemon requires systemd — systemctl / a running systemd was not found."
        warn "This host does not appear to run systemd. The runtime triggers work on"
        warn "any init, but the packaged service (and this installer) are systemd-only."
        warn "Install on a systemd host, or wire src/handler up to your init manually."
        exit 1
    fi
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
    # Optional: enable extra wipe depth / remote reach —
    #   mdadm       RAID teardown (Phase 3)
    #   efibootmgr  UEFI NVRAM entry removal (Phase 1.5 boot-artifact wipe)
    #   tpm2_clear  TPM-sealed key eviction (Phase 1.6 hardware-key wipe)
    #   tor         SSH-over-Tor onion kill switch (install-ssh-trigger --tor)
    local optional=(mdadm efibootmgr tpm2_clear tor)

    local missing=() missing_opt=()
    for cmd in "${required[@]}";  do command -v "$cmd" &>/dev/null || missing+=("$cmd");     done
    for cmd in "${optional[@]}";  do command -v "$cmd" &>/dev/null || missing_opt+=("$cmd"); done

    if [[ ${#missing_opt[@]} -gt 0 ]]; then
        warn "Optional wipe-depth tools not found: ${missing_opt[*]}"
        warn "  Packages: mdadm (RAID) · efibootmgr (UEFI) · tpm2-tools (TPM) · tor (onion trigger)"
    fi

    if [[ ${#missing[@]} -eq 0 ]]; then
        good "All required tools present"
        return 0
    fi

    bad "Missing required tools: ${missing[*]}"

    # ── distro detection ──────────────────────────────────────────────────────
    local id="" id_like="" family="" pm=""
    if [[ -r /etc/os-release ]]; then
        # PARSE, never `source`: sourcing os-release would execute any code in it as
        # root — inconsistent with the project's parse-don't-source discipline
        # (handler/pam/build-hook all parse KEY=value). Strip surrounding quotes.
        local _k _v
        while IFS='=' read -r _k _v; do
            _v="${_v%\"}"; _v="${_v#\"}"
            case "$_k" in
                ID)      id="$_v" ;;
                ID_LIKE) id_like="$_v" ;;
            esac
        done < /etc/os-release
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
    require_systemd            # abort cleanly on a non-systemd host BEFORE any changes

    echo -e "\n${BLD}Installing duressd wipe service${RST}\n"

    step "Checking dependencies"
    check_deps

    step "Installing daemon and handler to $LIBDIR/"
    install -d -m 0755 "$LIBDIR"
    install -m 0755 "$SRC/daemon"  "$LIBDIR/daemon"
    install -m 0755 "$SRC/handler" "$LIBDIR/handler"

    step "Installing CLI to $BINDIR/duressd"
    install -Dm0755 "$SRC/cli" "$BINDIR/duressd"

    if [[ -d "${_dir}/initramfs" ]]; then
        step "Installing initramfs hook templates to $LIBDIR/initramfs/"
        install -Dm644 "${_dir}/initramfs/duress-install-hook" "$LIBDIR/initramfs/duress-install-hook"
        install -Dm755 "${_dir}/initramfs/duress-runtime-hook" "$LIBDIR/initramfs/duress-runtime-hook"
    fi

    if [[ -f "${_dir}/pam/pam-duress" ]]; then
        step "Installing PAM duress hook to $LIBDIR/pam-duress"
        install -Dm755 "${_dir}/pam/pam-duress" "$LIBDIR/pam-duress"
    fi

    step "Installing shell aliases to $ALIASES"
    install -Dm0644 "$SRC/aliases.sh" "$ALIASES"

    if command -v fish &>/dev/null; then
        step "Installing fish aliases to $FISH_ALIASES"
        install -d -m 0755 /etc/fish/conf.d
        install -m 0644 "$SRC/aliases.fish" "$FISH_ALIASES"
    fi

    step "Installing systemd unit"
    install -Dm0644 "$SYSTEMD_SRC/duressd.service" "$UNITDIR/duressd.service"

    step "Creating config directory $CFGDIR/"
    if [[ $EUID -eq 0 ]]; then
        install -d -m 0700 -o root -g root "$CFGDIR"
    else
        install -d -m 0700 "$CFGDIR"          # test/non-root: skip the root chown
    fi

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
# Securely destroy the Argon2id duress oracle in <cfgdir>: erase the LUKS keyslots
# (so the KDF material is gone even if the file is later recovered) then shred the
# file. Best-effort — a missing tool must not abort uninstall.
secure_erase_oracle() {
    local oracle="$1/passphrase.luks"
    [[ -f "$oracle" ]] || return 0
    step "Erasing Argon2id keyslot container"
    cryptsetup luksErase --batch-mode "$oracle" 2>/dev/null || true
    shred -u "$oracle" 2>/dev/null || rm -f "$oracle"
}

cmd_uninstall() {
    require_root

    echo -e "\n${BLD}Uninstalling duressd wipe service${RST}\n"

    # The trigger installers modify system files (initramfs HOOKS, the PAM auth
    # stack, authorized_keys) that removing the binaries alone would ORPHAN — and
    # once the CLI below is gone those reversals can't be run. So reverse them
    # AUTOMATICALLY first, while the CLI still exists (each is a clean no-op if that
    # trigger was never installed). Skip with DURESSD_KEEP_TRIGGERS=1.
    local duressd_bin="$BINDIR/duressd"
    [[ -x "$duressd_bin" ]] || duressd_bin="$(command -v duressd 2>/dev/null || true)"
    if [[ -n "$duressd_bin" && -x "$duressd_bin" && "${DURESSD_KEEP_TRIGGERS:-}" != 1 ]]; then
        step "Reversing any installed triggers (boot hook, PAM login, SSH)"
        "$duressd_bin" install-luks-trigger  --uninstall 2>/dev/null || true
        "$duressd_bin" install-login-trigger --uninstall 2>/dev/null || true
        "$duressd_bin" install-ssh-trigger   --uninstall 2>/dev/null || true
        good "Trigger reversals attempted (no-op for any that weren't installed)"
    else
        warn "CLI not found — if you installed any triggers, reverse them manually:"
        warn "  duressd install-{luks,login,ssh}-trigger --uninstall   (before removing binaries)"
    fi

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
    rm -f "$FISH_ALIASES"

    if [[ -d "$CFGDIR" ]]; then
        warn "Configuration directory $CFGDIR/ still exists."
        read -rp "  Remove $CFGDIR/ (including any stored passphrase hash)? [y/N]: " ans
        if [[ "$ans" =~ ^[Yy]$ ]]; then
            secure_erase_oracle "$CFGDIR"
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

    [[ -f "$ALIASES" ]] && \
        echo -e "  ${GRN}✔${RST}  $ALIASES  ${GRN}(bash/zsh aliases)${RST}" || \
        echo -e "  ${YLW}⚠${RST}  $ALIASES  ${YLW}(missing)${RST}"

    if command -v fish &>/dev/null; then
        [[ -f "$FISH_ALIASES" ]] && \
            echo -e "  ${GRN}✔${RST}  $FISH_ALIASES  ${GRN}(fish aliases)${RST}" || \
            echo -e "  ${YLW}⚠${RST}  $FISH_ALIASES  ${YLW}(missing)${RST}"
    fi

    echo
    $all_ok && good "All components installed" || warn "Some components missing — run: ./install.sh install"
    echo
}

# ── main ──────────────────────────────────────────────────────────────────────
# DURESSD_LIB_ONLY=1 sources this file for its functions without running the
# dispatch (used by the unit tests).
if [[ "${DURESSD_LIB_ONLY:-}" != 1 ]]; then
case "${1:-install}" in
    install)   cmd_install ;;
    uninstall) cmd_uninstall ;;
    status)    cmd_status ;;
    *)
        echo "Usage: $0 [install|uninstall|status]" >&2
        exit 1
        ;;
esac
fi
