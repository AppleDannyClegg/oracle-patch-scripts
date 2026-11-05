#!/usr/bin/env bash
# get.sh - fetch the Oracle operations scripts (patching/, operations/, reports/ plus the shared lib/) onto this machine. No git needed, just curl or wget.
#
#   curl -fsSL https://raw.githubusercontent.com/AppleDannyClegg/oracle-patch-scripts/main/get.sh | bash
#
# Puts everything in ./oracle-patch-scripts (or the folder given as the first argument) and makes
# every script executable. Keep lib/ at the top of the tree: all scripts except wls-patch, apex-patch, ords-patch and
# oracle-diag source ../../lib/oracle-lib.sh from their <type>/<script>/ folder. Run it again later to pick up the newest version; the previous copy is
# kept as <folder>.old. Your own *.conf files are carried across.

set -euo pipefail
REPO="AppleDannyClegg/oracle-patch-scripts"
DEST="${1:-oracle-patch-scripts}"; DEST="${DEST%/}"

# GitHub's branch archive (archive/refs/heads/main.tar.gz) is CDN-cached and can serve a copy from before
# your last push - so a run right after a push gets stale scripts. The per-commit archive is immutable, so
# resolve the branch's commit first; if the API is unreachable, fall back to the (possibly stale) branch archive.
resolve_url() {
  local api="https://api.github.com/repos/$REPO/commits/main" json sha
  if command -v curl >/dev/null 2>&1; then json="$(curl -fsSL "$api" 2>/dev/null || true)"
  elif command -v wget >/dev/null 2>&1; then json="$(wget -qO- "$api" 2>/dev/null || true)"; fi
  # take the FIRST "sha":"<40hex>" - a greedy sed would grab the last one (a parent's) on a minified response.
  # no 'head -1' consumer: it exits after one line, the producer takes SIGPIPE, and with set -e that aborts
  matches="$(printf '%s\n' "${json:-}" | grep -oE '"sha" *: *"[0-9a-f]{40}"' || true)"
  sha="$(cut -d'"' -f4 <<<"${matches%%$'\n'*}")"
  if [ -n "$sha" ]; then printf 'https://github.com/%s/archive/%s.tar.gz\n' "$REPO" "$sha"
  else printf 'https://github.com/%s/archive/refs/heads/main.tar.gz\n' "$REPO"; fi
}
URL="$(resolve_url)"

fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL "$URL"
  elif command -v wget >/dev/null 2>&1; then wget -qO- "$URL"
  else echo "need curl or wget" >&2; exit 1; fi
}

# the parent must be writable BEFORE the download and before the previous copy is moved aside, or a typo in the target leaves only <folder>.old
parent="$(dirname "$DEST")"; mkdir -p "$parent" 2>/dev/null || true
[ -d "$parent" ] && [ -w "$parent" ] || { echo "cannot write to $parent" >&2; exit 1; }
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
echo "downloading $URL"
fetch | tar -xzf - -C "$tmp"
src="$(find "$tmp" -mindepth 1 -maxdepth 1 -type d -print -quit)"
[ -d "$src" ] || { echo "download did not contain a folder" >&2; exit 1; }

moved=0
if [ -d "$DEST" ]; then
  if [ -d "$DEST.old" ]; then
    # never rm a previous copy that holds downloaded patches: get-patches' default output is ./patches-<host>,
    # inside this tree. Keep it aside and say so instead of deleting multi-GB zips. Which names count is
    # lib/file-patterns 'staged' in the tree just downloaded - the same file get.ps1 and java-patch read.
    patterns="$src/lib/file-patterns"
    [ -f "$patterns" ] || { echo "$patterns missing from the download" >&2; exit 1; }
    staged_args=(); staged_first=1
    while IFS= read -r line; do
      case "$line" in ''|'#'*) continue;; esac
      case "$line" in
        staged:*) read -ra globs <<<"${line#*:}"
                  for g in "${globs[@]}"; do
                    [ "$staged_first" = 1 ] || staged_args+=( -o )
                    staged_args+=( -name "$g" ); staged_first=0
                  done;;
      esac
    done <"$patterns"
    [ "${#staged_args[@]}" -gt 0 ] || { echo "no 'staged:' globs in $patterns" >&2; exit 1; }
    if [ -n "$(find "$DEST.old" \( "${staged_args[@]}" \) -print -quit 2>/dev/null)" ]; then
      aside="$DEST.old-$(date +%Y%m%d%H%M%S)"
      mv "$DEST.old" "$aside"
      echo "kept the previous copy as $aside (it holds downloaded patches) - delete it when you are done, or keep patch downloads outside this folder"
    else
      rm -rf "$DEST.old"
    fi
  fi
  mv "$DEST" "$DEST.old"
  echo "previous copy moved to $DEST.old"; moved=1
fi
mv "$src" "$DEST"
find "$DEST" -name '*.sh' -type f -exec chmod +x {} +
[ -f "$DEST/lib/oracle-lib.sh" ] || { echo "lib/oracle-lib.sh missing from the download; the scripts will not run" >&2; exit 1; }
bash "$DEST/lib/oracle-lib.sh" selftest >/dev/null 2>&1 && echo "lib/oracle-lib.sh selftest ok" || echo "warning: lib/oracle-lib.sh selftest failed on this machine (bash 4+, GNU coreutils?)"
if [ "$moved" = 1 ]; then   # only the copy just moved aside, not a stale .old from an interrupted run
  for c in "$DEST.old"/*/*/*.conf "$DEST.old"/*/*.conf "$DEST.old"/oracle.conf; do
    [ -f "$c" ] || continue
    n="$(basename "$(dirname "$c")")"; d="$(find "$DEST" -mindepth 2 -maxdepth 2 -type d -name "$n" -print -quit 2>/dev/null)"; [ "$n" = "$(basename "$DEST.old")" ] && d="$DEST"
    [ -d "${d:-/nonexistent}" ] && cp -p "$c" "$d/" && echo "kept your ${d#"$DEST"/}/$(basename "$c")"
  done
fi

echo
echo "done: $(cd "$DEST" && pwd)"
for t in patching operations reports; do echo "  $t/"; for d in "$DEST/$t"/*/; do n="$(basename "$d")"; [ -f "$d/$n.sh" ] || continue; printf '    %-18s %s\n' "$n" "$(sed -n '2p' "$d/$n.sh" | sed 's/^# *[a-z-]*\.sh - //' | cut -c1-95)"; done; done
echo "  lib/                 shared library, needed by every script above (bash $DEST/lib/oracle-lib.sh selftest)"
echo
echo "next: read $DEST/README.md, then copy the whole tree to the server (a script needs lib/ two levels up), e.g."
echo "  scp -r $DEST oracle@server:~/"
