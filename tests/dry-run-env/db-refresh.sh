# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# db-refresh: a TEST CDB 'FREE' with PDB TESTPDB, PROD PDB 'PRODPDB' over link PRODLINK; one app account, one job, one
# PROD-named service, one link to prodhost, one directory under /prod, APEX installed, a mask script, a preserved run.
# The regex side of an answer line must not contain '|' (the stub splits on it); first match wins, so specific lines first.
{ case "$CMD" in create|run) echo "name=upper\\('TESTPDB'\\)|ABSENT";; esac; } >"$ANSWERS"   # create (and run after drop) must find no TESTPDB
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
max\\(open_mode\\),'ABSENT'|READ WRITE
open_mode from v\\\$pdbs where name=|READ WRITE
db_link like upper\\('PRODLINK|prodhost:1521/PROD as (current user)
v\\\$pdbs where name=|1
session_privs|1
encrypted_tablespaces|0
sum\\(bytes\\)/1048576\\) from cdb_data_files|1024
sum\\(bytes\\),0\\)/1048576\\) from cdb_temp_files|256
sum\\(bytes\\)/1048576\\) from dba_data_files|1024
account_status not like '%LOCKED%'|APPUSER
select 1 from dba_users where username=upper|1
dba_scheduler_jobs where enabled='TRUE'|APP.NIGHTLY_JOB
from dba_services where name not like 'SYS%'|prodpdb_app|prodpdb_app
nvl\\(host,''\\) from dba_db_links|APP|TO_PROD|prodhost:1521/PROD
select username from dba_db_links where owner=|PRODUSER
directory_path like '/prod/|DATA_DIR|/prod/data
listagg\\(directory_name|DATA_DIR=/prod/data
max\\(version_no\\),'none'\\) from apex_release|24.2.0
from apex_instance_parameters|SMTP_HOST_ADDRESS=mail.prod
select 'OK' from dual|OK
count\\(\\*\\)|0
A
ARGS="--sid FREE --prod-pdb PRODPDB --test-pdb TESTPDB --link PRODLINK"
ARGS_rollback="$ARGS --keep-old"
# run: preflight, backup and drop record ok before create (the first changing call the gate fails) - those are true; the
# forbidden claims are the steps at and after the failure
OK_run='^(create|rename_services|mask|reimport|relock|fix_[a-z]+|verify|run)=ok$'
export SQL_CMD="$STUB/sqlplus -S" ORACLE_HOME="$T/oh" TEST_SID=FREE
export PROD_HOST_PATTERN=prodhost DIRECTORY_MAP="/prod/=/test/" APEX_PARAMS="SMTP_HOST_ADDRESS=mail.test" MASK_SCRIPT="$T/mask.sql" MASK_VERIFY_SQL="select 'OK' from dual"
mkdir -p "$T/oh/bin"; printf "update app.customers set name='x';\n" >"$T/mask.sql"
# a run that already preserved the TEST-only definitions, so reimport has something to replay
r="$T/home/db-refresh/runs/20260101-000000-backup"; mkdir -p "$r/preserve"; printf 'backup=ok\nold_pdb=TESTPDB_OLD\n' >"$r/state"   # old_pdb: what rollback renames back
printf "CREATE PROFILE \"APP_PROF\" LIMIT PASSWORD_LIFE_TIME UNLIMITED;\n" >"$r/preserve/01_profiles.sql"; printf "CREATE ROLE \"APP_ROLE\";\n" >"$r/preserve/02_roles.sql"
printf "CREATE USER \"APPUSER\" IDENTIFIED BY VALUES 'S:1';\n" >"$r/preserve/03_users.sql"; : >"$r/preserve/04_grants.sql"; : >"$r/preserve/05_dblinks.sql"; : >"$r/preserve/06_directories.sql"
ln -sfn "$r" "$T/home/db-refresh/runs/latest"
