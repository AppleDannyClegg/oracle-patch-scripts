#!/usr/bin/env bash
# Two functions exist twice: once in ohs-patch and once in dbclient-upgrade, and on main each pair is
# byte-identical. A change to one copy that leaves the other behind does not fix a duplication, it creates a
# divergence - the dbclient-upgrade waits and start loop stay silent while ohs-patch's say what they are doing.
# Both functions are checked, because the first version of this gate named only ports_answer and passed forever
# while start_all was silent.
set -eu
cd "$(dirname "$0")/.."
PAIRS=(start_all ports_answer)
rc=0
for fn in "${PAIRS[@]}"; do
  a=$(sed -n "/^$fn()/,/^}/p" patching/ohs-patch/ohs-patch.sh)
  b=$(sed -n "/^$fn()/,/^}/p" patching/dbclient-upgrade/dbclient-upgrade.sh)
  [ -n "$a" ] || { echo "FAIL: no $fn in ohs-patch.sh"; rc=1; continue; }
  [ -n "$b" ] || { echo "FAIL: no $fn in dbclient-upgrade.sh"; rc=1; continue; }
  if [ "$a" != "$b" ]; then
    echo "FAIL: the two $fn copies have drifted"
    diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed 's/^/  /'
    rc=1
  else
    echo "ok: both copies of $fn are byte-identical"
  fi
done
exit $rc
