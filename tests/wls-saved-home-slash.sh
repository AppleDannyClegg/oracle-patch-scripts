#!/usr/bin/env bash
# A backup saved with a trailing slash on ORACLE_HOME must restore for the SAME
# home, while a backup for a different home is still refused. The comparison is
# before any stop or restore, so this is a compatibility refusal, not a crash.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
SCRIPT=patching/wls-patch/wls-patch.sh
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
STUB="$T/stub"; mkdir -p "$STUB"
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

build() {
  export CMD=restore CASE=""
  # shellcheck disable=SC1091
  . tests/dry-run-env/wls-patch.sh
}

restore() { # <saved home string> -> rc in $RC, output in $T/out
  build
  local B="$T/env/backups/b1" home="$T/home-$RANDOM"
  mkdir -p "$home"
  printf '%s\n' "$1" >"$B/oracle_home.txt"
  rm -rf "$T"/env/fmw.broken-* "$T"/env/domains/*.broken-*
  HOME="$home" bash "$SCRIPT" restore "$B" --yes >"$T/out" 2>&1
  RC=$?
}

build  # export the fixture path before the first control

# control 1: the exact saved path restores (the fixture's own value)
restore "$ORACLE_HOME"
[ "$RC" = 0 ] && ok || bad "exact saved home was refused: rc $RC: $(grep ERROR "$T/out" | head -1)"

# the real shape: the same home saved with a trailing slash
restore "$ORACLE_HOME/"
[ "$RC" = 0 ] && ok || bad "same home with a saved slash was refused: rc $RC: $(grep ERROR "$T/out" | head -1)"

# control 2: a different home stays refused, with the refusal named
restore "$ORACLE_HOME/other"
[ "$RC" != 0 ] && grep -q 'Backup is for' "$T/out" && ok || bad "a different home was accepted or the refusal was unnamed: rc $RC"

echo "wls saved home slash gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
