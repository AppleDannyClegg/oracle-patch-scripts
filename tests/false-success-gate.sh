#!/usr/bin/env bash
# Behavioural gate for false success: every change command of every script is run for real (--yes, no --dry-run) on a
# PATH of stub tools, with HOME and every path the script touches under a temp dir, and the FIRST call that could
# change something (DDL, DML, flashback, a PL/SQL block - exec/begin, whatever it does - a changing tool verb) fails - the stub logs 'FAILED <tool> <argv>', prints an error (ORA-00600 for sqlplus/sql) and exits 1; every later
# changing call fails the same way (the tool is broken), probes (select, --version, config get ...) keep answering.
# A script that then exits 0, or records success in its run dir (applied*=, verified=1, rolled_back=1, restored*=,
# opatch_upgraded=1, deleted=, downloaded=, <step>=ok, pool_<p>=ok, exported_<c>=N ok, 0 failed) claimed a change that did not happen: FAIL. NOT-EXERCISED:
# no changing call was reached (the command only reads, or ended before it): counted and listed, never a pass.
# tests/dry-run-env/<tool>.sh (shared with tests/dry-run-gate.sh) is sourced first, with CMD set to the command; it may set
# FAIL_<cmd> (the call to fail instead of the first changing one, a regex on 'tool argv | stdin') and OK / OK_<cmd>
# (the success lines to forbid in state, a regex). CASES_<cmd> names extra runs of the same command ('rp_unreadable ...'):
# each is run with FAIL_<cmd>__<case> / OK_<cmd>__<case> / ARGS_<cmd>__<case> (falling back to the command's own), with CASE set
# while the env file is sourced, so one command can be failed at two different calls. Only lines ADDED to a state file by the run count, so a seeded
# state may carry applied= or pool_x=ok. The env file may write $T/ps.txt (one process per line) for the ps stub to
# print, $T/pgrep.txt (pids) for pgrep to find, or create $T/ps.fail to make every ps call fail (logged as FAILED, so a stop that
# then claims 'stopped' is a FAIL); it cannot change CMD. Needs no database.
# Usage: tests/false-success-gate.sh [script...] | --selftest (the success-line regex against the lines it must and must not catch)
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
T="$(mktemp -d)"; STUB="$T/stub"; export DRY_LOG="$T/log" ANSWERS="$T/answers" FAIL_RE=""; mkdir -p "$STUB"; : >"$ANSWERS"
trap 'rm -rf "$T"' EXIT
# alarm <secs> <cmd...>: a deadline via GNU timeout where present (OL7/OL8), perl otherwise (macOS).
# timeout exits 124; perl's alarm is SIGALRM (142) or SIGKILL (137).
if command -v timeout >/dev/null 2>&1; then
  alarm() { local t="$1"; shift; timeout "$t" "$@"; }
elif command -v gtimeout >/dev/null 2>&1; then
  alarm() { local t="$1"; shift; gtimeout "$t" "$@"; }
elif command -v perl >/dev/null 2>&1; then
  alarm() { local t="$1"; shift; perl -e 'alarm shift; exec @ARGV' "$t" "$@"; }
else
  alarm() { shift; "$@"; }   # no deadline tool: run without one
fi
# a changing call, on one line 'tool argv | stdin': the same verbs tests/dry-run-gate.sh forbids under --dry-run
CHANGE_RE='^(sqlplus|sql) .*\| *(.*; *)?(alter +(pluggable|database|user|system|tablespace)|drop|create|flashback|shutdown|startup|truncate|delete|update|insert|grant|revoke|exec|begin|@)|^(opatch .*(apply|rollback|napply)|ords .*(install|upgrade|war)|srvctl .*(stop|start|modify|remove|add)|systemctl .*(stop|start|restart)|keytool .*(-import|-delete|-genkey)|orapki .*wallet .*(add|import|remove|create)|expdp|impdp|datapatch|java .*(weblogic\.Deployer|APEXExport|-jar)|lsnrctl .*(stop|start|reload)|crsctl .*(stop|start)|emctl .*(stop|start)|wlst\.sh|crontab - )|^(rman|ggsci) .*\| *(.*; *)?(restore|duplicate|delete|recover|backup|run|stop|start|alter|add|crosscheck|change|catalog|kill|send .*(handlecollisions|nohandlecollisions|forcestop))|^escli .*(chvault|rmfile|mkvault|rmvault|chfile|mkfile|chpool)|^dgmgrl .*\| *(.*; *)?(switchover|failover|reinstate|enable|disable|edit|remove|add|create|convert|stop|start|shutdown|startup)'
for tool in sqlplus sql rman opatch srvctl systemctl ords java keytool orapki expdp impdp ggsci datapatch lsnrctl crsctl emctl wlst.sh dgmgrl escli crontab pgrep ps rm; do
  cat >"$STUB/$tool" <<'STUB'
#!/bin/sh
me="$(basename "$0")"
# ps: fails (exit 1, logged as FAILED) while the env file's $T/ps.fail exists; else what the env file wrote to $T/ps.txt (one process
# per line, e.g. '1234 ora_pmon_FREE'), else the real ps; a ps that answers is never logged
[ "$me" = ps ] && { d="$(dirname "$DRY_LOG")"; [ -e "$d/ps.fail" ] && { echo "ps: cannot read the process list (false-success gate)" >&2; echo "FAILED ps $*" >>"$DRY_LOG"; exit 1; }; if [ -s "$d/ps.txt" ]; then cat "$d/ps.txt"; else exec /bin/ps "$@"; fi; exit 0; }
# pgrep: the pids the env file wrote to $T/pgrep.txt, else nothing is running on this box
[ "$me" = pgrep ] && { f="$(dirname "$DRY_LOG")/pgrep.txt"; echo "TOOL pgrep $*" >>"$DRY_LOG"; if [ -s "$f" ]; then cat "$f"; exit 0; fi; exit 1; }
q=""; [ -t 0 ] || q="$(cat)"
{ echo "TOOL $me $*"; [ -n "$q" ] && printf '%s\n' "$q" | sed 's/^/  > /'; } >>"$DRY_LOG"
line="$me $* | $(printf '%s' "$q" | tr '\n' ';')"
# RMAN's 'restore ... preview', 'restore ... validate' and 'backup validate' read the pieces or the datafiles and write nothing (rman-ops validate/run): not a change
ro="$(printf '%s' "$line" | tr 'A-Z' 'a-z' | sed -E 's/(restore|backup) [^;{}]*(preview|validate)[^;{}]*;?//g; s/set until[^;]*;//g; s/run *\{ *\}//g')"
if [ -n "$FAIL_RE" ] && printf '%s' "$ro" | grep -qiE -- "$FAIL_RE"; then
  echo "FAILED $me $*" >>"$DRY_LOG"
  case "$me" in sqlplus|sql) echo "ERROR at line 1:"; echo "ORA-00600: internal error code (false-success gate)";; *) echo "$me: failed (false-success gate)" >&2;; esac
  exit 1
fi
case "$me" in sqlplus|sql)   # canned answers so scripts reach their change steps: sql_ok, then the env file's regex|answer lines, matched on THIS call's stdin only
  printf '%s' "$q" | grep -q "'ok'" && echo ok
  while IFS='|' read -r re ans; do [ -n "$re" ] && printf '%s' "$q" | grep -qiE -- "$re" && { echo "$ans"; break; }; done <"$ANSWERS";;
esac
# rm: a delete the script asked for, unless FAIL_RE singled it out above - then it is the change that failed and
# the gate asserts the script did not exit 0 claiming it worked (wls-patch heal's lock removal, T264)
[ "$me" = rm ] && exec /bin/rm "$@"
exit 0
STUB
  chmod +x "$STUB/$tool"
done
readonly_cmds='inspect plan latest preflight verify expiring diff validate recovery-window zdlra evidence csr help'
# success lines a run may not add after its change failed. Prefixes, not exact keys: applied_spaceProvHC=1 (exascale-space),
# restored_from= and opatch_upgraded=1 (wls-patch), deleted= (exascale-space release) are change claims too (DeepSeek 21:00);
# not a blanket '=1' - app_stopped=1 and dry_run=1 are sub-states written before the change
default_ok='^(applied[^=]*=[^0[:space:]]|downloaded=[^[:space:]]|verified=1|rolled_back=1|restored[^=]*=[^[:space:]]|opatch_upgraded=1|deleted=[^[:space:]]|[a-z_]+=ok$|pool_[^=]*=ok|exported_[^=]*=[0-9]+ ok, 0 failed)'
# covered_by: for a verb this instrument did NOT reach, the gate that does reach it (T212). A NOT-EXERCISED verb is
# never a pass, and one no gate reaches is a HOLE to raise, not a gap to tolerate - so it must be named as one.
covered_by() {
  case "$1" in
    ohs-patch:*)        printf 'tests/ohs-patch.sh' ;;
    dbclient-upgrade:*) printf 'tests/dbclient-upgrade.sh' ;;
    # T264: heal's delete-failure path is reached by THIS gate's heal:rm_fails case (the default heal case finds no
    # issue, so it is still not exercised there) - named rather than left as "no gate reaches this verb"
    wls-patch:heal)     printf 'tests/false-success-gate.sh heal:rm_fails' ;;
    *)                  printf 'none - no gate reaches this verb, raise it' ;;
  esac
}
# --selftest: the regex against the state lines it must catch (DeepSeek 21:00's four, one of each older form) and must not
if [ "${1:-}" = --selftest ]; then f=0
  for l in 'applied=26.3.0' 'applied_spaceProvHC=1' 'downloaded=39000000' 'verified=1' 'rolled_back=1' 'restored=100 -> 100 from HEAD' 'restored_from=/u01/app/backup' 'opatch_upgraded=1' 'deleted=/vault/f1' 'backup=ok' 'pool_default=ok' 'exported_default=3 ok, 0 failed'; do
    if printf '%s\n' "$l" | grep -qE -- "$default_ok"; then echo "ok   caught   $l"; else echo "FAIL missed   $l"; f=1; fi; done
  for l in 'app_stopped=1' 'dry_run=1' 'apply_started=26.2' 'verified=0' 'rolled_back=0' 'reset=failed' 'exported_default=2 ok, 1 failed' 'restore_point=X' 'applied_spaceProvHC=0' 'preflight_problems=0'; do
    if printf '%s\n' "$l" | grep -qE -- "$default_ok"; then echo "FAIL caught   $l (not a success claim)"; f=1; else echo "ok   ignored  $l"; fi; done
  # T212: a NOT-EXERCISED verb must say who does reach it; one that no gate reaches says so and is a hole
  for p in 'ohs-patch:apply|tests/ohs-patch.sh' 'dbclient-upgrade:rollback|tests/dbclient-upgrade.sh' 'wls-patch:restore|none '; do
    v="${p%%|*}"; want="${p#*|}"; got="$(covered_by "$v" 2>/dev/null)"
    case "$got" in "$want"*) echo "ok   covered  $v -> $got";; *) echo "FAIL covered  $v -> '$got', wanted '$want'"; f=1;; esac; done
  echo "false-success gate selftest: $([ $f = 0 ] && echo passed || echo FAILED)"; exit $f
fi
# sorted: comm needs it, and state_set rewrites a file (grep -v + append) so an untouched seeded line moves (Fable 21:22)
states() { find "$T/home" -name state -type f 2>/dev/null | while read -r f; do sed "s|^|$f:|" "$f"; done | sort; }
scripts=("$@"); [ ${#scripts[@]} -gt 0 ] || scripts=(patching/*/*.sh operations/*/*.sh)
pass=0; fail=0; nx=0; nxlist=""
for s in "${scripts[@]}"; do
  tool="$(basename "$s" .sh)"
  # the header may hold several '# Commands' blocks parted by blank '#' lines (rman-ops): a blank line pauses, the next '# Commands' resumes; 'a | b' and 'a|b' list both
  cmds="$(sed -n '2,80p' "$s" | awk '/^# Commands/{p=1;next} /^# Options/{exit} /^#$/{p=0;next} p && /^#   [a-z]/{sub(/^#   /,""); n=split($0,w," "); for(i=1;i<=n;i++){ if(w[i]=="|") continue; if(i>1 && w[i-1]!="|") break; m=split(w[i],v,"|"); for(j=1;j<=m;j++) print v[j] } }')"
  for c in $cmds; do
    case " $readonly_cmds " in *" $c "*) continue;; esac
    # extra named cases of this command, from the env file's CASES_<cmd> (sourced once more to read it; CASE is empty then)
    # shellcheck disable=SC1090,SC2034
    cases="$( ( CMD="$c"; readonly CMD; CASE=""; [ -f "tests/dry-run-env/$tool.sh" ] && . "tests/dry-run-env/$tool.sh"; v="CASES_${CMD//-/_}"; printf '%s' "${!v-}" ) 2>/dev/null )"
    for k in "" $cases; do
    label="$c${k:+:$k}"
    # the ps world starts empty for every case: until now ps.txt written by one env file (exascale-space, rman-ops) was still there for
    # the next script's cases, and the ps.fail / pgrep.txt switches must never outlive the case that set them
    : >"$DRY_LOG"; : >"$ANSWERS"; rm -rf "${T:?}/env" "${T:?}/home" "$T/env.ok" "$T/ps.txt" "$T/ps.fail" "$T/pgrep.txt"; mkdir -p "$T/env" "$T/home"
    # the per-script environment: sourced in a subshell that then runs the command, so nothing leaks between cases
    # shellcheck disable=SC1090,SC2034
    ( CMD="$c"; readonly CMD; CASE="$k"; ARGS=""; OK=""; [ -f "tests/dry-run-env/$tool.sh" ] && . "tests/dry-run-env/$tool.sh"; : >"$T/env.ok"
      b="${CMD//-/_}"; sfx="${k:+__$k}"; a="ARGS_$b$sfx"; a0="ARGS_$b"; extra="${!a-${!a0-$ARGS}}"
      f="FAIL_$b$sfx"; f0="FAIL_$b"; o="OK_$b$sfx"; o0="OK_$b"; printf '%s\n%s\n' "${!f:-${!f0:-$CHANGE_RE}}" "${!o:-${!o0:-${OK:-$default_ok}}}" >"$T/case"
      states >"$T/state.before"
      # shellcheck disable=SC2086
      FAIL_RE="$(sed -n 1p "$T/case")" HOME="$T/home" PATH="$STUB:$PATH" OFFLINE=1 alarm 120 bash "$s" "$CMD" $extra --yes ) >"$T/out" 2>&1; rc=$?
    # a process the env file started to stand in for ORDS (pgrep.txt) is ours: end it if the script did not
    [ -s "$T/pgrep.txt" ] && while read -r pid; do kill "$pid" 2>/dev/null; done <"$T/pgrep.txt"
    if [ $rc = 124 ] || [ $rc = 142 ] || [ $rc = 137 ]; then echo "FAIL $tool $label: hung (120 s)"; fail=$((fail+1)); continue; fi
    if [ ! -f "$T/env.ok" ]; then echo "FAIL $tool $label: tests/dry-run-env/$tool.sh did not source to the end: $(grep -v '^$' "$T/out" | tail -1 | cut -c1-160)"; fail=$((fail+1)); continue; fi
    ok_re="$(sed -n 2p "$T/case")"
    if ! grep -q '^FAILED ' "$DRY_LOG"; then nx=$((nx+1)); nxlist="$nxlist $tool:$label"; continue; fi
    failed="$(grep -m1 '^FAILED ' "$DRY_LOG" | cut -c8- | cut -c1-90)"
    states >"$T/state.after"; added="$(comm -13 "$T/state.before" "$T/state.after" | sed 's|^.*/runs/||')"
    bad=""
    [ $rc = 0 ] && bad="exit 0 after '$failed' failed"
    claimed="$(printf '%s\n' "$added" | sed 's|^[^:]*:||' | grep -E -- "$ok_re" | head -3 | tr '\n' ' ')"
    [ -n "$claimed" ] && bad="$bad${bad:+; }state claims $claimed after '$failed' failed"
    if [ -n "$bad" ]; then echo "FAIL $tool $label: $bad"; grep -E 'ERROR|FAIL|error|failed' "$T/out" | tail -3 | sed 's/^/    out: /'; fail=$((fail+1))
    else pass=$((pass+1)); echo "ok   $tool $label: rc=$rc after '$failed' failed; $(grep -c '^FAILED ' "$DRY_LOG") failed call(s) of $(grep -c '^TOOL ' "$DRY_LOG"); state added: $(printf '%s' "$added" | sed 's|^[^:]*:||' | tr '\n' ' ' | cut -c1-120)"; fi
    done
  done
done
echo "false-success gate: $pass passed, $fail failed, $nx NOT-EXERCISED (no changing call reached - this instrument did not test that verb, and it is not a pass):$nxlist"
# one line per unreached verb saying who does reach it, so the gate's name stops claiming more than it tests (T212)
for v in $nxlist; do echo "  not tested here: $v -> $(covered_by "$v")"; done
[ $fail = 0 ]
