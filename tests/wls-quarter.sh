#!/usr/bin/env bash
# wls-quarter gate: the composition and its order, with stub children that log their argv. It pins:
#   - preflight of every present folder BEFORE the stop, java-patch preflight gets --will-stop
#   - stop once, then JDK -> SPB -> wls applies, then start once, then verify
#   - a failure recovers in reverse (wls restore, then java rollback) and starts only when both recovered
#   - a missing/empty folder is skipped; dry-run reaches no changing child verb
#
# Usage: tests/wls-quarter.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
QUARTER="$ROOT/patching/wls-quarter/wls-quarter.sh"
[ -f "$QUARTER" ] || { echo "wls-quarter gate: $QUARTER not found"; exit 2; }

T="$(cd "$(mktemp -d /tmp/wlq.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# a stub child: logs 'java|wls <args>' to $CALLS and writes run-dir state for apply; fails when told to
cat >"$T/stub-child" <<EOF
#!/bin/sh
who="\$(basename "\$0")"; case "\$who" in stub-java) who=java;; stub-wls) who=wls;; esac
printf '%s %s\n' "\$who" "\$*" >>"$T/calls.log"
rd=""; prev=""
for a in "\$@"; do [ "\$prev" = "--run-dir" ] && rd="\$a"; prev="\$a"; done
case "\$1" in
  apply)
    case "\$2" in
      */spb) [ -n "\${FAIL_WLS_SPB:-}" ] && exit 1 ;;
      */wls) [ -n "\${FAIL_WLS_WLS:-}" ] && exit 1 ;;
    esac
    [ "\$who" = java ] && [ -n "\${FAIL_JAVA_APPLY:-}" ] && { [ -n "\$rd" ] && echo "old_jdk=/tmp/x.old-1" >>"\$rd/state"; exit 1; }
    [ -n "\$rd" ] && echo "apply=ok" >>"\$rd/state" ;;
  restore) [ -n "\${FAIL_WLS_RESTORE:-}" ] && exit 1 ;;
  rollback) [ -n "\${FAIL_JAVA_ROLLBACK:-}" ] && exit 1 ;;
  verify) [ "\$who" = java ] && [ -n "\${FAIL_JAVA_VERIFY:-}" ] && exit 1 ;;
  start) [ -n "\${FAIL_WLS_START:-}" ] && exit 1 ;;
  stop) [ -n "\${FAIL_WLS_STOP:-}" ] && [ -e "$T/stop.ok" ] && exit 1; : >"$T/stop.ok" ;;
esac
exit 0
EOF
chmod +x "$T/stub-child"
stub() { cp "$T/stub-child" "$1"; chmod +x "$1"; }
stub "$T/stub-java"; stub "$T/stub-wls"
export WLS_QUARTER_JAVA_PATCH="$T/stub-java" WLS_QUARTER_WLS_PATCH="$T/stub-wls"

mkroot() { # <dir> [jdk] [spb] [wls]
  local d="$1"; mkdir -p "$d"
  [ "${2:-1}" = 1 ] && { mkdir -p "$d/jdk"; : >"$d/jdk/jdk-1.8.0_511_linux-x64_bin.tar.gz"; }
  [ "${3:-1}" = 1 ] && { mkdir -p "$d/spb"; : >"$d/spb/spb.zip"; }
  [ "${4:-1}" = 1 ] && { mkdir -p "$d/wls"; : >"$d/wls/psu.zip"; }
}
runq() { # <root> [env assignments...]  -> runs the quarter, returns rc, logs to $T/out
  local root="$1"; shift
  : >"$T/calls.log"; rm -rf "$T/run"; rm -f "$T/stop.ok"
  env "$@" bash "$QUARTER" --patch-root "$root" --run-dir "$T/run" --yes >"$T/out" 2>&1
}
line() { grep -n "$1" "$T/calls.log" | head -1 | cut -d: -f1; }
apply_line() { awk -v s="$1" '$1=="wls" && $2=="apply" && $3 ~ (s "$") {print NR; exit}' "$T/calls.log"; }

# ---- happy path: order, --will-stop, stop once, start once ------------------------------------------------
mkroot "$T/root"
runq "$T/root" && ok || bad "happy path failed: $(tail -3 "$T/out")"
[ "$(line 'java preflight')" ] && grep -q 'java preflight .*--will-stop' "$T/calls.log" && ok || bad "java preflight did not get --will-stop"
grep -q '^java apply .*--will-stop' "$T/calls.log" && bad "apply was given --will-stop (it must not be)" || ok
# every preflight before the stop; every apply after it
stop="$(line 'wls stop')"; [ -n "$stop" ] && ok || bad "no wls stop"
for p in 'java preflight' 'wls preflight' 'wls stop' 'java apply' 'wls apply' 'wls start' 'java verify' 'wls verify'; do
  [ -n "$(line "$p")" ] || bad "missing call: $p"
done
[ "$(line 'java preflight')" -lt "$stop" ] && [ "$(line 'wls preflight')" -lt "$stop" ] && ok || bad "a preflight ran after the stop"
[ "$(line 'java apply')" -gt "$stop" ] && [ "$(line 'wls apply')" -gt "$stop" ] && ok || bad "an apply ran before the stop"
[ "$(grep -c '^wls stop' "$T/calls.log")" = 1 ] && ok || bad "wls stop not called exactly once"
[ "$(grep -c '^wls start' "$T/calls.log")" = 1 ] && ok || bad "wls start not called exactly once"
# order: java apply before wls apply spb before wls apply wls
ja="$(line 'java apply')"; spb="$(apply_line spb)"; ww="$(apply_line wls)"
[ -n "$ja" ] && [ -n "$spb" ] && [ -n "$ww" ] && [ "$ja" -lt "$spb" ] && [ "$spb" -lt "$ww" ] && ok || bad "apply order is not JDK -> SPB -> wls"
grep -q '^wls backup' "$T/calls.log" && grep -q '^java backup' "$T/calls.log" && ok || bad "a backup is missing"

# ---- missing wls/ is skipped, not failed ------------------------------------------------------------------
mkroot "$T/root2" 1 1 0
runq "$T/root2" && ok || bad "a quarter without wls/ failed: $(tail -3 "$T/out")"
[ -z "$(apply_line wls)" ] && ok || bad "wls apply ran with no wls/"
grep -q 'wls/: missing' "$T/out" && ok || bad "the skipped wls/ folder was not named"

# ---- SPB failure: restore then java rollback, start after both -------------------------------------------------
runq "$T/root" FAIL_WLS_SPB=1; rc=$?
[ "$rc" != 0 ] && ok || bad "an SPB apply failure exited 0"
r="$(line 'wls restore')"; jr="$(line 'java rollback')"; st="$(line 'wls start')"
[ -n "$r" ] && [ -n "$jr" ] && ok || bad "recovery did not call wls restore and java rollback"
[ "$r" -lt "$jr" ] && ok || bad "recovery is not in reverse order (wls restore then java rollback)"
[ -n "$st" ] && [ "$st" -gt "$jr" ] && ok || bad "start did not run after both recoveries"
grep -q '^wls rollback' "$T/calls.log" && bad "recovery used wls rollback (cumulative nrollback)" || ok

# ---- SPB ok, wls/ fails: ONE pre-SPB backup, restore, no nrollback (Baymax) ---------------------------------
runq "$T/root" FAIL_WLS_WLS=1; rc=$?
[ "$rc" != 0 ] && ok || bad "a wls/ failure after a good SPB exited 0"
[ "$(grep -c '^wls backup' "$T/calls.log")" = 1 ] && ok || bad "wls backup was called $(grep -c '^wls backup' "$T/calls.log") times - a second one would repoint backup_dir past the SPB"
grep -Eq '^wls apply [^ ]*/spb' "$T/calls.log" && ok || bad "the SPB apply did not run before the wls/ failure"
[ -n "$(line 'wls restore')" ] && ok || bad "a wls/ failure after a good SPB did not restore"
grep -q '^wls rollback' "$T/calls.log" && bad "recovery used wls rollback (cumulative nrollback)" || ok

# ---- recovery fails: no start ---------------------------------------------------------------------------------
runq "$T/root" FAIL_WLS_SPB=1 FAIL_WLS_RESTORE=1; rc=$?
[ "$rc" != 0 ] && ok || bad "a failed recovery exited 0"
grep -q '^wls start' "$T/calls.log" && bad "servers were started although recovery failed" || ok
grep -q 'servers NOT started' "$T/out" && ok || bad "a failed recovery did not say the servers were left stopped"

# ---- recovery stops the servers BEFORE undoing anything (Baymax P2) ------------------------------------------
mkroot "$T/rootjdk" 1 0 0
runq "$T/rootjdk" FAIL_JAVA_VERIFY=1; rc=$?
[ "$rc" != 0 ] && ok || bad "a JDK-only verify failure exited 0"
v="$(line 'java verify')"; jr="$(line 'java rollback')"
[ -n "$v" ] && [ -n "$jr" ] && awk -v a="$v" -v b="$jr" 'NR>a && NR<b && /^wls stop/ {f=1} END{exit !f}' "$T/calls.log" && ok || bad "recovery did not stop the servers before the java rollback (verify=$v rollback=$jr)"

# recovery stop itself fails: nothing is undone and nothing is started
runq "$T/root" FAIL_WLS_WLS=1 FAIL_WLS_STOP=1; rc=$?
[ "$rc" != 0 ] && ok || bad "a recovery-stop failure exited 0"
[ -z "$(line 'wls restore')" ] && ok || bad "a restore ran although the recovery stop failed"
[ -z "$(line 'java rollback')" ] && ok || bad "a rollback ran although the recovery stop failed"
grep -q 'servers are NOT started' "$T/out" && ok || bad "a failed recovery stop did not say nothing was started"

# ---- dry-run: every changing verb carries --dry-run ----------------------------------------------------------
: >"$T/calls.log"; rm -rf "$T/run"
bash "$QUARTER" --patch-root "$T/root" --run-dir "$T/run" --yes --dry-run >"$T/out" 2>&1 && ok || bad "dry-run failed: $(tail -3 "$T/out")"
miss="$(grep -E '^(java|wls) (stop|apply|start|backup|restore|rollback)' "$T/calls.log" | grep -v -- '--dry-run')"
[ -z "$miss" ] && ok || bad "a changing call ran without --dry-run: $miss"

echo "wls-quarter gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
