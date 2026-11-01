# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# apex-patch: an APEX 24.2 full install in PDB1 of a 19c CDB, release 26.2 unpacked, images dir on disk
cat >"$ANSWERS" <<'A'
version_full|19.26.0.0.0
log_mode|ARCHIVELOG
select cdb from|YES
con_name|PDB1
select schema from dba_registry|APEX_240200
select status from dba_registry|VALID
version_no from apex_release|24.2.0
id between 4000 and 4999|12
dba_tablespaces|1
status='INVALID'|0
restore_point|
A
mkdir -p "$T/env/apex/apex_26.2/apex/images" "$T/env/apex/apex_24.2/apex" "$T/env/images"; touch "$T/env/apex/apex_26.2/apex/apexins.sql" "$T/env/apex/apex_26.2/apex/apxrtins.sql" "$T/env/apex/apex_24.2/apex/apxdwngrd.sql" "$T/env/apex/apex_24.2/apex/apexins.sql"
echo "Application Express Version: 26.2.0" >"$T/env/apex/apex_26.2/apex/images/apex_version.txt"; echo "Application Express Version: 24.2.0" >"$T/env/images/apex_version.txt"
export SQL_CMD="$STUB/sqlplus -S" APEX_BASE="$T/env/apex" APEX_IMAGES_DIR="$T/env/images" APEX_TS=SYSAUX APEX_FILES_TS=SYSAUX APEX_TEMP_TS=TEMP
ARGS="26.2"; ARGS_stop=""; ARGS_cleanup=""; ARGS_heal=""; ARGS_rollback="--allow-flashback"; ARGS_verify=""
# after 'apply': the database is on 26.2 and a run dir records the upgrade, so rollback/cleanup have something to act on
# (under --dry-run the flashback and the drops must send nothing; in the false-success gate apxdwngrd/flashback/drop fail)
case "$CMD" in rollback|cleanup|heal)
  sed -i.bak 's/^select schema from dba_registry|.*/select schema from dba_registry|APEX_260200/; s/^version_no from apex_release|.*/version_no from apex_release|26.2.0/' "$ANSWERS"; rm -f "$ANSWERS.bak"
  mkdir -p "$T/home/apex-patch/runs/r1"; printf 'target=26.2\nprev_version=24.2.0\nprev_schema=APEX_240200\nprev_type=full\nrestore_point=APEXPATCH_X\napplied=26.2\nimages_mode=copy\n' >"$T/home/apex-patch/runs/r1/state"
  ln -sfn "$T/home/apex-patch/runs/r1" "$T/home/apex-patch/runs/latest";;
esac
# run: apply fails at apexins, the revert runs apxdwngrd (fails too) and then trusts the registry, which the answers say is on the old schema - rolled_back=1 is that query, not the tool's exit
OK_run="^(applied=|verified=1)"
export START_TIMEOUT=5   # ords_start after a rollback must not wait 300 s for a URL nothing answers
