#!/bin/bash
# Bootstrap one-liner installer for duressd.
# Downloads the latest source from GitHub and runs install.sh.
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/twhalley/Duressd/main/get.sh | sudo bash
#   wget -qO- https://raw.githubusercontent.com/twhalley/Duressd/main/get.sh  | sudo bash
set -euo pipefail

REPO="twhalley/Duressd"
BRANCH="main"
ARCHIVE="https://github.com/${REPO}/archive/refs/heads/${BRANCH}.tar.gz"

# ── colours (pipe-safe) ───────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$'\033[1;31m' GRN=$'\033[1;32m' YLW=$'\033[1;33m'
    CYN=$'\033[1;36m' BLD=$'\033[1m'    RST=$'\033[0m'
else
    RED='' GRN='' YLW='' CYN='' BLD='' RST=''
fi

step() { echo -e "${CYN}  →  $*${RST}"; }
good() { echo -e "${GRN}  ✔  $*${RST}"; }
bad()  { echo -e "${RED}  ✘  $*${RST}" >&2; exit 1; }

[[ $EUID -eq 0 ]] || bad "Must be run as root.  Re-run:  curl ... | sudo bash"

work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT

# ── download ──────────────────────────────────────────────────────────────────
step "Downloading duressd (${REPO}@${BRANCH})"
if command -v curl &>/dev/null; then
    curl -fsSL "$ARCHIVE" -o "$work_dir/src.tar.gz" \
        || bad "Download failed — check your internet connection"
elif command -v wget &>/dev/null; then
    wget -q "$ARCHIVE" -O "$work_dir/src.tar.gz" \
        || bad "Download failed — check your internet connection"
else
    bad "curl or wget is required but neither was found"
fi
good "Downloaded"

# ── extract ───────────────────────────────────────────────────────────────────
step "Extracting archive"
tar -xzf "$work_dir/src.tar.gz" -C "$work_dir"
src_dir=$(find "$work_dir" -maxdepth 1 -type d -name "Duressd-*" | head -1)
[[ -n "$src_dir" ]] || bad "Extraction failed — unexpected archive layout"
good "Extracted to $src_dir"

# ── install ───────────────────────────────────────────────────────────────────
echo
bash "$src_dir/install.sh" install
