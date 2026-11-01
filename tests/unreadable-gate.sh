#!/usr/bin/env bash
# Behavioural gate for reads that fail: the read-only reports (db-health-daily, security-posture, perf-snapshot,
# space-forecast, oracle-diag, patch-status) and the two collectors (incident-pack, sr-draft) are run for real on a PATH of
# stub tools, with HOME, ORACLE_HOME and every output path under a temp dir and one database FREE in the stub's ps, and the
# SQL layer fails in one of two ways:
#   connect   sqlplus cannot connect (ORA-12547, exit 1) - every statement fails, the sql_ok probe included
#   statement the sql_ok probe answers 'ok' and every other statement fails (ORA-00942, exit 1): the view this edition
#             lacks, the closed PDB under with_pdb, the SQL_TIMEOUT kill, the privilege the account lost
# A report that then names what it could not read is ok: a CRIT/WARN finding, a table row or a fact saying cannot connect /
# unknown / not evaluated / could not / did not complete. A report whose FINDINGS say 'nothing tripped the built-in
# rules', whose scorecard or table simply omits the database, or whose facts are blank, claimed a clean read that never
# happened: FAIL. The six reports must also exit non-zero (findings_rc: 2 CRIT, 1 WARN, 0 clean - under cron the exit code is the
# whole interface; db-health-daily and space-forecast install themselves with >/dev/null 2>&1). NOT-EXERCISED: the run
# made no sqlplus call at all (the mode was not reached): counted and listed, never a pass. Needs no database.
# Usage: tests/unreadable-gate.sh [script...]
cd "$(dirname "$0")/.." || exit 1
exec </dev/null
T="$(mktemp -d)"; STUB="$T/stub"; export GATE_LOG="$T/log" GATE_MODE=""; mkdir -p "$STUB" "$T/home" "$T/oh"
trap 'rm -rf "$T"' EXIT
alarm() { perl -e 'alarm shift; exec @ARGV' "$@"; }
# the domain tools fail; coreutils stay real (a PATH where mkdir fails proves nothing); ps shows one database and its listener so
# discovery works and the SQL layer is what fails
cat >"$STUB/_stub" <<'STUB'
#!/bin/sh
me="$(basename "$0")"
if [ "$me" = ps ]; then
  case "$*" in
    *-eo\ args*|*-eo\ pid,args*|*-ef*) pre=""; [ "$*" = "-eo pid,args" ] && pre="101 "; printf '%sora_pmon_FREE\n%s/u01/app/oracle/product/19/bin/tnslsnr LISTENER -inherit\n' "$pre" "$pre"; exit 0;;
    *) exec /bin/ps "$@";;
  esac
fi
q=""; [ -t 0 ] || q="$(cat)"
{ echo "TOOL $me $*"; [ -n "$q" ] && printf '%s\n' "$q" | sed 's/^/  > /'; } >>"$GATE_LOG"
case "$me" in
  sqlplus|sql)
    if [ "$GATE_MODE" = statement ] && printf '%s' "$q" | grep -q "'ok'"; then echo ok; exit 0; fi
    echo "FAILED $me" >>"$GATE_LOG"
    if [ "$GATE_MODE" = statement ]; then echo "ERROR at line 1:"; echo "ORA-00942: table or view does not exist"; else echo "ERROR:"; echo "ORA-12547: TNS:lost contact"; echo; echo "SP2-0640: Not connected"; fi;;
  opatch) echo "OPatch failed to load the inventory: LsInventorySession failed" >&2; echo "FAILED $me" >>"$GATE_LOG";;
  *) echo "$me: cannot run (unreadable gate)" >&2; echo "FAILED $me" >>"$GATE_LOG";;
esac
exit 1
STUB
chmod +x "$STUB/_stub"
for tool in sqlplus sql opatch srvctl lsnrctl escli adrci crsctl emctl tfactl rman ords java jcmd ggsci datapatch wlst.sh asmcmd tnsping ps; do ln -s _stub "$STUB/$tool"; done
# what a report must say when a read failed: a CRIT/WARN finding, a table row or a fact that names the database AND the failure
# (an INFO about the host, or a finding about ORDS, is not it - the first run of this gate passed oracle-diag on 'Kernel and system
# log were not readable', a host INFO, while 16 of 17 database statements had failed)
OWN_UP='cannot|not evaluated|unknown|could not|did not complete|unreadable|not (checked|read|counted|collected|confirmed)|does not answer|failed'
owns_up() { grep -vE '\*\*INFO\*\*' | grep -E 'FREE' | grep -qiE -- "$OWN_UP"; }
own_up_line() { grep -vE '\*\*INFO\*\*' | grep -E 'FREE' | grep -iE -- "$OWN_UP" | head -1 | cut -c1-140; }
# per script: the arguments, and where the verdict is read from (report: the FINDINGS block of REPORT.md)
args_of() { case "$1" in
  db-health-daily)  echo "--sid FREE --out $T/out --no-tar";;
  security-posture) echo "--sid FREE --out $T/out --no-tar";;
  perf-snapshot)    echo "--sid FREE --out $T/out --no-tar --no-pack --samples 1";;
  space-forecast)   echo "--sid FREE --out $T/out --no-tar --no-pack --history $T/hist";;
  oracle-diag)      echo "--sid FREE --out $T/out --no-tar";;
  patch-status)     echo "--no-net --report --out $T/out";;
  sr-draft)         echo "--sid FREE --error ORA-00600 --out $T/out";;
  incident-pack)    echo "GATE --sid FREE --out $T/out --no-diag --no-tfa --hours 1 --yes";;
  *) return 1;; esac; }
scripts=("$@"); [ ${#scripts[@]} -gt 0 ] || scripts=(reports/*/*.sh patching/patch-status/patch-status.sh operations/incident-pack/incident-pack.sh operations/sr-draft/sr-draft.sh)
pass=0; fail=0; nx=0; nxlist=""; fverdict=0; frc=0   # a FAIL is counted once; 'verdict' when the report did not own up, '[rc]' when it only exited 0
for s in "${scripts[@]}"; do
  tool="$(basename "$s" .sh)"; extra="$(args_of "$tool")" || { echo "skip $tool: not a read-only report this gate knows"; continue; }
  for mode in connect statement; do
    : >"$GATE_LOG"; rm -rf "${T:?}/out" "${T:?}/hist" "${T:?}/home"; mkdir -p "$T/out" "$T/home"
    # shellcheck disable=SC2086
    GATE_MODE="$mode" HOME="$T/home" PATH="$STUB:$PATH" OFFLINE=1 ORACLE_HOME="$T/oh" SQL_CMD="$STUB/sqlplus -S" alarm 180 bash "$s" $extra >"$T/stdout" 2>&1; rc=$?
    if [ $rc = 142 ] || [ $rc = 137 ]; then echo "FAIL $tool $mode: hung (180 s)"; fail=$((fail+1)); continue; fi
    calls="$(grep -c '^TOOL sqlplus' "$GATE_LOG")"; failed="$(grep -c '^FAILED sqlplus' "$GATE_LOG")"
    if [ "$calls" = 0 ]; then nx=$((nx+1)); nxlist="$nxlist $tool:$mode"; continue; fi
    # the verdict: FINDINGS block of REPORT.md for the reports, the table for patch-status, SR.md for sr-draft, the log lines for incident-pack
    case "$tool" in
      patch-status) verdict="$(grep -E '^(Database|datapatch) FREE' "$T/stdout"; sed -n '/^# FINDINGS/,/^---$/p' "$T"/out/*/REPORT.md 2>/dev/null)";;
      sr-draft)     verdict="$(grep -E 'DB (VERSION|PATCHES)' "$T"/out/SR.md 2>/dev/null; grep -E '\[(WARN |ERROR)\]' "$T/stdout")";;
      incident-pack) verdict="$(grep -E '\[(WARN |ERROR)\]|INCOMPLETE' "$T/stdout")";;
      *) verdict="$(sed -n '/^# FINDINGS/,/^---$/p' "$T"/out/*/REPORT.md 2>/dev/null)";;
    esac
    reason=""; vfail=0
    if [ "$failed" -gt 0 ]; then
      printf '%s\n' "$verdict" | owns_up || { vfail=1; reason="$failed of $calls statements failed and nothing in the verdict says so: $(printf '%s\n' "$verdict" | grep -vE '^\s*$|^#|^---' | head -2 | tr '\n' ' ' | cut -c1-200)"; }
      [ "$tool" = patch-status ] && ! grep -qE '^(Database|datapatch) FREE' "$T/stdout" && { vfail=1; reason="${reason:+$reason; }no row for FREE although ps shows ora_pmon_FREE"; }
      # the exit code is the whole interface under cron (db-health-daily and space-forecast install themselves with >/dev/null 2>&1):
      # a report that could not read its database must not exit 0, whatever it printed (Colossus 23:43, findings_rc = 2 CRIT, 1 WARN, 0 clean)
      case "$tool" in db-health-daily|security-posture|perf-snapshot|space-forecast|oracle-diag|patch-status) [ $rc = 0 ] && reason="${reason:+$reason; }[rc] exit 0 after $failed failed statements (a cron caller reads this as clean)";; esac
    fi
    if [ -n "$reason" ]; then echo "FAIL $tool $mode: rc=$rc; $reason"; fail=$((fail+1)); if [ $vfail = 1 ]; then fverdict=$((fverdict+1)); else frc=$((frc+1)); fi
    else pass=$((pass+1)); echo "ok   $tool $mode: rc=$rc, $failed of $calls statements failed, verdict: $(printf '%s\n' "$verdict" | own_up_line)"; fi
  done
done
echo "unreadable gate: $pass passed, $fail failed ($fverdict verdict, $frc exit-code only), $nx NOT-EXERCISED (no sqlplus call reached):$nxlist"
[ $fail = 0 ]
