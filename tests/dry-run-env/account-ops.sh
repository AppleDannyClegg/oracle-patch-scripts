# account-ops: one SID given explicitly (no oratab on a dev box), one service account, no ORDS/WebLogic/GoldenGate
cat >"$ANSWERS" <<'A'
from dba_users where username in|FREE|-|APPUSER|OPEN|NO
v\$pdbs|
spare4|VALUES 'S:ABC'
A
ARGS="--sid FREE --user APPUSER"; ARGS_reset="--sid FREE --user APPUSER --generate --no-propagate"; ARGS_rollback=""; ARGS_cleanup=""
export SQL_CMD="$STUB/sqlplus -S"
