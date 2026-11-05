#!/usr/bin/env bash
# patch-status-unknown-level.sh - behavioural gate for patching/patch-status/patch-status.sh.
#
# A row whose level could not be dated is UNKNOWN. The findings that set the exit code were report-only, so
# a table/cron run over a stale estate printed '?/UNKNOWN' and still exited 0 - the whole interface when the
# output is discarded. An undated level must raise a WARN in every mode.
#
# Two fake WebLogic homes: one with a PSU that carries a yymmdd (datable), one with a level that carries no
# date (not datable). Runs the real script with --report and checks that the undated home is named in
# FINDINGS while the datable one is not.
#
# Usage: tests/patch-status-unknown-level.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/patching/patch-status/patch-status.sh"
[ -f "$SCRIPT" ] || { echo "patch-status gate: $SCRIPT not found" ; exit 2; }

T="$(cd "$(mktemp -d /tmp/psunk.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
DATED="$T/dated"; UNDATED="$T/undated"
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

mk_home() { # <home> <lspatches line>
  mkdir -p "$1/wlserver" "$1/inventory" "$1/OPatch"
  echo '<component name="WebLogic Server" version="12.2.1.4.0"/>' >"$1/inventory/registry.xml"
  cat >"$1/OPatch/opatch" <<EOF
#!/bin/sh
case "\$1" in
  version) echo "OPatch Version: 13.9.4.2.23" ;;
  lspatches) echo "$2"; echo; echo "OPatch succeeded." ;;
esac
EOF
  chmod +x "$1/OPatch/opatch"
}
mk_home "$DATED"   '11111;WLS PATCH SET UPDATE 12.2.1.4.240415'
mk_home "$UNDATED" '22222;WLS PATCH SET UPDATE 12.2.1.4'

OUT="$T/out"
( cd "$T" && HOME="$T" ORACLE_HOME="$DATED" MW_HOME="$UNDATED" bash "$SCRIPT" --no-net --report --no-tar --out "$OUT" ) >"$T/stdout" 2>"$T/stderr"
report="$(ls "$OUT"/*/REPORT.md 2>/dev/null | head -1)"
[ -n "$report" ] && ok || { bad "no REPORT.md written"; echo "patch-status unknown-level gate: $pass passed, $fail failed"; exit 1; }

# the undated level must be named, with the fact that it is unknown
grep -q "$UNDATED.*patch level unknown" "$report" && ok || bad "no 'patch level unknown' finding for $UNDATED"
grep -q "$DATED.*patch level unknown" "$report" && bad "flagged $DATED, whose level carries a date" || ok

# table/cron shape: no --report, the output is discarded and the exit code is the whole interface
( cd "$T" && HOME="$T" ORACLE_HOME="$DATED" MW_HOME="$UNDATED" bash "$SCRIPT" --no-net --quiet ) >"$T/stdout2" 2>&1
rc2=$?
[ "$rc2" = 1 ] && ok || bad "table/cron mode exits $rc2 for an undated level (want 1)"

echo "patch-status unknown-level gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
