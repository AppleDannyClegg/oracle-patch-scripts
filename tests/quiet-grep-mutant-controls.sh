#!/usr/bin/env bash
# quiet-grep-mutant-controls.sh - the equivalence gate's own power, measured on mutants.
#
# tests/quiet-grep-equivalence.sh compares an old grep command with the new form of it, and
# that comparison can only fail when some input makes the two disagree. A gate that passes
# cannot prove that about itself: a match-anything pattern was committed into a head and the
# gate called the site "same" on every input, because every input held the id the check looks
# for. This file is the control for that claim.
#
# Each mutant below puts ONE mutation into a scratch clone and runs the real gate,
# unmodified, through its normal --base/--head entry point. The target is resolved by TEXT
# and must match exactly once: a merge moves line numbers, and a control that cannot find
# its site proves nothing about the gate. A mutant counts as CAUGHT only when the gate exits
# non-zero AND fails on the site that was mutated, which is why the expected label is read
# out of the gate's own output instead of being written next to the mutation.
#
# The same-tree cases come first, because they are how run-all invokes both files once the
# change is merged: base and head are then the same commit. The gate must pass there (there
# is nothing to compare) and must still fail when the head holds an unconverted pipeline.
#
# Usage: tests/quiet-grep-mutant-controls.sh [--base REF] [--head REF] [--quiet]
#   --base defaults to the pre-conversion baseline, --head to HEAD.
#   exit 0 - the unmutated head was clean, both same-tree cases behaved, every mutant caught
#   exit 1 - any of those did not
#   exit 2 - bad usage, or the git refs could not be read
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
# THE BASELINE IS PINNED to the last tree before the conversion, and not origin/main. Once
# this branch is merged origin/main IS the converted form, so a mutant would be compared with
# a converted site instead of with the command the conversion replaced - the same fault as an
# empty fixture, one level up. The baseline only has to resolve in a full clone.
BASE_REF="eddc6d6"; HEAD_REF="HEAD"; QUIET=0
while [ $# -gt 0 ]; do
  case "$1" in
    --base) BASE_REF="$2"; shift 2;;
    --head) HEAD_REF="$2"; shift 2;;
    --quiet) QUIET=1; shift;;
    -h|--help) sed -n '2,28p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0;;
    *) echo "unknown option: $1" >&2; exit 2;;
  esac
done

WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
CLONE="$WORK/clone"
if ! git clone -q --no-hardlinks "$REPO" "$CLONE" 2>/dev/null; then
  echo "FAIL  cannot clone $REPO - the controls need a scratch clone" >&2; exit 1
fi
# THE MUTANTS ARE COMMITS, SO THE CLONE NEEDS AN IDENTITY. A fresh clone has no user.email, git refuses the
# commit, and every fixture then compares the unmutated head with itself: rc 0, count 0, reported as a MISS on
# the gate rather than as the harness fault it is. Local to the scratch clone, never global.
git -C "$CLONE" config user.email "mutant-controls@example.invalid"
git -C "$CLONE" config user.name  "mutant controls"
for r in "$BASE_REF" "$HEAD_REF"; do
  git -C "$CLONE" rev-parse --verify -q "$r^{commit}" >/dev/null || {
    echo "FAIL  $r is not in the clone" >&2; exit 1; }
done
# Resolve both refs to shas ONCE. A sha cannot move under the run; the same-tree controls
# below move refs/remotes/origin/main inside the clone on purpose.
BASE_SHA="$(git -C "$CLONE" rev-parse "$BASE_REF^{commit}")"
HEAD_SHA="$(git -C "$CLONE" rev-parse "$HEAD_REF^{commit}")"

# THE GATE THAT RUNS MUST BE THE HEAD UNDER TEST. A clone checks out the repo's default
# branch, so without this the baseline would run main's gate against the head's refs and
# report whatever main's copy says - a gate and a head from two different revisions.
git -C "$CLONE" checkout -q --detach "$HEAD_SHA"
GATE="$CLONE/tests/quiet-grep-equivalence.sh"

run_gate() { # $1 head ref, $2 base ref (default the resolved base) -> rc, output in $WORK/gate.out
  ( cd "$CLONE" && bash "$GATE" --base "${2:-$BASE_SHA}" --head "$1" ) > "$WORK/gate.out" 2>&1
  echo $?
}
run_default() { # the invocation run-all uses: no arguments at all
  ( cd "$CLONE" && bash "$GATE" ) > "$WORK/default.out" 2>&1
  echo $?
}
summary() { grep -E '^quiet-grep-equivalence:' "$WORK/gate.out" | tail -1; }
failed() { summary | sed -n 's/.* \([0-9][0-9]*\) failed.*/\1/p' | tail -1; }
OK=0; MISSES=0
passed() { OK=$((OK+1)); echo "   ok    $*"; }
miss()   { echo "   MISS  $*"; MISSES=$((MISSES+1)); }

# ------------------------------------------------------------------ the same-tree cases
# run-all invokes the registered file with no arguments once the change is merged, so the
# base is origin/main and the head is the checkout and they are the same commit.
same_tree() { git -C "$CLONE" update-ref refs/remotes/origin/main "$1"; }
same_tree "$HEAD_SHA"
rc="$(run_default)"
# The ok() line is printed only under --verbose, so the sentence is read from a second run
# with it. The rc above is the plain invocation, exactly as run-all makes it.
( cd "$CLONE" && bash "$GATE" --verbose ) > "$WORK/default-v.out" 2>&1
if [ "$rc" = 0 ] && grep -q 'are the same tree' "$WORK/default-v.out"; then
  passed "same-tree, clean: no arguments, refs equal -> rc 0 and the gate says the refs are the same tree"
  [ "$QUIET" = 0 ] && grep -E 'are the same tree|compared 0 grep' "$WORK/default.out" | sed 's/^/         /'
else
  miss "same-tree, clean: expected rc 0 naming the same tree, got rc $rc"
  tail -5 "$WORK/default.out" | sed 's/^/         /'
fi

# The twin, and the reason the case above is not a rubber stamp: the same invocation with an
# UNCONVERTED pipeline left in the head must fail. Without this control, "nothing to compare"
# and "nothing was checked" look identical from the outside.
git -C "$CLONE" checkout -q -B same-tree-dirty "$HEAD_SHA"
printf '%s\n' '' '# a pipeline left unconverted, as a mutation:' ': "${UNUSED:-}" || printf "%s\\n" "$UNUSED" | grep -q "x"' >> "$CLONE/patching/ohs-patch/ohs-patch.sh"
git -C "$CLONE" commit -qam "same-tree dirty control: an unconverted pipeline in the head"
DIRTY_SHA="$(git -C "$CLONE" rev-parse HEAD)"
same_tree "$DIRTY_SHA"
git -C "$CLONE" checkout -q --detach "$DIRTY_SHA"
rc="$(run_default)"
if [ "$rc" != 0 ] && grep -q 'not converted' "$WORK/default.out"; then
  passed "same-tree, dirty: no arguments, refs equal, one unconverted pipeline -> rc $rc naming it as not converted"
  [ "$QUIET" = 0 ] && grep -E 'left in the head|not converted' "$WORK/default.out" | head -2 | sed 's/^/         /'
else
  miss "same-tree, dirty: expected a failure naming the unconverted pipeline, got rc $rc"
  grep -E '^  (ok|FAIL)|unconverted' "$WORK/default.out" | tail -4 | sed 's/^/         /'
fi
same_tree "$BASE_SHA"
git -C "$CLONE" checkout -q --detach "$HEAD_SHA"
echo

# ------------------------------------------------------- the command-count fixtures
# Three defects were found in the completeness half of the gate after it had been cleared
# twice: a pipeline sharing its line with a here-string command was ACCEPTED on a successor,
# a here-string in a quoted pattern hid a real pipeline, and a line holding two commands was
# counted once. Each fixture is ONE line committed on top of the head with the converted head
# as the base, so what the gate prints for the head is the whole of the evidence - and the
# expected count is asserted, not just the exit code, because a count of zero is what the
# fault looked like from the outside.
fixture() { # $1 name, $2 line, $3 wanted rc, $4 wanted count
  local name="$1" line="$2" wrc="$3" wcount="$4" rc count
  git -C "$CLONE" checkout -q --detach "$HEAD_SHA"
  git -C "$CLONE" checkout -q -B "fixture-$name" "$HEAD_SHA"
  printf '%s\n' "$line" >> "$CLONE/patching/wls-patch/wls-patch.sh"
  if ! git -C "$CLONE" commit -qam "fixture: $name" 2>"$WORK/commit.err"; then
    miss "fixture $name: the mutant could not be committed, so nothing was mutated: $(head -1 "$WORK/commit.err")"
    return
  fi
  if [ "$(git -C "$CLONE" rev-parse HEAD)" = "$HEAD_SHA" ]; then
    miss "fixture $name: the commit left HEAD at $HEAD_SHA - the gate would compare the head with itself"
    return
  fi
  same_tree "$HEAD_SHA"
  rc="$(run_default)"
  count="$(grep -oE '[0-9]+ pipeline grep -q command\(s\) left in the head' "$WORK/default.out" | head -1 | grep -oE '^[0-9]+')"
  [ -n "$count" ] || count="$(grep -oE 'plus [0-9]+ pipeline grep -q left in the head' "$WORK/default.out" | head -1 | grep -oE '[0-9]+')"
  if [ "$rc" = "$wrc" ] && [ "${count:-x}" = "$wcount" ]; then
    passed "fixture $name: rc $rc and $count pipeline grep -q, exactly as the class says"
  else
    miss "fixture $name: rc $rc and count ${count:-?}, wanted rc $wrc and count $wcount"
    grep -E 'left in the head|not converted' "$WORK/default.out" | head -3 | sed 's/^/         /'
  fi
}
fixture 'a-pipeline-alone' 'if printf "%s\n" "$x" | grep -q needle; then :; fi' 1 1
fixture 'pipeline-plus-here-string' 'if printf "%s\n" "$x" | grep -q needle; then :; fi; grep -q needle <<<"$y"' 1 1
fixture 'two-pipelines-one-line' 'if printf "%s\n" "$x" | grep -q a && printf "%s\n" "$y" | grep -q b; then :; fi' 1 2
fixture 'pattern-holds-a-here-string' 'if printf "%s\n" "$x" | grep -q '"'"'<<<'"'"'; then :; fi' 1 1
# TWO REAL LINES, one each way, because they are the shapes a hand-written rule gets wrong. The
# first is patching/db-patch/db-patch.sh:255 on the pre-conversion tree: its pipeline is inside
# a quoted command substitution, which IS executed, so it is in the class. The second is
# patching/wls-patch/wls-patch.sh:1367: the bar before that grep is the second half of an OR.
fixture 'pipeline-inside-a-quoted-substitution' 'x="$(printf "%s\n" "$INSTALLED" | grep -q "^$(basename "$p");" && echo yes)"' 1 1
fixture 'an-or-not-a-pipeline' '{ [ -n "${MOS_USER:-}" ] || grep -qs '"'"'updates.oracle.com'"'"' "$HOME/.netrc"; } && :' 0 0

# ------------------------------------------------------------------ the unmutated head
rc="$(run_gate "$HEAD_REF")"
base_failed="$(failed)"
echo "== unmutated head $HEAD_REF =="
echo "   rc $rc  $(summary)"
if [ "$rc" != 0 ] || [ "${base_failed:-x}" != 0 ]; then
  echo "FAIL  the unmutated head is not clean, so a mutant verdict below proves nothing"
  [ "$QUIET" = 0 ] && grep -E '^FAIL' "$WORK/gate.out" | head -5 | sed 's/^/      /'
  exit 1
fi
passed "the gate passes the honest head - a failure below is the mutation, not the refs"
echo

# ------------------------------------------------------------------------------ the mutants
# tag <TAB> file <TAB> the text to replace (must occur EXACTLY ONCE in the file) <TAB> its
# replacement. THE SEPARATOR IS A TAB because the text being replaced contains pipes, and a
# pipe separator silently cut two of these controls down to a fragment that matched nothing.
MUTANTS=(
  "match-anything-1169	patching/wls-patch/wls-patch.sh	grep \"^\$id;\" >/dev/null; then log \"inventory has \$id\"	grep \".*\" >/dev/null; then log \"inventory has \$id\""
  "match-anything-1246	patching/wls-patch/wls-patch.sh	\"\$inv\" | grep \"^\$id;\"	\"\$inv\" | grep \".*\""
  "redirect-only-1169	patching/wls-patch/wls-patch.sh	| grep \"^\$id;\" >/dev/null; then log \"inventory has \$id\"	| grep \"^\$id;\"; then log \"inventory has \$id\""
  "wrong-pattern-1371	patching/wls-patch/wls-patch.sh	grep -s 'updates.oracle.com'	grep -s 'example.invalid'"
)

caught=0; missed=0
for m in "${MUTANTS[@]}"; do
  IFS=$'\t' read -r tag file old new <<<"$m"
  git -C "$CLONE" checkout -q -B "mutant-$tag" "$HEAD_SHA" || { miss "$tag: cannot branch"; missed=$((missed+1)); continue; }
  if ! found="$(python3 - "$CLONE/$file" "$old" "$new" <<'PY'
import sys
p, old, new = sys.argv[1], sys.argv[2], sys.argv[3]
lines = open(p).read().split("\n")
hits = [i for i, l in enumerate(lines) if old in l]
if len(hits) != 1:
    sys.exit("%s: %d lines hold %r - the control needs exactly one" % (p, len(hits), old))
i = hits[0]
lines[i] = lines[i].replace(old, new, 1)
open(p, "w").write("\n".join(lines))
print(i + 1)
PY
  )"; then
    miss "$tag: the mutation did not apply ($found) - a control that changed nothing proves nothing"
    missed=$((missed+1)); continue
  fi
  git -C "$CLONE" commit -qam "mutant: $tag"
  rc="$(run_gate "mutant-$tag")"
  # The label is read from the gate's own output: the file and the HEAD-side line that was
  # mutated. A label written beside the mutation cannot notice that the gate graded another
  # line, or that a merge moved the site.
  hit="$(grep -cE "^FAIL  $file:.*->$found#" "$WORK/gate.out")"
  if [ "$rc" != 0 ] && [ "$hit" -ge 1 ]; then
    echo "   CAUGHT   $file:$found (${tag})"
    grep -E "^FAIL  $file:" "$WORK/gate.out" | head -2 | sed 's/^/            /'
    caught=$((caught+1))
  else
    miss "$tag: the gate reported the mutated site as unchanged (rc $rc, $hit FAILs on $file line $found)"
    grep '^FAIL' "$WORK/gate.out" | head -3 | sed 's/^/         /'
    missed=$((missed+1))
  fi
done

echo
if [ "$missed" = 0 ]; then
  echo "quiet-grep-mutant-controls: $OK same-tree/control case(s) and $caught of $((caught+missed)) mutants caught"
else
  echo "quiet-grep-mutant-controls: $MISSES miss(es) - the gate does not have the power claimed for it"
fi
[ "$missed" = 0 ] || exit 1
