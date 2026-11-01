# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# dg-switchover: local instance FREE is the primary PRIMDB, one physical standby STBYDB, broker on, MaxAvailability.
# dgmgrl is not in the gates' stub list, so this file adds one: it logs like the others, honours FAIL_RE (false-success
# gate), answers show configuration / validate / show database from canned text, and keeps one piece of state - after a
# switchover or failover the configuration shows STBYDB as primary (so wait_roles ends; a switchover back clears it).
# The regex side of an answer line must not contain '|' (the stub splits on it); first match wins.
ROLE="PRIMDB|PRIMARY|READ WRITE|PRIM"; : >"$DRY_LOG.cmd"; printf '%s' "$CMD" >"$DRY_LOG.cmd"; rm -f "$DRY_LOG.switched" "$DRY_LOG.healed"
case "$CMD" in
  reinstate) ROLE="PRIMDB|PHYSICAL STANDBY|MOUNTED|PRIM"; touch "$DRY_LOG.switched";;   # the old primary, mounted after a failover to STBYDB
  rollback) touch "$DRY_LOG.switched";;                                                   # STBYDB is primary now; rollback switches back to PRIMDB
esac
cat >"$ANSWERS" <<A
database_role.*open_mode|$ROLE
dg_broker_start|TRUE
switchover_status|TO STANDBY
flashback_on|YES
log_mode|ARCHIVELOG
instance_name|FREE
v\\\$archive_gap|0
status='RUNNING'|0
status='ACTIVE'|0
from v\\\$pdbs where open_mode|
count\\(\\*\\)|0
A
cat >"$STUB/dgmgrl" <<'D'
#!/bin/sh
q=""; [ -t 0 ] || q="$(cat)"; cmd="$(cat "$DRY_LOG.cmd" 2>/dev/null)"
{ echo "TOOL dgmgrl $*"; [ -n "$q" ] && printf '%s\n' "$q" | sed 's/^/  > /'; } >>"$DRY_LOG"
line="dgmgrl $* | $(printf '%s' "$q" | tr '\n' ';')"
if [ -n "${FAIL_RE:-}" ] && printf '%s' "$line" | grep -qiE -- "$FAIL_RE"; then echo "FAILED dgmgrl $*" >>"$DRY_LOG"; echo "ORA-16625: cannot reach database (false-success gate)"; exit 1; fi
cfg() { printf 'Configuration - dgcfg\n\n  Protection Mode: MaxAvailability\n  Members:\n  %s - Primary database\n    %s - Physical standby database%s\n\nFast-Start Failover:  Disabled\n\nConfiguration Status:\nSUCCESS   (status updated 10 seconds ago)\n' "$@"; }
# heal: redo apply is stopped on STBYDB (ORA-16826, Intended State APPLY-OFF) until an 'edit database STBYDB set state=APPLY-ON' ran
if [ "$cmd" = heal ] && [ ! -e "$DRY_LOG.healed" ]; then case "$q" in
  *"edit database STBYDB"*"APPLY-ON"*) touch "$DRY_LOG.healed"; echo Succeeded.; exit 0;;
  *"show configuration"*) cfg PRIMDB STBYDB '
      Warning: ORA-16826: apply service state is inconsistent with the DelayMins property' | sed 's/^SUCCESS .*/WARNING/'; exit 0;;
  *"show database"*) printf 'Database - STBYDB\n\n  Role:               PHYSICAL STANDBY\n  Intended State:     APPLY-OFF\n  Transport Lag:      0 seconds (computed 1 second ago)\n  Apply Lag:          3 minutes 2 seconds (computed 1 second ago)\n  Instance(s):\n    STBY\n\n  Database Warning(s):\n    ORA-16826: apply service state is inconsistent with the DelayMins property\n\nDatabase Status:\nWARNING\n'; exit 0;;
esac; fi
case "$q" in
  *"show configuration"*) if [ -e "$DRY_LOG.switched" ]; then if [ "$cmd" = reinstate ]; then cfg STBYDB PRIMDB ' (disabled)
      ORA-16661: the standby database needs to be reinstated'; else cfg STBYDB PRIMDB ''; fi; else cfg PRIMDB STBYDB ''; fi;;
  *"validate database"*) if [ "$cmd" = failover ]; then rf="Yes"; else rf="Yes (Primary Running)"; fi
    printf '  Database Role:     Physical standby database\n  Primary Database:  PRIMDB\n\n  Ready for Switchover:  Yes\n  Ready for Failover:    %s\n\n  Flashback Database Status:\n    PRIMDB:  On\n    STBYDB:  On\n\n  Temporary Tablespace File Information:\n    PRIMDB TEMP Files:  1\n    STBYDB TEMP Files:  1\n' "$rf";;
  *"show database"*) printf 'Database - STBYDB\n\n  Role:               PHYSICAL STANDBY\n  Intended State:     APPLY-ON\n  Transport Lag:      0 seconds (computed 1 second ago)\n  Apply Lag:          0 seconds (computed 1 second ago)\n  Average Apply Rate: 1.00 MByte/s\n  Real Time Query:    ON\n  Instance(s):\n    STBY\n\nDatabase Status:\nSUCCESS\n';;
  *"switchover to PRIMDB"*) rm -f "$DRY_LOG.switched"; printf 'Performing switchover NOW, please wait...\nSwitchover succeeded, new primary is "PRIMDB"\n';;
  *"switchover to"*) touch "$DRY_LOG.switched"; printf 'Performing switchover NOW, please wait...\nSwitchover succeeded, new primary is "STBYDB"\n';;
  *"failover to"*) touch "$DRY_LOG.switched"; printf 'Performing failover NOW, please wait...\nFailover succeeded, new primary is "STBYDB"\n';;
  *"reinstate"*) printf 'Reinstating database "PRIMDB", please wait...\nReinstatement of database "PRIMDB" succeeded\n';;
  *) printf 'Succeeded.\n';;
esac
exit 0
D
chmod +x "$STUB/dgmgrl"
# the role change itself goes through dgmgrl, which the gates' CHANGE_RE does not name: fail that call, not an earlier sqlplus
FAIL_heal='dgmgrl .*edit database'; FAIL_switchover='dgmgrl .*switchover to'; FAIL_failover='dgmgrl .*failover to'; FAIL_reinstate='dgmgrl .*reinstate'; FAIL_rollback='dgmgrl .*switchover to'; FAIL_run='dgmgrl .*switchover to'
export DG_PASSWORD=stub   # dgmgrl connects as sys@STBYDB for a remote target; the gate has no terminal to ask
# the forbidden claim is the command's own step (the seeded run carries backup=ok/switchover=ok from the earlier switchover, and
# inspect/preflight/backup rightly record ok before the dgmgrl call of a run fails)
OK_backup='^backup=ok$'; OK_switchover='^switchover=ok$'; OK_failover='^failover=ok$'; OK_reinstate='^reinstate=ok$'; OK_cleanup='^cleanup=ok$'
OK_heal='^heal=ok$'; OK_run='^(switchover|verify|run)=ok$'; OK_rollback='^(rollback|switchover_back)=ok$'
ARGS="--sid FREE STBYDB"; ARGS_failover="--sid FREE STBYDB --force"; ARGS_backup="--sid FREE"; ARGS_cleanup="--sid FREE"; ARGS_rollback="--sid FREE"; ARGS_reinstate="--sid FREE PRIMDB"; ARGS_heal="--sid FREE"
export SQL_CMD="$STUB/sqlplus -S" DGMGRL_CMD="$STUB/dgmgrl" ORACLE_HOME="$T/oh" ORACLE_SID=FREE TNS_ADMIN="$T/oh/network/admin"
mkdir -p "$T/oh/bin" "$T/oh/network/admin"
printf 'SID_LIST_LISTENER = (SID_LIST = (SID_DESC = (GLOBAL_DBNAME = PRIMDB_DGMGRL) (ORACLE_HOME = %s) (SID_NAME = FREE)))\n' "$T/oh" >"$T/oh/network/admin/listener.ora"
printf 'PRIMDB = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = prim)(PORT = 1521)) (CONNECT_DATA = (SERVICE_NAME = PRIMDB)))\nSTBYDB = (DESCRIPTION = (ADDRESS = (PROTOCOL = TCP)(HOST = stby)(PORT = 1521)) (CONNECT_DATA = (SERVICE_NAME = STBYDB)))\n' >"$T/oh/network/admin/tnsnames.ora"
# a run that switched PRIMDB -> STBYDB, so rollback knows what to switch back and cleanup has a restore point to drop
r="$T/home/dg-switchover/runs/20260101-000000-switchover"; mkdir -p "$r"; printf 'old_primary=PRIMDB\ntarget=STBYDB\nbackup=ok\nswitchover=ok\nrestore_points=FREE:DGSWITCH_20260101000000\n' >"$r/state"; ln -sfn "$r" "$T/home/dg-switchover/runs/latest"
