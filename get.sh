#!/usr/bin/env bash
# get.sh - fetch the Oracle patching scripts onto this machine. No git needed, just curl or wget.
#
#   curl -fsSL https://raw.githubusercontent.com/AppleDannyClegg/oracle-patch-scripts/main/get.sh | bash
#
# Puts everything in ./oracle-patch-scripts (or the folder given as the first argument) and makes
# the scripts executable. Run it again later to pick up the newest version; the previous copy is
# kept as <folder>.old. Your own *.conf files are carried across.

set -euo pipefail
REPO="AppleDannyClegg/oracle-patch-scripts"
URL="https://github.com/$REPO/archive/refs/heads/main.tar.gz"
DEST="${1:-oracle-patch-scripts}"

fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$URL"
  elif command -v wget >/dev/null 2>&1; then wget -qO- "$URL"
  else echo "need curl or wget" >&2; exit 1; fi
}

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "downloading $URL"
fetch | tar -xzf - -C "$tmp"
src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d | head -1)"
[ -d "$src" ] || { echo "download did not contain a folder" >&2; exit 1; }

if [ -d "$DEST" ]; then
  rm -rf "$DEST.old"
  mv "$DEST" "$DEST.old"
  echo "previous copy moved to $DEST.old"
fi
mv "$src" "$DEST"
chmod +x "$DEST"/*/*.sh; [ -f "$DEST/get.sh" ] && chmod +x "$DEST/get.sh"
if [ -d "$DEST.old" ]; then
  for c in "$DEST.old"/*/*.conf; do
    [ -f "$c" ] || continue
    d="$DEST/$(basename "$(dirname "$c")")"
    [ -d "$d" ] && cp -p "$c" "$d/" && echo "kept your $(basename "$d")/$(basename "$c")"
  done
fi

echo
echo "done: $(cd "$DEST" && pwd)"
for d in "$DEST"/*/; do printf '  %s\n' "$(basename "$d")"; done
echo
echo "next: read $DEST/README.md, then copy the folder you need to the server, e.g."
echo "  scp -r $DEST/wls-patch oracle@server:~/"
