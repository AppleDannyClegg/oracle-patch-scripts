#!/usr/bin/env bash
# wls-patch-conflict.sh - behavioural gate for wls-patch.sh preflight's conflict check.
#
# OPatch's 'prereq CheckConflictAgainstOHWithDetail' prints the header 'Conflicts/Supersets for each patch are:' on a
# failed prereq as well, so the words superset/subset in the output are no proof the patch only supersedes. A failed
# prereq, or any 'Conflict with' line, is a blocking problem; a superset with no failure is a warning only (a newer
# PSU over an older one must not be blocked). Runs the real script against a fake home whose opatch prints canned
# prereq output.
#
# Usage: tests/wls-patch-conflict.sh [repo-root]
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/patching/wls-patch/wls-patch.sh"
T="$(cd "$(mktemp -d /tmp/wlscf.XXXXXX)" && pwd -P)"; trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

OH="$T/oh"; PD="$T/patches"
mkdir -p "$OH/wlserver" "$OH/inventory" "$OH/OPatch" "$OH/oui" "$T/jdk/bin" "$PD/extracted/39000002/etc/config"
echo '<component name="WebLogic Server" version="12.2.1.4.0"/>' >"$OH/inventory/registry.xml"
echo "JAVA_HOME=$T/jdk" >"$OH/oui/.globalEnv.properties"
printf '#!/bin/sh\necho "java version \\"1.8.0_471\\"" >&2\nexit 0\n' >"$T/jdk/bin/java"; chmod +x "$T/jdk/bin/java"
echo '<inventory/>' >"$PD/extracted/39000002/etc/config/inventory.xml"
printf 'WLS PATCH SET UPDATE 12.2.1.4.261020\nYou must have OPatch version 13.9.4.2.13 or higher\n' >"$PD/extracted/39000002/README.txt"
cat >"$OH/OPatch/opatch" <<O
#!/bin/sh
case "\$1" in
  version) echo "OPatch Version: 13.9.4.2.23" ;;
  lspatches) echo "39372515;WLS PATCH SET UPDATE 12.2.1.4.260514" ;;
  prereq) cat "$T/prereq"; exit "\$(cat "$T/prereq.rc")" ;;
esac
exit 0
O
chmod +x "$OH/OPatch/opatch"
# ps: a readable, empty process table, so the gate does not depend on the host's ps (none in OL8 slim - Cerebro P3)
mkdir -p "$T/stub"; printf '#!/bin/sh\necho "  PID ARGS"; echo "    1 /sbin/init"\n' >"$T/stub/ps"; chmod +x "$T/stub/ps"

run() { (cd "$T" && HOME="$T" ORACLE_HOME="$OH" PATH="$T/stub:$PATH" bash "$SCRIPT" preflight "$PD" --oracle-home "$OH" --java-home "$T/jdk" --yes) >"$T/out" 2>&1; echo $?; }

printf 'Prereq "checkConflictAgainstOHWithDetail" passed.\n\nOPatch succeeded.\n' >"$T/prereq"; echo 0 >"$T/prereq.rc"
rc="$(run)"; [ "$rc" = 0 ] && grep -q 'no conflicts' "$T/out" && ok || bad "a passed prereq: rc $rc, $(grep -iE 'conflict|problem' "$T/out" | head -3)"

# the real failure shape: failed line + the Conflicts/Supersets header + a Conflict with line
printf 'Invoking prereq "checkconflictagainstohwithdetail"\n\nPrereq "checkConflictAgainstOHWithDetail" failed.\n\nSummary of Conflict Analysis:\n\nConflicts/Supersets for each patch are:\n\nPatch : 39000002\n\n        Conflict with 31000001\n        Conflict details:\n\nOPatch failed with error code 73\n' >"$T/prereq"; echo 73 >"$T/prereq.rc"
rc="$(run)"; [ "$rc" != 0 ] && grep -q 'CONFLICT for 39000002' "$T/out" && ok || bad "a failed prereq with the Conflicts/Supersets header was not blocking: rc $rc, $(grep -iE 'conflict|supersed' "$T/out" | head -3)"

# a failed prereq with no 'Conflict with' line is still a failure
printf 'Prereq "checkConflictAgainstOHWithDetail" failed.\nConflicts/Supersets for each patch are:\nPatch : 39000002\n        Bug Superset of 31000001\n' >"$T/prereq"; echo 1 >"$T/prereq.rc"
rc="$(run)"; [ "$rc" != 0 ] && grep -q 'CONFLICT for 39000002' "$T/out" && ok || bad "a failed prereq that names only a superset was not blocking: rc $rc"

# a non-zero exit is a conflict whatever the wording (Jocasta/Edi P3): no 'failed', no 'Conflict with', only a superset
printf 'Conflicts/Supersets for each patch are:\nPatch : 39000002\n        Bug Superset of 31000001\n' >"$T/prereq"; echo 1 >"$T/prereq.rc"
rc="$(run)"; [ "$rc" != 0 ] && grep -q 'CONFLICT for 39000002' "$T/out" && ok || bad "a non-zero prereq exit with superset-only wording was not blocking: rc $rc"

# a 'Conflict with' line alone is a conflict, even with exit 0 and a 'passed' line (Cerebro P3: exercise that arm)
printf 'Prereq "checkConflictAgainstOHWithDetail" passed.\nPatch : 39000002\n        Conflict with 31000001\n' >"$T/prereq"; echo 0 >"$T/prereq.rc"
rc="$(run)"; [ "$rc" != 0 ] && grep -q 'CONFLICT for 39000002' "$T/out" && ok || bad "a 'Conflict with' line under exit 0 was not blocking: rc $rc"

# a superset with no failure: a warning, not a problem (a newer PSU over an older one)
printf 'Patch 39000002 is a superset of the patch(es) [  39372515 ] in the Oracle Home\nOPatch succeeded.\n' >"$T/prereq"; echo 0 >"$T/prereq.rc"
rc="$(run)"; [ "$rc" = 0 ] && grep -q 'supersedes' "$T/out" && ok || bad "a superset with no failure blocked or was silent: rc $rc"

# OPatch 13.9.4.2.25 wording (T1162): 'for patch <id> passed.' is no conflict; 'for patch <id> failed.' with only a superset
# under exit 0 is a conflict, not the superset warning
printf 'Invoking prereq "checkconflictagainstohwithdetail"\n\nPrereq "checkConflictAgainstOHWithDetail" for patch 39000002 passed.\n\nOPatch succeeded.\n' >"$T/prereq"; echo 0 >"$T/prereq.rc"
rc="$(run)"; [ "$rc" = 0 ] && grep -q 'no conflicts' "$T/out" && ok || bad "'for patch N passed': rc $rc, $(grep -iE 'conflict|problem' "$T/out" | head -3)"
printf 'Prereq "checkConflictAgainstOHWithDetail" for patch 39000002 failed.\nConflicts/Supersets for each patch are:\nPatch : 39000002\n        Bug Superset of 31000001\n' >"$T/prereq"; echo 0 >"$T/prereq.rc"
rc="$(run)"; [ "$rc" != 0 ] && grep -q 'CONFLICT for 39000002' "$T/out" && ok || bad "'for patch N failed' with only a superset under exit 0 was not blocking: rc $rc, $(grep -iE 'conflict|supersed' "$T/out" | head -3)"

echo "wls-patch conflict gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
