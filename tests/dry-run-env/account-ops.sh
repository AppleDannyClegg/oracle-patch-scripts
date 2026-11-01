# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# account-ops: one SID given explicitly (no oratab on a dev box), one service account, no ORDS/WebLogic/GoldenGate
ST=OPEN; [ "$CMD" = unlock ] && ST=LOCKED   # unlock has something to do only on a locked account
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
