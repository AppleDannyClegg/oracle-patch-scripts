#!/usr/bin/env bash
# ohs-quarter gate: the composition and its order, with stub children that log their argv. It pins:
#   - preflight of every present folder BEFORE the stop, java/dbclient preflight get --will-stop
#   - one backup phase (java, wls, and one shared home+inventory), stop once, apply in order
#     java -> wls -> dbclient -> dbclientru -> webgate -> oss -> ohs -> the other opatch rows, start once, verify
#   - every dbclient/opatch apply is given --backup-run <the one shared run dir>
#   - a failure after the backup recovers in reverse (shared restore, wls restore, java rollback), then starts
#   - a failed restore exits 3 and does NOT start; a missing/empty folder is skipped
#   - dry-run reaches no changing child verb; without --yes on a non-tty it refuses before any change
#
# Usage: tests/ohs-quarter.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/patching/ohs-quarter/ohs-quarter.sh"
[ -f "$SCRIPT" ] || { echo "ohs-quarter gate: $SCRIPT not found"; exit 2; }

T="$(cd "$(mktemp -d /tmp/oq.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
# the signals this test's caller already ignores, as a start would see them. run-all starts each gate as a background
# job, which bash gives SIGINT ignored, and a non-interactive shell cannot reset a signal ignored on entry (POSIX), so
# a start inherits that ignore whatever ohs-quarter does. The start check below fails only on traps beyond these (T1171).
bash -c 'trap -p TERM INT' >"$T/start-base"
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# a stub child: logs 'java|wls|dbclient|ohs <args>'; a shared backup writes the run dir's four keys and the two
# tarballs the child apply requires; a named FAIL_* makes the matching verb fail. __T__ becomes $T.
sed "s|__T__|$T|g" >"$T/stub-child" <<'STUB'
#!/bin/sh
who="$(basename "$0")"; case "$who" in stub-java) who=java;; stub-wls) who=wls;; stub-dbclient) who=dbclient;; stub-ohs) who=ohs;; esac
printf '%s %s\n' "$who" "$*" >>"__T__/calls.log"
# SIGNAL_AT='<who> <verb>' sends SIGTERM to ohs-quarter (this stub's parent) from inside that call, as a Ctrl-C or a
# kill mid-outage would; the call itself then finishes normally
[ -n "${SIGNAL_AT:-}" ] && [ "$who $1" = "$SIGNAL_AT" ] && kill -TERM "$PPID"
rd=""; prev=""
for a in "$@"; do [ "$prev" = "--run-dir" ] && rd="$a"; prev="$a"; done
case "$1" in
  preflight)
    [ "$who" = java ] && [ -n "${FAIL_JAVA_PREFLIGHT:-}" ] && exit 1
    [ "$who" = wls ] && [ -n "${FAIL_WLS_PREFLIGHT:-}" ] && exit 1
    [ "$who" = dbclient ] && [ -n "${FAIL_DB_PREFLIGHT:-}" ] && exit 1
    [ "$who" = ohs ] && [ -n "${FAIL_OHS_PREFLIGHT:-}" ] && exit 1 ;;
  backup)
    [ -n "${FAIL_BACKUP:-}" ] && exit 1
    if [ "$who" = wls ] && [ -n "$rd" ]; then echo "backup_dir=__T__/wlsbk" >>"$rd/state" 2>/dev/null; mkdir -p "$rd"; echo "backup_dir=__T__/wlsbk" >>"$rd/state"; fi
    if { [ "$who" = dbclient ] || [ "$who" = ohs ]; } && [ -n "$rd" ]; then mkdir -p "$rd"; {
      echo "oracle_home=/u01/ohs"; echo "backup=ok"; echo "backup_dir=__T__/bk"; echo "pre_patches=1 2 3"
    } >>"$rd/state"; mkdir -p "__T__/bk"; : >"__T__/bk/home.tgz"; : >"__T__/bk/oraInventory.tgz"; fi ;;
  stop) n=$(cat "__T__/stops.n" 2>/dev/null || echo 0); n=$((n+1)); echo "$n" >"__T__/stops.n"
    [ -n "${STOP_FAIL_AT:-}" ] && [ "$n" = "${STOP_FAIL_AT}" ] && exit 1
    [ -n "${FAIL_FIRST_STOP:-}" ] && exit 1; [ -n "${FAIL_STOP:-}" ] && [ -e "__T__/stop.ok" ] && exit 1; : >"__T__/stop.ok" ;;
  apply)
    [ "$who" = java ] && [ -n "${FAIL_JAVA_APPLY:-}" ] && exit 1
    [ "$who" = wls ] && [ -n "${FAIL_WLS_APPLY:-}" ] && exit 1
    [ "$who" = dbclient ] && [ -n "${FAIL_DB_APPLY:-}" ] && exit 1
    # the WLS PSU lands in the inventory at this call: write wls-patch's before/after pair, so ohs-quarter can
    # hand the new id to the dbclient apply (T1560)
    if [ "$who" = wls ] && [ -n "$rd" ]; then mkdir -p "$rd"
      echo "applied=39919567 38000001" >>"$rd/state"
    fi
    case "$2" in
      */dbclientru) [ -n "${FAIL_DBCLIENTRU:-}" ] && exit 1;;
      */webgate) [ -n "${FAIL_WEBGATE:-}" ] && exit 1;;
      */oss) [ -n "${FAIL_OSS:-}" ] && exit 1;;
      */ohs) [ -n "${FAIL_OHS_APPLY:-}" ] && exit 1;;
    esac ;;
  start) bash -c 'trap -p TERM INT' >>"__T__/start-traps"   # what a daemon started now would inherit (T1137)
    if [ -n "${FAIL_START:-}" ] && [ ! -e "__T__/start.failed" ]; then : >"__T__/start.failed"; exit 1; fi; : >"__T__/start.ok" ;;
  verify) [ -n "${FAIL_VERIFY:-}" ] && exit 1; [ "$who" = ohs ] && [ -n "${FAIL_OHS_VERIFY:-}" ] && exit 1 ;;
  rollback) [ -n "${FAIL_ROLLBACK:-}" ] && exit 1; [ -n "${SLOW_ROLLBACK:-}" ] && sleep 2 ;;
  restore) [ -n "${FAIL_WLS_RESTORE:-}" ] && exit 1 ;;
esac
exit 0
STUB
chmod +x "$T/stub-child"
stub() { cp "$T/stub-child" "$1"; chmod +x "$1"; }
stub "$T/stub-java"; stub "$T/stub-wls"; stub "$T/stub-dbclient"; stub "$T/stub-ohs"
export OHS_QUARTER_JAVA_PATCH="$T/stub-java" OHS_QUARTER_WLS_PATCH="$T/stub-wls"
export OHS_QUARTER_DBCLIENT="$T/stub-dbclient" OHS_QUARTER_OHS_PATCH="$T/stub-ohs"

mkroot() { # <dir> [jdk] [wlspsu] [dbclient] [dbclientru] [webgate] [oss] [ohs] [extras]
  local d="$1"; mkdir -p "$d"
  [ "${2:-1}" = 1 ] && { mkdir -p "$d/jdk"; : >"$d/jdk/jdk-1.8.0_511_linux-x64_bin.tar.gz"; }
  local specs="wlspsu:${3:-1} dbclient:${4:-1} dbclientru:${5:-1} webgate:${6:-1} oss:${7:-1} ohs:${8:-1}"
  for s in $specs; do [ "${s#*:}" = 1 ] && { mkdir -p "$d/${s%%:*}"; : >"$d/${s%%:*}/patch.zip"; }; done
  if [ "${9:-0}" = 1 ]; then for f in fmwbp jdbc libovd fmwthirdparty perl libdms2 libiau cloningspu rda; do mkdir -p "$d/$f"; : >"$d/$f/p.zip"; done; fi
}
runq() { # <root> [env assignments...]
  local root="$1"; shift
  : >"$T/calls.log"; : >"$T/start-traps"; rm -rf "$T/run" "$T/bk" "$T/wlsbk"; rm -f "$T/stop.ok" "$T/start.ok" "$T/start.failed" "$T/stops.n"
  env "$@" bash "$SCRIPT" --patch-root "$root" --run-dir "$T/run" --yes >"$T/out" 2>&1
}
line() { grep -n "$1" "$T/calls.log" | head -1 | cut -d: -f1; }
# the line of the apply whose patch dir has this basename, whatever follows it
aapply_line() { awk -v s="$1" '$2=="apply" { n=split($3,a,"/"); if (a[n]==s) { print NR; exit } }' "$T/calls.log"; }

# ---- happy path: order, --will-stop, one backup phase, stop once, start once, --backup-run --------------------
mkroot "$T/root" 1 1 1 1 1 1 1 1
runq "$T/root" && ok || bad "happy path failed: $(tail -3 "$T/out")"
grep -q 'java preflight .*--will-stop' "$T/calls.log" && ok || bad "java preflight did not get --will-stop"
# --will-stop is java-patch's option; dbclient-upgrade.sh has none and stops at "unknown option" (this line used to
# assert the opposite, against a stub that accepts anything)
grep -q 'dbclient preflight' "$T/calls.log" && ! grep -q 'dbclient preflight .*--will-stop' "$T/calls.log" && ok || bad "dbclient preflight missing, or handed --will-stop, which the real script rejects"
# T1550: --operator-stops must reach BOTH children, or the real scripts stop and start again
: >"$T/calls.log"
env OHS_QUARTER_JAVA_PATCH="$T/stub-java" OHS_QUARTER_WLS_PATCH="$T/stub-wls" OHS_QUARTER_DBCLIENT="$T/stub-dbclient" OHS_QUARTER_OHS_PATCH="$T/stub-ohs" \
  bash "$SCRIPT" --patch-root "$T/root" --run-dir "$T/run" --yes --operator-stops >"$T/out" 2>&1
missing="$(grep -E '^(dbclient|ohs) ' "$T/calls.log" | grep -vc -- '--operator-stops')"
grep -q 'the home is left STOPPED for the operator to start, and ports were not checked' "$T/out" && ok || bad "quarter 7/7 with operator-stops does not say the home is left stopped: $(grep '7/7' "$T/out" | head -1)"
[ -n "$(grep -E '^(dbclient|ohs) ' "$T/calls.log")" ] && [ "$missing" = 0 ] && ok || bad "$missing dbclient/ohs call(s) did not get --operator-stops: [$(grep -E '^(dbclient|ohs) ' "$T/calls.log" | grep -v -- '--operator-stops' | head -2)]"
grep -q '^java apply .*--will-stop' "$T/calls.log" && bad "apply was given --will-stop (it must not be)" || ok
# T1560: the WebLogic PSU applied in 4/7 must reach the dbclient apply as --keep-patches, or its re-run
# preflight blocks it as "neither rolled back nor kept" - a dry run skips that apply, so no earlier check sees it
grep -q '^dbclient apply .*--keep-patches 38000001,39919567' "$T/calls.log" && ok || bad "the dbclient apply did not get BOTH WLS ids (space-separated applied=) as --keep-patches: [$(grep '^dbclient apply' "$T/calls.log" | head -1)]"
stop="$(line 'ohs stop')"; [ -n "$stop" ] && ok || bad "no ohs stop"
# every preflight before the stop; every apply after it
lastpre="$(grep -n ' preflight' "$T/calls.log" | tail -1 | cut -d: -f1)"
[ -n "$lastpre" ] && [ "$lastpre" -lt "$stop" ] && ok || bad "a preflight ran after the stop"
[ "$(line 'java apply')" -gt "$stop" ] && ok || bad "the JDK apply ran before the stop"
# one backup phase: one java backup, one wls backup, one shared backup (dbclient)
[ "$(grep -c '^java backup' "$T/calls.log")" = 1 ] && [ "$(grep -c '^wls backup' "$T/calls.log")" = 1 ] && [ "$(grep -c '^dbclient backup' "$T/calls.log")" = 1 ] && ok || bad "the backup phase is not one java + one wls + one shared: [$(grep ' backup' "$T/calls.log")]"
[ "$(grep -c '^ohs stop' "$T/calls.log")" = 1 ] && ok || bad "ohs stop not exactly once"
[ "$(grep -c '^ohs start' "$T/calls.log")" = 1 ] && ok || bad "ohs start not exactly once"
# apply order: java -> wls -> dbclient -> dbclientru -> webgate -> oss -> ohs -> fmwbp -> jdbc -> libovd -> fmwthirdparty -> perl -> libdms2 -> libiau
#   -> cloningspu -> rda
ja="$(line '^java apply')"; wa="$(line '^wls apply')"; da="$(line '^dbclient apply')"
ru="$(aapply_line dbclientru)"; wg="$(aapply_line webgate)"; oss="$(aapply_line oss)"; oh="$(aapply_line ohs)"
fb="$(aapply_line fmwbp)"; jb="$(aapply_line jdbc)"; lo="$(aapply_line libovd)"; ft="$(aapply_line fmwthirdparty)"; pe="$(aapply_line perl)"; dm="$(aapply_line libdms2)"; ia="$(aapply_line libiau)"; cs="$(aapply_line cloningspu)"; rd="$(aapply_line rda)"
all="$ja $wa $da $ru $wg $oss $oh $fb $jb $lo $ft $pe $dm $ia $cs $rd"
for v in $all; do [ -n "$v" ] || bad "an expected apply is missing (chain: $all)"; done
prev=0; good=1
for v in $all; do [ "$v" -gt "$prev" ] || good=0; prev="$v"; done
[ "$good" = 1 ] && ok || bad "apply order is not java -> wls -> dbclient -> dbclientru -> webgate -> oss -> ohs -> extras (chain: $all)"
# every dbclient/opatch apply carries --backup-run (the shared restore point); java/wls do not
miss="$(awk '$1=="dbclient" && $2=="apply" || $1=="ohs" && $2=="apply"' "$T/calls.log" | grep -v -- '--backup-run')"
[ -z "$miss" ] && ok || bad "an apply ran without --backup-run: $miss"
shared="$(sed -n 's/.*--backup-run \([^ ]*\).*/\1/p' "$T/calls.log" | sort -u)"
[ "$(printf '%s\n' "$shared" | wc -l | tr -d ' ')" = 1 ] && [ -n "$shared" ] && ok || bad "applies did not share one run dir: [$shared]"

# ---- a missing/empty folder is left out ONLY when --skip names it -------------------------------------------
# The composer used to skip a missing folder on its own and still print "OHS QUARTER OK". Pointed at a
# get-patches.ps1 download tree (folders by patch kind) it would have applied the two names that match and
# reported success over an outage that did two of sixteen sets.
runskip() { # <root> <skip list> [env...]: runq with --skip
  local root="$1" skip="$2"; shift 2
  : >"$T/calls.log"; rm -rf "$T/run" "$T/bk" "$T/wlsbk"; rm -f "$T/stop.ok" "$T/start.ok" "$T/start.failed" "$T/stops.n"
  env "$@" bash "$SCRIPT" --patch-root "$root" --run-dir "$T/run" --yes --skip "$skip" >"$T/out" 2>&1
}
nochild() { [ ! -s "$T/calls.log" ] && ok || bad "$1: a child was called ($(head -2 "$T/calls.log" | tr '\n' ';'))"; }
REST=fmwbp,jdbc,libovd,fmwthirdparty,perl,libdms2,libiau,cloningspu,rda
mkroot "$T/root2" 1 1 1 1 0 0 0 0
# not named: refused before any child is called, and it prints the list to add
runq "$T/root2" && bad "a root missing nine folders ran without --skip" || ok
nochild "missing folders without --skip"
grep -q 'Not applying a partial runbook' "$T/out" && ok || bad "the partial-root refusal was not named: $(tail -1 "$T/out")"
grep -q -- "--skip webgate,oss,ohs,$REST" "$T/out" && ok || bad "the refusal did not print the --skip list to add: $(tail -1 "$T/out")"
[ ! -e "$T/run" ] && ok || bad "a refused root still created a run dir"
# named: runs, applies what is there, and the last line does not claim the whole runbook
runskip "$T/root2" "webgate,oss,ohs,$REST" && ok || bad "an outage that names what it leaves out failed: $(tail -3 "$T/out")"
[ -z "$(aapply_line webgate)" ] && [ -z "$(aapply_line ohs)" ] && ok || bad "a skipped folder was applied"
grep -q 'webgate/: missing' "$T/out" && ok || bad "the skipped webgate/ folder was not named"
tail -1 "$T/out" | grep -q 'PARTIAL BY REQUEST: 4 of 16 sets' && ok || bad "a partial outage did not say so on its last line: $(tail -1 "$T/out")"
tail -1 "$T/out" | grep -q "LEFT OUT (--skip): webgate oss ohs ${REST//,/ }" && ok || bad "the last line did not list what was left out: $(tail -1 "$T/out")"
grep -q "^left_out=webgate oss ohs ${REST//,/ }\$" "$T/run/state" && ok || bad "the run state does not record what was left out: $(grep left_out "$T/run/state")"
# the whole runbook says so, and only then
runq "$T/root" && tail -1 "$T/out" | grep -q 'OHS QUARTER OK: all 16 sets' && ok || bad "a full outage did not say all 16 sets: $(tail -1 "$T/out")"
grep -q '^left_out=-$' "$T/run/state" && ok || bad "a full outage recorded something left out"
# named but present: refused, either the flag or the folder is wrong
runskip "$T/root" "webgate" && bad "--skip of a folder that has content ran" || ok
nochild "--skip of a present folder"
grep -q -- '--skip names webgate, but' "$T/out" && ok || bad "the contradicted --skip was not named: $(tail -1 "$T/out")"
# a name this runbook does not have
runskip "$T/root" "wls" && bad "--skip of an unknown name ran" || ok
grep -q "not a folder of this runbook" "$T/out" && ok || bad "an unknown --skip name was not refused by name"
# a get-patches.ps1 download tree: folders by patch kind. Refused whole, whatever --skip says.
mkdir -p "$T/gp/jdk" "$T/gp/ohs" "$T/gp/wls" "$T/gp/db" "$T/gp/spb"
: >"$T/gp/jdk/jdk-1.8.0_511_linux-x64_bin.tar.gz"; : >"$T/gp/ohs/p40005842.zip"; : >"$T/gp/wls/p39919567.zip"
runq "$T/gp" && bad "a get-patches download tree ran" || ok
nochild "a get-patches download tree"
grep -q 'get-patches.ps1 download tree' "$T/out" && grep -q 'wls/ db/ spb/' "$T/out" && ok || bad "the download tree was not refused by name: $(tail -1 "$T/out")"
runskip "$T/gp" "wlspsu,dbclient,dbclientru,webgate,oss,$REST" && bad "a get-patches download tree ran once --skip named the rest" || ok
nochild "a get-patches download tree with --skip"
# the same tree for an OHS-only host has just jdk/ and ohs/: nothing foreign to see, so it is the --skip rule that stops it
mkdir -p "$T/gp2/jdk" "$T/gp2/ohs"; : >"$T/gp2/jdk/jdk-1.8.0_511_linux-x64_bin.tar.gz"; : >"$T/gp2/ohs/p40005842.zip"
runq "$T/gp2" && bad "a two-folder root ran as if it were the whole runbook" || ok
nochild "a two-folder root"
grep -q 'OHS QUARTER OK' "$T/out" && bad "a two-folder root printed OHS QUARTER OK" || ok

# ---- JDK apply failure: only the JDK is rolled back, then start -----------------------------------------------
runq "$T/root" FAIL_JAVA_APPLY=1; rc=$?
[ "$rc" = 1 ] && ok || bad "a JDK apply failure exited $rc (want 1)"
[ -n "$(line '^java rollback')" ] && ok || bad "a JDK failure did not roll the JDK back"
[ -z "$(line '^wls restore')" ] && [ -z "$(line '^dbclient rollback')" ] && ok || bad "a JDK-only failure restored things that were not changed"
[ "$(line '^java rollback')" -lt "$(line '^ohs start')" ] && ok || bad "recovery did not start after the rollback"

# ---- WLS apply failure: wls restore + java rollback, then start -----------------------------------------------
runq "$T/root" FAIL_WLS_APPLY=1; rc=$?
[ "$rc" = 1 ] && ok || bad "a WLS apply failure exited $rc (want 1)"
[ -n "$(line '^wls restore')" ] && [ -n "$(line '^java rollback')" ] && ok || bad "a WLS failure did not restore wls and roll back java"
[ "$(line '^wls restore')" -lt "$(line '^java rollback')" ] && ok || bad "recovery is not in reverse order (wls restore then java rollback)"
# T1562 [P3]: before a WLS-only restore, stop first; if the stop cannot prove it, refuse rather than untar over
# a running home. Stop call 1 = the outage 3/7 stop, 2 = recover's first stop, 3 = the guard before the restore
runq "$T/root" FAIL_WLS_APPLY=1 STOP_FAIL_AT=3; rc=$?
[ "$rc" = 3 ] && ok || bad "a failed guard stop exited $rc (want 3)"
[ -z "$(line '^wls restore')" ] && grep -q 'refusing to restore over a running home' "$T/out" && ok || bad "the wls restore ran although the guard stop could not prove the home stopped"

# ---- dbclient apply failure: shared restore (covers the WLS home too), NO wls restore, java rollback -----------
runq "$T/root" FAIL_DB_APPLY=1; rc=$?
[ "$rc" = 1 ] && ok || bad "a dbclient apply failure exited $rc (want 1)"
grep -q "^dbclient rollback .*--run-dir $T/run/backup" "$T/calls.log" && ok || bad "recovery did not run dbclient rollback from the shared backup"
# T1562: the WLS PSU went into the same home the shared backup covers, and a child's rollback can have STARTED
# the components - a wls home restore over that is the bug that left the server with no OPatch
[ -z "$(line '^wls restore')" ] && grep -q 'skipping the wls home restore' "$T/out" && ok || bad "after the shared restore the recovery still ran a wls home restore: [$(grep -E 'wls restore|skipping the wls' "$T/out" "$T/calls.log" | head -2)]"
[ -n "$(line '^java rollback')" ] && ok || bad "a dbclient failure did not roll back java"
[ "$(line 'ohs stop')" -lt "$(line 'dbclient rollback')" ] && ok || bad "recovery did not stop before the restore"
grep -q 'may be part-patched' "$T/out" && grep -q 'broken-' "$T/out" && ok || bad "recovery does not name the partial-home signature or the moved-aside copy (T1563)"
# T1563: a TERM to the quarter during a recovery is IGNORED and does NOT cut the restore; the partial-home line is
# on the record up front. NOT-EXERCISED here: the process-GROUP case (a terminal Ctrl-C hits every child). This
# harness cannot put the composer in its own process group (perl setpgrp/setsid fail here), and SIGNAL_AT signals
# the quarter only - the protection for the children is the inherited 'trap ""', shown by Louie's probe #18269.
runq "$T/root" FAIL_DB_APPLY=1 SIGNAL_AT='dbclient rollback'; rc=$?
[ "$rc" = 1 ] && ok || bad "a TERM during a recovery exited $rc (want 1: the recovery finishes)"
grep -q '^java rollback' "$T/calls.log" && ok || bad "a TERM during recovery cut the restore short (no java rollback)"
grep -q 'may be part-patched' "$T/out" && grep -q 'broken-' "$T/out" && ok || bad "a recovery does not leave the partial-home line (T1563)"

# ---- an opatch apply failure after everything else: same shared restore ---------------------------------------
runq "$T/root" FAIL_WEBGATE=1; rc=$?
[ "$rc" = 1 ] && ok || bad "a webgate apply failure exited $rc (want 1)"
grep -q "^dbclient rollback .*--run-dir $T/run/backup" "$T/calls.log" && ok || bad "recovery after an opatch failure did not restore from the shared backup"

# ---- a failed restore exits 3 and does NOT start -------------------------------------------------------------
runq "$T/root" FAIL_OHS_APPLY=1 FAIL_ROLLBACK=1; rc=$?
[ "$rc" = 3 ] && ok || bad "a failed restore exited $rc (want 3)"
grep -q '^ohs start' "$T/calls.log" && bad "components were started although the restore failed" || ok
grep -q 'NOT started' "$T/out" && ok || bad "a failed restore did not say the components were left stopped"

# ---- a failed recovery stop: nothing restored, nothing started ------------------------------------------------
runq "$T/root" FAIL_OHS_APPLY=1 FAIL_STOP=1; rc=$?
[ "$rc" = 3 ] && ok || bad "a failed recovery stop exited $rc (want 3)"
grep -q '^dbclient rollback' "$T/calls.log" && bad "a restore ran although the recovery stop failed" || ok
grep -q '^ohs start' "$T/calls.log" && bad "components were started although the recovery stop failed" || ok

# ---- the outage's own stop fails (3/7): nothing is applied, and what was stopped is started again (T1135). A stop
#      that cannot prove the home stopped has already stopped some of it; leaving that down is an outage nobody asked for
runq "$T/root" FAIL_FIRST_STOP=1; rc=$?
[ "$rc" = 1 ] && ok || bad "a failed 3/7 stop exited $rc (want 1)"
grep -qE '^(java|wls|dbclient|ohs) apply' "$T/calls.log" && bad "an apply ran after the 3/7 stop failed" || ok
[ -n "$(line '^ohs start')" ] && ok || bad "a failed 3/7 stop left the components down: no start was tried"
grep -q 'started again' "$T/out" && ok || bad "a failed 3/7 stop did not say the components are up again: $(tail -2 "$T/out" | tr '\n' ' ')"
# ... and when that start fails too, the operator has a down service to fix by hand: exit 3, and say so
runq "$T/root" FAIL_FIRST_STOP=1 FAIL_START=1; rc=$?
[ "$rc" = 3 ] && ok || bad "a failed 3/7 stop whose start also failed exited $rc (want 3)"
grep -q 'DOWN' "$T/out" && ok || bad "a failed stop + failed start did not say components are down: $(tail -2 "$T/out" | tr '\n' ' ')"
# which one is down: a component the stop could not stop is still UP, so the message must come from a port check of
# every component, not from the failed start alone (T1145, Quark T1142)
start_n="$(line '^ohs start')"; verify_n="$(grep -n '^ohs verify' "$T/calls.log" | head -1 | cut -d: -f1)"
[ -n "$verify_n" ] && [ "$verify_n" -gt "${start_n:-0}" ] && ok || bad "a failed restart did not check which components answer: $(grep '^ohs' "$T/calls.log" | tr '\n' ' ')"
grep -q 'port check above' "$T/out" && ok || bad "the DOWN message does not point at the port check: $(tail -1 "$T/out")"

# ---- a signal mid-run (T1137): before the stop nothing has changed; after it, what was stopped is started again and
#      what was applied is restored - the same paths a failure takes - and the exit says which
runq "$T/root" SIGNAL_AT='java preflight'; rc=$?
[ "$rc" = 1 ] && ok || bad "a signal in preflight exited $rc (want 1)"
grep -qE '^(java|wls|dbclient|ohs) (backup|stop|apply|start)' "$T/calls.log" && bad "a changing call ran after a signal in preflight" || ok
grep -q 'interrupted' "$T/out" && grep -q 'nothing changed' "$T/out" && ok || bad "a signal in preflight did not say interrupted, nothing changed: $(tail -1 "$T/out")"
runq "$T/root" SIGNAL_AT='ohs stop'; rc=$?
[ "$rc" = 1 ] && ok || bad "a signal during the 3/7 stop exited $rc (want 1)"
grep -qE '^(java|wls|dbclient|ohs) apply' "$T/calls.log" && bad "an apply ran after a signal during the stop" || ok
[ -n "$(line '^ohs start')" ] && grep -q 'started again' "$T/out" && ok || bad "a signal during the stop left the components down: $(tail -1 "$T/out")"
runq "$T/root" SIGNAL_AT='dbclient apply'; rc=$?
[ "$rc" = 1 ] && ok || bad "a signal during an apply exited $rc (want 1)"
[ -n "$(line '^dbclient rollback')" ] && [ -n "$(line '^java rollback')" ] && [ -n "$(line '^ohs start')" ] && ok \
  || bad "a signal during an apply did not restore and start: $(grep -E 'rollback|restore|start' "$T/calls.log" | tr '\n' ' ')"
grep -qE '^(ohs apply|dbclient verify)' "$T/calls.log" && bad "the run went on applying after the signal" || ok
grep -q 'interrupted' "$T/out" && ok || bad "a signal during an apply did not say interrupted: $(tail -1 "$T/out")"
runq "$T/root" SIGNAL_AT='dbclient apply' FAIL_ROLLBACK=1; rc=$?
[ "$rc" = 3 ] && ok || bad "a signal during an apply whose restore failed exited $rc (want 3)"
# a signal while a failure is already being recovered does not start a second recovery inside the first
runq "$T/root" FAIL_DB_APPLY=1 SIGNAL_AT='dbclient rollback'; rc=$?
[ "$rc" = 1 ] && ok || bad "a signal during recovery exited $rc (want 1: the recovery finishes)"
[ "$(grep -c '^dbclient rollback' "$T/calls.log")" = 1 ] && [ "$(grep -c '^java rollback' "$T/calls.log")" = 1 ] && ok \
  || bad "a signal during recovery ran a restore twice: $(grep -E 'rollback|restore' "$T/calls.log" | tr '\n' ' ')"

# every start - a failed-stop restart, a recovery, a signalled recovery - gives the components default INT/TERM: an
# ignored signal is inherited, and a node manager or OHS started with TERM ignored cannot be stopped by the next
# outage (Nexus T1144)
for c in "FAIL_FIRST_STOP=1" "FAIL_DB_APPLY=1" "SIGNAL_AT=dbclient apply" "SIGNAL_AT=ohs stop"; do
  runq "$T/root" "$c"
  leaked="$(sort -u "$T/start-traps" | grep -vxF -f "$T/start-base")"
  [ -n "$(line '^ohs start')" ] && [ -z "$leaked" ] && ok || bad "$c: a start ran with signals ignored that the caller did not ignore: $(printf '%s' "$leaked" | tr '\n' ' ')"
done

# ---- the promises the header makes, each tested (Cerebro 23:05:15: a hook defined but never set is a
#      test that does not run) -----------------------------------------------------------------------------------
# a preflight failure refuses BEFORE any change
runq "$T/root" FAIL_JAVA_PREFLIGHT=1; rc=$?
[ "$rc" != 0 ] && ok || bad "a JDK preflight failure exited 0"
grep -qE '^(java|wls|dbclient|ohs) (backup|stop|apply|start)' "$T/calls.log" && bad "a changing call ran after a JDK preflight failure" || ok
grep -q 'nothing changed' "$T/out" && ok || bad "a JDK preflight failure did not say nothing changed"
runq "$T/root" FAIL_OHS_PREFLIGHT=1; rc=$?
[ "$rc" != 0 ] && ok || bad "an ohs preflight failure exited 0"
grep -qE '^(java|wls|dbclient|ohs) (backup|stop|apply|start)' "$T/calls.log" && bad "a changing call ran after an ohs preflight failure" || ok
runq "$T/root" FAIL_DB_PREFLIGHT=1; rc=$?
[ "$rc" != 0 ] && ok || bad "a dbclient preflight failure exited 0"
runq "$T/root" FAIL_WLS_PREFLIGHT=1; rc=$?
[ "$rc" != 0 ] && ok || bad "a wls preflight failure exited 0"

# a backup failure is all-or-nothing: nothing is stopped or applied
runq "$T/root" FAIL_BACKUP=1; rc=$?
[ "$rc" != 0 ] && ok || bad "a backup failure exited 0"
grep -qE '^(java|wls|dbclient|ohs) (stop|apply|start)' "$T/calls.log" && bad "a changing call ran after a backup failure" || ok
grep -q 'nothing changed' "$T/out" && ok || bad "a backup failure did not say nothing changed"

# the health check: if ohs-patch verify fails, the outage fails (a dead component must not pass)
runq "$T/root" FAIL_OHS_VERIFY=1; rc=$?
[ "$rc" != 0 ] && ok || bad "an ohs-patch verify failure exited 0 (a dead component would pass the outage)"
[ -n "$(line 'ohs start')" ] && ok || bad "the components were not started before their verify"
# a start failure recovers (java rollback)
runq "$T/root" FAIL_START=1; rc=$?
[ "$rc" = 1 ] && ok || bad "a start failure exited $rc (want 1)"
[ -n "$(line '^java rollback')" ] && ok || bad "a start failure did not recover"

# every opatch bundle that fails restores from the shared backup, not just webgate
for hook in FAIL_DBCLIENTRU FAIL_OSS; do
  runq "$T/root" "$hook=1"; rc=$?
  [ "$rc" = 1 ] && ok || bad "a $hook apply failure exited $rc (want 1)"
  grep -q "^dbclient rollback .*--run-dir $T/run/backup" "$T/calls.log" && ok || bad "a $hook failure did not restore from the shared backup"
done

# a recovery that cannot restore exits 3 and does not start. The restore that runs after a dc failure is the
# SHARED one (the wls home restore is skipped, T1562), so fail that one
runq "$T/root" FAIL_DB_APPLY=1 FAIL_ROLLBACK=1; rc=$?
[ "$rc" = 3 ] && ok || bad "a failed shared restore exited $rc (want 3)"
grep -q '^ohs start' "$T/calls.log" && bad "components were started although a recovery step failed" || ok

# ---- not a single folder present: refuse, no run dir, no child call -------------------------------------------
mkdir -p "$T/empty"
: >"$T/calls.log"
bash "$SCRIPT" --patch-root "$T/empty" --run-dir "$T/run-empty" --yes >"$T/out" 2>&1 && bad "an empty patch root exited 0" || ok
grep -q 'nothing to apply' "$T/out" && ok || bad "an empty patch root was not refused with 'nothing to apply'"

# ---- one confirmation: without --yes and no tty, refuse before any change --------------------------------------
: >"$T/calls.log"; rm -rf "$T/run" "$T/bk" "$T/wlsbk"; rm -f "$T/stop.ok" "$T/start.ok"
bash "$SCRIPT" --patch-root "$T/root" --run-dir "$T/run" </dev/null >"$T/out" 2>&1 && bad "outage without --yes on a non-tty exited 0" || ok
grep -q 'Non-interactive and --yes not given' "$T/out" && ok || bad "the no---yes refusal was not named"
grep -qE '^(java|wls|dbclient|ohs) (stop|apply|start|backup)' "$T/calls.log" && bad "a changing call ran although it refused without --yes" || ok

# ---- dry-run: every changing verb carries --dry-run -----------------------------------------------------------
: >"$T/calls.log"; rm -rf "$T/run" "$T/bk" "$T/wlsbk"
bash "$SCRIPT" --patch-root "$T/root" --run-dir "$T/run" --yes --dry-run >"$T/out" 2>&1 && ok || bad "dry-run failed: $(tail -3 "$T/out")"
miss="$(grep -E '^(java|wls|dbclient|ohs) (stop|apply|start|backup|rollback|restore)' "$T/calls.log" | grep -v -- '--dry-run')"
[ -z "$miss" ] && ok || bad "a changing call ran without --dry-run: $miss"

# ---- the options the composer hands each child are options that child really has -----------------------------
# The stubs accept anything, so a flag the real child rejects ("unknown option") sails through every test above:
# --remove-12c and --force both reached dbclient-upgrade.sh, which has neither. Run with every option set, then
# look each '--flag' a stub was called with up in the REAL script's own option parser.
: >"$T/calls.log"; rm -rf "$T/run" "$T/bk" "$T/wlsbk" "$T/stop.ok" "$T/start.ok" "$T/start.failed"
bash "$SCRIPT" --patch-root "$T/root" --run-dir "$T/run" --yes --dry-run --force --no-cacerts --java-home /j --oracle-home /o \
  --backup-dir "$T/bkd" --remove-12c 111,222,333 --keep-patches 444 >"$T/out" 2>&1 && ok || bad "run with every option set failed: $(tail -3 "$T/out")"
grep -q '^dbclient .*--remove-patches 111,222,333' "$T/calls.log" && ok || bad "--remove-12c did not reach the installer as --remove-patches 111,222,333: $(grep '^dbclient' "$T/calls.log" | head -2)"
grep -q '^dbclient .*--keep-patches 444' "$T/calls.log" && ok || bad "--keep-patches did not reach the installer"
# ohs-patch checks free space on its backup dir and defaults to /u01/backup: without --backup-dir it reads the wrong
# disk, or stops preflight UNKNOWN on a box with no /u01/backup (T1114, Louie #15840)
grep -q '^ohs preflight ' "$T/calls.log" && ! grep '^ohs preflight ' "$T/calls.log" | grep -qv -- "--backup-dir $T/bkd" && ok \
  || bad "--backup-dir did not reach every ohs-patch preflight: $(grep '^ohs preflight' "$T/calls.log" | head -2)"
# the installer is staged, so every opatch preflight gets --client-19c-pending (the 19c client comes first in this
# outage); no opatch apply does - apply re-checks on the 19c home (field run 12 Nov 2026, 40005842 at 1/7)
grep -q '^ohs preflight ' "$T/calls.log" && ! grep '^ohs preflight ' "$T/calls.log" | grep -qv -- '--client-19c-pending' && ok \
  || bad "--client-19c-pending did not reach every ohs-patch preflight: $(grep '^ohs preflight' "$T/calls.log" | head -2)"
! grep -E '^ohs (apply|verify|stop|start|rollback|backup) ' "$T/calls.log" | grep -q -- '--client-19c-pending' && ok || bad "--client-19c-pending leaked past preflight"
REAL_DIR="$(cd "$(dirname "$SCRIPT")/.." && pwd)"
for pair in "java:java-patch/java-patch.sh" "wls:wls-patch/wls-patch.sh" "dbclient:dbclient-upgrade/dbclient-upgrade.sh" "ohs:ohs-patch/ohs-patch.sh"; do
  who="${pair%%:*}"; real="$REAL_DIR/${pair#*:}"
  flags="$(grep "^$who " "$T/calls.log" | tr ' ' '\n' | grep '^--[a-z]' | sort -u)"
  [ -n "$flags" ] && ok || bad "no $who call recorded - the contract check below would pass on nothing"
  unknown=""
  for f in $flags; do grep -qE -- "(^|[ |(])$f([|)])" "$real" || unknown="$unknown $f"; done
  [ -z "$unknown" ] && ok || bad "ohs-quarter passes $who options its script (${pair#*:}) has no arm for:$unknown"
done

echo "ohs-quarter gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
