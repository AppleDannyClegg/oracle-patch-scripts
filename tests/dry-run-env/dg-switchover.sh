# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# dg-switchover: local instance FREE is the primary PRIMDB, one physical standby STBYDB, broker on, MaxAvailability.
# dgmgrl is not in the gates' stub list, so this file adds one: it logs like the others, honours FAIL_RE (false-success
# gate) and answers show configuration / validate / show database from canned text keyed on the command.
cat >"$ANSWERS" <<A
database_role\|\|'\|'\|\|open_mode|PRIMDB|PRIMARY|READ WRITE|PRIM
dg_broker_start|TRUE
switchover_status|TO STANDBY
flashback_on|YES
log_mode|ARCHIVELOG
instance_name|FREE
count\(\*\)|0
A
cat >"$STUB/dgmgrl" <<'D'
#!/bin/sh
q=""; [ -t 0 ] || q="$(cat)"
{ echo "TOOL dgmgrl $*"; [ -n "$q" ] && printf '%s\n' "$q" | sed 's/^/  > /'; } >>"$DRY_LOG"
line="dgmgrl $* | $(printf '%s' "$q" | tr '\n' ';')"
if [ -n "${FAIL_RE:-}" ] && printf '%s' "$line" | grep -qiE -- "$FAIL_RE"; then echo "FAILED dgmgrl $*" >>"$DRY_LOG"; echo "ORA-16625: cannot reach database (false-success gate)"; exit 1; fi
case "$q" in
  *"show configuration"*) if [ -e "$DRY_LOG.switched" ]; then printf 'Configuration - dgcfg\n\n  Protection Mode: MaxAvailability\n  Members:\n  STBYDB - Primary database\n    PRIMDB - Physical standby database\n'; else printf 'Configuration - dgcfg\n\n  Protection Mode: MaxAvailability\n  Members:\n  PRIMDB - Primary database\n    STBYDB - Physical standby database\n'; fi; printf '\nFast-Start Failover:  Disabled\n\nConfiguration Status:\nSUCCESS   (status updated 10 seconds ago)\n';;
  *"validate database"*) printf '  Database Role:     Physical standby database\n  Primary Database:  PRIMDB\n\n  Ready for Switchover:  Yes\n  Ready for Failover:    Yes (Primary Running)\n\n  Flashback Database Status:\n    PRIMDB:  On\n    STBYDB:  On\n\n  Temporary Tablespace File Information:\n    PRIMDB TEMP Files:  1\n    STBYDB TEMP Files:  1\n';;
  *"show database"*) printf 'Database - STBYDB\n\n  Role:               PHYSICAL STANDBY\n  Intended State:     APPLY-ON\n  Transport Lag:      0 seconds (computed 1 second ago)\n  Apply Lag:          0 seconds (computed 1 second ago)\n  Average Apply Rate: 1.00 MByte/s\n  Real Time Query:    ON\n  Instance(s):\n    STBY\n\nDatabase Status:\nSUCCESS\n';;
  *"switchover to"*) touch "$DRY_LOG.switched"; printf 'Performing switchover NOW, please wait...\nSwitchover succeeded, new primary is "STBYDB"\n';;
  *"failover to"*) touch "$DRY_LOG.switched"; printf 'Performing failover NOW, please wait...\nFailover succeeded, new primary is "STBYDB"\n';;
  *"reinstate"*) printf 'Reinstating database "PRIMDB", please wait...\nReinstatement of database "PRIMDB" succeeded\n';;
  *) printf 'Succeeded.\n';;
esac
exit 0
D
chmod +x "$STUB/dgmgrl"
# the role change itself goes through dgmgrl, which the gates' CHANGE_RE does not name: fail that call, not an earlier sqlplus
FAIL_switchover='dgmgrl .*switchover to'; FAIL_failover='dgmgrl .*failover to'; FAIL_reinstate='dgmgrl .*reinstate'; FAIL_rollback='dgmgrl .*switchover to'; FAIL_run='dgmgrl .*switchover to'
export DG_PASSWORD=stub   # dgmgrl connects as sys@STBYDB for a remote target; the gate has no terminal to ask
ARGS="--sid FREE STBYDB"; ARGS_backup="--sid FREE"; ARGS_cleanup="--sid FREE"; ARGS_rollback="--sid FREE"; ARGS_reinstate="--sid FREE PRIMDB"; ARGS_heal="--sid FREE"
export SQL_CMD="$STUB/sqlplus -S" DGMGRL_CMD="$STUB/dgmgrl" ORACLE_HOME="$T/oh" ORACLE_SID=FREE
mkdir -p "$T/oh/bin" "$T/oh/network/admin"
