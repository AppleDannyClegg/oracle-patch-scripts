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
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# a stub child: logs 'java|wls|dbclient|ohs <args>'; a shared backup writes the run dir's four keys and the two
# tarballs the child apply requires; a named FAIL_* makes the matching verb fail. __T__ becomes $T.
sed "s|__T__|$T|g" >"$T/stub-child" <<'STUB'
#!/bin/sh
who="$(basename "$0")"; case "$who" in stub-java) who=java;; stub-wls) who=wls;; stub-dbclient) who=dbclient;; stub-ohs) who=ohs;; esac
printf '%s %s\n' "$who" "$*" >>"__T__/calls.log"
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
  stop) [ -n "${FAIL_STOP:-}" ] && [ -e "__T__/stop.ok" ] && exit 1; : >"__T__/stop.ok" ;;
  apply)
    [ "$who" = java ] && [ -n "${FAIL_JAVA_APPLY:-}" ] && exit 1
    [ "$who" = wls ] && [ -n "${FAIL_WLS_APPLY:-}" ] && exit 1
    [ "$who" = dbclient ] && [ -n "${FAIL_DB_APPLY:-}" ] && exit 1
    case "$2" in
      */dbclientru) [ -n "${FAIL_DBCLIENTRU:-}" ] && exit 1;;
      */webgate) [ -n "${FAIL_WEBGATE:-}" ] && exit 1;;
      */oss) [ -n "${FAIL_OSS:-}" ] && exit 1;;
      */ohs) [ -n "${FAIL_OHS_APPLY:-}" ] && exit 1;;
    esac ;;
  start) [ -n "${FAIL_START:-}" ] && exit 1 ;;
  verify) [ -n "${FAIL_VERIFY:-}" ] && exit 1 ;;
  rollback) [ -n "${FAIL_ROLLBACK:-}" ] && exit 1 ;;
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
  if [ "${9:-0}" = 1 ]; then for f in jdbc libovd fmwthirdparty perl libdms2 libiau; do mkdir -p "$d/$f"; : >"$d/$f/p.zip"; done; fi
}
runq() { # <root> [env assignments...]
  local root="$1"; shift
  : >"$T/calls.log"; rm -rf "$T/run" "$T/bk" "$T/wlsbk"; rm -f "$T/stop.ok"
  env "$@" bash "$SCRIPT" --patch-root "$root" --run-dir "$T/run" --yes >"$T/out" 2>&1
}
line() { grep -n "$1" "$T/calls.log" | head -1 | cut -d: -f1; }
# the line of the apply whose patch dir has this basename, whatever follows it
aapply_line() { awk -v s="$1" '$2=="apply" { n=split($3,a,"/"); if (a[n]==s) { print NR; exit } }' "$T/calls.log"; }

# ---- happy path: order, --will-stop, one backup phase, stop once, start once, --backup-run --------------------
mkroot "$T/root" 1 1 1 1 1 1 1 1
runq "$T/root" && ok || bad "happy path failed: $(tail -3 "$T/out")"
grep -q 'java preflight .*--will-stop' "$T/calls.log" && ok || bad "java preflight did not get --will-stop"
grep -q 'dbclient preflight .*--will-stop' "$T/calls.log" && ok || bad "dbclient preflight did not get --will-stop"
grep -q '^java apply .*--will-stop' "$T/calls.log" && bad "apply was given --will-stop (it must not be)" || ok
stop="$(line 'ohs stop')"; [ -n "$stop" ] && ok || bad "no ohs stop"
# every preflight before the stop; every apply after it
lastpre="$(grep -n ' preflight' "$T/calls.log" | tail -1 | cut -d: -f1)"
[ -n "$lastpre" ] && [ "$lastpre" -lt "$stop" ] && ok || bad "a preflight ran after the stop"
[ "$(line 'java apply')" -gt "$stop" ] && ok || bad "the JDK apply ran before the stop"
# one backup phase: one java backup, one wls backup, one shared backup (dbclient)
[ "$(grep -c '^java backup' "$T/calls.log")" = 1 ] && [ "$(grep -c '^wls backup' "$T/calls.log")" = 1 ] && [ "$(grep -c '^dbclient backup' "$T/calls.log")" = 1 ] && ok || bad "the backup phase is not one java + one wls + one shared: [$(grep ' backup' "$T/calls.log")]"
[ "$(grep -c '^ohs stop' "$T/calls.log")" = 1 ] && ok || bad "ohs stop not exactly once"
[ "$(grep -c '^ohs start' "$T/calls.log")" = 1 ] && ok || bad "ohs start not exactly once"
# apply order: java -> wls -> dbclient -> dbclientru -> webgate -> oss -> ohs -> jdbc -> libovd -> fmwthirdparty -> perl -> libdms2 -> libiau
ja="$(line '^java apply')"; wa="$(line '^wls apply')"; da="$(line '^dbclient apply')"
ru="$(aapply_line dbclientru)"; wg="$(aapply_line webgate)"; oss="$(aapply_line oss)"; oh="$(aapply_line ohs)"
jb="$(aapply_line jdbc)"; lo="$(aapply_line libovd)"; ft="$(aapply_line fmwthirdparty)"; pe="$(aapply_line perl)"; dm="$(aapply_line libdms2)"; ia="$(aapply_line libiau)"
all="$ja $wa $da $ru $wg $oss $oh $jb $lo $ft $pe $dm $ia"
for v in $all; do [ -n "$v" ] || bad "an expected apply is missing (chain: $all)"; done
prev=0; good=1
for v in $all; do [ "$v" -gt "$prev" ] || good=0; prev="$v"; done
[ "$good" = 1 ] && ok || bad "apply order is not java -> wls -> dbclient -> dbclientru -> webgate -> oss -> ohs -> extras (chain: $all)"
# every dbclient/opatch apply carries --backup-run (the shared restore point); java/wls do not
miss="$(awk '$1=="dbclient" && $2=="apply" || $1=="ohs" && $2=="apply"' "$T/calls.log" | grep -v -- '--backup-run')"
[ -z "$miss" ] && ok || bad "an apply ran without --backup-run: $miss"
shared="$(sed -n 's/.*--backup-run \([^ ]*\).*/\1/p' "$T/calls.log" | sort -u)"
[ "$(printf '%s\n' "$shared" | wc -l | tr -d ' ')" = 1 ] && [ -n "$shared" ] && ok || bad "applies did not share one run dir: [$shared]"

# ---- a missing/empty folder is skipped, not failed -----------------------------------------------------------
mkroot "$T/root2" 1 1 1 1 0 0 0 0
runq "$T/root2" && ok || bad "an outage without webgate/oss/ohs failed: $(tail -3 "$T/out")"
[ -z "$(aapply_line webgate)" ] && [ -z "$(aapply_line ohs)" ] && ok || bad "a skipped folder was applied"
grep -q 'webgate/: missing' "$T/out" && ok || bad "the skipped webgate/ folder was not named"

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

# ---- dbclient apply failure: shared restore + wls restore + java rollback, then start --------------------------
runq "$T/root" FAIL_DB_APPLY=1; rc=$?
[ "$rc" = 1 ] && ok || bad "a dbclient apply failure exited $rc (want 1)"
grep -q "^dbclient rollback .*--run-dir $T/run/backup" "$T/calls.log" && ok || bad "recovery did not run dbclient rollback from the shared backup"
[ -n "$(line '^wls restore')" ] && [ -n "$(line '^java rollback')" ] && ok || bad "a dbclient failure did not restore wls and roll back java"
[ "$(line 'ohs stop')" -lt "$(line 'dbclient rollback')" ] && ok || bad "recovery did not stop before the restore"

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

# ---- not a single folder present: refuse, no run dir, no ffild call -------------------------------------------
mkdir -p "$T/empty"
: >"$T/calls.log"
bash "$SCRIPT" --patch-root "$T/empty" --run-dir "$T/run-empty" --yes >"$T/out" 2>&1 && bad "an empty patch root exited 0" || ok
grep -q 'nothing to apply' "$T/out" && ok || bad "an empty patch root was not refused with 'nothing to apply'"

# ---- one confirmation: without --yes and no tty, refuse before any change --------------------------------------
: >"$T/calls.log"; rm -rf "$T/run" "$T/bk" "$T/wlsbk"; rm -f "$T/stop.ok"
bash "$SCRIPT" --patch-root "$T/root" --run-dir "$T/run" </dev/null >"$T/out" 2>&1 && bad "outage without --yes on a non-tty exited 0" || ok
grep -q 'Non-interactive and --yes not given' "$T/out" && ok || bad "the no---yes refusal was not named"
grep -qE '^(java|wls|dbclient|ohs) (stop|apply|start|backup)' "$T/calls.log" && bad "a changing call ran although it refused without --yes" || ok

# ---- dry-run: every changing verb carries --dry-run -----------------------------------------------------------
: >"$T/calls.log"; rm -rf "$T/run" "$T/bk" "$T/wlsbk"
bash "$SCRIPT" --patch-root "$T/root" --run-dir "$T/run" --yes --dry-run >"$T/out" 2>&1 && ok || bad "dry-run failed: $(tail -3 "$T/out")"
miss="$(grep -E '^(java|wls|dbclient|ohs) (stop|apply|start|backup|rollback|restore)' "$T/calls.log" | grep -v -- '--dry-run')"
[ -z "$miss" ] && ok || bad "a changing call ran without --dry-run: $miss"

echo "ohs-quarter gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
