#!/usr/bin/env bash
# Behavioural gate for false success: every change command of every script is run for real (--yes, no --dry-run) on a
# PATH of stub tools, with HOME and every path the script touches under a temp dir, and the FIRST call that could
# change something (DDL, DML, flashback, a PL/SQL block - exec/begin, whatever it does - a changing tool verb) fails - the stub logs 'FAILED <tool> <argv>', prints an error (ORA-00600 for sqlplus/sql) and exits 1; every later
# changing call fails the same way (the tool is broken), probes (select, --version, config get ...) keep answering.
# A script that then exits 0, or records success in its run dir (applied*=, verified=1, rolled_back=1, restored*=,
# opatch_upgraded=1, deleted=, <step>=ok, pool_<p>=ok, exported_<c>=N ok, 0 failed) claimed a change that did not happen: FAIL. NOT-EXERCISED:
# no changing call was reached (the command only reads, or ended before it): counted and listed, never a pass.
# tests/dry-run-env/<tool>.sh (shared with tests/dry-run-gate.sh) is sourced first, with CMD set to the command; it may set
# FAIL_<cmd> (the call to fail instead of the first changing one, a regex on 'tool argv | stdin') and OK / OK_<cmd>
# (the success lines to forbid in state, a regex). Only lines ADDED to a state file by the run count, so a seeded
# state may carry applied= or pool_x=ok. Needs no database.
# Usage: tests/false-success-gate.sh [script...] | --selftest (the success-line regex against the lines it must and must not catch)
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
T="$(mktemp -d)"; STUB="$T/stub"; export DRY_LOG="$T/log" ANSWERS="$T/answers" FAIL_RE=""; mkdir -p "$STUB"; : >"$ANSWERS"
trap 'rm -rf "$T"' EXIT
alarm() { perl -e 'alarm shift; exec @ARGV' "$@"; }
# a changing call, on one line 'tool argv | stdin': the same verbs tests/dry-run-gate.sh forbids under --dry-run
CHANGE_RE='^(sqlplus|sql) .*\| *(.*; *)?(alter +(pluggable|database|user|system|tablespace)|drop|create|flashback|shutdown|startup|truncate|delete|update|insert|grant|revoke|exec|begin|@)|^(opatch .*(apply|rollback|napply)|ords .*(install|upgrade|war)|srvctl .*(stop|start|modify|remove|add)|systemctl .*(stop|start|restart)|keytool .*(-import|-delete|-genkey)|orapki .*wallet .*(add|import|remove|create)|expdp|impdp|datapatch|java .*(weblogic\.Deployer|APEXExport|-jar)|lsnrctl .*(stop|start|reload)|crsctl .*(stop|start)|emctl .*(stop|start)|wlst\.sh|crontab - )|^(rman|ggsci) .*\| *(.*; *)?(restore|duplicate|delete|recover|backup|run|stop|start|alter|add)|^dgmgrl .*\| *(.*; *)?(switchover|failover|reinstate|enable|disable|edit|remove|add|create|convert|stop|start|shutdown|startup)'
for tool in sqlplus sql rman opatch srvctl systemctl ords java keytool orapki expdp impdp ggsci datapatch lsnrctl crsctl emctl wlst.sh dgmgrl crontab pgrep; do
  cat >"$STUB/$tool" <<'STUB'
#!/bin/sh
me="$(basename "$0")"; q=""; [ -t 0 ] || q="$(cat)"
{ echo "TOOL $me $*"; [ -n "$q" ] && printf '%s\n' "$q" | sed 's/^/  > /'; } >>"$DRY_LOG"
[ "$me" = pgrep ] && exit 1                       # nothing is running on this box
line="$me $* | $(printf '%s' "$q" | tr '\n' ';')"
if [ -n "$FAIL_RE" ] && printf '%s' "$line" | grep -qiE -- "$FAIL_RE"; then
  echo "FAILED $me $*" >>"$DRY_LOG"
  case "$me" in sqlplus|sql) echo "ERROR at line 1:"; echo "ORA-00600: internal error code (false-success gate)";; *) echo "$me: failed (false-success gate)" >&2;; esac
  exit 1
fi
case "$me" in sqlplus|sql)   # canned answers so scripts reach their change steps: sql_ok, then the env file's regex|answer lines, matched on THIS call's stdin only
  printf '%s' "$q" | grep -q "'ok'" && echo ok
  while IFS='|' read -r re ans; do [ -n "$re" ] && printf '%s' "$q" | grep -qiE -- "$re" && { echo "$ans"; break; }; done <"$ANSWERS";;
esac
exit 0
STUB
  chmod +x "$STUB/$tool"
done
readonly_cmds='inspect plan latest preflight verify expiring diff validate recovery-window zdlra evidence csr help'
# success lines a run may not add after its change failed. Prefixes, not exact keys: applied_spaceProvHC=1 (exascale-space),
# restored_from= and opatch_upgraded=1 (wls-patch), deleted= (exascale-space release) are change claims too (DeepSeek 21:00);
# not a blanket '=1' - app_stopped=1 and dry_run=1 are sub-states written before the change
default_ok='^(applied[^=]*=[^0[:space:]]|verified=1|rolled_back=1|restored[^=]*=[^[:space:]]|opatch_upgraded=1|deleted=[^[:space:]]|[a-z_]+=ok$|pool_[^=]*=ok|exported_[^=]*=[0-9]+ ok, 0 failed)'
# --selftest: the regex against the state lines it must catch (DeepSeek 21:00's four, one of each older form) and must not
if [ "${1:-}" = --selftest ]; then f=0
  for l in 'applied=26.3.0' 'applied_spaceProvHC=1' 'verified=1' 'rolled_back=1' 'restored=100 -> 100 from HEAD' 'restored_from=/u01/app/backup' 'opatch_upgraded=1' 'deleted=/vault/f1' 'backup=ok' 'pool_default=ok' 'exported_default=3 ok, 0 failed'; do
    if printf '%s\n' "$l" | grep -qE -- "$default_ok"; then echo "ok   caught   $l"; else echo "FAIL missed   $l"; f=1; fi; done
  for l in 'app_stopped=1' 'dry_run=1' 'apply_started=26.2' 'verified=0' 'rolled_back=0' 'reset=failed' 'exported_default=2 ok, 1 failed' 'restore_point=X' 'applied_spaceProvHC=0' 'preflight_problems=0'; do
    if printf '%s\n' "$l" | grep -qE -- "$default_ok"; then echo "FAIL caught   $l (not a success claim)"; f=1; else echo "ok   ignored  $l"; fi; done
  echo "false-success gate selftest: $([ $f = 0 ] && echo passed || echo FAILED)"; exit $f
fi
states() { find "$T/home" -name state -type f 2>/dev/null | sort | while read -r f; do sed "s|^|$f:|" "$f"; done; }
scripts=("$@"); [ ${#scripts[@]} -gt 0 ] || scripts=(patching/*/*.sh operations/*/*.sh)
pass=0; fail=0; nx=0; nxlist=""
for s in "${scripts[@]}"; do
  tool="$(basename "$s" .sh)"
  cmds="$(sed -n '2,60p' "$s" | awk '/^# Commands/{p=1;next} /^# Options|^#$/{if(p)exit} p && /^#   [a-z]/{print $2}' | tr '|' '\n')"
  for c in $cmds; do
    case " $readonly_cmds " in *" $c "*) continue;; esac
    : >"$DRY_LOG"; : >"$ANSWERS"; rm -rf "${T:?}/env" "${T:?}/home"; mkdir -p "$T/env" "$T/home"
    # the per-script environment: sourced in a subshell that then runs the command, so nothing leaks between cases
    # shellcheck disable=SC1090,SC2034
    ( CMD="$c"; ARGS=""; OK=""; [ -f "tests/dry-run-env/$tool.sh" ] && . "tests/dry-run-env/$tool.sh"; a="ARGS_${c//-/_}"; extra="${!a:-$ARGS}"
      f="FAIL_${c//-/_}"; o="OK_${c//-/_}"; printf '%s\n%s\n' "${!f:-$CHANGE_RE}" "${!o:-${OK:-$default_ok}}" >"$T/case"
      states >"$T/state.before"
      # shellcheck disable=SC2086
      FAIL_RE="$(sed -n 1p "$T/case")" HOME="$T/home" PATH="$STUB:$PATH" OFFLINE=1 alarm 120 bash "$s" "$c" $extra --yes ) >"$T/out" 2>&1; rc=$?
    ok_re="$(sed -n 2p "$T/case")"
    if [ $rc = 142 ] || [ $rc = 137 ]; then echo "FAIL $tool $c: hung (120 s)"; fail=$((fail+1)); continue; fi
    if ! grep -q '^FAILED ' "$DRY_LOG"; then nx=$((nx+1)); nxlist="$nxlist $tool:$c"; continue; fi
    failed="$(grep -m1 '^FAILED ' "$DRY_LOG" | cut -c8- | cut -c1-90)"
    states >"$T/state.after"; added="$(comm -13 "$T/state.before" "$T/state.after" | sed 's|^.*/runs/||')"
    bad=""
    [ $rc = 0 ] && bad="exit 0 after '$failed' failed"
    claimed="$(printf '%s\n' "$added" | sed 's|^[^:]*:||' | grep -E -- "$ok_re" | head -3 | tr '\n' ' ')"
    [ -n "$claimed" ] && bad="$bad${bad:+; }state claims $claimed after '$failed' failed"
    if [ -n "$bad" ]; then echo "FAIL $tool $c: $bad"; grep -E 'ERROR|FAIL|error|failed' "$T/out" | tail -3 | sed 's/^/    out: /'; fail=$((fail+1))
    else pass=$((pass+1)); echo "ok   $tool $c: rc=$rc after '$failed' failed; $(grep -c '^FAILED ' "$DRY_LOG") failed call(s) of $(grep -c '^TOOL ' "$DRY_LOG"); state added: $(printf '%s' "$added" | sed 's|^[^:]*:||' | tr '\n' ' ' | cut -c1-120)"; fi
  done
done
echo "false-success gate: $pass passed, $fail failed, $nx NOT-EXERCISED (no changing call reached):$nxlist"
[ $fail = 0 ]
