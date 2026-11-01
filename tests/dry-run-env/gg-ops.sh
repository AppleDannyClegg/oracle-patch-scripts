# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# gg-ops: a classic GoldenGate home under $T/env/ogg whose ggsci answers the reads itself ('info all' from the process states kept
# in $T/env/gg/<GROUP>, 'info X, detail' with a checkpoint) and hands everything else to the gate's ggsci stub; when the stub
# accepted a start/stop/kill the state file changes with it, so the status the script re-reads is what the command did.
# Manager RUNNING, extract EXT1 RUNNING, replicat REP1 ABENDED on OGG-01296 (its report says so); for heal and run the manager
# is STOPPED, so heal has a 'start mgr' to send. No database side (nothing in ps, GG_SID unset). --force on skip-transaction and
# resync stands in for the typed confirmation (confirm_typed is 'type the word' on a terminal, --force off one).
G="$T/env/ogg"; S="$T/env/gg"; mkdir -p "$G/dirrpt" "$G/dirprm" "$G/dirdat" "$S" "$T/env/oh"
echo RUNNING >"$S/MANAGER"; echo RUNNING >"$S/EXT1"; echo ABENDED >"$S/REP1"
case "$CMD" in heal|run) echo STOPPED >"$S/MANAGER";; esac
cat >"$G/ggsci" <<GG
#!/bin/sh
q="\$(cat)"
case "\$q" in
  *"info all"*) printf 'Program     Status      Group       Lag at Chkpt  Time Since Chkpt\n\nMANAGER     %s\nEXTRACT     %s     EXT1        00:00:00      00:00:05\nREPLICAT    %s     REP1        00:00:00      01:12:33\n' "\$(cat "$S/MANAGER")" "\$(cat "$S/EXT1")" "\$(cat "$S/REP1")"; exit 0;;
  *"info "*", detail"*) printf 'Log Read Checkpoint  File ./dirdat/aa000000012\n                     2026-11-01 10:00:00.000000  RBA 1234\n'; exit 0;;
  *"info trandata"*|*"info schematrandata"*) echo "Logging of supplemental redo log data is disabled for table APP.T1."; exit 0;;
esac
printf '%s\n' "\$q" | "$STUB/ggsci" "\$@"; rc=\$?
if [ \$rc = 0 ]; then
  for g in EXT1 REP1; do
    case "\$q" in *"start extract \$g"*|*"start replicat \$g"*|*"start extract \$(echo \$g | tr A-Z a-z)"*|*"start replicat \$(echo \$g | tr A-Z a-z)"*) echo RUNNING >"$S/\$g";; esac
    case "\$q" in *"stop extract \$g"*|*"stop replicat \$g"*|*"kill extract \$g"*|*"kill replicat \$g"*|*"stop extract \$(echo \$g | tr A-Z a-z)"*|*"stop replicat \$(echo \$g | tr A-Z a-z)"*) echo STOPPED >"$S/\$g";; esac
  done
  case "\$q" in *"start mgr"*) echo RUNNING >"$S/MANAGER";; *"stop mgr"*) echo STOPPED >"$S/MANAGER";; esac
fi
exit \$rc
GG
chmod +x "$G/ggsci"
printf '2026-11-01 09:00:01  ERROR   OGG-01296  Error mapping from APP.T1 to APP.T1.\n2026-11-01 09:00:01  WARNING OGG-01004  Aborted grouped transaction on APP.T1, Database error 1 (ORA-00001: unique constraint (APP.T1_PK) violated).\n2026-11-01 09:00:01  ERROR   OGG-01668  PROCESS ABENDING.\n' >"$G/dirrpt/REP1.rpt"
printf 'REPLICAT rep1\nUSERIDALIAS ggadmin\nMAP app.*, TARGET app.*;\n' >"$G/dirprm/rep1.prm"; printf 'EXTRACT ext1\nUSERIDALIAS ggadmin\nEXTTRAIL ./dirdat/aa\nTABLE app.*;\n' >"$G/dirprm/ext1.prm"; printf 'PORT 7809\n' >"$G/dirprm/mgr.prm"
for n in 000000008 000000009 000000010 000000011 000000012; do head -c 2048 /dev/zero >"$G/dirdat/aa$n"; done
export OGG_HOME="$G" GG_ALIAS=ggadmin ORACLE_HOME="$T/env/oh" GG_OUT="$T/env/out"
ARGS=""; ARGS_start="rep1"; ARGS_stop="ext1"; ARGS_restart="ext1"; ARGS_skip_transaction="rep1 --force"; ARGS_resync="rep1 --from 12 --force"
ARGS_handlecollisions="rep1 on"; ARGS_trail_cleanup="--apply"; ARGS_trandata="app.t1"
