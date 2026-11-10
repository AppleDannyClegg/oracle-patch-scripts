#!/usr/bin/env bash
# Gate row for tests/false-success-gate.sh --selftest (T246): the selftest holds the success-line regex assertions
# (default_ok must CATCH every change claim and must NOT catch a sub-state), and since 8a4bb8c the covered_by map
# assertions as well. Until this row existed, tests/README.md:45 documented the command and no gate in
# tests/run-all.sh called it, so a regression in either set made nothing red on a full run.
#
# An exit code is NOT enough here: with an argument the gate does not understand, false-success-gate.sh:77 takes it
# as a script list, sweeps nothing, and prints '0 passed, 0 failed, 0 NOT-EXERCISED' rc=0 - a green that proves
# nothing (measured on d3a93f9 with '--selftesst'). So this row also requires the terminal 'selftest: passed' line
# and a floor of assertions actually RUN, which is what turns "the loop was deleted" into a red.
#
# The floors are PER SECTION, because the selftest is two independent sets and one total counts them as one
# (Puck [P2] on 728e1c3): delete the covered_by loop alone and a single total still sees the 22 regex lines and
# stays green - the half T246 was filed about gone, the row happy. Each set now has its own floor, so either
# loop can be removed and the row is red.
cd "$(dirname "$0")/.." || exit 1
# floors, not exact counts: the suite must fail when assertions STOP RUNNING, not when one is added.
# Measured at cd35ee3: 12 caught + 10 ignored = 22 regex, 3 covered_by (T212).
REGEX_FLOOR=20
COVERED_FLOOR=3
out="$(bash tests/false-success-gate.sh --selftest 2>&1)"; rc=$?
printf '%s\n' "$out"
re="$(printf '%s\n' "$out" | grep -cE '^ok   (caught|ignored)')"
cov="$(printf '%s\n' "$out" | grep -c '^ok   covered')"
bad="$(printf '%s\n' "$out" | grep -c '^FAIL')"
last="$(printf '%s\n' "$out" | tail -1)"
why=''
[ "$rc" = 0 ] || why="$why rc=$rc"
[ "$bad" = 0 ] || why="$why FAIL-lines=$bad"
[ "$re" -ge "$REGEX_FLOOR" ] || why="$why regex-assertions=$re(floor-$REGEX_FLOOR)"
[ "$cov" -ge "$COVERED_FLOOR" ] || why="$why covered-by-assertions=$cov(floor-$COVERED_FLOOR)"
printf '%s' "$last" | grep -q 'false-success gate selftest: passed' || why="$why no-passed-line(last='$last')"
if [ -z "$why" ]; then
  echo "false-success selftest: passed ($re regex + $cov covered_by assertions, 0 failed)"; exit 0
fi
echo "FAIL false-success selftest row:$why"
exit 1