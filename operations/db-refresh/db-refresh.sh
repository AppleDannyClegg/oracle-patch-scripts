#!/usr/bin/env bash
# db-refresh.sh - refresh a TEST database from PROD and make it safe to be a test again: PDB hot clone
# over a database link (optionally through a refreshable golden copy) or RMAN duplicate (active or from
# backup), then the post-refresh hygiene: services renamed, data masked, accounts locked, database links
# to production removed, APEX pointed at test, scheduler jobs disabled, directories remapped, the old
# TEST's users/grants/links put back. Runs on the TEST database server as oracle, never root.
#
# Usage: db-refresh.sh <command> [options]
#
# Commands
#   inspect            TEST CDB/PDB, PROD reachable over the link / TNS, sizes, charset/compatible, TDE, users connected
#   plan               What run would do, touching nothing
#   preflight          Space, TNS both ways, password file, link privileges, charset/compatible, TDE keystore, local undo
#                      and archivelog on PROD, mask script present, nobody important connected, keep-old space
#   backup             Preservation: DDL of the TEST PDB's users/roles/grants/profiles/db links/directories (dbms_metadata),
#                      expdp of --preserve-schemas when EXP_CONNECT is set, spfile, tnsnames, APEX instance parameters,
#                      scheduler job states, services
#   drop               Close and drop the TEST PDB (--keep-old renames it to <PDB>_OLD instead; --no-drop skips)
#   create             pdb-clone: create pluggable database ... from PROD_PDB@PROD_LINK (or refresh the golden copy and
#                      clone from it with --refreshable); rman-duplicate: duplicate ... from active database / backup
#   rename-services    Services carrying PROD names -> SERVICE_MAP or PROD_PDB->TEST_PDB substitution
#   mask               Run MASK_SCRIPT in the new PDB (required when --require-mask / REQUIRE_MASK=yes)
#   relock             Lock every account not in ACCOUNT_WHITELIST / TEST_ACCOUNTS; set TEST_ACCOUNTS' password
#   fix-dblinks        Drop (or remap via DBLINK_MAP) every database link whose host matches PROD_HOST_PATTERN
#   fix-apex           apex_instance_admin.set_parameter for APEX_PARAMS, restore the old TEST's instance parameters
#   fix-scheduler      Disable jobs: DISABLE_JOBS=ALL | job,job | NONE (oracle-maintained ones untouched)
#   fix-directories    DIRECTORY_MAP /prod/path=/test/path applied to dba_directories
#   reimport           Re-create the preserved users/roles/grants/links/directories; impdp the preserved schemas
#   verify             PDB open, MASK_VERIFY_SQL says OK, no link to PROD, no stray open account, services, APEX URL
#   rollback           Only after --keep-old: drop the new PDB, rename <PDB>_OLD back and open it
#   cleanup            Drop <PDB>_OLD (and the golden copy with --all)
#   run                inspect > preflight > backup > drop > create > rename-services > mask > relock > fix-dblinks >
#                      fix-apex > fix-scheduler > fix-directories > reimport > verify
#
# Options
#   --method pdb-clone|rman-duplicate    --sid TESTSID   --prod-pdb NAME   --test-pdb NAME   --link DBLINK
#   --refreshable       keep a refreshable golden PDB <TEST_PDB>_GOLD; refresh it, clone TEST from it (fast repeats)
#   --snapshot          snapshot copy for the local clone (storage must support it)
#   --from-backup DIR   rman-duplicate from a backup location instead of the active database
#   --no-drop  --keep-old  --preserve-schemas A,B  --require-mask  --noarchivelog  --skip STEP,STEP
#   --dry-run  --yes  --force  --verbose  --run-dir DIR
#
# Config (db-refresh.conf, mode 600): see db-refresh.conf.example. PROD passwords and the keystore password are
# prompted when not in the file; they never appear on a command line.

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="db-refresh"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

METHOD="${METHOD:-pdb-clone}"; SID="${TEST_SID:-${ORACLE_SID:-}}"; PROD_PDB="${PROD_PDB:-}"; TEST_PDB="${TEST_PDB:-}"; PROD_LINK="${PROD_LINK:-}"
PROD_TNS="${PROD_TNS:-}"; TEST_TNS="${TEST_TNS:-}"; REFRESHABLE="${REFRESHABLE:-0}"; SNAPSHOT=0; FROM_BACKUP=""; NO_DROP=0; KEEP_OLD="${KEEP_OLD:-0}"
PRESERVE_SCHEMAS="${PRESERVE_SCHEMAS:-}"; REQUIRE_MASK="${REQUIRE_MASK:-no}"; NOARCHIVELOG="${NOARCHIVELOG:-no}"; SKIP=""
MASK_SCRIPT="${MASK_SCRIPT:-}"; MASK_VERIFY_SQL="${MASK_VERIFY_SQL:-}"; ACCOUNT_WHITELIST="${ACCOUNT_WHITELIST:-}"; TEST_ACCOUNTS="${TEST_ACCOUNTS:-}"
PROD_HOST_PATTERN="${PROD_HOST_PATTERN:-}"; DBLINK_MAP="${DBLINK_MAP:-}"; APEX_PARAMS="${APEX_PARAMS:-}"; APEX_RESTORE_PARAMS="${APEX_RESTORE_PARAMS:-yes}"; APEX_TEST_URL="${APEX_TEST_URL:-}"
DISABLE_JOBS="${DISABLE_JOBS:-ALL}"; DIRECTORY_MAP="${DIRECTORY_MAP:-}"; SERVICE_MAP="${SERVICE_MAP:-}"; EXP_CONNECT="${EXP_CONNECT:-}"; DATA_PUMP_DIR="${DATA_PUMP_DIR:-DATA_PUMP_DIR}"
CLONE_OPTIONS="${CLONE_OPTIONS:-}"; CLONE_PARALLEL="${CLONE_PARALLEL:-4}"; TEST_PFILE="${TEST_PFILE:-}"; DUPLICATE_OPTIONS="${DUPLICATE_OPTIONS:-nofilenamecheck}"; SECTION_SIZE="${SECTION_SIZE:-32G}"
GOLD_PDB=""; DB_HOME=""; GRID_HOME=""; IS_CDB=0; TEST_DBUN=""; ALL=0

usage() { usage_from_header "$0"; }
parse_opts() {
  while [ $# -gt 0 ]; do case "$1" in
    --method) optchk "$@"; METHOD="$2"; shift 2;; --sid) optchk "$@"; SID="$2"; shift 2;; --prod-pdb) optchk "$@"; PROD_PDB="$2"; shift 2;; --test-pdb) optchk "$@"; TEST_PDB="$2"; shift 2;; --link) optchk "$@"; PROD_LINK="$2"; shift 2;;
    --refreshable) REFRESHABLE=1; shift;; --snapshot) SNAPSHOT=1; shift;; --from-backup) optchk "$@"; FROM_BACKUP="$2"; shift 2;; --no-drop) NO_DROP=1; shift;; --keep-old) KEEP_OLD=1; shift;;
    --preserve-schemas) optchk "$@"; PRESERVE_SCHEMAS="$2"; shift 2;; --require-mask) REQUIRE_MASK=yes; shift;; --noarchivelog) NOARCHIVELOG=yes; shift;; --skip) optchk "$@"; SKIP=",$2,"; shift 2;; --all) ALL=1; shift;;
    --dry-run) DRY_RUN=1; shift;; --yes) ASSUME_YES=1; shift;; --force) FORCE=1; shift;; --verbose) VERBOSE=1; shift;; --run-dir) optchk "$@"; RUN_DIR="$2"; shift 2;;
    -h|--help) usage; exit 0;; *) die "Unknown option: $1";; esac; done
  case "$METHOD" in pdb-clone|rman-duplicate) ;; *) die "--method must be pdb-clone or rman-duplicate";; esac
  [ -n "$TEST_PDB" ] && GOLD_PDB="${TEST_PDB}_GOLD"
}
skipped() { case "$SKIP" in *",$1,"*) log "step $1 skipped (--skip)"; return 0;; esac; return 1; }

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
uc() { tr '[:lower:]' '[:upper:]'; }
psql() { with_pdb "$TEST_PDB" sql_run "$SID" "$@"; }          # in the TEST PDB (formatted)
plines() { with_pdb "$TEST_PDB" sql_lines "$SID" "$@"; }      # in the TEST PDB (rows)
pval() { with_pdb "$TEST_PDB" sql_val "$SID" "$@"; }
rsql() { PDB_SET="" sql_run "$SID" "$@"; }                     # in the root
rlines() { PDB_SET="" sql_lines "$SID" "$@"; }
rval() { PDB_SET="" sql_val "$SID" "$@"; }
# do_sql <where root|pdb> <description> <sql>: logged, honours dry-run, fails on ORA-
do_sql() {
  local where="$1" desc="$2" q="$3" out
  log "SQL[$where]: $desc"; dbg "$q"; [ "$DRY_RUN" = 1 ] && return 0
  if [ "$where" = pdb ]; then out="$(psql "whenever sqlerror exit 1\n$q")"; else out="$(rsql "whenever sqlerror exit 1\n$q")"; fi
  printf '%s\n' "$out" >>"$LOG_FILE"
  if printf '%s' "$out" | grep -qE 'ORA-[0-9]+|SP2-[0-9]+'; then err "  $(printf '%s' "$out" | grep -E 'ORA-|SP2-' | head -2 | tr '\n' ' ')"; return 1; fi
  return 0
}
pdb_mode() { rval "(select nvl(max(open_mode),'ABSENT') from v\$pdbs where name=upper('$1'))"; }
pdb_exists() { [ "$(pdb_mode "$1")" != ABSENT ]; }
pdb_refresh_mode() { rval "(select nvl(max(refresh_mode),'-') from dba_pdbs where pdb_name=upper('$1'))"; }
# prod_val "(select x from t ...)": the scalar from PROD. "@link" goes on every table in the expression ("from t" -> "from t@link");
# an expression cannot carry the link itself ("(select ...)@link" is not SQL)
prod_val() {
  [ -n "$PROD_LINK" ] || return 1; local q n m k
  # case-insensitive, and every FROM must end up linked: a FROM the rewrite did not reach (uppercase before this
  # fix, an unexpected shape) would run that clause on TEST and compare PROD with itself, silently; a FROM inside a
  # string literal would get the link bolted into the literal, so that is refused as well
  q="$(printf '%s' "$1" | sed -E "s/([[:space:]])([Ff][Rr][Oo][Mm])([[:space:]]+)([A-Za-z_][A-Za-z0-9_\$#.]*)/\1\2\3\4@$PROD_LINK/g")"
  n="$(printf '%s' "$1" | grep -oiE '[[:space:]]from[[:space:]]' | grep -c .)"; m="$(printf '%s' "$q" | grep -oF "@$PROD_LINK" | grep -c .)"
  k="$(printf '%s' "$1" | sed "s/'[^']*'//g" | grep -oiE '[[:space:]]from[[:space:]]' | grep -c .)"
  [ "$n" = "$k" ] || die "prod_val: a FROM inside a string literal in: $1"
  [ "$n" = "$m" ] || die "prod_val: $n FROM but $m linked to $PROD_LINK in: $1"
  rval "$q" 2>/dev/null
}
discover() {
  [ -z "$SID" ] && { local n; n="$(db_instances | grep -vE '^\+' | grep -c .)"; [ "$n" = 1 ] && SID="$(db_instances | grep -vE '^\+')"; }
  [ -n "$SID" ] || die "Which TEST instance? --sid SID / TEST_SID (running: $(db_instances | tr '\n' ' '))"
  DB_HOME="$(db_home_of "$SID")"; GRID_HOME="$(grid_home)"
  sql_ok "$SID" || die "cannot connect to $SID as sysdba"
  TEST_DBUN="$(rval "(select db_unique_name from v\$database)")"; db_is_cdb "$SID" && IS_CDB=1
  if [ "$METHOD" = pdb-clone ]; then
    [ "$IS_CDB" = 1 ] || die "$SID is not a CDB: use --method rman-duplicate"
    [ -n "$PROD_PDB" ] || die "PROD_PDB / --prod-pdb needed"; [ -n "$TEST_PDB" ] || die "TEST_PDB / --test-pdb needed"; [ -n "$PROD_LINK" ] || die "PROD_LINK / --link needed (a database link in $SID's root to the PROD CDB root)"
    PROD_PDB="$(printf '%s' "$PROD_PDB" | uc)"; TEST_PDB="$(printf '%s' "$TEST_PDB" | uc)"; GOLD_PDB="${TEST_PDB}_GOLD"
  else
    [ -n "$PROD_TNS" ] || [ -n "$FROM_BACKUP" ] || die "PROD_TNS needed for an active duplicate (or --from-backup DIR)"
  fi
}
refuse_prod() { # never run this against something that looks like production
  local n; n="$(printf '%s' "$TEST_DBUN" | uc)"
  if [ -n "$PROD_HOST_PATTERN" ] && hostname -f 2>/dev/null | grep -qiE "$PROD_HOST_PATTERN"; then [ "$FORCE" = 1 ] || die "this host matches PROD_HOST_PATTERN ($PROD_HOST_PATTERN) - refusing to refresh here (--force if you are sure)"; fi
  case "$n" in *PROD*|*PRD*|*LIVE*) [ "$FORCE" = 1 ] || die "TEST database is called $TEST_DBUN - that looks like production; --force if it really is the test";; esac
  [ "$METHOD" = pdb-clone ] && [ "$TEST_PDB" = "$PROD_PDB" ] && [ -z "$PROD_LINK" ] && die "TEST and PROD PDB have the same name on the same CDB?"
  return 0
}

# ---------------------------------------------------------------------------
# inspect / plan / preflight
# ---------------------------------------------------------------------------
cmd_inspect() {
  discover
  echo "TEST            : $SID ($TEST_DBUN) home $DB_HOME, CDB=$IS_CDB, $(rval "(select open_mode||' '||log_mode from v\$database)"), db_create_file_dest=$(rval "(select nvl(value,'not set') from v\$parameter where name='db_create_file_dest')")"
  echo "Method          : $METHOD$([ "$REFRESHABLE" = 1 ] && echo " (refreshable golden copy $GOLD_PDB)")$([ "$SNAPSHOT" = 1 ] && echo ' snapshot copy')$([ -n "$FROM_BACKUP" ] && echo " from backup $FROM_BACKUP")"
  if [ "$METHOD" = pdb-clone ]; then
    echo "TEST PDB        : $TEST_PDB $(pdb_mode "$TEST_PDB") refresh_mode=$(pdb_refresh_mode "$TEST_PDB") size $(pval "(select round(sum(bytes)/1073741824,1)||' GB' from dba_data_files)" 2>/dev/null)  sessions: $(rval "(select count(*) from v\$session s join v\$pdbs p on p.con_id=s.con_id where p.name='$TEST_PDB' and s.type='USER')")"
    pdb_exists "$GOLD_PDB" && echo "Golden copy     : $GOLD_PDB $(pdb_mode "$GOLD_PDB") refresh_mode=$(pdb_refresh_mode "$GOLD_PDB") last refresh scn $(rval "(select nvl(max(last_refresh_scn),0) from dba_pdbs where pdb_name='$GOLD_PDB')")"
    pdb_exists "${TEST_PDB}_OLD" && echo "Old copy        : ${TEST_PDB}_OLD $(pdb_mode "${TEST_PDB}_OLD") (from a --keep-old run; cleanup drops it)"
    echo "Link $PROD_LINK : $(rlines "select host||' as '||nvl(username,'(current user)') from dba_db_links where owner in ('SYS','PUBLIC') and db_link like upper('$PROD_LINK%');" | head -1)"
    local pver; pver="$(prod_val "(select version_full from v\$instance)")"; [ -z "$pver" ] && pver="$(prod_val "(select version from v\$instance)")"
    if [ -n "$pver" ]; then
      echo "PROD (via link) : version $pver, $(prod_val "(select name||' '||log_mode from v\$database)"), local undo $(prod_val "(select property_value from database_properties where property_name='LOCAL_UNDO_ENABLED')"), charset $(prod_val "(select value from nls_database_parameters where parameter='NLS_CHARACTERSET')"), compatible $(prod_val "(select value from v\$parameter where name='compatible')")"
      echo "PROD PDB        : $PROD_PDB $(prod_val "(select nvl(max(open_mode),'ABSENT') from v\$pdbs where name='$PROD_PDB')") size $(prod_val "(select round(sum(bytes)/1073741824,1)||' GB' from cdb_data_files where con_id=(select con_id from v\$pdbs where name='$PROD_PDB'))") , encrypted tablespaces $(prod_val "(select count(*) from v\$encrypted_tablespaces where con_id=(select con_id from v\$pdbs where name='$PROD_PDB'))")"
    else echo "PROD (via link) : NOT REACHABLE through $PROD_LINK ($(rlines "select 'x' from dual@$PROD_LINK;" 2>&1 | grep -E 'ORA-' | head -1))"; fi
    echo "TEST charset    : $(rval "(select value from nls_database_parameters where parameter='NLS_CHARACTERSET')"), compatible $(rval "(select value from v\$parameter where name='compatible')"), keystore $(rval "(select nvl(max(status),'none') from v\$encryption_wallet)")"
  else
    echo "TEST instance   : $(rval "(select instance_name||' '||status from v\$instance)") db_name $(rval "(select name from v\$database)") datafiles $(rval "(select round(sum(bytes)/1073741824,1)||' GB' from v\$datafile)")"
    echo "PROD TNS        : ${PROD_TNS:-n/a}  $([ -n "$PROD_TNS" ] && { ORACLE_HOME="$DB_HOME" to 20 "$DB_HOME/bin/tnsping" "$PROD_TNS" 2>&1 | tail -1; })"
    echo "TEST TNS        : ${TEST_TNS:-n/a} (PROD must reach this for an active duplicate; static listener entry needed while NOMOUNT)"
    echo "Password file   : $(ls "$DB_HOME/dbs/orapw$SID" 2>/dev/null || echo "missing: $DB_HOME/dbs/orapw$SID")"
    echo "pfile for dup   : ${TEST_PFILE:-$RUN_DIR/init$SID.ora (generated from the spfile)}"
  fi
  echo "Space           : $(rval "(select nvl(value,'') from v\$parameter where name='db_create_file_dest')" | grep -q '^+' && "$GRID_HOME/bin/asmcmd" lsdg 2>/dev/null | awk 'NR>1{printf "%s %s MB free; ", $NF, $(NF-4)}' || df -Pm "$(rval "(select substr(name,1,instr(name,'/',-1)) from v\$datafile where rownum=1)" 2>/dev/null || echo /)" | awk 'NR==2{print $6": "$4" MB free"}')"
  echo "Mask            : ${MASK_SCRIPT:-none} $([ -n "$MASK_SCRIPT" ] && { [ -f "$MASK_SCRIPT" ] && echo '(present)' || echo '(MISSING)'; }) required=$REQUIRE_MASK verify=${MASK_VERIFY_SQL:+set}"
  echo "Hygiene         : whitelist [$ACCOUNT_WHITELIST] test accounts [$TEST_ACCOUNTS] prod pattern [$PROD_HOST_PATTERN] jobs=$DISABLE_JOBS apex params [$APEX_PARAMS] dirs [$DIRECTORY_MAP] services [$SERVICE_MAP] preserve [$PRESERVE_SCHEMAS]"
  [ "$METHOD" = pdb-clone ] && pdb_exists "$TEST_PDB" && { echo "TEST PDB links  :"; plines "select '  '||owner||'.'||db_link||' -> '||host from dba_db_links;" 2>/dev/null; echo "TEST PDB open accounts: $(plines "select listagg(username,',') within group (order by username) from dba_users where account_status='OPEN' and oracle_maintained='N';" 2>/dev/null | head -1)"; }
  return 0
}

cmd_plan() {
  discover
  echo "PLAN: refresh $([ "$METHOD" = pdb-clone ] && echo "$TEST_PDB in $SID from $PROD_PDB@$PROD_LINK" || echo "$SID from ${FROM_BACKUP:-$PROD_TNS (active)}") via $METHOD"
  echo "  1. preflight      space, link/TNS, charset+compatible, TDE, PROD local undo+archivelog, mask script, sessions"
  echo "  2. backup         dbms_metadata DDL of users/roles/grants/profiles/db links/directories of $TEST_PDB$([ -n "$PRESERVE_SCHEMAS" ] && echo "; expdp $PRESERVE_SCHEMAS"); spfile; tnsnames; APEX instance parameters; job states; services"
  echo "  3. drop           $([ "$NO_DROP" = 1 ] && echo 'skipped (--no-drop)' || { [ "$KEEP_OLD" = 1 ] && echo "rename $TEST_PDB -> ${TEST_PDB}_OLD (rollback possible; needs the space of both)" || echo "drop pluggable database $TEST_PDB including datafiles"; })"
  if [ "$METHOD" = pdb-clone ]; then
    [ "$REFRESHABLE" = 1 ] && echo "  4. create         $GOLD_PDB: $(pdb_exists "$GOLD_PDB" && echo 'alter pluggable database refresh' || echo "create ... from $PROD_PDB@$PROD_LINK refresh mode manual"); then create pluggable database $TEST_PDB from $GOLD_PDB$([ "$SNAPSHOT" = 1 ] && echo ' snapshot copy') $CLONE_OPTIONS; open" \
                         || echo "  4. create         create pluggable database $TEST_PDB from $PROD_PDB@$PROD_LINK parallel $CLONE_PARALLEL ${KEYSTORE_PASSWORD:+keystore identified by ***} $CLONE_OPTIONS; open read write; save state"
  else echo "  4. create         shutdown abort $SID; startup nomount pfile; rman duplicate $([ -n "$FROM_BACKUP" ] && echo "database ... to $SID backup location '$FROM_BACKUP'" || echo "target database to $SID from active database using backupset section size $SECTION_SIZE") $DUPLICATE_OPTIONS$([ "$NOARCHIVELOG" = yes ] && echo '; alter database noarchivelog')"; fi
  echo "  5. rename-services ${SERVICE_MAP:-$PROD_PDB->$TEST_PDB substitution}   6. mask ${MASK_SCRIPT:-none} (required: $REQUIRE_MASK)   7. relock all but [$ACCOUNT_WHITELIST $TEST_ACCOUNTS]"
  echo "  8. fix-dblinks    drop links to '$PROD_HOST_PATTERN'${DBLINK_MAP:+, remap $DBLINK_MAP}   9. fix-apex ${APEX_PARAMS:-} restore=$APEX_RESTORE_PARAMS   10. fix-scheduler $DISABLE_JOBS   11. fix-directories ${DIRECTORY_MAP:-none}"
  echo "  12. reimport      preserved DDL${PRESERVE_SCHEMAS:+ + impdp $PRESERVE_SCHEMAS}   13. verify  mask OK, no prod links, accounts, services${APEX_TEST_URL:+, $APEX_TEST_URL}"
  echo "  rollback          $([ "$KEEP_OLD" = 1 ] && echo "drop $TEST_PDB, rename ${TEST_PDB}_OLD back" || echo 'NOT possible without --keep-old (the old TEST is gone once dropped)')"
  echo "  dry-run $DRY_RUN  yes $ASSUME_YES  force $FORCE  skip [${SKIP//,/ }]"
}

cmd_preflight() {
  discover; [ -n "$RUN_DIR" ] || init_run_dir preflight; refuse_prod; local fail=0
  log "Preflight: $METHOD refresh of $([ "$METHOD" = pdb-clone ] && echo "$TEST_PDB from $PROD_PDB@$PROD_LINK" || echo "$SID from ${FROM_BACKUP:-$PROD_TNS}")"
  # mask
  if [ "$REQUIRE_MASK" = yes ]; then [ -n "$MASK_SCRIPT" ] && [ -f "$MASK_SCRIPT" ] || { err "masking is required but MASK_SCRIPT is unset or missing ($MASK_SCRIPT)"; fail=1; }; [ -n "$MASK_VERIFY_SQL" ] || warn "REQUIRE_MASK=yes but no MASK_VERIFY_SQL: verify cannot prove the masking ran"; fi
  [ -n "$MASK_SCRIPT" ] && [ ! -f "$MASK_SCRIPT" ] && { err "MASK_SCRIPT $MASK_SCRIPT not found"; fail=1; }
  if [ -n "$PRESERVE_SCHEMAS" ]; then
    if [ -z "$EXP_CONNECT" ]; then err "PRESERVE_SCHEMAS=$PRESERVE_SCHEMAS but no EXP_CONNECT (user/pw@TESTPDB with DATAPUMP_EXP/IMP_FULL_DATABASE)"; fail=1
    else local dp; dp="$(printf 'connect %s\nset heading off feedback off pagesize 0\nselect (select count(*) from session_roles where role in (%s))||q[|]||(select count(*) from session_privs where privilege in (%s))||q[|]||(select count(*) from user_ts_quotas q join user_users u on u.default_tablespace=q.tablespace_name where q.max_bytes<>0)||q[|]||nvl((select directory_path from all_directories where directory_name=upper(%s)),q[none]) from dual;\nexit\n' "$EXP_CONNECT" "'DATAPUMP_EXP_FULL_DATABASE','DATAPUMP_IMP_FULL_DATABASE','DBA'" "'UNLIMITED TABLESPACE','CREATE TABLE'" "'$DATA_PUMP_DIR'" | sed "s/q\[/'/g; s/\]/'/g" | ORACLE_HOME="$DB_HOME" to 60 "$DB_HOME/bin/sqlplus" -S -L /nolog 2>&1 | grep -E '^[0-9]+\|' | tail -1)"
      if [ -z "$dp" ]; then err "EXP_CONNECT cannot log in to run expdp/impdp"; fail=1
      else local r pv qv dpath; IFS='|' read -r r pv qv dpath <<<"$dp"
        [ "${r:-0}" -ge 1 ] || { err "the EXP_CONNECT user has none of DATAPUMP_EXP_FULL_DATABASE / DATAPUMP_IMP_FULL_DATABASE / DBA"; fail=1; }
        [ "${pv:-0}" -ge 1 ] || [ "${qv:-0}" -ge 1 ] || { err "the EXP_CONNECT user has no quota on its default tablespace (Data Pump's master table needs one: grant unlimited tablespace or a quota)"; fail=1; }
        [ "$dpath" = none ] && { err "directory $DATA_PUMP_DIR is not visible to the EXP_CONNECT user"; fail=1; }; [ -n "$dpath" ] && [ "$dpath" != none ] && [ ! -w "$dpath" ] && { err "$DATA_PUMP_DIR = $dpath is not writable by $(id -un) on this host"; fail=1; }
      fi
    fi
  fi
  [ -z "$PROD_HOST_PATTERN" ] && warn "PROD_HOST_PATTERN is empty: fix-dblinks cannot recognise links to production"
  if [ "$METHOD" = pdb-clone ]; then
    # link + privileges
    local lk; lk="$(rlines "select host from dba_db_links where owner in ('SYS','PUBLIC') and db_link like upper('$PROD_LINK%');" | head -1)"; [ -n "$lk" ] || { err "database link $PROD_LINK does not exist in $SID's root (SYS or PUBLIC)"; fail=1; }
    local pver; pver="$(prod_val "(select version from v\$instance)")"
    if [ -z "$pver" ]; then
      local lerr; lerr="$(rlines "select 'x' from dual@$PROD_LINK;" 2>&1 | grep -E 'ORA-' | head -1)"
      if [ -n "$lerr" ]; then err "cannot query PROD through $PROD_LINK: $lerr"
      else err "link $PROD_LINK connects, but v\$instance@$PROD_LINK is not readable: grant SELECT_CATALOG_ROLE (and CREATE PLUGGABLE DATABASE) to the link user on PROD; in a CDB also 'alter user <link user> set container_data=all container=current'"; fi
      fail=1
    else
      log "PROD reachable: version $pver, TEST $(rval "(select version from v\$instance)")"
      local tver; tver="$(rval "(select version_full from v\$instance)")"; local pverf; pverf="$(prod_val "(select version_full from v\$instance)")"
      [ -n "$pverf" ] && ! version_ge "$tver" "$pverf" && { err "TEST ($tver) is older than PROD ($pverf): a PDB cloned from a newer release cannot open here without upgrade"; fail=1; }
      local priv; priv="$(prod_val "(select count(*) from session_privs where privilege in ('CREATE PLUGGABLE DATABASE','SYSOPER'))")"; [ "${priv:-0}" = 0 ] && { err "the link user on PROD has no CREATE PLUGGABLE DATABASE privilege"; fail=1; }
      [ "$(prod_val "(select nvl(max(open_mode),'ABSENT') from v\$pdbs where name='$PROD_PDB')")" = "READ WRITE" ] || warn "PROD PDB $PROD_PDB is not READ WRITE on the source (hot clone needs it open; a closed/RO source still clones)"
      [ "$(prod_val "(select log_mode from v\$database)")" = ARCHIVELOG ] || { err "PROD is NOARCHIVELOG: hot clone impossible (PROD PDB would have to be read only)"; fail=1; }
      [ "$(prod_val "(select property_value from database_properties where property_name='LOCAL_UNDO_ENABLED')")" = TRUE ] || { err "PROD has no local undo: hot clone impossible"; fail=1; }
      local pcs tcs; pcs="$(prod_val "(select value from nls_database_parameters where parameter='NLS_CHARACTERSET')")"; tcs="$(rval "(select value from nls_database_parameters where parameter='NLS_CHARACTERSET')")"
      [ "$pcs" = "$tcs" ] || { [ "$tcs" = AL32UTF8 ] && warn "charset PROD $pcs, TEST $tcs (superset; plug-in allowed but check)" || { err "charset mismatch PROD $pcs vs TEST $tcs"; fail=1; }; }
      local pco tco; pco="$(prod_val "(select value from v\$parameter where name='compatible')")"; tco="$(rval "(select value from v\$parameter where name='compatible')")"; version_ge "$tco" "$pco" || { err "compatible TEST $tco < PROD $pco"; fail=1; }
      local enc; enc="$(prod_val "(select count(*) from v\$encrypted_tablespaces where con_id=(select con_id from v\$pdbs where name='$PROD_PDB'))")"
      if [ "${enc:-0}" != 0 ]; then local ks; ks="$(rval "(select nvl(max(status),'none') from v\$encryption_wallet where con_id in (0,1))")"; [ "$ks" = OPEN ] || { err "PROD PDB has $enc encrypted tablespace(s) and TEST's keystore is $ks"; fail=1; }; [ -n "${KEYSTORE_PASSWORD:-}" ] || warn "TDE source and no KEYSTORE_PASSWORD: the clone needs 'keystore identified by' (one_step_plugin_for_pdb_with_tde) - will prompt"; fi
      # space
      local need; need="$(prod_val "(select ceil(sum(bytes)/1048576) from cdb_data_files where con_id=(select con_id from v\$pdbs where name='$PROD_PDB'))")"; need="${need:-0}"; local tmp; tmp="$(prod_val "(select ceil(nvl(sum(bytes),0)/1048576) from cdb_temp_files where con_id=(select con_id from v\$pdbs where name='$PROD_PDB'))")"; need=$((need + ${tmp:-0}))
      local have; local dest; dest="$(rval "(select nvl(value,'') from v\$parameter where name='db_create_file_dest')")"
      # without OMF, "create pluggable database ... from x@link" fails with ORA-65016 unless the statement names the file destination
      if [ -z "$dest" ] && ! printf '%s' "$CLONE_OPTIONS" | grep -qiE 'file_name_convert|create_file_dest'; then
        err "db_create_file_dest is not set in $SID and CLONE_OPTIONS has no FILE_NAME_CONVERT / CREATE_FILE_DEST: the clone would fail with ORA-65016. Set db_create_file_dest (OMF) or CLONE_OPTIONS=\"create_file_dest='/u02/oradata/$SID'\""; fail=1
      fi
      if [ -n "$dest" ] && [ "${dest:0:1}" = + ]; then have="$("$GRID_HOME/bin/asmcmd" lsdg "${dest#+}" 2>/dev/null | awk 'NR==2{print $(NF-4)}')"; else local path="$dest"; [ -z "$path" ] && path="$(rval "(select substr(name,1,instr(name,'/',-1)) from v\$datafile where rownum=1)")"; have="$(df -Pm "$path" 2>/dev/null | awk 'NR==2{print $4}')"; fi
      local old=0; [ "$KEEP_OLD" = 1 ] || [ "$NO_DROP" = 1 ] || old="$(pval "(select ceil(sum(bytes)/1048576) from dba_data_files)" 2>/dev/null)"; old="${old:-0}"
      local reclaim=$old
      log "space: PROD PDB ${need} MB, destination ${dest:-datafile dir} has ${have:-?} MB free, dropping the old TEST frees ~${reclaim} MB$([ "$REFRESHABLE" = 1 ] && ! pdb_exists "$GOLD_PDB" && echo " (first refreshable run: golden copy needs another ${need} MB)")"
      local want=$need; [ "$REFRESHABLE" = 1 ] && ! pdb_exists "$GOLD_PDB" && want=$((need*2)); [ "$SNAPSHOT" = 1 ] && [ "$REFRESHABLE" = 1 ] && want=$need
      [ -n "$have" ] && [ $((have + reclaim)) -lt $((want + 2048)) ] && { err "not enough space: need ~${want} MB (+2 GB), have ${have} MB + ${reclaim} MB reclaimable"; fail=1; }
    fi
    # sessions in the TEST PDB
    if pdb_exists "$TEST_PDB"; then local n; n="$(rval "(select count(*) from v\$session s join v\$pdbs p on p.con_id=s.con_id where p.name='$TEST_PDB' and s.type='USER' and s.username is not null)")"; [ "${n:-0}" != 0 ] && warn "$n user session(s) in $TEST_PDB will be killed: $(rlines "select listagg(distinct s.username||'@'||s.machine,', ') within group (order by 1) from v\$session s join v\$pdbs p on p.con_id=s.con_id where p.name='$TEST_PDB' and s.type='USER' and s.username is not null;" | head -1)"
    else warn "$TEST_PDB does not exist yet in $SID (first refresh: nothing to preserve)"; fi
    [ "$KEEP_OLD" = 1 ] && pdb_exists "${TEST_PDB}_OLD" && { err "${TEST_PDB}_OLD already exists: run cleanup first"; fail=1; }
    [ "$SNAPSHOT" = 1 ] && [ "$(rval "(select value from v\$parameter where name='clonedb')")" != TRUE ] && [ -z "$(rval "(select value from v\$parameter where name='db_create_file_dest')" | grep -E '^\+|acfs|/zfs|/nfs')" ] && warn "--snapshot: clonedb=FALSE and the file dest does not look like ACFS/ZFS/NFS - snapshot copy may fail (ORA-65169)"
  else
    [ -x "$DB_HOME/bin/rman" ] || { err "no rman binary in $DB_HOME/bin"; fail=1; }
    [ -f "$DB_HOME/dbs/orapw$SID" ] || { err "no password file $DB_HOME/dbs/orapw$SID (active duplicate needs one with PROD's SYS password)"; fail=1; }
    if [ -n "$PROD_TNS" ] && [ -z "$FROM_BACKUP" ]; then read_secret PROD_SYS_PASSWORD "SYS password of PROD ($PROD_TNS)"
      local pid tid; pid="$(printf 'connect sys/"%s"@%s as sysdba\nset heading off feedback off pagesize 0\nselect dbid||q[|]||db_unique_name from v$database;\nexit\n' "$PROD_SYS_PASSWORD" "$PROD_TNS" | sed "s/q\[/'/g; s/\]/'/g" | ORACLE_HOME="$DB_HOME" to 60 "$DB_HOME/bin/sqlplus" -S -L /nolog 2>&1 | grep -E '^[0-9]+\|' | tail -1)"
      tid="$(rval "(select dbid||'|'||db_unique_name from v\$database)")"
      if [ -z "$pid" ]; then err "cannot connect to PROD as SYS through $PROD_TNS (password? sysdba over the network needs the password file)"; fail=1
      elif [ "$pid" = "$tid" ]; then err "$PROD_TNS is THIS database ($tid): duplicating a database onto itself would destroy it"; fail=1
      else log "PROD $PROD_TNS: dbid/db_unique_name $pid (TEST: $tid)"; fi
    fi
    [ -n "$PROD_TNS" ] && { ORACLE_HOME="$DB_HOME" to 20 "$DB_HOME/bin/tnsping" "$PROD_TNS" >/dev/null 2>&1 || { err "tnsping $PROD_TNS fails"; fail=1; }; }
    [ -n "$TEST_TNS" ] && { ORACLE_HOME="$DB_HOME" to 20 "$DB_HOME/bin/tnsping" "$TEST_TNS" >/dev/null 2>&1 || { err "tnsping $TEST_TNS fails (PROD must reach the auxiliary through this; add a static SID_LIST entry)"; fail=1; }; }
    [ -n "$FROM_BACKUP" ] && { [ -d "$FROM_BACKUP" ] || { err "backup location $FROM_BACKUP not found"; fail=1; }; }
    [ -n "$TEST_PFILE" ] && [ ! -f "$TEST_PFILE" ] && { err "TEST_PFILE $TEST_PFILE not found"; fail=1; }
    [ "$(rval "(select count(*) from v\$session where type='USER' and username is not null)")" != 0 ] && warn "users are connected to $SID; they will be thrown out by shutdown abort"
    [ "$KEEP_OLD" = 1 ] && warn "--keep-old is not possible with rman-duplicate (the whole database is overwritten); take your own backup first"
    [ -n "$(rval "(select nvl(max(name),'') from v\$encryption_wallet where status='OPEN')")" ] && warn "TDE: the TEST keystore must hold PROD's master keys (copy the wallet/auto-login before duplicate)"
  fi
  state_set preflight "$([ "$fail" = 0 ] && echo ok || echo failed)"
  [ "$fail" = 0 ] && { log "Preflight OK"; return 0; } || { err "Preflight FAILED - see $LOG_FILE"; return 1; }
}

# ---------------------------------------------------------------------------
# backup (preservation)
# ---------------------------------------------------------------------------
cmd_backup() {
  discover; reuse_or_init backup; local d="$RUN_DIR/preserve"; mkdir -p "$d"
  rsql "create pfile='$RUN_DIR/init$SID.ora.bak' from spfile;" >>"$LOG_FILE" 2>&1
  cp -p "${TNS_ADMIN:-$DB_HOME/network/admin}"/tnsnames.ora "$RUN_DIR/" 2>/dev/null
  if [ "$METHOD" = pdb-clone ] && ! pdb_exists "$TEST_PDB"; then log "no $TEST_PDB yet: nothing to preserve"; state_set backup ok; return 0; fi
  if [ "$METHOD" = pdb-clone ]; then log "preserving the TEST-only definitions of $TEST_PDB into $d"; else log "preserving the TEST-only definitions of $SID into $d"; fi
  local sq="set long 1000000 longchunksize 32767 pagesize 0 linesize 32767 trimspool on feedback off heading off\nexec dbms_metadata.set_transform_param(dbms_metadata.session_transform,'SQLTERMINATOR',true);\nexec dbms_metadata.set_transform_param(dbms_metadata.session_transform,'PRETTY',true);\n"
  local who="username not in (select username from dba_users where oracle_maintained='Y')"
  psql "${sq}spool $d/01_profiles.sql\nselect dbms_metadata.get_ddl('PROFILE',profile) from (select distinct profile from dba_profiles where profile<>'DEFAULT');\nspool off" >>"$LOG_FILE" 2>&1
  psql "${sq}spool $d/02_roles.sql\nselect dbms_metadata.get_ddl('ROLE',role) from dba_roles where oracle_maintained='N';\nspool off" >>"$LOG_FILE" 2>&1
  psql "${sq}spool $d/03_users.sql\nselect dbms_metadata.get_ddl('USER',username) from dba_users where $who;\nspool off" >>"$LOG_FILE" 2>&1
  psql "${sq}spool $d/04_grants.sql\nselect dbms_metadata.get_granted_ddl('SYSTEM_GRANT',username) from dba_users where $who and username in (select grantee from dba_sys_privs);\nselect dbms_metadata.get_granted_ddl('ROLE_GRANT',username) from dba_users where $who and username in (select grantee from dba_role_privs);\nselect dbms_metadata.get_granted_ddl('OBJECT_GRANT',username) from dba_users where $who and username in (select grantee from dba_tab_privs);\nselect dbms_metadata.get_granted_ddl('TABLESPACE_QUOTA',username) from dba_users where $who and username in (select username from dba_ts_quotas);\nspool off" >>"$LOG_FILE" 2>&1
  psql "${sq}spool $d/05_dblinks.sql\nselect dbms_metadata.get_ddl('DB_LINK',db_link,owner) from dba_db_links;\nspool off" >>"$LOG_FILE" 2>&1
  psql "${sq}spool $d/06_directories.sql\nselect dbms_metadata.get_ddl('DIRECTORY',directory_name) from dba_directories;\nspool off" >>"$LOG_FILE" 2>&1
  psql "set pagesize 0 linesize 400 feedback off heading off\nspool $d/accounts.txt\nselect username||'|'||account_status||'|'||profile from dba_users where oracle_maintained='N' order by 1;\nspool off" >>"$LOG_FILE" 2>&1
  psql "set pagesize 0 linesize 400 feedback off heading off\nspool $d/services.txt\nselect name||'|'||network_name from dba_services;\nspool off" >>"$LOG_FILE" 2>&1
  psql "set pagesize 0 linesize 400 feedback off heading off\nspool $d/jobs.txt\nselect owner||'.'||job_name||'|'||enabled from dba_scheduler_jobs where owner not in (select username from dba_users where oracle_maintained='Y');\nspool off" >>"$LOG_FILE" 2>&1
  psql "set pagesize 0 linesize 4000 feedback off heading off\nspool $d/apex_params.txt\nselect name||'='||value from apex_instance_parameters where name in ('SMTP_HOST_ADDRESS','SMTP_HOST_PORT','SMTP_USERNAME','SMTP_TLS_MODE','SMTP_FROM','WALLET_PATH','PRINT_BIB_LICENSED','PRINT_SVR_HOST','PRINT_SVR_PORT','PRINT_SVR_PROTOCOL','PRINT_SVR_SCRIPT','ALLOW_PUBLIC_FILE_UPLOAD','RESTRICT_IP_RANGE','EMAIL_INSTANCE_URL','EMAIL_IMAGES_URL','IMAGE_PREFIX','DISABLE_WORKSPACE_LOGIN','DISABLE_ADMIN_LOGIN','APEX_BUILDER_AUTHENTICATION') order by 1;\nspool off" >>"$LOG_FILE" 2>&1
  # dbms_metadata emits "BEGIN NULL; END;" placeholders without a terminating "/": sqlplus then stays in PL/SQL mode and silently
  # swallows every statement after it (the role grants never ran). Drop them and terminate any real block with "/".
  local f; for f in "$d"/*.sql; do [ -f "$f" ] && sed -i -e '/^[[:space:]]*BEGIN NULL; END;[[:space:]]*$/d' -e 's#^\(.*END;\)[[:space:]]*$#\1\n/#' "$f"; done
  for f in "$d"/*.sql "$d"/*.txt; do [ -f "$f" ] && grep -qE '^ORA-|^SP2-' "$f" && warn "$(basename "$f") contains errors: $(grep -E '^ORA-|^SP2-' "$f" | head -1)"; done
  log "preserved: $(for f in "$d"/*; do [ -f "$f" ] || continue; printf '%s(%s) ' "$(basename "$f")" "$(wc -l <"$f" | tr -d ' ')"; done)"
  if [ -n "$PRESERVE_SCHEMAS" ]; then
    if [ -n "$EXP_CONNECT" ]; then
      local dump; dump="refresh_preserve_$(date +%Y%m%d%H%M%S).dmp"; local dpath; dpath="$(plines "select directory_path from dba_directories where directory_name=upper('$DATA_PUMP_DIR');" | head -1)"; state_set preserve_dir_path "$dpath"; state_set preserve_objects "$(plines "select count(*) from dba_objects where owner in ($(printf '%s' "$PRESERVE_SCHEMAS" | uc | sed "s/[^,]*/'&'/g"));" | head -1)"; log "expdp schemas=$PRESERVE_SCHEMAS ($(state_get preserve_objects) objects) to $DATA_PUMP_DIR ($dpath)/$dump"
      [ "$DRY_RUN" = 1 ] || { ORACLE_HOME="$DB_HOME" PATH="$DB_HOME/bin:$PATH" to 7200 "$DB_HOME/bin/expdp" "$EXP_CONNECT" schemas="$PRESERVE_SCHEMAS" directory="$DATA_PUMP_DIR" dumpfile="$dump" logfile="${dump%.dmp}.log" reuse_dumpfiles=y >>"$LOG_FILE" 2>&1 && state_set preserve_dump "$dump" || { err "expdp failed (see $LOG_FILE)"; return 1; }; }
    else err "PRESERVE_SCHEMAS set but no EXP_CONNECT (user/pw@TESTPDB with DATAPUMP_EXP_FULL_DATABASE): cannot export"; return 1; fi
  fi
  state_set backup ok
}

# ---------------------------------------------------------------------------
# drop / create
# ---------------------------------------------------------------------------
kill_pdb_sessions() { [ "$DRY_RUN" = 1 ] && return 0; rlines "select 'alter system kill session '''||sid||','||serial#||',@'||inst_id||''' immediate;' from gv\$session s join v\$pdbs p on p.con_id=s.con_id where p.name='$1' and s.type='USER';" 2>/dev/null | while read -r k; do rsql "$k" >>"$LOG_FILE" 2>&1; done; return 0; }
cmd_drop() {
  discover; reuse_or_init drop; refuse_prod
  [ "$METHOD" = rman-duplicate ] && { log "rman-duplicate: the database is overwritten by create, nothing to drop"; state_set drop ok; return 0; }
  [ "$NO_DROP" = 1 ] && { log "--no-drop: $TEST_PDB left in place (create will fail if it exists)"; state_set drop ok; return 0; }
  pdb_exists "$TEST_PDB" || { log "$TEST_PDB does not exist"; state_set drop ok; return 0; }
  if [ "$KEEP_OLD" = 1 ]; then
    confirm "Rename $TEST_PDB to ${TEST_PDB}_OLD (kept for rollback)?" || die "aborted"
    kill_pdb_sessions "$TEST_PDB"
    do_sql root "close $TEST_PDB" "alter pluggable database $TEST_PDB close immediate instances=all;" || true
    do_sql root "open $TEST_PDB restricted for rename" "alter pluggable database $TEST_PDB open restricted;" || return 1
    do_sql root "rename to ${TEST_PDB}_OLD" "alter session set container=$TEST_PDB;\nalter pluggable database rename global_name to ${TEST_PDB}_OLD;" || return 1
    do_sql root "close ${TEST_PDB}_OLD" "alter pluggable database ${TEST_PDB}_OLD close immediate instances=all;\nalter pluggable database ${TEST_PDB}_OLD save state;" || true
    state_set old_pdb "${TEST_PDB}_OLD"
  else
    confirm "DROP pluggable database $TEST_PDB INCLUDING DATAFILES in $SID ($(pval "(select round(sum(bytes)/1073741824,1)||' GB' from dba_data_files)"))? This cannot be undone." || die "aborted"
    kill_pdb_sessions "$TEST_PDB"
    do_sql root "close $TEST_PDB" "alter pluggable database $TEST_PDB close immediate instances=all;" || true
    do_sql root "drop $TEST_PDB" "drop pluggable database $TEST_PDB including datafiles;" || return 1
  fi
  state_set drop ok
}

create_pdb_clone() {
  local ks=""; local enc; enc="$(prod_val "(select count(*) from v\$encrypted_tablespaces where con_id=(select con_id from v\$pdbs where name='$PROD_PDB'))")"
  if [ "${enc:-0}" != 0 ]; then read_secret KEYSTORE_PASSWORD "TEST keystore password (TDE source)"; ks="keystore identified by \"$KEYSTORE_PASSWORD\""; fi
  local src="$PROD_PDB@$PROD_LINK"
  if [ "$REFRESHABLE" = 1 ]; then
    if pdb_exists "$GOLD_PDB"; then
      [ "$(pdb_refresh_mode "$GOLD_PDB")" = MANUAL ] || [ "$(pdb_refresh_mode "$GOLD_PDB")" = AUTO ] || die "$GOLD_PDB exists but is not refreshable (refresh_mode $(pdb_refresh_mode "$GOLD_PDB")); drop it (cleanup --all) to start again"
      do_sql root "close $GOLD_PDB" "alter pluggable database $GOLD_PDB close immediate instances=all;" || true
      log "refreshing $GOLD_PDB from $src (incremental: only redo since the last refresh)"
      do_sql root "refresh $GOLD_PDB" "alter pluggable database $GOLD_PDB refresh;" || return 1
    else
      log "first run: creating the refreshable golden copy $GOLD_PDB from $src (full copy)"
      do_sql root "create $GOLD_PDB" "create pluggable database $GOLD_PDB from $src refresh mode manual parallel $CLONE_PARALLEL $ks $CLONE_OPTIONS;" || return 1
    fi
    do_sql root "open $GOLD_PDB read only (needed as a clone source)" "alter pluggable database $GOLD_PDB open read only instances=all;" || return 1
    log "cloning $TEST_PDB from $GOLD_PDB locally$([ "$SNAPSHOT" = 1 ] && echo ' (snapshot copy)')"
    do_sql root "create $TEST_PDB" "create pluggable database $TEST_PDB from $GOLD_PDB $([ "$SNAPSHOT" = 1 ] && echo 'snapshot copy') parallel $CLONE_PARALLEL $ks $CLONE_OPTIONS;" || return 1
    do_sql root "close $GOLD_PDB again" "alter pluggable database $GOLD_PDB close immediate instances=all;" || true
  else
    log "hot clone $TEST_PDB from $src (full copy over the link, parallel $CLONE_PARALLEL)"
    do_sql root "create $TEST_PDB" "create pluggable database $TEST_PDB from $src parallel $CLONE_PARALLEL $ks $CLONE_OPTIONS;" || return 1
  fi
  do_sql root "open $TEST_PDB" "alter pluggable database $TEST_PDB open read write instances=all;\nalter pluggable database $TEST_PDB save state instances=all;" || return 1
  [ "$DRY_RUN" = 1 ] || [ "$(pdb_mode "$TEST_PDB")" = "READ WRITE" ] || { err "$TEST_PDB is $(pdb_mode "$TEST_PDB") after open: $(rlines "select cause||': '||message from pdb_plug_in_violations where name='$TEST_PDB' and status<>'RESOLVED' and type='ERROR';" | head -3 | tr '\n' ';')"; return 1; }
  [ "$DRY_RUN" = 1 ] || { local v; v="$(rval "(select count(*) from pdb_plug_in_violations where name='$TEST_PDB' and status<>'RESOLVED' and type='ERROR')")"; [ "${v:-0}" != 0 ] && warn "$v unresolved plug-in violation(s): select * from pdb_plug_in_violations where name='$TEST_PDB'"; }
  return 0
}
create_rman_duplicate() {
  local pfile="${TEST_PFILE:-$RUN_DIR/init$SID.ora}"
  [ -n "$TEST_PFILE" ] || { rsql "create pfile='$pfile' from spfile;" >>"$LOG_FILE" 2>&1; [ -s "$pfile" ] || die "could not create $pfile from the spfile; give --pfile via TEST_PFILE"; }
  local conn_t="" conn_a="/"
  if [ -z "$FROM_BACKUP" ]; then read_secret PROD_SYS_PASSWORD "SYS password of PROD ($PROD_TNS)"; conn_t="connect target sys/\"$PROD_SYS_PASSWORD\"@$PROD_TNS"; [ -n "$TEST_TNS" ] && conn_a="sys/\"$PROD_SYS_PASSWORD\"@$TEST_TNS"; fi
  local dup; if [ -n "$FROM_BACKUP" ]; then local dbid; dbid="${PROD_DBID:-}"; dup="duplicate database ${PROD_DB_NAME:-$(basename "$PROD_TNS" 2>/dev/null)} ${dbid:+dbid $dbid} to $SID backup location '$FROM_BACKUP' $DUPLICATE_OPTIONS;"
  else dup="duplicate target database to $SID from active database using backupset section size $SECTION_SIZE $DUPLICATE_OPTIONS;"; fi
  confirm "shutdown abort $SID, startup nomount pfile='$pfile', then: $dup ?" || die "aborted"
  log "shutdown abort / startup nomount $SID"
  [ "$DRY_RUN" = 1 ] || ORACLE_SID="$SID" ORACLE_HOME="$DB_HOME" to 600 "$DB_HOME/bin/sqlplus" -S / as sysdba <<<"shutdown abort
startup nomount pfile='$pfile'" >>"$LOG_FILE" 2>&1
  log "rman: $dup  (allocate ${RMAN_CHANNELS:-4} channels; output: $RUN_DIR/rman_duplicate.log)"
  [ "$DRY_RUN" = 1 ] && return 0
  local chans="" i; for ((i=1;i<=${RMAN_CHANNELS:-4};i++)); do chans="$chans allocate channel c$i device type disk;"; [ -z "$FROM_BACKUP" ] && chans="$chans allocate auxiliary channel a$i device type disk;"; done
  printf '%s\nconnect auxiliary %s\nrun {%s\n%s\n}\nexit\n' "$conn_t" "$conn_a" "$chans" "$dup" | rman_script "$SID" "${RMAN_TIMEOUT:-43200}" >"$RUN_DIR/rman_duplicate.log"
  grep -q 'Finished Duplicate Db' "$RUN_DIR/rman_duplicate.log" || { err "duplicate did not finish: $(grep -E 'RMAN-0[0-9]{4}|ORA-' "$RUN_DIR/rman_duplicate.log" | grep -vE 'RMAN-08' | head -3 | tr '\n' ';')"; return 1; }
  sql_ok "$SID" || { err "$SID not reachable after duplicate"; return 1; }
  [ "$NOARCHIVELOG" = yes ] && { log "switching $SID to NOARCHIVELOG"; ORACLE_SID="$SID" ORACLE_HOME="$DB_HOME" "$DB_HOME/bin/sqlplus" -S / as sysdba <<<"shutdown immediate
startup mount
alter database noarchivelog;
alter database open;" >>"$LOG_FILE" 2>&1; }
  [ -z "$TEST_PFILE" ] && rsql "create spfile from pfile='$pfile';" >>"$LOG_FILE" 2>&1
  db_is_cdb "$SID" && rsql "alter pluggable database all open;" >>"$LOG_FILE" 2>&1
  return 0
}
cmd_create() {
  discover; reuse_or_init create; refuse_prod
  [ "$METHOD" = pdb-clone ] && pdb_exists "$TEST_PDB" && die "$TEST_PDB still exists: run drop first (or --keep-old)"
  local t0; t0="$(date +%s)"
  if [ "$METHOD" = pdb-clone ]; then create_pdb_clone || { state_set create failed; return 1; }; else create_rman_duplicate || { state_set create failed; return 1; }; fi
  log "create finished in $(( ( $(date +%s) - t0 ) / 60 )) min"; state_set create ok
}

# ---------------------------------------------------------------------------
# post-refresh hygiene
# ---------------------------------------------------------------------------
cmd_rename_services() {
  discover; reuse_or_init rename-services; skipped rename-services && return 0
  local rows; rows="$(plines "select name||'|'||network_name from dba_services where name not like 'SYS%' and upper(name)<>upper('$TEST_PDB') and name not like '%XDB';" 2>/dev/null)"
  local line; while IFS='|' read -r name net; do [ -z "$name" ] && continue
    local new=""; local m; for m in ${SERVICE_MAP//,/ }; do [ "$(printf '%s' "${m%%:*}" | uc)" = "$(printf '%s' "$name" | uc)" ] && new="${m#*:}"; done
    [ -z "$new" ] && [ -n "$PROD_PDB" ] && printf '%s' "$name" | grep -qi "$PROD_PDB" && new="$(printf '%s' "$name" | sed "s/$PROD_PDB/$TEST_PDB/I")"
    [ -z "$new" ] && [ -n "$PROD_HOST_PATTERN" ] && printf '%s' "$name" | grep -qiE "$PROD_HOST_PATTERN" && new="$(printf '%s' "$name" | sed -E "s/$PROD_HOST_PATTERN/test/I")"
    if [ -n "$new" ]; then
      log "service $name -> $new"
      do_sql pdb "replace service $name" "begin begin dbms_service.stop_service('$name'); exception when others then null; end; dbms_service.delete_service('$name'); dbms_service.create_service('$new','$new'); dbms_service.start_service('$new'); end;\n/" || warn "could not replace service $name"
    else log "service $name kept"; fi
  done <<<"$rows"
  [ -n "$GRID_HOME" ] && warn "clusterware: PROD's srvctl services are not copied by a PDB clone; add test ones with srvctl add service -d $TEST_DBUN -pdb $TEST_PDB -s <name>"
  state_set rename_services ok
}

cmd_mask() {
  discover; reuse_or_init mask; skipped mask && return 0
  if [ -z "$MASK_SCRIPT" ]; then [ "$REQUIRE_MASK" = yes ] && { err "masking is required and MASK_SCRIPT is not set"; return 1; }; log "no MASK_SCRIPT: data is NOT masked (production data in test)"; state_set mask skipped; return 0; fi
  [ -f "$MASK_SCRIPT" ] || { err "MASK_SCRIPT $MASK_SCRIPT missing"; return 1; }
  log "running $MASK_SCRIPT in $TEST_PDB (output: $RUN_DIR/mask.log)"; [ "$DRY_RUN" = 1 ] && return 0
  local out; out="$(psql "whenever sqlerror exit 1\nset echo on feedback on\n@$MASK_SCRIPT")"; printf '%s\n' "$out" >"$RUN_DIR/mask.log"
  printf '%s' "$out" | grep -qE '^ORA-|ORA-[0-9]+:' && { err "mask script raised errors: $(printf '%s' "$out" | grep -E 'ORA-' | head -2 | tr '\n' ';')"; state_set mask failed; return 1; }
  if [ -n "$MASK_VERIFY_SQL" ]; then local v; v="$(plines "$MASK_VERIFY_SQL" | head -1)"; [ "$v" = OK ] || { err "MASK_VERIFY_SQL returned '$v', expected OK"; state_set mask failed; return 1; }; log "mask verified: OK"; fi
  state_set mask ok
}

cmd_relock() {
  discover; reuse_or_init relock; skipped relock && return 0
  local keep; keep="$(printf '%s,%s' "$ACCOUNT_WHITELIST" "$TEST_ACCOUNTS" | tr ',' '\n' | grep . | uc | sed "s/.*/'&'/" | paste -sd, -)"; [ -z "$keep" ] && keep="'NONE_'"
  local to_lock; to_lock="$(plines "select username from dba_users where oracle_maintained='N' and account_status not like '%LOCKED%' and username not in ($keep) order by 1;" | tr '\n' ' ')"
  log "locking $(printf '%s' "$to_lock" | wc -w | tr -d ' ') account(s): $to_lock"
  local u; for u in $to_lock; do do_sql pdb "lock $u" "alter user \"$u\" account lock;" || true; done
  if [ -n "$TEST_ACCOUNTS" ]; then
    read_secret TEST_ACCOUNT_PASSWORD "new password for the test accounts ($TEST_ACCOUNTS)"
    for u in ${TEST_ACCOUNTS//,/ }; do plines "select 1 from dba_users where username=upper('$u');" | grep -q 1 || { warn "test account $u does not exist in the clone (preserved DDL may create it in reimport)"; continue; }; do_sql pdb "reset + unlock $u" "alter user \"$(printf '%s' "$u" | uc)\" identified by \"$TEST_ACCOUNT_PASSWORD\" account unlock;" || true; done
  fi
  for u in ${ACCOUNT_WHITELIST//,/ }; do do_sql pdb "unlock $u" "alter user \"$(printf '%s' "$u" | uc)\" account unlock;" >/dev/null 2>&1 || true; done
  state_set relock ok
}

# link_ddl <owner> <statement...>: DROP/CREATE DATABASE LINK cannot name a schema (a dotted name is read as the link's own
# name, ORA-02024), so another user's private link is handled by running the statement as that user via dbms_sys_sql
link_ddl() { local owner="$1"; shift; local stmt="$*"
  case "$owner" in PUBLIC|SYS) printf '%s;' "$stmt";;
    *) printf "declare c integer; u number; begin select user_id into u from dba_users where username = '%s'; c := sys.dbms_sys_sql.open_cursor; sys.dbms_sys_sql.parse_as_user(c, q'[%s]', dbms_sql.native, u); sys.dbms_sys_sql.close_cursor(c); end;\\n/" "$owner" "$stmt";;
  esac; }
cmd_fix_dblinks() {
  discover; reuse_or_init fix-dblinks; skipped fix-dblinks && return 0
  local rows; rows="$(plines "select owner||'|'||db_link||'|'||nvl(host,'') from dba_db_links;" 2>/dev/null)"
  [ -z "$rows" ] && { log "no database links in $TEST_PDB"; state_set fix_dblinks ok; return 0; }
  local owner link host; while IFS='|' read -r owner link host; do [ -z "$link" ] && continue
    local mapped=""; local m; for m in ${DBLINK_MAP//,/ }; do [ "$(printf '%s' "${m%%=*}" | uc)" = "$(printf '%s' "$link" | uc)" ] && mapped="${m#*=}"; done
    if [ -n "$mapped" ]; then
      log "link $owner.$link: $host -> $mapped"
      local user; user="$(plines "select username from dba_db_links where owner='$owner' and db_link='$link';" | head -1)"
      local pw_var; pw_var="DBLINK_PASSWORD_$(printf '%s' "$link" | tr -c 'A-Za-z0-9\n' '_' | uc)"; read_secret "$pw_var" "password of $user for link $link"
      local pfx=""; [ "$owner" = PUBLIC ] && pfx="public "
      do_sql pdb "re-create $link" "$(link_ddl "$owner" "drop ${pfx}database link \"$link\"")\n$(link_ddl "$owner" "create ${pfx}database link \"$link\" connect to \"$user\" identified by \"${!pw_var}\" using '$mapped'")" || warn "could not re-create $link (as $owner)"
    elif [ -n "$PROD_HOST_PATTERN" ] && printf '%s' "$host" | grep -qiE "$PROD_HOST_PATTERN"; then
      log "link $owner.$link points at production ($host): dropping"
      local pfx=""; [ "$owner" = PUBLIC ] && pfx="public "
      do_sql pdb "drop $owner.$link" "$(link_ddl "$owner" "drop ${pfx}database link \"$link\"")" || warn "drop of $owner.$link failed (run as $owner through dbms_sys_sql) - drop it as $owner, or use DBLINK_MAP to re-point it"
    else log "link $owner.$link -> $host kept"; fi
  done <<<"$rows"
  state_set fix_dblinks ok
}

cmd_fix_apex() {
  discover; reuse_or_init fix-apex; skipped fix-apex && return 0
  local ver; ver="$(pval "(select nvl(max(version_no),'none') from apex_release)" 2>/dev/null)"; [ -z "$ver" ] || [ "$ver" = none ] && { log "no APEX in $TEST_PDB"; state_set fix_apex ok; return 0; }
  log "APEX $ver in $TEST_PDB"
  local kv; local saved="$RUN_DIR/preserve/apex_params.txt"
  if [ "$APEX_RESTORE_PARAMS" = yes ] && [ -s "$saved" ]; then
    while IFS='=' read -r k v; do [ -z "$k" ] && continue; do_sql pdb "apex $k = (old TEST value)" "begin apex_instance_admin.set_parameter('$k','$(printf '%s' "$v" | sed "s/'/''/g")'); commit; end;\n/" || true; done <"$saved"
  fi
  for kv in ${APEX_PARAMS//,/ }; do do_sql pdb "apex ${kv%%=*}" "begin apex_instance_admin.set_parameter('${kv%%=*}','$(printf '%s' "${kv#*=}" | sed "s/'/''/g")'); commit; end;\n/" || true; done
  [ -n "${APEX_URL_REPLACE:-}" ] && warn "APEX_URL_REPLACE: URLs inside applications (REST data sources, web credentials, substitution strings) are application data - put those UPDATEs in MASK_SCRIPT; this step only sets instance parameters"
  plines "select name||'='||value from apex_instance_parameters where name in ('SMTP_HOST_ADDRESS','SMTP_FROM','EMAIL_INSTANCE_URL','IMAGE_PREFIX','WALLET_PATH') order by 1;" 2>/dev/null | sed 's/^/  apex: /' | tee -a "$LOG_FILE" >&2
  state_set fix_apex ok
}

cmd_fix_scheduler() {
  discover; reuse_or_init fix-scheduler; skipped fix-scheduler && return 0
  case "$(printf '%s' "$DISABLE_JOBS" | uc)" in
    NONE) log "DISABLE_JOBS=NONE: scheduler jobs left as they came from PROD (they WILL run here)";;
    ALL) local jobs; jobs="$(plines "select owner||'.'||job_name from dba_scheduler_jobs where enabled='TRUE' and owner not in (select username from dba_users where oracle_maintained='Y');" | tr '\n' ' ')"
      log "disabling $(printf '%s' "$jobs" | wc -w | tr -d ' ') enabled job(s)"; local j; for j in $jobs; do do_sql pdb "disable $j" "begin dbms_scheduler.disable('\"${j%%.*}\".\"$(printf '%s' "${j#*.}" | sed "s/'/''/g")\"', force=>true); end;\n/" || true; done
      local saved="$RUN_DIR/preserve/jobs.txt"; [ -s "$saved" ] && { log "re-enabling what the old TEST had enabled"; grep '|TRUE$' "$saved" | cut -d'|' -f1 | while read -r j; do do_sql pdb "enable $j (was enabled on the old TEST)" "begin dbms_scheduler.enable('\"${j%%.*}\".\"${j#*.}\"'); end;\n/" >/dev/null 2>&1 || true; done; };;
    *) local j; for j in ${DISABLE_JOBS//,/ }; do do_sql pdb "disable $j" "begin dbms_scheduler.disable('$j', force=>true); end;\n/" || true; done;;
  esac
  state_set fix_scheduler ok
}

cmd_fix_directories() {
  discover; reuse_or_init fix-directories; skipped fix-directories && return 0
  [ -z "$DIRECTORY_MAP" ] && { log "no DIRECTORY_MAP; directories: $(plines "select listagg(directory_name||'='||directory_path,' ') within group (order by 1) from dba_directories where directory_path not like '%/rdbms/%';" | head -1)"; state_set fix_directories ok; return 0; }
  local m; for m in ${DIRECTORY_MAP//,/ }; do local from="${m%%=*}" to="${m#*=}"
    plines "select directory_name||'|'||directory_path from dba_directories where directory_path like '$from%';" | while IFS='|' read -r n p; do [ -z "$n" ] && continue; local np="$to${p#"$from"}"; do_sql pdb "directory $n: $p -> $np" "create or replace directory \"$n\" as '$np';" || true; [ -d "$np" ] || warn "  $np does not exist on this host"; done
  done
  state_set fix_directories ok
}

cmd_reimport() {
  discover; reuse_or_init reimport; skipped reimport && return 0
  local d="$RUN_DIR/preserve"; [ -d "$d" ] || { log "nothing preserved in this run ($d missing)"; state_set reimport ok; return 0; }
  local f; for f in "$d"/01_profiles.sql "$d"/02_roles.sql "$d"/03_users.sql "$d"/04_grants.sql "$d"/06_directories.sql "$d"/05_dblinks.sql; do
    [ -s "$f" ] || continue; log "replaying $(basename "$f") (objects that already exist raise errors that are ignored)"; [ "$DRY_RUN" = 1 ] && continue
    psql "set echo on feedback on\n@$f" >"$RUN_DIR/reimport_$(basename "$f" .sql).log" 2>&1
    local okn errn; okn="$(grep -cE 'created|succeeded|altered' "$RUN_DIR/reimport_$(basename "$f" .sql).log")"; errn="$(grep -cE '^ORA-' "$RUN_DIR/reimport_$(basename "$f" .sql).log")"; log "  $okn ok, $errn errors (ORA-01920/01921/02379 'already exists' are expected)"
  done
  # links re-created from the old TEST must not point at production either
  [ -s "$d/05_dblinks.sql" ] && [ -n "$PROD_HOST_PATTERN" ] && grep -qiE "$PROD_HOST_PATTERN" "$d/05_dblinks.sql" && warn "the old TEST had links matching PROD_HOST_PATTERN; fix-dblinks runs again in verify's check - drop them"
  local dump; dump="$(state_get preserve_dump || true)"
  if [ -n "$dump" ]; then
    [ -n "$EXP_CONNECT" ] || { err "preserved dump $dump but no EXP_CONNECT for impdp"; return 1; }
    # the clone's $DATA_PUMP_DIR is PROD's directory object (another path, maybe not even on this host) and, being a common
    # object, cannot be re-pointed inside the PDB (ORA-65040): import through a directory of our own that names the export path
    local dpath expuser idir="$DATA_PUMP_DIR"; dpath="$(state_get preserve_dir_path || true)"; expuser="${EXP_CONNECT%%/*}"; expuser="${expuser%%@*}"
    if [ -n "$dpath" ]; then idir=DB_REFRESH_DPDIR; do_sql pdb "directory $idir -> $dpath for $expuser" "create or replace directory $idir as '$dpath';\ngrant read, write on directory $idir to \"$(printf '%s' "$expuser" | uc)\";" || { err "cannot create $idir in the clone"; return 1; }; fi
    log "impdp schemas=$PRESERVE_SCHEMAS from $idir/$dump (table_exists_action=replace)"
    local irc=0; [ "$DRY_RUN" = 1 ] || ORACLE_HOME="$DB_HOME" PATH="$DB_HOME/bin:$PATH" to 7200 "$DB_HOME/bin/impdp" "$EXP_CONNECT" schemas="$PRESERVE_SCHEMAS" directory="$idir" dumpfile="$dump" logfile="imp_${dump%.dmp}.log" table_exists_action=replace >>"$LOG_FILE" 2>&1 || irc=$?
    if [ "$DRY_RUN" != 1 ]; then local before after; before="$(state_get preserve_objects || echo 0)"; after="$(plines "select count(*) from dba_objects where owner in ($(printf '%s' "$PRESERVE_SCHEMAS" | uc | sed "s/[^,]*/'&'/g"));" | head -1)"
      log "preserved schemas: $after object(s) now, $before before the refresh"
      [ "${after:-0}" -lt "${before:-0}" ] && { err "impdp brought back only $after of $before objects of $PRESERVE_SCHEMAS (rc $irc) - see $LOG_FILE and the Data Pump log; the old TEST is $([ "$KEEP_OLD" = 1 ] && echo "${TEST_PDB}_OLD (rollback restores it)" || echo 'gone: restore the schemas from the dump by hand')"; return 1; }
      [ "$irc" != 0 ] && warn "impdp finished with warnings (rc $irc): check imp_${dump%.dmp}.log"; fi
  fi
  [ "$DRY_RUN" = 1 ] || psql "@?/rdbms/admin/utlrp.sql" >>"$LOG_FILE" 2>&1
  state_set reimport ok
}

cmd_verify() {
  discover; reuse_or_init verify; local fail=0
  if [ "$METHOD" = pdb-clone ]; then
    [ "$(pdb_mode "$TEST_PDB")" = "READ WRITE" ] && log "$TEST_PDB is READ WRITE" || { err "$TEST_PDB is $(pdb_mode "$TEST_PDB")"; fail=1; }
    [ "$DRY_RUN" = 0 ] && { local v; v="$(rval "(select count(*) from pdb_plug_in_violations where name='$TEST_PDB' and status<>'RESOLVED' and type='ERROR')")"; [ "${v:-0}" != 0 ] && { err "$v plug-in violation(s)"; fail=1; }; }
  else [ "$(rval "(select open_mode from v\$database)")" = "READ WRITE" ] && log "$SID open READ WRITE ($(rval "(select log_mode from v\$database)"))" || { err "$SID is not open read write"; fail=1; }; fi
  [ "$DRY_RUN" = 1 ] && { log "dry-run: verify skipped"; return 0; }
  if [ -n "$MASK_VERIFY_SQL" ]; then local m; m="$(plines "$MASK_VERIFY_SQL" 2>/dev/null | head -1)"; if [ "$m" = OK ]; then log "masking verified: OK"; else err "MASK_VERIFY_SQL returned '${m:-nothing}' (expected OK) - production data may be unmasked"; fail=1; fi
  elif [ "$REQUIRE_MASK" = yes ]; then err "no MASK_VERIFY_SQL: cannot prove masking"; fail=1; fi
  if [ -n "$PROD_HOST_PATTERN" ]; then local bad; bad="$(plines "select owner||'.'||db_link||'->'||host from dba_db_links where upper(host) like upper('%$PROD_HOST_PATTERN%') or regexp_like(host,'$PROD_HOST_PATTERN','i');" 2>/dev/null | tr '\n' ' ')"; [ -n "$bad" ] && { err "database links to production remain: $bad"; fail=1; } || log "no database link matches '$PROD_HOST_PATTERN'"; fi
  local keep; keep="$(printf '%s,%s' "$ACCOUNT_WHITELIST" "$TEST_ACCOUNTS" | tr ',' '\n' | grep . | uc | sed "s/.*/'&'/" | paste -sd, -)"; [ -z "$keep" ] && keep="'NONE_'"
  local open; open="$(plines "select listagg(username,',') within group (order by 1) from dba_users where oracle_maintained='N' and account_status='OPEN' and username not in ($keep);" 2>/dev/null | head -1)"
  [ -n "$open" ] && { warn "accounts OPEN that are neither whitelisted nor test accounts: $open"; } || log "only whitelisted/test accounts are open"
  local svc; svc="$(plines "select listagg(name,',') within group (order by name) from v\$active_services where name not like 'SYS%';" 2>/dev/null | head -1)"; log "services: ${svc:-none}"
  [ -n "$PROD_PDB" ] && printf '%s' "$svc" | grep -qi "$PROD_PDB" && { warn "a service still carries the PROD PDB name: $svc"; }
  local jobs; jobs="$(pval "(select count(*) from dba_scheduler_jobs where enabled='TRUE' and owner not in (select username from dba_users where oracle_maintained='Y'))" 2>/dev/null)"; log "enabled scheduler jobs (non-Oracle): ${jobs:-?}"
  local inv; inv="$(pval "(select count(*) from dba_objects where status<>'VALID')" 2>/dev/null)"; log "invalid objects: ${inv:-?}"
  if [ -n "$APEX_TEST_URL" ]; then local code; code="$(url_code "$APEX_TEST_URL" 20)"; [[ "$code" =~ ^(200|30[0-9])$ ]] && log "APEX via ORDS: $APEX_TEST_URL -> HTTP $code" || { err "APEX via ORDS: $APEX_TEST_URL -> HTTP ${code:-none} (ORDS pool pointing at the old service? APEX_PUBLIC_USER locked by relock?)"; fail=1; }; fi
  local apexpub; apexpub="$(plines "select username||':'||account_status from dba_users where username in ('APEX_PUBLIC_USER','ORDS_PUBLIC_USER','APEX_REST_PUBLIC_USER','APEX_LISTENER') and account_status<>'OPEN';" 2>/dev/null | tr '\n' ' ')"; [ -n "$apexpub" ] && warn "ORDS/APEX service accounts not OPEN: $apexpub (put them in ACCOUNT_WHITELIST)"
  state_set verify "$([ "$fail" = 0 ] && echo ok || echo failed)"; [ "$fail" = 0 ] && log "Verify OK" || err "Verify FAILED"; return "$fail"
}

cmd_rollback() {
  discover; reuse_or_init rollback
  local old; old="$(state_get old_pdb || true)"; [ -n "$old" ] && pdb_exists "$old" || die "no ${TEST_PDB}_OLD from a --keep-old run: rollback is not possible (restore from your own backup)"
  confirm "Drop the new $TEST_PDB and rename $old back to $TEST_PDB?" || die "aborted"
  if pdb_exists "$TEST_PDB"; then kill_pdb_sessions "$TEST_PDB"; do_sql root "close new $TEST_PDB" "alter pluggable database $TEST_PDB close immediate instances=all;" || true; do_sql root "drop new $TEST_PDB" "drop pluggable database $TEST_PDB including datafiles;" || return 1; fi
  do_sql root "open $old restricted" "alter pluggable database $old open restricted;" || return 1
  do_sql root "rename $old -> $TEST_PDB" "alter session set container=$old;\nalter pluggable database rename global_name to $TEST_PDB;" || return 1
  do_sql root "reopen $TEST_PDB" "alter pluggable database $TEST_PDB close immediate;\nalter pluggable database $TEST_PDB open instances=all;\nalter pluggable database $TEST_PDB save state instances=all;" || return 1
  state_set rollback ok; log "rolled back: $TEST_PDB is the previous copy again"
}

cmd_cleanup() {
  discover; reuse_or_init cleanup
  local old="${TEST_PDB}_OLD"; pdb_exists "$old" && confirm "Drop $old including datafiles?" && { [ "$(rval "(select open_mode from v\$pdbs where name=upper('$old'))")" = MOUNTED ] || do_sql root "close $old" "alter pluggable database $old close immediate instances=all;" || true; do_sql root "drop $old" "drop pluggable database $old including datafiles;"; }
  [ "${ALL:-0}" = 1 ] && pdb_exists "$GOLD_PDB" && confirm "Drop the golden copy $GOLD_PDB (next --refreshable run does a full copy again)?" && { do_sql root "close $GOLD_PDB" "alter pluggable database $GOLD_PDB close immediate instances=all;" || true; do_sql root "drop $GOLD_PDB" "drop pluggable database $GOLD_PDB including datafiles;"; }
  return 0
}

cmd_run() {
  discover; init_run_dir run; refuse_prod
  cmd_inspect; echo
  cmd_preflight || die "preflight failed - nothing changed"
  cmd_plan; confirm "Proceed? The current TEST ($([ "$METHOD" = pdb-clone ] && echo "$TEST_PDB" || echo "$SID")) will be $([ "$KEEP_OLD" = 1 ] && echo 'renamed and kept' || echo 'DESTROYED') and replaced by a copy of PROD." || die "aborted"
  cmd_backup || die "FAILED: backup (preservation) - nothing destroyed yet. Log: $LOG_FILE"
  cmd_drop || die "FAILED: drop. Log: $LOG_FILE"
  cmd_create || die "FAILED: create. $([ "$KEEP_OLD" = 1 ] && echo "'rollback' brings ${TEST_PDB}_OLD back." || echo 'The old TEST is gone; fix the cause and run create again.') Log: $LOG_FILE"
  local step rc=0; for step in rename_services mask relock fix_dblinks fix_apex fix_scheduler fix_directories reimport; do
    "cmd_$step" || { err "step $step failed"; [ "$step" = mask ] && [ "$REQUIRE_MASK" = yes ] && { err "masking is required: the clone stays CLOSED until it is masked"; do_sql root "close $TEST_PDB" "alter pluggable database $TEST_PDB close immediate instances=all;"; die "FAILED: mask. Fix MASK_SCRIPT, open the PDB, run 'mask' then the remaining steps. Log: $LOG_FILE"; }; rc=1; }
  done
  cmd_verify || rc=1
  [ "$rc" = 0 ] && echo "SUCCESS: $([ "$METHOD" = pdb-clone ] && echo "$TEST_PDB" || echo "$SID") refreshed from PROD and re-secured. $([ "$KEEP_OLD" = 1 ] && echo "${TEST_PDB}_OLD kept (cleanup drops it). ")Log: $LOG_FILE" || die "FINISHED WITH ERRORS: read $LOG_FILE, fix, re-run the failed step(s) by name, then 'verify'."
}

main() {
  load_config; refuse_root
  local cmd="${1:-}"; shift || true; parse_opts "$@"
  case "$cmd" in
    inspect) cmd_inspect;; plan) cmd_plan;; preflight) cmd_preflight;; backup) cmd_backup;; drop) cmd_drop;; create) cmd_create;;
    rename-services) cmd_rename_services;; mask) cmd_mask;; relock) cmd_relock;; fix-dblinks) cmd_fix_dblinks;; fix-apex) cmd_fix_apex;; fix-scheduler) cmd_fix_scheduler;;
    fix-directories) cmd_fix_directories;; reimport) cmd_reimport;; verify) cmd_verify;; rollback) cmd_rollback;; cleanup) cmd_cleanup;; run) cmd_run;;
    ""|-h|--help|help) usage;; *) die "Unknown command: $cmd";;
  esac
}
main "$@"
