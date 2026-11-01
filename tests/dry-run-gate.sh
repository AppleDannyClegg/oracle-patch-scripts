#!/usr/bin/env bash
# Behavioural gate for --dry-run: every change command of every script is run with --dry-run --yes on a PATH of stub
# tools (sqlplus, sql, rman, opatch, srvctl, systemctl, ords, java, keytool, orapki, expdp, impdp, ggsci, datapatch,
# lsnrctl, crsctl, emctl, wlst.sh) that record their argv and stdin and change nothing. tests/dry-run-env/<tool>.sh,
# when present, is sourced first: it gives the script what it needs to reach its change step - extra arguments (ARGS,
# ARGS_<cmd>), fake homes under $T, and canned answers for the sqlplus stub ($ANSWERS: one 'regex|answer' per line). confirm() answers yes under
# --dry-run in every script, so a statement without its own dry-run guard runs for real: this gate reads what the
# stubs saw. FAIL: a sqlplus/sql session carried DDL, DML, flashback, shutdown or startup, or a tool was called with a
# changing verb (opatch apply, ords install, rman restore, srvctl stop ...). NOT-EXERCISED: the command ended before
# any stub was called (no config, no database): counted and listed on the last line, never a pass. Needs no database.
# Usage: tests/dry-run-gate.sh [script...]
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
T="$(mktemp -d)"; STUB="$T/stub"; export DRY_LOG="$T/log" ANSWERS="$T/answers"; mkdir -p "$STUB" "$T/home"; : >"$ANSWERS"
trap 'rm -rf "$T"' EXIT
alarm() { perl -e 'alarm shift; exec @ARGV' "$@"; }
for tool in sqlplus sql rman opatch srvctl systemctl ords java keytool orapki expdp impdp ggsci datapatch lsnrctl crsctl emctl wlst.sh; do
  cat >"$STUB/$tool" <<'STUB'
#!/bin/sh
me="$(basename "$0")"; q=""; [ -t 0 ] || q="$(cat)"
{ echo "TOOL $me $*"; [ -n "$q" ] && printf '%s\n' "$q" | sed 's/^/  > /'; } >>"$DRY_LOG"
case "$me" in sqlplus|sql)   # canned answers so scripts reach their change steps: sql_ok, then the env file's regex|answer lines, matched on THIS call's stdin only
  printf '%s' "$q" | grep -q "'ok'" && echo ok
  while IFS='|' read -r re ans; do [ -n "$re" ] && printf '%s' "$q" | grep -qiE -- "$re" && { echo "$ans"; break; }; done <"$ANSWERS";;
esac
exit 0
STUB
  chmod +x "$STUB/$tool"
done
readonly_cmds='inspect plan latest preflight verify expiring diff validate recovery-window zdlra evidence csr'
scripts=("$@"); [ ${#scripts[@]} -gt 0 ] || scripts=(patching/*/*.sh operations/*/*.sh)
pass=0; fail=0; nx=0; nxlist=""
for s in "${scripts[@]}"; do
  tool="$(basename "$s" .sh)"
  cmds="$(sed -n '2,60p' "$s" | awk '/^# Commands/{p=1;next} /^# Options|^#$/{if(p)exit} p && /^#   [a-z]/{print $2}' | tr '|' '\n')"
  for c in $cmds; do
    case " $readonly_cmds " in *" $c "*) continue;; esac
    : >"$DRY_LOG"; : >"$ANSWERS"; rm -rf "$T/env"; mkdir -p "$T/env"
    # the per-script environment: sourced in a subshell that then runs the command, so nothing leaks between scripts
    # shellcheck disable=SC1090
    ( ARGS=""; [ -f "tests/dry-run-env/$tool.sh" ] && . "tests/dry-run-env/$tool.sh"; a="ARGS_${c//-/_}"; extra="${!a:-$ARGS}"
      # shellcheck disable=SC2086
      HOME="$T/home" PATH="$STUB:$PATH" OFFLINE=1 alarm 60 bash "$s" "$c" $extra --dry-run --yes ) >"$T/out" 2>&1; rc=$?
    if [ $rc = 142 ] || [ $rc = 137 ]; then echo "FAIL $tool $c: hung (60 s)"; fail=$((fail+1)); continue; fi
    if ! grep -q '^TOOL ' "$DRY_LOG"; then nx=$((nx+1)); nxlist="$nxlist $tool:$c"; continue; fi
    bad="$(awk '/^TOOL (sqlplus|sql) /{s=1;next} /^TOOL /{s=0} s && /^  > /{print}' "$DRY_LOG" | sed 's/^  > //' | grep -iE '^[[:space:]]*(alter[[:space:]]+(pluggable|database|user|system|tablespace)|drop|create|flashback|shutdown|startup|truncate|delete|update|insert|grant|revoke|exec|begin|@)' | head -3)"
    bad="$bad$(grep -E '^TOOL (opatch .*(apply|rollback|napply)|ords .*(install|upgrade|war)|srvctl .*(stop|start|modify|remove|add)|systemctl .*(stop|start|restart)|keytool .*(-import|-delete|-genkey)|orapki .*wallet .*(add|import|remove|create)|expdp|impdp|datapatch|java .*(weblogic\.Deployer|APEXExport|-jar)|lsnrctl .*(stop|start|reload)|crsctl .*(stop|start)|emctl .*(stop|start)|wlst\.sh)' "$DRY_LOG" | head -3)"
    bad="$bad$(awk '/^TOOL (rman|ggsci) /{s=1;next} /^TOOL /{s=0} s && /^  > /{print}' "$DRY_LOG" | grep -iE '^  > [[:space:]]*(restore|duplicate|delete|recover|backup|run|stop|start|alter|add)' | head -3)"
    if [ -n "$bad" ]; then echo "FAIL $tool $c --dry-run changed something:"; printf '%s\n' "$bad" | sed 's/^/    /'; fail=$((fail+1))
    else pass=$((pass+1)); echo "ok   $tool $c: $(grep -c '^TOOL ' "$DRY_LOG") tool call(s), $(grep -oE '^TOOL [a-z.]+' "$DRY_LOG" | sort | uniq -c | awk '{printf "%s x%s ", $3, $1}')"; fi
  done
done
echo "dry-run gate: $pass passed, $fail failed, $nx NOT-EXERCISED (ended before any tool was called):$nxlist"
[ $fail = 0 ]
