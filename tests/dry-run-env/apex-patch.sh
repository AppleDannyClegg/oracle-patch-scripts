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
ARGS="26.2"; ARGS_stop=""; ARGS_cleanup=""; ARGS_heal=""; ARGS_rollback=""; ARGS_verify=""
