#!/usr/bin/env bash
# oem-standby-lag.sh - behavioural gate for operations/oem-standby-lag/oem-standby-lag.sh.
#
# What the wrapper must never do, each driven through stub emcli/sqlplus that log their argv and stdin:
#  - sql-test: a lag over the threshold, an UNKNOWN status (apply off, stats not computed), a stale contact with the
#    primary, a failed read and an empty read are all CRIT (rc 2) - an unreadable lag is never a clean 0.
#  - preflight: an emcli that is not logged in, or whose help does not list a flag the wrapper passes, stops the run
#    before any change (a renamed flag in another EM release must fail here, not half-way through a deploy).
#  - --dry-run reaches no changing emcli verb; a real deploy passes the targets and records them for rollback; a
#    failed deploy exits non-zero and records nothing; rollback undeploys exactly the recorded targets.
#  - verify: every target must have a current row in the repository; a missing target is CRIT, a failed repository
#    read is CRIT, and no OMR_CONNECT is a WARN (never "verified").
#  - the repository password in OMR_CONNECT never reaches an argv.
#
# No database, no EM: stubs only. What a stub cannot prove - the real emcli flag names on your EM release, the SQL on
# a real standby, the metric in the console - is the runbook's preflight / sql-test / verify on the real estate.
#
# Usage: tests/oem-standby-lag.sh [repo-root]
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SH="$ROOT/operations/oem-standby-lag/oem-standby-lag.sh"
[ -f "$SH" ] || { echo "oem-standby-lag gate: $SH not found"; exit 2; }
pass=0; fail=0
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
ok() { pass=$((pass + 1)); }
no() { fail=$((fail + 1)); echo "FAIL $*"; }
mkdir -p "$T/stub" "$T/home" "$T/oh/bin"
LOG="$T/calls.log"

# emcli: logs argv. help <verb> lists every flag the wrapper uses, minus EMCLI_HELP_DROP ("verb:-flag"); sync fails
# when EMCLI_SYNC_RC=1 (not logged in); get_targets prints a row per name in EMCLI_TARGETS; a changing verb matching
# EMCLI_FAIL exits 1.
cat >"$T/stub/emcli" <<'STUB'
#!/bin/sh
echo "emcli $*" >>"$CALLS_LOG"
verb="$1"; shift
case "$verb" in
  sync) exit "${EMCLI_SYNC_RC:-0}";;
  help)
    for f in -file_name -target_type -name -version -target_names -targets; do
      [ "$1:$f" = "${EMCLI_HELP_DROP:-}" ] && continue
      echo "    [$f=\"value\"]"
    done; exit 0;;
  get_targets) for t in ${EMCLI_TARGETS:-}; do echo "1  Up  oracle_database  $t"; done; exit 0;;
esac
[ -n "${EMCLI_FAIL:-}" ] && [ "$verb" = "$EMCLI_FAIL" ] && { echo "Error: $verb failed (stub)"; exit 1; }
echo "$verb ok"
exit 0
STUB
# sqlplus: logs argv (stdin is not logged - that is where the connect string belongs); answers the lag query from
# $LAG_ROW and the repository query from $OMR_ROWS; SQL_FAIL=1 answers with an ORA- error.
cat >"$T/stub/sqlplus" <<'STUB'
#!/bin/sh
echo "sqlplus $*" >>"$CALLS_LOG"
q="$(cat)"
[ "${SQL_FAIL:-0}" = 1 ] && { echo "ORA-01034: ORACLE not available"; exit 0; }
case "$q" in
  *'mgmt$metric_current'*) [ -n "${OMR_ROWS:-}" ] && printf '%b\n' "$OMR_ROWS";;
  *'v$dataguard_stats'*) [ -n "${LAG_ROW:-}" ] && printf '%s\n' "$LAG_ROW";;
esac
exit 0
STUB
chmod +x "$T/stub/emcli" "$T/stub/sqlplus"

# run <args...>: the wrapper in the stub world; output in $T/out, exit code in $rc
run() {
  : >"$LOG"
  env HOME="$T/home" PATH="$T/stub:$PATH" CALLS_LOG="$LOG" SQL_CMD="$T/stub/sqlplus" ORACLE_HOME="$T/oh" \
    ME_ARCHIVE="${ME_ARCHIVE:-$T/me.zip}" bash "$SH" "$@" </dev/null >"$T/out" 2>&1
  rc=$?
}
: >"$T/me.zip"

# --- sql-test: the metric's own SQL, run locally -------------------------------------------------------------
LAG_ROW='PHYSICAL STANDBY|READ ONLY WITH APPLY|0|5|3|1|OK' run sql-test --sid STBY
[ "$rc" = 0 ] && grep -q 'apply lag 5s' "$T/out" && ok || { no "sql-test healthy standby: rc=$rc (want 0) / no 'apply lag 5s'"; sed 's/^/    /' "$T/out"; }

LAG_ROW='PHYSICAL STANDBY|READ ONLY WITH APPLY|0|4000|3|1|OK' run sql-test --sid STBY
[ "$rc" = 2 ] && ok || no "sql-test apply lag 4000s over the 3600s critical: rc=$rc (want 2)"

LAG_ROW='PHYSICAL STANDBY|READ ONLY WITH APPLY|600|5|3|1|OK' run sql-test --sid STBY
[ "$rc" = 1 ] && ok || no "sql-test transport lag 600s over the 300s warning: rc=$rc (want 1)"

LAG_ROW='PHYSICAL STANDBY|MOUNTED|||40|0|UNKNOWN' run sql-test --sid STBY
[ "$rc" = 2 ] && grep -q 'UNKNOWN' "$T/out" && ok || no "sql-test UNKNOWN status (apply off): rc=$rc (want 2)"

LAG_ROW='PHYSICAL STANDBY|READ ONLY WITH APPLY|0|0|1000|1|OK' run sql-test --sid STBY
[ "$rc" = 2 ] && ok || no "sql-test stale primary contact (1000s, lag reads 0): rc=$rc (want 2) - a frozen 0 must not read as healthy"

SQL_FAIL=1 run sql-test --sid STBY
[ "$rc" = 2 ] && grep -qi 'could not read' "$T/out" && ok || no "sql-test failed read: rc=$rc (want 2) and 'could not read'"

LAG_ROW='' run sql-test --sid STBY
[ "$rc" = 2 ] && ok || no "sql-test empty read: rc=$rc (want 2)"

LAG_ROW='PRIMARY|READ WRITE|||||PRIMARY' run sql-test --sid PRIM
[ "$rc" = 0 ] && grep -qi 'primary' "$T/out" && ok || no "sql-test on a primary: rc=$rc (want 0, said out loud)"

# --- preflight -------------------------------------------------------------------------------------------------
EMCLI_TARGETS='STBYA STBYB' run preflight --targets STBYA,STBYB
[ "$rc" = 0 ] && ok || { no "preflight all present: rc=$rc (want 0)"; sed 's/^/    /' "$T/out"; }

EMCLI_SYNC_RC=1 EMCLI_TARGETS='STBYA' run preflight --targets STBYA
[ "$rc" != 0 ] && grep -qi 'logged in' "$T/out" && ok || no "preflight not logged in: rc=$rc (want non-zero, 'logged in')"

EMCLI_HELP_DROP='deploy_metric_extension:-target_names' EMCLI_TARGETS='STBYA' run preflight --targets STBYA
[ "$rc" != 0 ] && grep -q 'deploy_metric_extension' "$T/out" && grep -q -- '-target_names' "$T/out" && ok \
  || no "preflight with a flag missing from emcli help: rc=$rc (want non-zero naming deploy_metric_extension -target_names)"

EMCLI_TARGETS='STBYA' run preflight --targets STBYA,NOSUCH
[ "$rc" != 0 ] && grep -q 'NOSUCH' "$T/out" && ok || no "preflight unknown target: rc=$rc (want non-zero naming NOSUCH)"

run preflight --targets "STBYA');drop"
[ "$rc" != 0 ] && ! grep -q 'get_targets' "$LOG" && ok || no "preflight target name with quotes: rc=$rc (want refused before emcli)"

# --- change commands -------------------------------------------------------------------------------------------
EMCLI_TARGETS='STBYA STBYB' run deploy --targets STBYA,STBYB --dry-run --yes
if [ "$rc" = 0 ] && ! grep -qE '^emcli (import|save|publish|deploy|undeploy)_metric_extension' "$LOG"; then ok
else no "deploy --dry-run: rc=$rc or a changing verb reached emcli:"; sed 's/^/    /' "$LOG"; fi

EMCLI_TARGETS='STBYA STBYB' run deploy --targets STBYA,STBYB --yes --run-dir "$T/run-deploy"
if [ "$rc" = 0 ] && grep -qxF 'emcli deploy_metric_extension -target_type=oracle_database -name=ME$STANDBY_LAG -version=1 -target_names=STBYA,STBYB' "$LOG" \
   && grep -qx 'deployed_targets=STBYA,STBYB' "$T/run-deploy/state"; then ok
else no "deploy: rc=$rc, or the deploy call/state is not what was asked:"; sed 's/^/    /' "$LOG"; cat "$T/run-deploy/state" 2>/dev/null | sed 's/^/    state: /'; fi

EMCLI_FAIL=deploy_metric_extension EMCLI_TARGETS='STBYA' run deploy --targets STBYA --yes --run-dir "$T/run-fail"
if [ "$rc" != 0 ] && ! grep -q '^deployed_targets=STBYA' "$T/run-fail/state" 2>/dev/null; then ok
else no "failed deploy: rc=$rc (want non-zero) and no deployed_targets recorded"; fi

EMCLI_TARGETS='STBYA STBYB' run rollback --yes --run-dir "$T/run-deploy"
grep -qxF 'emcli undeploy_metric_extension -target_type=oracle_database -name=ME$STANDBY_LAG -version=1 -target_names=STBYA,STBYB' "$LOG" && [ "$rc" = 0 ] && ok \
  || { no "rollback: rc=$rc, did not undeploy the recorded STBYA,STBYB:"; sed 's/^/    /' "$LOG"; }

EMCLI_TARGETS='STBYA' run import --yes --run-dir "$T/run-import"
grep -qxF "emcli import_metric_extension -file_name=$T/me.zip" "$LOG" && [ "$rc" = 0 ] && ok || no "import: rc=$rc, file_name not passed"

EMCLI_TARGETS='STBYA' ME_ARCHIVE="$T/absent.zip" run import --yes
[ "$rc" != 0 ] && ! grep -q 'import_metric_extension -file' "$LOG" && ok || no "import of a missing archive: rc=$rc (want refused before emcli)"

EMCLI_TARGETS='STBYA' run publish --yes
grep -q '^emcli save_metric_extension_draft ' "$LOG" && grep -q '^emcli publish_metric_extension ' "$LOG" && [ "$rc" = 0 ] && ok \
  || no "publish: rc=$rc, save draft + publish not both called"

# --- verify: the repository says each target is collecting ---------------------------------------------------
r_a='STBYA|lag_status|OK|2026-11-03 12:00:00'; r_b='STBYB|lag_status|OK|2026-11-03 12:00:00'
OMR_CONNECT='sysman/S3cretPw@omr' OMR_ROWS="$r_a\n$r_b" run verify --targets STBYA,STBYB
[ "$rc" = 0 ] && ok || { no "verify both collecting: rc=$rc (want 0)"; sed 's/^/    /' "$T/out"; }
grep -q 'S3cretPw' "$LOG" && no "secret: the OMR password reached an argv: $(grep S3cretPw "$LOG")" || ok

OMR_CONNECT='sysman/x@omr' OMR_ROWS="$r_a" run verify --targets STBYA,STBYB
[ "$rc" = 2 ] && grep -q 'STBYB' "$T/out" && ok || no "verify one target missing: rc=$rc (want 2 naming STBYB)"

OMR_CONNECT='sysman/x@omr' SQL_FAIL=1 run verify --targets STBYA
[ "$rc" = 2 ] && ok || no "verify repository read failed: rc=$rc (want 2)"

OMR_CONNECT='' run verify --targets STBYA
[ "$rc" = 1 ] && ok || no "verify with no OMR_CONNECT: rc=$rc (want 1 - not verified)"

OMR_CONNECT='sysman/x@omr' OMR_ROWS='STBYA|lag_status|UNKNOWN|2026-11-03 12:00:00' run verify --targets STBYA
[ "$rc" = 2 ] && ok || no "verify a target reporting UNKNOWN: rc=$rc (want 2)"

echo "oem-standby-lag gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
