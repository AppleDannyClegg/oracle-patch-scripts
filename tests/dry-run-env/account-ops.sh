# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# account-ops: one SID given explicitly (no oratab on a dev box), one service account, no ORDS/WebLogic/GoldenGate
ST=OPEN; case "$CMD" in unlock|heal|run) ST=LOCKED;; esac   # unlock, and heal (run = heal), have something to do only on a locked account
# heal probes ORDS with curl: answer 000 (no ORDS here) without touching the network
printf '#!/bin/sh\necho "TOOL curl $*" >>"$DRY_LOG"; printf 000\n' >"$STUB/curl"; chmod +x "$STUB/curl"
cat >"$ANSWERS" <<A
from dba_users where username in|FREE|-|APPUSER|${ST:-OPEN}|NO
v\\\$pdbs|
spare4|VALUES 'S:ABC'
dba_profiles where profile=|1
A
ARGS="--sid FREE --user APPUSER"; ARGS_reset="--sid FREE --user APPUSER --generate --no-propagate"; ARGS_rollback=""; ARGS_cleanup=""
export SQL_CMD="$STUB/sqlplus -S"
# a run dir as 'reset' leaves it, so rollback has hashes to restore (the alter user ... identified by values is the change)
mkdir -p "$T/home/account-ops/runs/r1"; printf 'reset=ok\nreset_done=FREE:-:APPUSER\n' >"$T/home/account-ops/runs/r1/state"
printf "FREE|-|APPUSER|VALUES 'S:ABC'\n" >"$T/home/account-ops/runs/r1/old_hashes.txt"; chmod 600 "$T/home/account-ops/runs/r1/old_hashes.txt"; ln -sfn "$T/home/account-ops/runs/r1" "$T/home/account-ops/runs/latest"
# <cmd>:ps_unreadable - ps cannot run (the gate's $T/ps.fail) and PROC_DIR is an empty dir (5cc183f); --sid FREE stripped from the
# case's ARGS so discovery has to read the list; FAIL_* matches nothing, the ps stub's FAILED line is the count. 129998b: before it
# unlock/profile/rollback walked an empty SID list and recorded unlock=ok / profile=ok / rollback=ok with no database touched, rc 0;
# now the loop head dies on db_instances' status, rc 1, no state line. Not here: reset (rc 1 before too - it needs a named user
# first), heal/run (rc 1 before too: heal=failed), cleanup (never reaches a tool) - ok on both sides of 129998b, so not a proof.
for _c in unlock profile rollback; do
  _a="ARGS_$_c"; _v="${!_a-$ARGS}"; eval "CASES_$_c='ps_unreadable'; FAIL_${_c}__ps_unreadable='^never matches\$'; ARGS_${_c}__ps_unreadable=\"\${_v//--sid FREE/}\""
done
case "${CASE:-}" in ps_unreadable) : >"$T/ps.fail"; mkdir -p "$T/env/noproc"; export PROC_DIR="$T/env/noproc";; esac
