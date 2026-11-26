#!/usr/bin/env bash
# An ORACLE_HOME from the environment with a trailing slash must be stripped
# before a restore builds its aside path. One probe per script family.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
mkdir -p "$T/tree/patching/ohs-patch" "$T/tree/patching/dbclient-upgrade" "$T/tree/patching/wls-patch" "$T/home/ohs"
ln -s "$(cd lib && pwd)" "$T/tree/lib"

probe() { # <script> <function>
  local script="$1" fn="$2" dir="$T/tree/patching/$1" out
  sed '$d' "patching/$script/$script.sh" >"$dir/$script.sh"
  {
    printf '. "%s/%s.sh" >/dev/null 2>&1\n' "$dir" "$script"
    if [ "$fn" = discover_oracle_home ]; then
      printf '%s 2>/dev/null || :\n' "$fn"
    else
      printf '_result="$(%s 2>/dev/null)"; [ -n "$_result" ] && ORACLE_HOME="$_result"\n' "$fn"
    fi
    printf 'printf "RESULT:%%s\\n" "${ORACLE_HOME:-}"\n'
  } >"$T/probe.sh"
  out="$(cd "$dir" && ORACLE_HOME="$T/home/" HOME="$T" bash "$T/probe.sh" 2>/dev/null)"
  printf '%s\n' "$out" | grep '^RESULT:' | tail -1 | sed 's/^RESULT://'
}

for pair in 'ohs-patch:find_home' 'dbclient-upgrade:find_home' 'wls-patch:discover_oracle_home'; do
  script="${pair%%:*}"; fn="${pair##*:}"
  got="$(probe "$script" "$fn")"
  case "$got" in
    "$T/home") ok ;;
    *) bad "$script $fn from ORACLE_HOME with trailing slash returned [$got]" ;;
  esac
done
echo "env home slash gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
