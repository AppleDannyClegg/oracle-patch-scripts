#!/usr/bin/env bash
# quiet-grep-mutant-controls.sh - the equivalence gate's own power, measured on mutants.
#
# The gate compares the old command with the new one, and that comparison can only fail
# when some input makes the two disagree. A gate that passes cannot prove that about
# itself. Vesper #49787 committed a match-anything pattern at wls-patch.sh:1165 and the
# gate reported 355 passed, 0 failed, 18 gaps: the mutant was in the head it compared,
# and it called the site "same" on all three inputs.
#
# So each control below puts ONE mutation into a scratch clone and runs the real gate
# (tests/quiet-grep-equivalence.sh, unmodified, through its normal --base/--head entry
# point) against it. A control PASSES only when the gate FAILS on it and names the site.
# The unmutated head runs first: if that is not clean, a failure on a mutant means
# nothing.
#
# Usage: tests/quiet-grep-mutant-controls.sh [--base REF] [--head REF] [--quiet]
#   exit 0 - every mutant was caught and the unmutated head was clean
#   exit 1 - at least one mutant was missed, or the unmutated head was not clean
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
BASE_REF="eddc6d6"; HEAD_REF="HEAD"; QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_REF="$2"; shift 2;;
    --head) HEAD_REF="$2"; shift 2;;
    --quiet) QUIET=1; shift;;
    -h|--help) sed -n '2,22p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CLONE="$WORK/clone"
if ! git clone -q --no-hardlinks "$REPO" "$CLONE" 2>/dev/null; then
  echo "FAIL  cannot clone $REPO - the controls need a scratch clone" >&2; exit 1
fi
# The clone carries the source's refs; a local branch name resolves what a sha would too.
for r in "$BASE_REF" "$HEAD_REF"; do
  git -C "$CLONE" rev-parse --verify -q "$r^{commit}" >/dev/null || {
    echo "FAIL  $r is not in the clone" >&2; exit 1; }
done
HEAD_SHA="$(git -C "$CLONE" rev-parse "$HEAD_REF^{commit}")"

# The GATE THAT RUNS MUST BE THE HEAD UNDER TEST. A clone checks out the repo's default
# branch, so without this the baseline would run main's gate against the head's refs and
# report whatever main's copy says - a gate and a head from two different revisions.
git -C "$CLONE" checkout -q --detach "$HEAD_SHA"
GATE="$CLONE/tests/quiet-grep-equivalence.sh"
run_gate() { # $1 head ref -> writes the gate output to $WORK/gate.out, echoes its rc
  ( cd "$CLONE" && bash "$GATE" --base "$BASE_REF" --head "$1" ) > "$WORK/gate.out" 2>&1
  echo $?
}
summary() { grep -E '^quiet-grep-equivalence:' "$WORK/gate.out" | tail -1; }
failed() { summary | sed -n 's/.* \([0-9][0-9]*\) failed.*/\1/p' | tail -1; }

# ------------------------------------------------------------------ the control's own control
rc="$(run_gate "$HEAD_REF")"
base_failed="$(failed)"
echo "== unmutated head $HEAD_REF =="
echo "   rc $rc  $(summary)"
if [ "$rc" != 0 ] || [ "${base_failed:-x}" != 0 ]; then
  echo "FAIL  the unmutated head is not clean, so a mutant verdict below proves nothing"
  [ "$QUIET" = 0 ] && grep -E '^FAIL' "$WORK/gate.out" | head -5 | sed 's/^/      /'
  exit 1
fi
echo "   ok   the gate passes the honest head - a failure below is the mutation, not the refs"
echo

# ------------------------------------------------------------------------------ the mutants
# tag | file | line | text to replace (must occur exactly once on that line) | replacement | the label the gate must fail on
MUTANTS=(
  "match-anything-1165|patching/wls-patch/wls-patch.sh|1165|grep \"^\$id;\"|grep \".*\"|patching/wls-patch/wls-patch.sh:1165->1165#1"
  "match-anything-1242|patching/wls-patch/wls-patch.sh|1242|grep \"^\$id;\"|grep \".*\"|patching/wls-patch/wls-patch.sh:1242->1242#1"
  "redirect-only-1165|patching/wls-patch/wls-patch.sh|1165|grep \"^\$id;\" >/dev/null|grep \"^\$id;\"|patching/wls-patch/wls-patch.sh:1165->1165#1"
  "wrong-pattern-1367|patching/wls-patch/wls-patch.sh|1367|grep -s 'updates.oracle.com'|grep -s 'example.invalid'|patching/wls-patch/wls-patch.sh:1367->1367#1"
)

caught=0; missed=0
for m in "${MUTANTS[@]}"; do
  IFS='|' read -r tag file line old new label <<<"$m"
  git -C "$CLONE" checkout -q -B "mutant-$tag" "$HEAD_SHA" || { echo "FAIL  cannot branch for $tag"; missed=$((missed+1)); continue; }
  if ! python3 - "$CLONE/$file" "$line" "$old" "$new" <<'PY'
import sys
p, ln, old, new = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
lines = open(p).read().split("\n")
if old not in lines[ln-1]:
    sys.exit(f"{p}:{ln} does not hold {old!r}")
lines[ln-1] = lines[ln-1].replace(old, new, 1)
open(p, "w").write("\n".join(lines))
PY
  then
    echo "FAIL  $tag: the mutation did not apply - a control that changed nothing proves nothing"
    missed=$((missed+1)); continue
  fi
  git -C "$CLONE" commit -qam "mutant: $tag"
  rc="$(run_gate "mutant-$tag")"
  hit="$(grep -c "^FAIL  .*$label" "$WORK/gate.out")"
  if [ "$QUIET" = 0 ]; then
    echo "== mutant $tag =="
    echo "   $(git -C "$CLONE" show --format= --unified=0 HEAD -- "$file" | sed -n '3p' | cut -c1-140)"
    echo "   rc $rc  $(summary)"
  fi
  if [ "$rc" != 0 ] && [ "$hit" -ge 1 ]; then
    echo "   CAUGHT   $label"
    caught=$((caught+1))
  else
    echo "   MISSED   $tag: the gate reported the mutant site as unchanged (rc $rc, $hit FAILs on $label)"
    missed=$((missed+1))
    grep "^FAIL" "$WORK/gate.out" | head -3 | sed 's/^/      /'
  fi
done

echo
echo "quiet-grep-mutant-controls: $caught of $((caught+missed)) mutants caught"
[ "$missed" = 0 ] || exit 1
