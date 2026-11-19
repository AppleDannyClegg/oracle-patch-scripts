#!/usr/bin/env bash
# shellcheck disable=SC2034
# run-latest-link.sh - a run dir handed over from outside RUN_BASE leaves runs/latest alone, quietly (T2294).
#
# wls-quarter passes <quarter run>/wls and <quarter run>/java as --run-dir. On a fresh OUTPUT_DIR the child's own
# RUN_BASE (<output>/wls-patch/runs, <output>/java-patch/runs) did not exist, so the link had no directory to go in:
# wls-patch printed "ln: failed to create symbolic link '.../runs/latest': No such file or directory" at every step,
# and every java-patch step warned "could not point .../runs/latest at this run". The same run also showed a PLAN
# title taken from a README sentence citing ANOTHER patch ("... can be downloaded using Patch 28186730 from").
# runs/latest means the tool's own last run (latest_run_dir, reuse_or_init and the 'latest' command read it), and the
# quarter passes the same --run-dir to every later step, so the link is not moved into the quarter's tree (Loki #29427).
#
# Sources the real scripts (less their trailing main call) in a copy of the tree, as run-dir-log.sh does.
# Usage: tests/run-latest-link.sh [repo-root]
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
T="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/rll.XXXXXX")" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

mkdir -p "$T/lib" "$T/patching/wls-patch" "$T/patching/java-patch"; cp "$ROOT/lib/oracle-lib.sh" "$T/lib/"
sed '$d' "$ROOT/patching/wls-patch/wls-patch.sh" >"$T/patching/wls-patch/wls-patch.sh"
sed '$d' "$ROOT/patching/java-patch/java-patch.sh" >"$T/patching/java-patch/java-patch.sh"

# link <script> <outside|own>: init_run_dir on a fresh OUTPUT_DIR (no RUN_BASE yet) with a run dir handed over from
# the quarter's tree, or one of the tool's own; prints the link's target (or NO LINK), then any stderr line naming it
link() {
  local s="$1" how="$2" out="$T/out-$1-$2"
  (
    export ORACLE_OUTPUT_DIR="$out"
    # shellcheck disable=SC1090
    . "$T/patching/$s/$s.sh" >/dev/null 2>&1
    RUN_BASE="$out/$s/runs"
    if [ "$how" = outside ]; then RUN_DIR="$out/wls-quarter/runs/q1/x"; mkdir -p "$RUN_DIR"; else RUN_DIR=""; fi
    init_run_dir test 2>"$T/err-$s" >/dev/null
    readlink "$RUN_BASE/latest" || echo "NO LINK"
    grep -E 'latest' "$T/err-$s" || true
  )
}

for s in wls-patch java-patch; do
  o="$(link "$s" outside)"
  [ "$(printf '%s\n' "$o" | head -1)" = "NO LINK" ] && ok || bad "$s: a handed-over run dir moved runs/latest to: $(printf '%s\n' "$o" | head -1)"
  [ "$(printf '%s\n' "$o" | sed -n 2p)" = "" ] && ok || bad "$s: init_run_dir complained about latest: $(printf '%s\n' "$o" | sed -n 2p)"
  o="$(link "$s" own)"
  case "$(printf '%s\n' "$o" | head -1)" in "$T/out-$s-own/$s/runs/"*-test) ok;; *) bad "$s: the tool's own run should still be runs/latest, got: $(printf '%s\n' "$o" | head -1)";; esac
done

# edge <script> <case> <RUN_BASE> <RUN_DIR> <want: LINK|NO LINK>: the "strictly inside RUN_BASE" boundaries (Loki #29433)
edge() {
  local s="$1" c="$2" base="$3" dir="$4" want="$5" got
  got="$(
    export ORACLE_OUTPUT_DIR="$T/edge"
    # shellcheck disable=SC1090
    . "$T/patching/$s/$s.sh" >/dev/null 2>&1
    mkdir -p "${base%/}" "$dir" 2>/dev/null; rm -f "${base%/}/latest"; RUN_BASE="$base"; RUN_DIR="$dir"
    ( cd "$T/edge" && init_run_dir test >/dev/null 2>&1 )
    if [ -L "${base%/}/latest" ]; then echo LINK; else echo "NO LINK"; fi
  )"
  [ "$got" = "$want" ] && ok || bad "$s $c: want $want, got $got"
}
for s in wls-patch java-patch; do
  B="$T/edge/$s/runs"; mkdir -p "$T/edge"
  edge "$s" "inside, base with a trailing slash" "$B/" "$B/r1" LINK
  edge "$s" "inside, run dir with a trailing slash" "$B" "$B/r2/" LINK
  edge "$s" "run dir IS the base" "$B" "$B" "NO LINK"
  edge "$s" "sibling sharing the prefix" "$B" "$B-archive/r3" "NO LINK"
  edge "$s" "relative run dir is never inside" "$B" "rel/r4" "NO LINK"
done

# the note is in the run's log, with the --run-dir to pass, and not on the console
for s in wls-patch java-patch; do
  lf="$(find "$T/out-$s-outside/wls-quarter/runs/q1/x" -name '*.log' | head -1)"
  grep -q -- "--run-dir $T/out-$s-outside/wls-quarter/runs/q1/x" "$lf" 2>/dev/null && ok || bad "$s: the run's log should carry the --run-dir to pass (log: ${lf:-none})"
done

# patch_description: the README line naming this patch, never a sentence citing another patch
desc() {
  ( . "$T/patching/wls-patch/wls-patch.sh" >/dev/null 2>&1; patch_description "$1" )
}
P="$T/pd/38063775"; mkdir -p "$P"
printf 'The latest OPatch version can be downloaded using Patch 28186730 from My Oracle Support.\nOracle WebLogic Server 14.1.2.0.0 Patch 38063775 README\n' >"$P/README.txt"
[ "$(desc "$P")" = "Oracle WebLogic Server 14.1.2.0.0 Patch 38063775 README" ] && ok || bad "description should be the line naming 38063775, got: $(desc "$P")"
printf 'The latest OPatch version can be downloaded using Patch 28186730 from My Oracle Support.\n' >"$P/README.txt"
[ "$(desc "$P")" = "" ] && ok || bad "a README naming only another patch should give no title, got: $(desc "$P")"
printf 'WLS PATCH SET UPDATE 14.1.2.0.261112\nsee Patch 28186730 for OPatch\n' >"$P/README.txt"
[ "$(desc "$P")" = "WLS PATCH SET UPDATE 14.1.2.0.261112" ] && ok || bad "a PSU title line should still be the title, got: $(desc "$P")"
printf 'Oracle WebLogic Server 14.1.2.0.0 Patch 38063775 README\n\nDownload patch 38063775 from My Oracle Support.\n' >"$P/README.txt"
[ "$(desc "$P")" = "Oracle WebLogic Server 14.1.2.0.0 Patch 38063775 README" ] && ok || bad "the title line should win over a prose line naming the id, got: $(desc "$P")"
printf '\n  Notes\nDownload patch 38063775 from My Oracle Support.\n' >"$P/README.txt"
[ "$(desc "$P")" = "Download patch 38063775 from My Oracle Support." ] && ok || bad "with no title naming the id, the first line naming it is next, got: $(desc "$P")"
printf 'see Patch 138063775 for the overlay\n' >"$P/README.txt"
[ "$(desc "$P")" = "" ] && ok || bad "38063775 inside a longer number is not this patch's id, got: $(desc "$P")"

echo "run-latest-link: $pass passed, $fail failed"
[ "$fail" = 0 ]
