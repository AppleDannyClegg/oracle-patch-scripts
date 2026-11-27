set -e
# The two ports_answer copies are the same function with the same job; a change to one that leaves the other
# behind makes the dbclient-upgrade waits silent while ohs-patch's are not, which is how [P2] happened.
a=$(sed -n '/^ports_answer()/,/^}/p' patching/ohs-patch/ohs-patch.sh)
b=$(sed -n '/^ports_answer()/,/^}/p' patching/dbclient-upgrade/dbclient-upgrade.sh)
[ -n "$a" ] || { echo "no ports_answer in ohs-patch"; exit 1; }
[ -n "$b" ] || { echo "no ports_answer in dbclient-upgrade"; exit 1; }
if [ "$a" != "$b" ]; then
  echo "FAIL: the two ports_answer copies have drifted"
  diff <(printf '%s\n' "$a") <(printf '%s\n' "$b") | sed 's/^/  /'
  exit 1
fi
echo "ok: both copies of ports_answer are byte-identical"
