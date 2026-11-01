# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# db-refresh: a TEST CDB 'FREE' with PDB TESTPDB, PROD PDB 'PRODPDB' over link PRODLINK, no masking, nothing to preserve
# create must find no TESTPDB; every other command works on an existing one
{ [ "$CMD" = create ] && echo "name=upper\\('TESTPDB'\\)|ABSENT"; } >"$ANSWERS"
cat >>"$ANSWERS" <<A
select cdb from|YES
db_unique_name|TESTDB
select version_full|19.0.0.0.0
select version from|19.0.0.0.0
open_mode from v\\\$database|READ WRITE
log_mode|ARCHIVELOG
LOCAL_UNDO_ENABLED|TRUE
NLS_CHARACTERSET|AL32UTF8
name='compatible'|19.0.0
db_create_file_dest|/u02/oradata
max\(open_mode\),'ABSENT'|READ WRITE
open_mode from v\\\$pdbs where name=|READ WRITE
v\\\$pdbs where name=|1
session_privs|1
encrypted_tablespaces|0
sum\(bytes\)/1048576\) from cdb_data_files|1024
sum\(bytes\),0\)/1048576\) from cdb_temp_files|256
sum\(bytes\)/1048576\) from dba_data_files|1024
count\(\*\)|0
A
ARGS="--sid FREE --prod-pdb PRODPDB --test-pdb TESTPDB --link PRODLINK"
ARGS_rollback="--sid FREE --prod-pdb PRODPDB --test-pdb TESTPDB --link PRODLINK --keep-old"
export SQL_CMD="$STUB/sqlplus -S" ORACLE_HOME="$T/oh" TEST_SID=FREE
mkdir -p "$T/oh/bin"
