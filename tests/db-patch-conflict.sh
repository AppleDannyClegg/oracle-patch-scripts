#!/usr/bin/env bash
# db-patch-conflict.sh - behavioural gate for db-patch.sh preflight's conflict verdict (T1162).
#
# OPatch 13.9.4.2.25 prints 'Prereq "checkConflictAgainstOHWithDetail" for patch <id> passed.' where older
# versions print '... passed.' (field run, 12 Nov 2026). Both are 'no conflicts'. If the 'for patch <id> ' form
# were not matched, the fallback grep for 'conflict' would match the prereq name itself and call it a CONFLICT.
#
# Sources the real script (minus its trailing main call), stubs the environment and opatch, and runs
# cmd_preflight with no databases, so only the patch checks run.
#
# Usage: tests/db-patch-conflict.sh [repo-root]
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/patching/db-patch/db-patch.sh"
[ -f "$SCRIPT" ] || { echo "db-patch conflict gate: $SCRIPT not found"; exit 2; }

T="$(cd "$(mktemp -d /tmp/dbcf.XXXXXX)" && pwd -P)"; trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# the script sources ../../lib/oracle-lib.sh, so its copy sits at the same depth
mkdir -p "$T/patching/db-patch" "$T/lib" "$T/oh" "$T/patches/39000000/etc/config" "$T/run"
sed '$d' "$SCRIPT" >"$T/patching/db-patch/db-patch.sh"
cp "$ROOT/lib/oracle-lib.sh" "$T/lib/oracle-lib.sh"
printf '<oneoffs><oneoff><description>Database Release Update : 19.24.0.0.240716 (39000000)</description></oneoff></oneoffs>\n' \
  >"$T/patches/39000000/etc/config/inventory.xml"

# run <prereq output>: cmd_preflight with opatch printing that output; stderr (the log) goes to $T/out
run() {
  printf '%s' "$1" >"$T/prereq"
  # shellcheck disable=SC2034   # the globals below are read by the sourced cmd_preflight
  (
    # shellcheck disable=SC1091
    . "$T/patching/db-patch/db-patch.sh"
    setup_env() { :; }; file_owner() { id -un; }; opatch_locked() { return 1; }; opatch_running() { return 1; }
    state_set() { :; }
    opatch() { cat "$T/prereq"; }
    HOME_DIR="$T/oh" DB_VERSION=19.24.0.0.0 RU_LEVEL="" INSTALLED="" OPATCH_VERSION=12.2.0.1.42 OPATCH_ZIP=""
    RUN_DIR="$T/run" LOG_FILE="$T/run/log" NO_BACKUP=1 NO_RP=1 SIDS="" GRID=0 IS_RAC=0 ROLLING=0 OOP=""
    DG_STANDBY_FIRST=no FORCE=0 ARGS=("$T/patches")
    cmd_preflight
  ) >"$T/out" 2>&1
  echo $?
}

rc="$(run 'Prereq "checkConflictAgainstOHWithDetail" passed.
OPatch succeeded.
')"
[ "$rc" = 0 ] && grep -q 'no conflicts' "$T/out" && ok || bad "the plain 'passed' line: rc $rc, $(grep -E 'conflict|CONFLICT|ERROR' "$T/out" | head -2)"

rc="$(run 'Invoking prereq "checkconflictagainstohwithdetail"

Prereq "checkConflictAgainstOHWithDetail" for patch 39000000 passed.

OPatch succeeded.
')"
[ "$rc" = 0 ] && grep -q 'no conflicts' "$T/out" && ! grep -q CONFLICT "$T/out" && ok \
  || bad "OPatch 13.9.4.2.25's 'for patch N passed' was not 'no conflicts': rc $rc, $(grep -E 'conflict|CONFLICT|ERROR' "$T/out" | head -2)"

rc="$(run 'Prereq "checkConflictAgainstOHWithDetail" for patch 39000000 failed.
Patch : 39000000
  Conflict with 31000001
')"
[ "$rc" = 1 ] && grep -q 'CONFLICT: ' "$T/out" && ok || bad "'for patch N failed' with a Conflict with line was not a CONFLICT: rc $rc"

rc="$(run 'Prereq "checkConflictAgainstOHWithDetail" for patch  passed.
')"
# with no id the strict match must not fire, so the fallback calls it a CONFLICT (it matches the prereq name):
# assert that verdict, so the case cannot pass on a cmd_preflight that never ran
[ "$rc" = 1 ] && grep -q 'CONFLICT: ' "$T/out" && ! grep -q 'no conflicts' "$T/out" && ok \
  || bad "'for patch  passed' with no id was not a CONFLICT: rc $rc, $(grep -E 'conflict|CONFLICT|ERROR' "$T/out" | head -2)"

echo "db-patch conflict gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
