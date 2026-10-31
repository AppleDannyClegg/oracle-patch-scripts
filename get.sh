#!/usr/bin/env bash
# get.sh - fetch the Oracle operations scripts (all 20 folders plus the shared lib/) onto this machine. No git needed, just curl or wget.
#
#   curl -fsSL https://raw.githubusercontent.com/AppleDannyClegg/oracle-patch-scripts/main/get.sh | bash
#
# Puts everything in ./oracle-patch-scripts (or the folder given as the first argument) and makes
# every script executable. Keep lib/ next to the script folders: all scripts except wls-patch, apex-patch,
# ords-patch and oracle-diag source ../lib/oracle-lib.sh. Run it again later to pick up the newest version; the previous copy is
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
[ -f "$DEST/lib/oracle-lib.sh" ] || { echo "lib/oracle-lib.sh missing from the download; the scripts will not run" >&2; exit 1; }
bash "$DEST/lib/oracle-lib.sh" selftest >/dev/null 2>&1 && echo "lib/oracle-lib.sh selftest ok" || echo "warning: lib/oracle-lib.sh selftest failed on this machine (bash 4+, GNU coreutils?)"
if [ -d "$DEST.old" ]; then
  for c in "$DEST.old"/*/*.conf; do
    [ -f "$c" ] || continue
    d="$DEST/$(basename "$(dirname "$c")")"
    [ -d "$d" ] && cp -p "$c" "$d/" && echo "kept your $(basename "$d")/$(basename "$c")"
  done
fi

echo
echo "done: $(cd "$DEST" && pwd)"
for d in "$DEST"/*/; do n="$(basename "$d")"; [ "$n" = lib ] && continue; [ -f "$d/$n.sh" ] || continue; printf '  %-18s %s\n' "$n" "$(sed -n '2p' "$d/$n.sh" | sed 's/^# *[a-z-]*\.sh - //' | cut -c1-95)"; done
echo "  lib/               shared library, needed by every script above (bash $DEST/lib/oracle-lib.sh selftest)"
echo
echo "next: read $DEST/README.md, then copy the whole tree to the server (the scripts need lib/ one level up), e.g."
echo "  scp -r $DEST oracle@server:~/   # or just one folder plus lib/: scp -r $DEST/lib $DEST/gg-ops oracle@server:~/scripts/"
