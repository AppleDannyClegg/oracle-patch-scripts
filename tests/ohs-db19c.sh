#!/usr/bin/env bash
# ohs-db19c gate: the composition and its order, with stub children that log their argv. It pins:
#   - preflight of every present folder BEFORE the stop, installer preflight gets --will-stop
#   - ONE backup, stop once, apply in order installer -> DBCLIENT RU -> OSS -> WebGate -> OHS, start once, verify
#   - every apply is given --backup-run <the one shared run dir> (the whole point of the composition)
#   - a failure after the backup recovers through the installer's restore_all from that SAME run dir, then starts
#   - a failed restore exits 3 and does NOT start; a missing/empty folder is skipped
#   - dry-run reaches no changing child verb; without --yes on a non-tty it refuses before any change
#
# Usage: tests/ohs-db19c.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/patching/ohs-db19c/ohs-db19c.sh"
[ -f "$SCRIPT" ] || { echo "ohs-db19c gate: $SCRIPT not found"; exit 2; }

T="$(cd "$(mktemp -d /tmp/odc.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# a stub child: logs 'dbclient|ohs <args>' to the calls log; a backup writes the shared run dir's four keys and
# the two tarballs the child apply requires; a named FAIL_* makes the matching verb fail. __T__ becomes $T.
sed "s|__T__|$T|g" >"$T/stub-child" <<'STUB'
#!/bin/sh
who="$(basename "$0")"; case "$who" in stub-dbclient) who=dbclient;; stub-ohs) who=ohs;; esac
printf '%s %s\n' "$who" "$*" >>"__T__/calls.log"
rd=""; prev=""
for a in "$@"; do [ "$prev" = "--run-dir" ] && rd="$a"; prev="$a"; done
case "$1" in
  preflight)
    [ "$who" = dbclient ] && [ -n "${FAIL_DB_PREFLIGHT:-}" ] && exit 1
    [ "$who" = ohs ] && [ -n "${FAIL_OHS_PREFLIGHT:-}" ] && exit 1 ;;
  backup)
    [ -n "${FAIL_BACKUP:-}" ] && exit 1
    if [ -n "$rd" ]; then mkdir -p "$rd"; {
      echo "oracle_home=/u01/ohs"; echo "backup=ok"; echo "backup_dir=__T__/bk"; echo "pre_patches=1 2 3"
    } >>"$rd/state"; mkdir -p "__T__/bk"; : >"__T__/bk/home.tgz"; : >"__T__/bk/oraInventory.tgz"; fi ;;
  stop) [ -n "${FAIL_STOP:-}" ] && [ -e "__T__/stop.ok" ] && exit 1; : >"__T__/stop.ok" ;;
  apply)
    [ "$who" = dbclient ] && [ -n "${FAIL_DB_APPLY:-}" ] && exit 1
    case "$2" in */dbclientru) [ -n "${FAIL_DBCLIENTRU:-}" ] && exit 1;; esac
    case "$2" in */oss) [ -n "${FAIL_OSS:-}" ] && exit 1;; esac
    case "$2" in */webgate) [ -n "${FAIL_WEBGATE:-}" ] && exit 1;; esac
    case "$2" in */ohs) [ -n "${FAIL_OHS_APPLY:-}" ] && exit 1;; esac ;;
  start) [ -n "${FAIL_START:-}" ] && exit 1 ;;
  verify) [ -n "${FAIL_VERIFY:-}" ] && exit 1 ;;
  rollback) [ -n "${FAIL_ROLLBACK:-}" ] && exit 1 ;;
esac
exit 0
STUB
chmod +x "$T/stub-child"
stub() { cp "$T/stub-child" "$1"; chmod +x "$1"; }
stub "$T/stub-dbclient"; stub "$T/stub-ohs"
export OHS_DB19C_DBCLIENT="$T/stub-dbclient" OHS_DB19C_OHS_PATCH="$T/stub-ohs"

mkroot() { # <dir> [installer] [dbclientru] [oss] [webgate] [ohs]
  local d="$1"; mkdir -p "$d"
  for s in "dbclient:${2:-1}" "dbclientru:${3:-1}" "oss:${4:-1}" "webgate:${5:-1}" "ohs:${6:-1}"; do
    [ "${s#*:}" = 1 ] && { mkdir -p "$d/${s%%:*}"; : >"$d/${s%%:*}/patch.zip"; }
  done
}
runq() { # <root> [env assignments...]
  local root="$1"; shift
  : >"$T/calls.log"; rm -rf "$T/run" "$T/bk"; rm -f "$T/stop.ok"
  env "$@" bash "$SCRIPT" --patch-root "$root" --run-dir "$T/run" --yes >"$T/out" 2>&1
}
line() { grep -n "$1" "$T/calls.log" | head -1 | cut -d: -f1; }
# the line of the apply whose patch dir has this basename, whatever follows it
aapply_line() { awk -v s="$1" '$2=="apply" { n=split($3,a,"/"); if (a[n]==s) { print NR; exit } }' "$T/calls.log"; }

# ---- happy path: order, --will-stop, one backup, stop once, start once, --backup-run -------------------------
mkroot "$T/root"
runq "$T/root" && ok || bad "happy path failed: $(tail -3 "$T/out")"
[ -n "$(line 'dbclient preflight')" ] && grep -q 'dbclient preflight .*--will-stop' "$T/calls.log" && ok || bad "dbclient preflight did not get --will-stop"
grep -q '^dbclient apply .*--will-stop' "$T/calls.log" && bad "apply was given --will-stop (it must not be)" || ok
stop="$(line 'ohs stop')"; [ -n "$stop" ] && ok || bad "no ohs stop"
for p in 'dbclient preflight' 'ohs preflight' 'ohs stop' 'dbclient apply' 'ohs apply' 'ohs start' 'dbclient verify' 'ohs verify'; do
  [ -n "$(line "$p")" ] || bad "missing call: $p"
done
# every preflight before the stop; every apply after it
[ -n "$(line 'dbclient preflight')" ] && [ "$(line 'dbclient preflight')" -lt "$stop" ] && ok || bad "a preflight ran after the stop"
lastpre="$(grep -n ' preflight' "$T/calls.log" | tail -1 | cut -d: -f1)"
[ -n "$lastpre" ] && [ "$lastpre" -lt "$stop" ] && ok || bad "an ohs preflight ran after the stop"
[ "$(line 'dbclient apply')" -gt "$stop" ] && ok || bad "the installer apply ran before the stop"
# exactly one backup and one stop and one start
[ "$(grep -c ' backup ' "$T/calls.log")" = 1 ] && ok || bad "backup not exactly once: [$(grep ' backup ' "$T/calls.log")]"
[ "$(grep -c '^ohs stop' "$T/calls.log")" = 1 ] && ok || bad "ohs stop not exactly once"
[ "$(grep -c '^ohs start' "$T/calls.log")" = 1 ] && ok || bad "ohs start not exactly once"
# apply order: installer -> dbclientru -> oss -> webgate -> ohs
da="$(aapply_line dbclient)"; ru="$(aapply_line dbclientru)"; oss="$(aapply_line oss)"; wg="$(aapply_line webgate)"; oh="$(aapply_line ohs)"
[ -n "$da" ] && [ -n "$ru" ] && [ -n "$oss" ] && [ -n "$wg" ] && [ -n "$oh" ] && \
  [ "$da" -lt "$ru" ] && [ "$ru" -lt "$oss" ] && [ "$oss" -lt "$wg" ] && [ "$wg" -lt "$oh" ] && ok || \
  bad "apply order is not installer -> dbclientru -> oss -> webgate -> ohs (da=$da ru=$ru oss=$oss wg=$wg oh=$oh)"
# every apply carries --backup-run (the shared restore point)
miss="$(grep -E ' apply ' "$T/calls.log" | grep -v -- '--backup-run')"
[ -z "$miss" ] && ok || bad "an apply ran without --backup-run: $miss"
# the shared run dir is one path, used by the backup and every apply
shared="$(sed -n 's/.*--backup-run \([^ ]*\).*/\1/p' "$T/calls.log" | sort -u)"
[ "$(printf '%s\n' "$shared" | wc -l | tr -d ' ')" = 1 ] && [ -n "$shared" ] && ok || bad "applies did not share one run dir: [$shared]"

# ---- a missing/empty folder is skipped, not failed -----------------------------------------------------------
mkroot "$T/root2" 1 1 0 0 0
runq "$T/root2" && ok || bad "an outage without webgate/ and ohs/ failed: $(tail -3 "$T/out")"
[ -z "$(aapply_line webgate)" ] && [ -z "$(aapply_line ohs)" ] && ok || bad "a skipped folder was applied"
grep -q 'webgate/: missing' "$T/out" && ok || bad "the skipped webgate/ folder was not named"

# ---- installer apply failure: recover via the installer's restore_all from the SHARED dir, then start ---------
runq "$T/root" FAIL_DB_APPLY=1; rc=$?
[ "$rc" = 1 ] && ok || bad "an installer apply failure exited $rc (want 1)"
grep -q "^dbclient rollback .*--run-dir $T/run/backup" "$T/calls.log" && ok || bad "recovery did not run dbclient rollback from the shared backup: [$(grep rollback "$T/calls.log")]"
[ "$(line 'ohs stop')" -lt "$(line 'dbclient rollback')" ] && ok || bad "recovery did not stop before the restore"
[ -n "$(line 'ohs start')" ] && [ "$(line 'dbclient rollback')" -lt "$(line 'ohs start')" ] && ok || bad "recovery did not start after the restore"
grep -q '^ohs rollback' "$T/calls.log" && bad "recovery used ohs rollback instead of the installer's restore" || ok

# ---- an opatch apply failure after the installer succeeded: same restore, still from the SHARED dir ------------
runq "$T/root" FAIL_WEBGATE=1; rc=$?
[ "$rc" = 1 ] && ok || bad "a webgate apply failure exited $rc (want 1)"
grep -q "^dbclient rollback .*--run-dir $T/run/backup" "$T/calls.log" && ok || bad "recovery after an opatch failure did not restore from the shared backup"
grep -q "^dbclient apply" "$T/calls.log" && ok || bad "the installer did not run before the opatch failure"

# ---- a failed restore exits 3 and does NOT start -------------------------------------------------------------
runq "$T/root" FAIL_OHS_APPLY=1 FAIL_ROLLBACK=1; rc=$?
[ "$rc" = 3 ] && ok || bad "a failed restore exited $rc (want 3)"
grep -q '^ohs start' "$T/calls.log" && bad "components were started although the restore failed" || ok
grep -q 'NOT started' "$T/out" && ok || bad "a failed restore did not say the components were left stopped"

# ---- the recovery stop itself fails: nothing restored, nothing started (the FIRST stop still succeeded) ---------
runq "$T/root" FAIL_OHS_APPLY=1 FAIL_STOP=1; rc=$?
[ "$rc" = 3 ] && ok || bad "a failed recovery stop exited $rc (want 3)"
grep -q '^dbclient rollback' "$T/calls.log" && bad "a restore ran although the recovery stop failed" || ok
grep -q '^ohs start' "$T/calls.log" && bad "components were started although the recovery stop failed" || ok

# ---- no installer: one backup is still taken through ohs-patch, and recovery uses ohs rollback ------------------
mkroot "$T/root3" 0 1 1 1 1
runq "$T/root3" && ok || bad "an outage without the installer failed: $(tail -3 "$T/out")"
grep -q '^ohs backup' "$T/calls.log" && ok || bad "with no installer, ohs-patch did not take the one backup"
[ "$(grep -c ' backup ' "$T/calls.log")" = 1 ] && ok || bad "with no installer, backup was not exactly once"

# ---- one confirmation: without --yes and no tty, refuse before any change --------------------------------------
: >"$T/calls.log"; rm -rf "$T/run" "$T/bk"; rm -f "$T/stop.ok"
bash "$SCRIPT" --patch-root "$T/root" --run-dir "$T/run" </dev/null >"$T/out" 2>&1 && bad "outage without --yes on a non-tty exited 0" || ok
grep -q 'Non-interactive and --yes not given' "$T/out" && ok || bad "the no---yes refusal was not named"
grep -qE '^(dbclient|ohs) (stop|apply|start|backup)' "$T/calls.log" && bad "a changing call ran although it refused without --yes" || ok

# ---- dry-run: every changing verb carries --dry-run -----------------------------------------------------------
: >"$T/calls.log"; rm -rf "$T/run" "$T/bk"
bash "$SCRIPT" --patch-root "$T/root" --run-dir "$T/run" --yes --dry-run >"$T/out" 2>&1 && ok || bad "dry-run failed: $(tail -3 "$T/out")"
miss="$(grep -E '^(dbclient|ohs) (stop|apply|start|backup|rollback)' "$T/calls.log" | grep -v -- '--dry-run')"
[ -z "$miss" ] && ok || bad "a changing call ran without --dry-run: $miss"

echo "ohs-db19c gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
