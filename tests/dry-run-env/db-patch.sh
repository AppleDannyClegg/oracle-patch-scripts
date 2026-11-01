# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# db-patch: one 19c home under $T/env/oh with a fake OPatch, one database FREE given with --sid (no oratab, nothing in ps), RU 39000000 waiting in $T/env/patches
OH="$T/env/oh"; mkdir -p "$OH/OPatch" "$OH/bin" "$OH/rdbms/admin" "$OH/dbs" "$OH/network/admin" "$T/env/patches/39000000/etc/config" "$T/env/backups"
# opatch: version/lspatches answer here; apply and rollback go to the gate's stub, and only a stub that SUCCEEDED marks the patch installed
# (lspatches lists 39000000 while $T/env/installed exists) - so a failed apply is not in the inventory, as on a real home
cat >"$OH/OPatch/opatch" <<O
#!/bin/sh
case "\$1" in
  version) echo "OPatch Version: 12.2.0.1.42"; exit 0;;
  lspatches) [ -e "$T/env/installed" ] && echo "39000000;Database Release Update : 19.24.0.0.240716 (39000000)"; echo "29585399;OCW RELEASE UPDATE 19.3.0.0.0 (29585399)"; exit 0;;
  apply) "$STUB/opatch" "\$@" && touch "$T/env/installed"; exit \$?;;
  rollback) "$STUB/opatch" "\$@" && rm -f "$T/env/installed"; exit \$?;;
esac
exec "$STUB/opatch" "\$@"
O
chmod +x "$OH/OPatch/opatch"
# datapatch is called by its path in the home; sqlplus by its path for -V, shutdown and startup (the SQL itself goes through SQL_CMD = the stub)
printf '#!/bin/sh\nexec "%s/datapatch" "$@"\n' "$STUB" >"$OH/OPatch/datapatch"; chmod +x "$OH/OPatch/datapatch"
printf '#!/bin/sh\n[ "$1" = -V ] && { echo "SQL*Plus: Release 19.0.0.0.0 - Production"; echo "Version 19.24.0.0.0"; exit 0; }\nexec "%s/sqlplus" "$@"\n' "$STUB" >"$OH/bin/sqlplus"; chmod +x "$OH/bin/sqlplus"
: >"$OH/rdbms/admin/utlrp.sql"; : >"$OH/dbs/initFREE.ora"
# the patch, already unzipped (prepare_patch_dir unzips only what is not there)
printf '<oneoffs><oneoff ref_id="39000000"><description>Database Release Update : 19.24.0.0.240716 (39000000)</description></oneoff></oneoffs>\n' >"$T/env/patches/39000000/etc/config/inventory.xml"
# installed for the commands that come after apply (rollback must have something to roll back; verify/datapatch see the RU in the home)
case "$CMD" in rollback|datapatch|verify|start|cleanup|restore) touch "$T/env/installed";; esac
cat >"$ANSWERS" <<'A'
database_role.*open_mode|PRIMARY/READ WRITE
database_role|PRIMARY
log_mode|ARCHIVELOG
dataguard_stats|
v\$backup where status|0
rman_backup_job_details|0
sqlpatch where status not in|0
dba_objects where status|0
v\$pdbs where open_mode|0
select cdb from|NO
v\$containers|FREE: 19.24.0.0.240716 SUCCESS
recovery_file_dest|40
restore_point where name|0
A
export SQL_CMD="$STUB/sqlplus -S" BACKUP_DIR="$T/env/backups" RMAN_CMD="$STUB/rman"
ARGS="$T/env/patches --home $OH --sid FREE"; for dbp_cmd in backup stop start datapatch verify rollback restore cleanup heal; do eval "ARGS_$dbp_cmd=\"--home $OH --sid FREE\""; done   # not c: that is the gate's loop variable; ARGS_download="$T/env/patches --home $OH --sid FREE 39000000"
# a run dir as 'apply' left it: the RU applied, FREE was running, a restore point and a home backup to clean up / restore
R="$T/home/db-patch/runs/r1"; mkdir -p "$R/FREE"; tar -czf "$T/env/backups/oracle_home_oh_20260101000000.tar.gz" -C "$T/env" oh
printf 'preflight=ok\nwas_running=FREE\nhome_backup=%s\nrestore_points=FREE:DBPATCH_20260101000000\nbackup=ok\napplied=39000000\napply=ok\n' "$T/env/backups/oracle_home_oh_20260101000000.tar.gz" >"$R/state"
ln -sfn "$R" "$T/home/db-patch/runs/latest"
# start: the change is 'startup' through the home's sqlplus; when it fails the instance is down, so every later sqlplus call fails
# too (the probes included) - the default 'probes keep answering' would make a down instance answer 'ok' as sysdba
FAIL_start='^sqlplus '
# rollback: the change is 'opatch rollback'; a home left half rolled back does not start, so the startup inside rollback and the
# probes after it fail as well (otherwise the stub answers 'PRIMARY/READ WRITE' to a database whose startup just failed)
FAIL_rollback='^(opatch rollback|sqlplus )'
