#!/usr/bin/env bash
# check-parse.sh - regression gate for the option parser.
#
# Every parse_opts arm that consumes a value ("shift 2") must call optchk "$@" first. Without it, the
# option as the last argument fails "shift 2", the while loop reads the same word again and spins
# forever; and "--opt --flag" swallows the flag as the option's value. A fix for this landed across
# every script once and still missed 8 options, which is why this gate exists: it fails loudly when an
# arm is added or edited without the guard.
#
# It enumerates from the option LABELS and the structural "shift 2", never from the assignment shapes
# (VAR="$2" vs VAR="${2#@}" vs APPS+=("$2")), because those are the part that varies and the part the
# broken patch matched on.
#
# Usage: tests/check-parse.sh [repo-root]

set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
bad=0; arms=0; guarded=0

for f in "$ROOT"/patching/*/*.sh "$ROOT"/operations/*/*.sh "$ROOT"/reports/*/*.sh; do
  [ -f "$f" ] || continue
  # the parse_opts function body only
  body="$(awk '/^parse_opts\(\)/{p=1} p{print} p && /^}/{exit}' "$f")"
  [ -n "$body" ] || continue
  # split on the case terminator ";;" (multi-line arms get joined); drop the leading "case ... in" frame
  while IFS= read -r arm; do
    case "$arm" in *"shift 2"*) ;; *) continue;; esac
    arms=$((arms + 1))
    if printf '%s' "$arm" | grep -q 'optchk'; then
      guarded=$((guarded + 1))
    else
      bad=$((bad + 1))
      echo "MISSING optchk: ${f#"$ROOT"/} :: $(printf '%s' "$arm" | tr -s '[:space:]' ' ' | cut -c1-120)"
    fi
  done < <(printf '%s\n' "$body" | awk 'BEGIN{RS=";;"} {gsub(/\n/," "); if (length($0)) print}')
done

echo "parse gate: $guarded/$arms value arms call optchk"
[ "$bad" = 0 ]
