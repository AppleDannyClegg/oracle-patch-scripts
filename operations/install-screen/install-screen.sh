#!/bin/bash
# install-screen.sh - install GNU screen on a server with no internet, from RPMs fetched on a laptop.
#
# The RPMs come from Get-ScreenRpm.ps1 (same folder), run on a Windows laptop with internet:
#   powershell -ExecutionPolicy Bypass -File .\Get-ScreenRpm.ps1 -EL 9
#   scp -r .\screen-el9 oracle@server:/tmp/
# Then on the server:
#   sudo bash install-screen.sh /tmp/screen-el9            install
#   bash install-screen.sh --dry-run /tmp/screen-el9       check the RPMs fit this server, change nothing
#
# Only the local files are used; no repo is contacted. x86_64, EL7 or EL9 (Oracle Linux, RHEL and rebuilds).
# libutempter is installed only when it is missing. --nosignature is used because the EPEL signing key is
# usually not imported on an offline server; Get-ScreenRpm.ps1 checks each file against its repo checksum.
set -euo pipefail

dry=0
if [ "${1:-}" = --dry-run ]; then dry=1; shift; fi
dir="${1:-}"
[ -n "$dir" ] || { echo "usage: install-screen.sh [--dry-run] <folder with the .rpm files>" >&2; exit 2; }
[ -d "$dir" ] || { echo "install-screen: $dir is not a folder" >&2; exit 2; }

if command -v screen >/dev/null 2>&1; then
    echo "screen is already installed: $(screen --version 2>&1 | head -1)"
    exit 0
fi

arch="$(uname -m)"
el="$(rpm -E '%{rhel}')"
echo "server: EL$el, $arch"
[ "$arch" = x86_64 ] || { echo "install-screen: the RPMs are x86_64; this server is $arch" >&2; exit 1; }
case "$el" in
    '' | *[!0-9]*) echo "install-screen: could not read the EL version (rpm -E '%{rhel}' gave '$el')" >&2; exit 1 ;;
esac

shopt -s nullglob
screen_rpms=("$dir"/screen-[0-9]*.el"$el"*.x86_64.rpm)
[ "${#screen_rpms[@]}" -eq 1 ] || {
    echo "install-screen: want exactly one screen RPM for el$el in $dir, found ${#screen_rpms[@]} (downloaded for the wrong version?)" >&2
    exit 1
}
pkgs=("${screen_rpms[0]}")

if rpm -q libutempter >/dev/null 2>&1; then
    echo "libutempter already installed: $(rpm -q libutempter)"
else
    ut=("$dir"/libutempter-[0-9]*.el"$el"*.x86_64.rpm)
    [ "${#ut[@]}" -eq 1 ] || { echo "install-screen: libutempter is not installed and $dir has no el$el RPM for it" >&2; exit 1; }
    pkgs=("${ut[0]}" "${pkgs[@]}")
fi

echo "checking (no changes): ${pkgs[*]}"
rpm -Uvh --test --nosignature "${pkgs[@]}"
if [ "$dry" = 1 ]; then
    echo "dry run: the RPMs fit this server; nothing installed"
    exit 0
fi

rpm -Uvh --nosignature "${pkgs[@]}"
command -v screen >/dev/null 2>&1 || { echo "install-screen: rpm finished but screen is not on PATH" >&2; exit 1; }
screen --version
