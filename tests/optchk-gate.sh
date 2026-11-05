#!/usr/bin/env bash
# Behavioural gate for option parsing: every value-taking option, taken from each script's own header documentation
# (independent of the case arms that implement it), is run as the LAST argument and again followed by --dry-run.
# Pass: the script exits within 5 s with "needs a value". Fail: it hangs (the old 'shift 2' spin), exits without the
# message, or (with --dry-run next) swallows the flag. Needs no database. Usage: tests/optchk-gate.sh [script...]
cd "$(dirname "$0")/.." || exit 1
scripts=("$@"); [ ${#scripts[@]} -gt 0 ] || scripts=(get.sh patching/*/*.sh operations/*/*.sh reports/*/*.sh)
# a 5 s deadline: GNU timeout where present (OL7/OL8), perl otherwise (macOS has perl, no timeout).
# timeout exits 124; perl's alarm is SIGALRM (142) or SIGKILL (137).
if command -v timeout >/dev/null 2>&1; then
  alarm() { local t="$1"; shift; timeout "$t" "$@"; }        # OL7/OL8: coreutils timeout, no perl
elif command -v gtimeout >/dev/null 2>&1; then
  alarm() { local t="$1"; shift; gtimeout "$t" "$@"; }       # macOS with coreutils installed
elif command -v perl >/dev/null 2>&1; then
  alarm() { local t="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$t" "$@"; }   # macOS default
else
  alarm() { shift; "$@"; }   # no deadline tool: run without one
fi
pass=0; fail=0; nopt=0
for s in "${scripts[@]}"; do
  # documented value options: "--opt VALUE" in the header comment (uppercase word, <...>, or N/DAYS style)
  opts="$(sed -n '2,80p' "$s" | grep -oE -- '--[a-z][a-z-]+ (<[^>]+>|[A-Z][A-Z0-9_|./-]*|[a-z0-9]+\|[a-z0-9|-]+)' | awk '{print $1}' | sort -u)"
  # scripts that take a command first: use the first read-only one their dispatcher names
  cmd=""; cmd="$(grep -oE '^\s*(inspect|list|status|show|report|overview|usage)[|)]' "$s" | head -1 | tr -d ' |)')"
  for o in $opts; do
    nopt=$((nopt+1))
    out="$(alarm 5 bash "$s" $cmd "$o" 2>&1)"; rc=$?
    if [ $rc = 124 ] || [ $rc = 142 ] || [ $rc = 137 ]; then echo "FAIL $s $o: hung"; fail=$((fail+1)); continue; fi
    printf '%s' "$out" | grep -q -- "$o needs a value" || { echo "FAIL $s $o (last arg): rc=$rc, no 'needs a value' (${out:0:100})"; fail=$((fail+1)); continue; }
    out="$(alarm 5 bash "$s" $cmd "$o" --dry-run 2>&1)"; printf '%s' "$out" | grep -q -- "needs a value, got '--dry-run'" || { echo "FAIL $s $o --dry-run: swallowed (${out:0:100})"; fail=$((fail+1)); continue; }
    pass=$((pass+1))
  done
done
echo "optchk gate: $pass passed, $fail failed, $nopt documented value options over ${#scripts[@]} scripts"
[ $fail = 0 ]
