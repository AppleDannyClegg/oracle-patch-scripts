# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# db-patch: one 19c home under $T/env/oh with a fake OPatch, one database FREE given with --sid (no oratab; its pmon is in the gate's
# ps for every command but start and restore, which want it down), RU 39000000 waiting in $T/env/patches
OH="$T/env/oh"; mkdir -p "$OH/OPatch" "$OH/bin" "$OH/rdbms/admin" "$OH/dbs" "$OH/network/admin" "$T/env/patches/39000000/etc/config" "$T/env/backups"
# opatch: version/lspatches answer here; apply and rollback go to the gate's stub, and only a stub that SUCCEEDED marks the patch installed
# (lspatches lists 39000000 while $T/env/installed exists) - so a failed apply is not in the inventory, as on a real home
cat >"$OH/OPatch/opatch" <<O
#!/bin/sh
case "\$1" in
  version) echo "OPatch Version: 12.2.0.1.42"; exit 0;;
  prereq) echo 'Prereq "checkConflictAgainstOHWithDetail" passed.'; exit 0;;
  lspatches) [ -e "$T/env/installed" ] && echo "39000000;Database Release Update : 19.24.0.0.240716 (39000000)"; echo "29585399;OCW RELEASE UPDATE 19.3.0.0.0 (29585399)"; exit 0;;
  apply) "$STUB/opatch" "\$@" && touch "$T/env/installed"; exit \$?;;
  rollback) "$STUB/opatch" "\$@" && rm -f "$T/env/installed"; exit \$?;;
esac
exec "$STUB/opatch" "\$@"
O
chmod +x "$OH/OPatch/opatch"
# datapatch is called by its path in the home; sqlplus by its path for -V, shutdown and startup (the SQL itself goes through SQL_CMD = the stub)
printf '#!/bin/sh\nexec "%s/datapatch" "$@"\n' "$STUB" >"$OH/OPatch/datapatch"; chmod +x "$OH/OPatch/datapatch"
# the home's sqlplus models the world the ps stub shows ($T/ps.txt): a shutdown the stub accepted takes ora_pmon_FREE out of ps, a
# startup it accepted puts it back - so stop's 'pmon gone' proof and start's 'already running' check see what the statements did
cat >"$OH/bin/sqlplus" <<S
#!/bin/sh
[ "\$1" = -V ] && { echo "SQL*Plus: Release 19.0.0.0.0 - Production"; echo "Version 19.24.0.0.0"; exit 0; }
q="\$(cat)"; printf '%s' "\$q" | "$STUB/sqlplus" "\$@"; rc=\$?
[ \$rc = 0 ] && case "\$q" in *shutdown*) rm -f "$T/ps.txt";; *startup*) echo ora_pmon_FREE >"$T/ps.txt";; esac
exit \$rc
S
chmod +x "$OH/bin/sqlplus"
case "$CMD" in start|restore) rm -f "$T/ps.txt";; *) echo ora_pmon_FREE >"$T/ps.txt";; esac
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
archive_dest where target|0
v\$session where type|3
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
# rollback: the change is 'opatch rollback' and only that fails - the stop before it succeeds (pmon leaves ps) and the start after it
# brings FREE back READ WRITE on the home as it was, which is what a cleanly refused opatch rollback leaves. The lines a failed
# opatch rollback must not produce: rollback=ok. stopped=ok and started=ok are those steps' own claims, each proved (pmon gone / open_mode read)
FAIL_rollback='^opatch rollback'; OK_rollback='^rollback=ok$'
# run: the change is 'opatch apply'; backup (pfile, controlfile, restore point) and stop (pmon gone) before it are true, the fake
# opatch leaves a failed RU out of lspatches so apply=failed, nothing is recorded as applied and run starts FREE again (started=ok,
# open_mode read) and exits 1. Forbidden after that: apply=ok, applied=<id>, datapatch=ok, verify=ok, rollback=ok
FAIL_run='^opatch apply'; OK_run='^(apply=ok|applied=[^[:space:]]|datapatch=ok|verify=ok|rollback=ok)'
# <cmd>:ps_unreadable - ps cannot run (the gate's $T/ps.fail) and PROC_DIR is an empty dir, so lib's /proc fallback finds nothing
# either (5cc183f). --sid FREE is stripped from the case's ARGS: with it, discovery never reads the list. No stub call is meant to
# fail, so FAIL_* matches nothing and the ps stub's own FAILED line is what the gate counts. df9d2c9: before it every
# 'db_instances | grep -qx SID' read a failed ps as 'not running' - stop recorded stopped=ok with nothing stopped, apply/datapatch/
# rollback/run recorded applied=/datapatch=ok/rollback=ok on a home whose instance may be up, restore untarred over it, start
# recorded started=ok; now up() dies 'cannot read the process list ... refusing to go on', rc 1, no state line. download is not
# here: it never reads the list (ok on both sides of df9d2c9 - a case that cannot fail proves nothing).
for _c in backup stop apply start datapatch rollback restore cleanup heal run; do
  _a="ARGS_$_c"; _v="${!_a-$ARGS}"; eval "CASES_$_c='ps_unreadable'; FAIL_${_c}__ps_unreadable='^never matches\$'; ARGS_${_c}__ps_unreadable=\"\${_v//--sid FREE/}\""
done
case "${CASE:-}" in ps_unreadable) : >"$T/ps.fail"; mkdir -p "$T/env/noproc"; export PROC_DIR="$T/env/noproc";; esac
