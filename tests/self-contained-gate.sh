#!/usr/bin/env bash
# self-contained-gate.sh - the scripts README.md lists as NOT sourcing lib/oracle-lib.sh
# (wls-patch, apex-patch, ords-patch, ohs-patch, oracle-diag, patch-manifest) must DEFINE every lib-named function they call.
#
# Why: oracle-diag.sh :728 called lib's epoch_of and :278 called lib's err, but the script sources
# nothing and defines neither, so both were command-not-found - a silent, latent defect. A harness that
# sources the lib cannot see it (that vacuous harness is how the epoch_of call shipped, 3 Nov 2026).
#
# Detection: build the set of names CALLED in the script - command position (after ^ ; & | ( { }) in the
# quote/comment-stripped text, plus any name in $(...), since a naive quote strip eats "$(fn ". Then any
# lib function that is in that set but not defined locally is a finding.
# Run: bash tests/self-contained-gate.sh        (exit 0 clean, 1 findings)
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
LIB=lib/oracle-lib.sh
SCRIPTS=(
  patching/wls-patch/wls-patch.sh
  patching/apex-patch/apex-patch.sh
  patching/ords-patch/ords-patch.sh
  reports/oracle-diag/oracle-diag.sh
  patching/patch-manifest.sh
  patching/ohs-patch/ohs-patch.sh
  patching/dbclient-upgrade/dbclient-upgrade.sh
)

defs()  { grep -oE '^[a-zA-Z_][a-zA-Z0-9_]*\(\)' "$1" 2>/dev/null | tr -d '()' | sort -u; }
strip() { sed -e "s/'[^']*'//g" -e 's/"[^"]*"//g' -e 's/#.*$//' "$1" 2>/dev/null; }
# names the script calls: bare at command position (must be followed by space/EOL, so an assignment
# like 'local to; to=...' is not a call), or any name inside $(...)
called() {
  { strip "$1"; grep -oE '\$\([[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*' "$1"; } \
    | grep -oE '(^|[;&|(){}])[[:space:]]*[a-zA-Z_][a-zA-Z0-9_]*([[:space:]]|$)' \
    | grep -oE '[a-zA-Z_][a-zA-Z0-9_]*' | sort -u
}

libfns="$(defs "$LIB")"
fails=0
for s in "${SCRIPTS[@]}"; do
  [ -f "$s" ] || { echo "self-contained gate: missing $s" >&2; exit 2; }
  # predicate check: it must really not source the lib, or the rule does not apply to it
  grep -qE '^[[:space:]]*(source|\.)[[:space:]]+.*oracle-lib\.sh' "$s" && { echo "self-contained gate: $s DOES source $LIB - remove it from the list" >&2; exit 2; }
  localdefs="$(defs "$s")"; calls="$(
    called "$s"
  )"
  for fn in $libfns; do
    grep -qx "$fn" <<<"$localdefs" && continue
    if grep -qx "$fn" <<<"$calls"; then
      line="$(strip "$s" | grep -nE "(^|[;&|(){}])[[:space:]]*$fn([[:space:]]|$)" | head -1 | cut -d: -f1)"
      echo "FAIL $s: calls '$fn' (defined in $LIB, not in this self-contained script)${line:+ near line $line}"
      fails=$((fails+1))
    fi
  done
done

if [ "$fails" = 0 ]; then
  echo "self-contained gate: ${#SCRIPTS[@]}/${#SCRIPTS[@]} scripts clean - every lib-named call resolves locally"
  exit 0
fi
echo "self-contained gate: $fails lib-only call(s) in self-contained scripts - define it locally or use a self-contained equivalent"
exit 1