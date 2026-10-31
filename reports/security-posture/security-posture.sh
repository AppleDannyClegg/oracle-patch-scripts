#!/usr/bin/env bash
# security-posture.sh - read-only security check of the database, listener/network, host and
# WebLogic, written as an auditor-shaped scorecard (control, PASS/FAIL/INFO, evidence) plus the
# usual FINDINGS. Follows the CIS Oracle Database 19c benchmark and Oracle's own hardening notes
# where they apply (--cis adds the approximate benchmark section numbers). Changes nothing.
#
# Usage: security-posture.sh [options]
#   --sid SID        one database (default: every running instance)
#   --pdb NAME       also run the per-container checks in this PDB (open PDBs otherwise)
#   --cis            label controls with CIS Oracle Database 19c benchmark sections (approximate)
#   --out DIR  --lines N  --quiet  --no-tar
#
# Config: security-posture.conf or the shared oracle.conf: SEC_OUT, SQL_CONNECT, PDB,
# SEC_APP_SCHEMAS (comma list of application schemas to report privileges for),
# SEC_ALLOWED_DBA (comma list of accounts allowed to hold DBA; others are flagged).
# Output: SEC_OUT/<host>_<ts>/REPORT.md (SCORECARD + FINDINGS first) + raw/ + tar.gz.

# shellcheck disable=SC2034  # QUIET/VERBOSE read by the lib
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="security-posture"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

SEC_OUT="${SEC_OUT:-$HOME/security-posture}"; SEC_APP_SCHEMAS="${SEC_APP_SCHEMAS:-}"; SEC_ALLOWED_DBA="${SEC_ALLOWED_DBA:-SYS,SYSTEM}"
ONLY_SID=""; CIS=0; MAKE_TAR=1; SCORE=""; NPASS=0; NFAIL=0

usage() { usage_from_header "$0"; }
parse_args() {
  while [ $# -gt 0 ]; do case "$1" in
    --sid) ONLY_SID="$2"; shift 2;; --pdb) PDB="$2"; shift 2;; --cis) CIS=1; shift;;
    --out) SEC_OUT="$2"; shift 2;; --lines) DIAG_LINES="$2"; shift 2;; --quiet) QUIET=1; shift;; --no-tar) MAKE_TAR=0; shift;; --verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;; *) die "Unknown option: $1";; esac; done
}
# control <scope> <cis-ref> <control text> <PASS|FAIL|INFO> <evidence>  (FAIL also becomes a WARN finding; "CRIT:" prefix in evidence -> CRIT)
control() {
  local scope="$1" ref="$2" text="$3" st="$4" ev="$5"
  [ "$CIS" = 1 ] && [ -n "$ref" ] && text="$text (CIS $ref)"
  SCORE="${SCORE}| $scope | $text | $st | $(printf '%s' "$ev" | tr '|' '/' | cut -c1-120) |"$'\n'
  case "$st" in PASS) NPASS=$((NPASS+1));; FAIL) NFAIL=$((NFAIL+1)); if [[ "$ev" == CRIT:* ]]; then finding CRIT sec "$scope: $text - ${ev#CRIT:}"; else finding WARN sec "$scope: $text - $ev"; fi;; esac
  [ -n "${SCORE_FILE:-}" ] && printf '%s|%s|%s|%s\n' "$scope" "$text" "$st" "$ev" >>"$SCORE_FILE"; return 0
}
# sql_controls <sid> <scope> <sql>: rows "CTRL|ref|text|status|evidence"
sql_controls() { sql_run "$1" "set heading off\n$3" 2>/dev/null | grep -a '^CTRL|' | while IFS='|' read -r _ ref text st ev; do control "$2" "$ref" "$text" "$st" "$ev"; done; }

# ---------------------------------------------------------------------------
db_controls() {
  local sid="$1" scope="$2"
  sql_controls "$sid" "$scope" "
select 'CTRL|2.2.x|'||name||' = '||nvl(value,'(null)')||'|'||decode(nvl(value,'~'), nvl(want,'~'), 'PASS', 'FAIL')||'|should be '||nvl(want,'(unset)') from (
  select name, upper(value) value, want from v\$parameter p join (
    select 'remote_os_authent' n, 'FALSE' want from dual union all select 'remote_login_passwordfile','EXCLUSIVE' from dual union all
    select 'o7_dictionary_accessibility','FALSE' from dual union all select 'sql92_security','TRUE' from dual union all
    select 'remote_os_roles','FALSE' from dual union all select 'os_roles','FALSE' from dual union all
    select 'sec_case_sensitive_logon','TRUE' from dual union all select 'audit_sys_operations','TRUE' from dual union all
    select 'sec_return_server_release_banner','FALSE' from dual union all select 'global_names','TRUE' from dual union all
    select 'sec_protocol_error_further_action','(DROP,3)' from dual union all select 'sec_max_failed_login_attempts','3' from dual union all
    select '_trace_files_public','FALSE' from dual union all select 'utl_file_dir','' from dual) w on w.n=p.name where name not like '\_%' escape '\' or value is not null) where name<>'sec_max_failed_login_attempts' or value is not null;
select 'CTRL|2.2.2|audit_trail = '||value||'|'||case when upper(value) in ('DB','DB,EXTENDED','XML','XML,EXTENDED','OS') or (select count(*) from audit_unified_enabled_policies)>0 then 'PASS' else 'FAIL' end||'|traditional or unified audit must be on' from v\$parameter where name='audit_trail';
select 'CTRL|6.1|unified audit policies enabled: '||count(*)||'|'||case when count(*)>=2 then 'PASS' else 'FAIL' end||'|'||listagg(policy_name, ',') within group (order by policy_name) from audit_unified_enabled_policies;
select 'CTRL|6.1.x|ORA_LOGON_FAILURES policy enabled|'||case when count(*)>0 then 'PASS' else 'FAIL' end||'|failed logons must be audited' from audit_unified_enabled_policies where policy_name='ORA_LOGON_FAILURES';
select 'CTRL|6.1.x|ORA_SECURECONFIG policy enabled|'||case when count(*)>0 then 'PASS' else 'FAIL' end||'|Oracle secure-config policy' from audit_unified_enabled_policies where policy_name='ORA_SECURECONFIG';
select 'CTRL|6.2.x|audit of SYS actions (unified: ORA_SECURECONFIG or audit_sys_operations)|'||case when (select upper(value) from v\$parameter where name='audit_sys_operations')='TRUE' or exists (select 1 from audit_unified_enabled_policies where policy_name='ORA_SECURECONFIG') then 'PASS' else 'FAIL' end||'|' from dual;
select 'CTRL|3.x|accounts with default passwords: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|CRIT:'||listagg(username, ',') within group (order by username) from dba_users_with_defpwd where username in (select username from dba_users where account_status='OPEN');
select 'CTRL|3.1|sample schemas absent|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(username, ',') within group (order by username) from dba_users where username in ('SCOTT','HR','OE','SH','PM','IX','BI','ADAMS','JONES','CLARK','BLAKE');
select 'CTRL|3.x|SYSDBA/SYSOPER/SYSBACKUP/SYSDG/SYSKM holders: '||listagg(username||'('||decode(sysdba,'TRUE','DBA,','')||decode(sysoper,'TRUE','OPER,','')||decode(sysbackup,'TRUE','BKP,','')||decode(sysdg,'TRUE','DG,','')||decode(syskm,'TRUE','KM','')||')', ' ') within group (order by username)||'|INFO|v\$pwfile_users' from v\$pwfile_users;
select 'CTRL|4.x|DBA role members outside the allowed list|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(grantee, ',') within group (order by grantee) from dba_role_privs where granted_role='DBA' and grantee not in (select regexp_substr(upper('$SEC_ALLOWED_DBA'),'[^,]+',1,level) from dual connect by regexp_substr(upper('$SEC_ALLOWED_DBA'),'[^,]+',1,level) is not null) and grantee not in (select username from dba_users where oracle_maintained='Y');
select 'CTRL|4.5|ANY privileges held by non-Oracle accounts: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(distinct grantee, ',') within group (order by grantee) from dba_sys_privs where privilege like '%ANY%' and grantee not in (select username from dba_users where oracle_maintained='Y') and grantee not in (select role from dba_roles where oracle_maintained='Y') and grantee<>'DBA';
select 'CTRL|4.2|PUBLIC execute on dangerous packages: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(table_name, ',') within group (order by table_name) from dba_tab_privs where grantee='PUBLIC' and privilege='EXECUTE' and table_name in ('UTL_FILE','UTL_HTTP','UTL_TCP','UTL_SMTP','UTL_MAIL','UTL_INADDR','UTL_DBWS','DBMS_JAVA','DBMS_JAVA_TEST','DBMS_LOB','DBMS_RANDOM','DBMS_SCHEDULER','DBMS_SQL','DBMS_XMLGEN','DBMS_XMLQUERY','DBMS_ADVISOR','DBMS_LDAP','DBMS_OBFUSCATION_TOOLKIT','DBMS_BACKUP_RESTORE','DBMS_AQADM_SYS','DBMS_STREAMS_ADM_UTL','DBMS_SYS_SQL','HTTPURITYPE','DBMS_CREDENTIAL','UTL_ORAMTS','DBMS_JOB','DBMS_XMLSTORE','DBMS_XMLSAVE','DBMS_REDACT','DBMS_AW','OWA_UTIL');
select 'CTRL|4.x|users with ALTER SYSTEM / CREATE ANY PROCEDURE / BECOME USER / EXEMPT ACCESS POLICY: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(grantee||':'||privilege, ' ') within group (order by grantee) from dba_sys_privs where privilege in ('ALTER SYSTEM','BECOME USER','EXEMPT ACCESS POLICY','EXEMPT REDACTION POLICY','ALTER USER','GRANT ANY PRIVILEGE','GRANT ANY ROLE') and grantee not in (select username from dba_users where oracle_maintained='Y') and grantee not in (select role from dba_roles where oracle_maintained='Y');
select 'CTRL|4.x|WITH ADMIN OPTION grants to non-Oracle users: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(grantee||':'||privilege, ' ') within group (order by grantee) from dba_sys_privs where admin_option='YES' and grantee not in (select username from dba_users where oracle_maintained='Y') and grantee not in (select role from dba_roles where oracle_maintained='Y');
select 'CTRL|4.x|proxy users: '||count(*)||'|INFO|'||listagg(proxy||'->'||client, ' ') within group (order by proxy) from dba_proxies where rownum<=20;
select 'CTRL|5.x|profiles with PASSWORD_LIFE_TIME UNLIMITED used by humans: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(distinct u.profile, ',') within group (order by u.profile) from dba_users u join dba_profiles p on p.profile=u.profile and p.resource_name='PASSWORD_LIFE_TIME' and p.limit='UNLIMITED' where u.oracle_maintained='N' and u.username not like 'APEX%' and u.username not like 'ORDS%' and u.authentication_type='PASSWORD';
select 'CTRL|5.1.x|profiles without a PASSWORD_VERIFY_FUNCTION: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(profile, ',') within group (order by profile) from dba_profiles where resource_name='PASSWORD_VERIFY_FUNCTION' and limit in ('NULL','DEFAULT') and profile in (select distinct profile from dba_users where oracle_maintained='N' and authentication_type='PASSWORD');
select 'CTRL|5.1.x|FAILED_LOGIN_ATTEMPTS > 5 or UNLIMITED: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(profile||'='||limit, ',') within group (order by profile) from dba_profiles where resource_name='FAILED_LOGIN_ATTEMPTS' and (limit='UNLIMITED' or (limit not in ('DEFAULT') and to_number(limit)>5)) and profile in (select distinct profile from dba_users where authentication_type='PASSWORD');
select 'CTRL|5.x|human accounts on the DEFAULT profile: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'INFO' end||'|'||listagg(username, ',') within group (order by username) from dba_users where profile='DEFAULT' and oracle_maintained='N' and authentication_type='PASSWORD' and rownum<=30;
select 'CTRL|5.x|accounts still with 10G password version: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(username, ',') within group (order by username) from dba_users where password_versions like '%10G%' and account_status='OPEN';
select 'CTRL|5.x|accounts not logged in for 90+ days (unified audit / last_login): '||count(*)||'|INFO|'||listagg(username, ',') within group (order by username) from dba_users where oracle_maintained='N' and account_status='OPEN' and authentication_type='PASSWORD' and nvl(last_login, created) < sysdate-90 and rownum<=40;
select 'CTRL|5.x|open accounts whose password is older than 365 days: '||count(*)||'|INFO|'||listagg(username, ',') within group (order by username) from (select username from dba_users where oracle_maintained='N' and account_status='OPEN' and authentication_type='PASSWORD' and nvl(expiry_date, sysdate+9999) > sysdate+365 and rownum<=40);
select 'CTRL|7.x|TDE: tablespaces not encrypted (excluding SYSTEM/SYSAUX/UNDO/TEMP): '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'INFO' end||'|'||listagg(tablespace_name, ',') within group (order by tablespace_name) from dba_tablespaces where encrypted='NO' and contents='PERMANENT' and tablespace_name not in ('SYSTEM','SYSAUX') and rownum<=30;
select 'CTRL|7.x|TDE keystore: '||wrl_type||' '||status||' '||wallet_type||'|'||case when status='OPEN' then 'PASS' when wallet_type='UNKNOWN' then 'INFO' else 'FAIL' end||'|CRIT:'||wrl_parameter from v\$encryption_wallet where con_id in (0,1) and rownum=1;
select 'CTRL|7.x|Database Vault: '||listagg(name||'='||status, ',') within group (order by name)||'|INFO|' from dba_dv_status;
select 'CTRL|4.x|network ACLs granting connect/resolve to PUBLIC: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(host||':'||privilege, ' ') within group (order by host) from dba_host_aces where principal='PUBLIC' and rownum<=20;
select 'CTRL|4.x|network ACLs with host * : '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(principal||':'||privilege, ' ') within group (order by principal) from dba_host_aces where host='*' and rownum<=20;
select 'CTRL|4.x|PUBLIC database links: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(db_link, ',') within group (order by db_link) from dba_db_links where owner='PUBLIC';
select 'CTRL|4.x|database links with a fixed user (stored password): '||count(*)||'|INFO|'||listagg(owner||'.'||db_link||'->'||username, ' ') within group (order by owner) from dba_db_links where username is not null and rownum<=20;
select 'CTRL|4.x|directory objects writable by PUBLIC or pointing at system paths: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(d.directory_name||'='||d.directory_path, ' ') within group (order by d.directory_name) from dba_directories d where (d.directory_path like '/etc%' or d.directory_path like '/tmp%' or d.directory_path='/' or d.directory_path like '%/bin%' or d.directory_path like '%/admin%' or d.directory_path like '%dbs%') or exists (select 1 from dba_tab_privs p where p.table_name=d.directory_name and p.grantee='PUBLIC' and p.privilege in ('WRITE','EXECUTE'));
select 'CTRL|4.x|scheduler credentials stored: '||count(*)||'|INFO|'||listagg(owner||'.'||credential_name, ',') within group (order by owner) from dba_credentials where rownum<=20;
select 'CTRL|4.x|external (OS) jobs in the scheduler: '||count(*)||'|INFO|'||listagg(owner||'.'||job_name, ',') within group (order by owner) from dba_scheduler_jobs where job_type in ('EXECUTABLE','EXTERNAL_SCRIPT') and rownum<=20;
select 'CTRL|4.x|Java in the database (JAVAVM): '||r.st||'|INFO|java sources owned by non-Oracle users: '||j.n from (select nvl(max(status),'absent') st from dba_registry where comp_id='JAVAVM') r, (select count(*) n from dba_objects where object_type like 'JAVA%' and owner not in (select username from dba_users where oracle_maintained='Y')) j;
select 'CTRL|4.x|roles granted to PUBLIC: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(granted_role, ',') within group (order by granted_role) from dba_role_privs where grantee='PUBLIC';
select 'CTRL|4.x|object grants to PUBLIC on application tables (non-Oracle owners): '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(owner||'.'||table_name, ',') within group (order by owner) from (select owner, table_name from dba_tab_privs where grantee='PUBLIC' and owner not in (select username from dba_users where oracle_maintained='Y') and rownum<=20);
select 'CTRL|4.x|APEX/ORDS public users: '||listagg(username||'='||account_status||'/'||profile, ' ') within group (order by username)||'|INFO|' from dba_users where username in ('APEX_PUBLIC_USER','ORDS_PUBLIC_USER','APEX_LISTENER','APEX_REST_PUBLIC_USER','ORDS_METADATA');
select 'CTRL|4.x|users with UNLIMITED TABLESPACE: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'INFO' end||'|'||listagg(grantee, ',') within group (order by grantee) from dba_sys_privs where privilege='UNLIMITED TABLESPACE' and grantee not in (select username from dba_users where oracle_maintained='Y') and rownum<=30;
select 'CTRL|4.x|SELECT ANY DICTIONARY / SELECT_CATALOG_ROLE holders (non-Oracle): '||count(*)||'|INFO|'||listagg(grantee, ',') within group (order by grantee) from (select grantee from dba_sys_privs where privilege='SELECT ANY DICTIONARY' union select grantee from dba_role_privs where granted_role='SELECT_CATALOG_ROLE') where grantee not in (select username from dba_users where oracle_maintained='Y') and rownum<=30;
select 'CTRL|2.x|failed logons in the last 7 days (unified audit): '||f.n||'|'||case when f.n<100 then 'PASS' else 'FAIL' end||'|top: '||t.l from (select count(*) n from unified_audit_trail where action_name='LOGON' and return_code<>0 and event_timestamp>sysdate-7) f, (select listagg(u||'='||c, ',') within group (order by c desc) l from (select dbusername u, count(*) c from unified_audit_trail where action_name='LOGON' and return_code<>0 and event_timestamp>sysdate-7 group by dbusername order by 2 desc fetch first 5 rows only)) t;
select 'CTRL|6.x|audit trail housekeeping (DBMS_AUDIT_MGMT purge job): '||nvl(max(job_name),'none')||'|'||case when count(*)>0 then 'PASS' else 'FAIL' end||'|unified/aud\$ grows forever without a purge job' from dba_scheduler_jobs where job_name like '%AUDIT%PURGE%' or job_class like '%AUDIT%' or job_name like 'SEC_AUD%';
select 'CTRL|2.x|dba_users with the SYSTEM default tablespace: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(username, ',') within group (order by username) from dba_users where default_tablespace='SYSTEM' and oracle_maintained='N';
select 'CTRL|2.x|triggers on LOGON/DDL/DATABASE owned by non-Oracle users: '||count(*)||'|INFO|'||listagg(owner||'.'||trigger_name, ',') within group (order by owner) from dba_triggers where triggering_event like '%LOGON%' or triggering_event like '%DDL%' or base_object_type='DATABASE' and owner not in (select username from dba_users where oracle_maintained='Y') and rownum<=20;"
  # APEX instance settings if APEX is there
  local apexv; apexv="$(sql_val "$sid" "(select version_no from apex_release)" 2>/dev/null)"
  [ -n "$apexv" ] && sql_controls "$sid" "$scope/APEX $apexv" "
select 'CTRL|APEX|instance setting '||name||' = '||value||'|'||case when (name='REQUIRE_HTTPS' and value in ('A','Y')) or (name='ACL_ENABLED' and value='Y') or (name='ALLOW_HOSTNAMES' and value is not null) or (name='RESTFUL_SERVICES_ENABLED' and value in ('Y','N')) or (name='PLSQL_EDITING' and value='N') or (name='WORKSPACE_PROVISION_DEMO_OBJECTS' and value='N') or (name='SERVICE_REQUESTS_ENABLED' and value='N') or (name='INSTANCE_NO_PROXY_DOMAINS') or (name='STRONG_SITE_ADMIN_PASSWORD' and value='Y') or (name='PASSWORD_HISTORY_DAYS' and value<>'0') or (name='MAX_LOGIN_FAILURES' and value<>'0') or (name='ACCOUNT_LIFETIME_DAYS' and value<>'0') then 'PASS' else 'FAIL' end||'|Administration > Instance > Security' from apex_instance_parameters where name in ('REQUIRE_HTTPS','ACL_ENABLED','ALLOW_HOSTNAMES','RESTFUL_SERVICES_ENABLED','PLSQL_EDITING','WORKSPACE_PROVISION_DEMO_OBJECTS','SERVICE_REQUESTS_ENABLED','STRONG_SITE_ADMIN_PASSWORD','PASSWORD_HISTORY_DAYS','MAX_LOGIN_FAILURES','ACCOUNT_LIFETIME_DAYS');
select 'CTRL|APEX|workspaces with Allow Public File Upload / SQL Workshop enabled in production|INFO|'||count(*)||' workspaces' from apex_workspaces;
select 'CTRL|APEX|instance admin accounts: '||listagg(user_name, ',') within group (order by user_name)||'|INFO|'||count(*)||' admins in INTERNAL' from apex_workspace_apex_users where workspace_name='INTERNAL' and is_admin='Yes';
select 'CTRL|APEX|applications with Session State Protection off: '||count(*)||'|'||case when count(*)=0 then 'PASS' else 'FAIL' end||'|'||listagg(application_id, ',') within group (order by application_id) from apex_applications where session_state_protection='Disabled' and availability_status like 'Available%';
select 'CTRL|APEX|applications with authentication NO AUTHENTICATION (public): '||count(*)||'|INFO|'||listagg(application_id, ',') within group (order by application_id) from apex_applications where authentication_scheme_type='No Authentication' and rownum<=20;
select 'CTRL|APEX|applications without SSL required (Rejoin Sessions / Deep linking enabled): '||count(*)||'|INFO|'||listagg(application_id, ',') within group (order by application_id) from apex_applications where rejoin_existing_sessions<>'N' and rownum<=20;"
}

pdb_controls() { # per container: accounts, PUBLIC grants, APEX
  local sid="$1"
  db_is_cdb "$sid" || return 0
  local p pdbs; pdbs="$(db_pdbs "$sid")"; [ -n "${PDB:-}" ] && pdbs="$(printf '%s\n%s\n' "$PDB" "$pdbs" | awk '!s[$0]++')"
  for p in $pdbs; do with_pdb "$p" db_controls "$sid" "$sid/$p"; done
}

network_controls() {
  local h lsn; listener_homes | while read -r h lsn; do
    local sq="$h/network/admin/sqlnet.ora" lo="$h/network/admin/listener.ora"; [ -n "${TNS_ADMIN:-}" ] && [ -f "$TNS_ADMIN/sqlnet.ora" ] && sq="$TNS_ADMIN/sqlnet.ora" && lo="$TNS_ADMIN/listener.ora"
    section_sh "net_$lsn" "echo '== $sq'; grep -vE '^\s*#|^\s*$' '$sq' 2>/dev/null; echo; echo '== $lo'; grep -vE '^\s*#|^\s*$' '$lo' 2>/dev/null | redact; echo; ls -la '$h/network/admin' 2>/dev/null"
    local v
    v="$(grep -iE '^\s*SQLNET.ALLOWED_LOGON_VERSION_SERVER' "$sq" 2>/dev/null | grep -oE '[0-9]+' | head -1)"; control "net/$lsn" "2.1.x" "SQLNET.ALLOWED_LOGON_VERSION_SERVER >= 12" "$([ "${v:-0}" -ge 12 ] && echo PASS || echo FAIL)" "value: ${v:-unset (default 12 on 12c+, but set it explicitly)}"
    [ -z "$v" ] && control "net/$lsn" "2.1.x" "SQLNET.ALLOWED_LOGON_VERSION_SERVER set explicitly" INFO "not set"
    v="$(grep -iE '^\s*SQLNET.ENCRYPTION_SERVER' "$sq" 2>/dev/null | sed 's/.*=//; s/[[:space:]]//g')"; control "net/$lsn" "2.1.x" "SQLNET.ENCRYPTION_SERVER REQUIRED (native network encryption)" "$([[ "${v^^}" == *REQUIRED* ]] && echo PASS || echo FAIL)" "value: ${v:-unset}"
    v="$(grep -iE '^\s*SQLNET.CRYPTO_CHECKSUM_SERVER' "$sq" 2>/dev/null | sed 's/.*=//; s/[[:space:]]//g')"; control "net/$lsn" "2.1.x" "SQLNET.CRYPTO_CHECKSUM_SERVER REQUIRED" "$([[ "${v^^}" == *REQUIRED* ]] && echo PASS || echo FAIL)" "value: ${v:-unset}"
    v="$(grep -iE '^\s*SQLNET.ENCRYPTION_TYPES_SERVER' "$sq" 2>/dev/null | sed 's/.*=//')"; [[ "${v^^}" == *AES* ]] || [ -z "$v" ] && [[ "${v^^}" != *AES* ]] && control "net/$lsn" "2.1.x" "encryption types restricted to AES" INFO "value: ${v:-unset (all algorithms)}"
    v="$(grep -iE '^\s*SQLNET.EXPIRE_TIME' "$sq" 2>/dev/null | grep -oE '[0-9]+' | head -1)"; control "net/$lsn" "2.1.x" "SQLNET.EXPIRE_TIME set (dead connection detection)" "$([ -n "$v" ] && echo PASS || echo FAIL)" "value: ${v:-unset}"
    v="$(grep -iE '^\s*TCP.VALIDNODE_CHECKING' "$sq" 2>/dev/null | sed 's/.*=//; s/[[:space:]]//g')"; control "net/$lsn" "2.1.x" "TCP.VALIDNODE_CHECKING with INVITED_NODES" "$([[ "${v^^}" == *YES* ]] && echo PASS || echo INFO)" "value: ${v:-unset}"
    grep -qiE '^\s*SEC_PROTOCOL_ERROR_FURTHER_ACTION|^\s*SQLNET.INBOUND_CONNECT_TIMEOUT' "$sq" 2>/dev/null && control "net/$lsn" "2.1.x" "SQLNET.INBOUND_CONNECT_TIMEOUT set" PASS "set" || control "net/$lsn" "2.1.x" "SQLNET.INBOUND_CONNECT_TIMEOUT set" FAIL "unset (default 60 s; set it, and INBOUND_CONNECT_TIMEOUT_<listener> in listener.ora)"
    v="$(grep -iE '^\s*ADMIN_RESTRICTIONS_' "$lo" 2>/dev/null | sed 's/.*=//; s/[[:space:]]//g')"; control "net/$lsn" "2.1.1" "ADMIN_RESTRICTIONS_$lsn = ON" "$([[ "${v^^}" == ON ]] && echo PASS || echo FAIL)" "value: ${v:-unset}"
    v="$(grep -iE '^\s*LOCAL_OS_AUTHENTICATION_' "$lo" 2>/dev/null | sed 's/.*=//; s/[[:space:]]//g')"; [ -n "$v" ] && [ "${v^^}" = OFF ] && control "net/$lsn" "2.1.x" "LOCAL_OS_AUTHENTICATION off (listener password in use?)" INFO "value $v - listener passwords are deprecated, keep OS auth"
    grep -qiE 'PROTOCOL\s*=\s*TCPS' "$lo" 2>/dev/null && control "net/$lsn" "2.1.x" "TCPS endpoint configured" PASS "listener.ora has TCPS" || control "net/$lsn" "2.1.x" "TCPS endpoint configured" INFO "no TCPS endpoint (native encryption may cover it)"
    grep -qiE 'HOST\s*=\s*0\.0\.0\.0' "$lo" 2>/dev/null && control "net/$lsn" "" "listener bound to 0.0.0.0" INFO "all interfaces"
    local wl; wl="$(grep -iE 'WALLET_LOCATION' -A3 "$sq" 2>/dev/null | grep -oE 'DIRECTORY\s*=\s*[^)]+' | sed 's/.*=\s*//')"
    [ -n "$wl" ] && { local wp; wp="$(file_mode "$wl")"; control "net/$lsn" "" "wallet directory $wl not world-readable" "$([ -n "$wp" ] && [ "${wp: -1}" = 0 ] && echo PASS || echo FAIL)" "mode ${wp:-unknown}"; }
    local pw; pw="$(ls "$h"/dbs/orapw* 2>/dev/null | head -1)"; [ -n "$pw" ] && { local pm; pm="$(file_mode "$pw")"; control "net/$lsn" "1.x" "password file $(basename "$pw") mode 640 or stricter" "$([ -n "$pm" ] && [ "${pm: -1}" = 0 ] && echo PASS || echo FAIL)" "mode ${pm:-unknown}"; }
    local ob; ob="$(file_mode "$h/bin/oracle")"; [ -n "$ob" ] && control "net/$lsn" "1.x" "\$ORACLE_HOME/bin/oracle is 6751 (setuid oracle, no world execute beyond the binary's design)" "$([ "$ob" = 6751 ] || [ "$ob" = 751 ] && echo PASS || echo INFO)" "mode $ob"
    local ww; ww="$(find "$h" -xdev -perm -o+w ! -type l 2>/dev/null | head -5 | tr '\n' ' ')"; control "net/$lsn" "1.x" "no world-writable files under ORACLE_HOME" "$([ -z "$ww" ] && echo PASS || echo FAIL)" "${ww:-none}"
  done
  grep -qE '^[^#].*:Y' /etc/oratab 2>/dev/null && true
}

host_controls() {
  section_sh host_sec "id; umask; echo; grep -E '^(PermitRootLogin|PasswordAuthentication|Protocol|X11Forwarding|PermitEmptyPasswords|MaxAuthTries)' /etc/ssh/sshd_config 2>/dev/null; echo; echo 'sudo rules for oracle/grid/weblogic:'; $SUDO grep -hE 'oracle|grid|weblogic' /etc/sudoers /etc/sudoers.d/* 2>/dev/null; echo; getenforce 2>/dev/null; echo; (systemctl is-active firewalld 2>/dev/null || $SUDO iptables -S 2>/dev/null | head -3); echo; echo 'kernel:'; uname -r; (uptrack-uname -r 2>/dev/null || echo 'no ksplice'); echo; echo 'last patches:'; $SUDO yum history list 2>/dev/null | sed -n '3,6p'; echo; echo 'oracle user:'; getent passwd oracle grid weblogic 2>/dev/null; chage -l oracle 2>/dev/null | head -3; echo; echo 'oraInst / central inventory:'; cat /etc/oraInst.loc 2>/dev/null; ls -ld /etc/oraInst.loc /etc/oratab 2>/dev/null; echo; echo 'cron for oracle:'; crontab -l 2>/dev/null | grep -v '^#' | head -10"
  local u; u="$(umask)"; control host "" "umask of the Oracle owner is 022 or stricter" "$([ "${u: -2}" = 22 ] || [ "${u: -2}" = 27 ] || [ "${u: -2}" = 77 ] && echo PASS || echo FAIL)" "umask $u"
  local prl; prl="$(grep -E '^PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')"; [ -n "$prl" ] && control host "" "sshd PermitRootLogin no" "$([ "$prl" = no ] && echo PASS || echo FAIL)" "value $prl"
  local pa; pa="$(grep -E '^PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}')"; [ -n "$pa" ] && control host "" "sshd PasswordAuthentication no (keys only)" "$([ "$pa" = no ] && echo PASS || echo INFO)" "value $pa"
  local se; se="$(getenforce 2>/dev/null)"; [ -n "$se" ] && control host "" "SELinux enforcing" "$([ "$se" = Enforcing ] && echo PASS || echo INFO)" "$se"
  local fw; fw="$(systemctl is-active firewalld 2>/dev/null)"; [ -n "$fw" ] && control host "" "host firewall active" "$([ "$fw" = active ] && echo PASS || echo INFO)" "firewalld $fw"
  [ -f /etc/oratab ] && control host "" "/etc/oratab not world-writable" "$(o="$(file_mode /etc/oratab | cut -c3)"; [ $(( ${o:-0} & 2 )) -ne 0 ] && echo FAIL || echo PASS)" "mode $(file_mode /etc/oratab)"
  local ks; ks="$(uptrack-uname -r 2>/dev/null)"; control host "" "kernel patched (Ksplice effective kernel)" "$([ -n "$ks" ] && echo PASS || echo INFO)" "${ks:-no ksplice; running $(uname -r)}"
  [ -n "$SUDO" ] || control host "" "sudo -n available to this script" INFO "no: sudoers rules and iptables were not read"
  local sr; sr="$($SUDO grep -hE '^oracle.*NOPASSWD.*ALL' /etc/sudoers /etc/sudoers.d/* 2>/dev/null | head -1)"; [ -n "$sr" ] && control host "" "oracle has NOPASSWD: ALL sudo" FAIL "CRIT:$sr"
}

wls_controls() {
  local h d; for h in $(wls_homes); do for d in $(wls_domains "$h"); do
    local cfg="$d/config/config.xml" dn; dn="$(basename "$d")"
    section_sh "wls_${dn}_sec" "grep -E '<production-mode-enabled>|<name>weblogic</name>|DemoIdentity|DemoTrust|custom-identity-keystore|<listen-address>|<ssl>|<enabled>|<listen-port-enabled>|<two-way-ssl|<hostname-verification|<administration-port-enabled>|<console-enabled>|<web-service-test-page|<anonymous-admin-lookup|<t3|<tunneling|<credential-encrypted>|<password-encrypted>' '$cfg' | sed 's/^ *//' | redact | head -80; echo; ls -la '$d'/security/ 2>/dev/null; echo; grep -lE 'password-encrypted>\{AES' '$d'/config/jdbc/*.xml 2>/dev/null | wc -l | sed 's/^/jdbc modules with encrypted passwords: /'; grep -LE 'password-encrypted>\{AES' '$d'/config/jdbc/*.xml 2>/dev/null | sed 's/^/PLAINTEXT or missing: /'"
    local pm; pm="$(sed -n 's/.*<production-mode-enabled>\([^<]*\)<.*/\1/p' "$cfg" | head -1)"; control "wls/$dn" "" "production mode enabled" "$([ "$pm" = true ] && echo PASS || echo FAIL)" "production-mode-enabled=${pm:-false}"
    grep -q 'DemoIdentity' "$cfg" && ! grep -q 'custom-identity-keystore-file-name' "$cfg" && control "wls/$dn" "" "no Demo identity keystore" FAIL "DemoIdentity.jks in use" || control "wls/$dn" "" "no Demo identity keystore" PASS "custom keystore or no demo reference"
    local ap; ap="$(sed -n 's/.*<administration-port-enabled>\([^<]*\)<.*/\1/p' "$cfg" | head -1)"; control "wls/$dn" "" "administration port enabled (admin traffic on SSL, separate from app traffic)" "$([ "$ap" = true ] && echo PASS || echo FAIL)" "administration-port-enabled=${ap:-false}"
    grep -qE '<listen-port-enabled>false' "$cfg" && control "wls/$dn" "" "plain-text listen ports disabled on some servers" PASS "listen-port-enabled=false present" || control "wls/$dn" "" "plain-text listen ports disabled" INFO "no server has listen-port-enabled=false; make sure non-SSL ports are not reachable from users"
    grep -qE '<console-enabled>false' "$cfg" && control "wls/$dn" "" "console disabled on this domain" INFO "console-enabled=false" || control "wls/$dn" "" "console reachable only from admin networks" INFO "console enabled (default) - restrict at the proxy/firewall"
    grep -qE '<anonymous-admin-lookup-enabled>true' "$cfg" && control "wls/$dn" "" "anonymous admin lookup disabled" FAIL "anonymous-admin-lookup-enabled=true" || control "wls/$dn" "" "anonymous admin lookup disabled" PASS "default"
    grep -qE '<web-service-test-page-enabled>true' "$cfg" && control "wls/$dn" "" "web service test page disabled" FAIL "enabled" || true
    grep -qE '<hostname-verification-ignored>true|<hostname-verifier-ignored>true' "$cfg" && control "wls/$dn" "" "SSL hostname verification not ignored" FAIL "hostname verification ignored" || control "wls/$dn" "" "SSL hostname verification not ignored" PASS "default"
    local pt; pt="$(grep -LE 'password-encrypted>\{AES' "$d"/config/jdbc/*.xml 2>/dev/null | wc -l | tr -d ' ')"; [ "$pt" != 0 ] && control "wls/$dn" "" "all JDBC passwords encrypted ({AES})" FAIL "CRIT:$pt JDBC module(s) without an {AES} encrypted password"
    local bp; bp="$(ls -la "$d/servers/"*/security/boot.properties 2>/dev/null | awk '$1 !~ /^-rw-------/ {print $NF}' | head -3 | tr '\n' ' ')"; [ -n "$bp" ] && control "wls/$dn" "" "boot.properties mode 600" FAIL "$bp"
    local t3; t3="$(grep -c '<tunneling-enabled>true' "$cfg")"; [ "$t3" != 0 ] && control "wls/$dn" "" "HTTP tunneling (T3 over HTTP) disabled" FAIL "tunneling-enabled=true on $t3 server(s) - exposes T3/RMI to the web tier"
    control "wls/$dn" "" "T3 reachable only from trusted networks (JEP290 filter / network channels)" INFO "check: non-SSL T3 on $(wls_servers "$d" | awk '{print $2}' | tr '\n' ',') - put a network channel for HTTP only behind the proxy; set the RMI filter in JAVA_OPTIONS (weblogic.rmi.filter)"
    local ws; ws="$(wls_servers "$d" | awk '{print $2}')"; local p; for p in $ws; do port_open "$p" && { local c; c="$(url_code "http://127.0.0.1:$p/console")"; [ "$c" = 200 ] || [ "$c" = 302 ] && control "wls/$dn" "" "console answers on plain HTTP port $p" INFO "HTTP $c"; }; done
    grep -q '<name>weblogic</name>' "$cfg" && control "wls/$dn" "" "admin user not named 'weblogic'" INFO "an account literally named weblogic exists in config (common; rename or ensure a strong password)"
    local kv_; kv_="$(ls "$d"/security/*.jks "$d"/servers/*/security/*.jks 2>/dev/null | head -5 | tr '\n' ' ')"; [ -n "$kv_" ] && kv "keystores" "$kv_" && kv_end
  done; done
}

write_scorecard() {
  local sc="$OUT/SCORECARD.md"
  { printf '# Security scorecard: %s  %s\n\n%s PASS, %s FAIL (INFO rows are for review)\n\n| scope | control | status | evidence |\n|---|---|---|---|\n' "$HOST" "$(ts)" "$NPASS" "$NFAIL"
    printf '%s' "$SCORE" | grep '| FAIL |'; printf '%s' "$SCORE" | grep '| INFO |'; printf '%s' "$SCORE" | grep '| PASS |'; } >"$sc"
  { printf '# SCORECARD  (%s PASS, %s FAIL)\n\n| scope | control | status | evidence |\n|---|---|---|---|\n' "$NPASS" "$NFAIL"; printf '%s' "$SCORE" | grep '| FAIL |'; printf '%s' "$SCORE" | grep '| INFO |'; printf '%s' "$SCORE" | grep '| PASS |'; printf '\n'; cat "$REPORT"; } >"$REPORT.new" && mv "$REPORT.new" "$REPORT"
}

main() {
  load_config; parse_args "$@"
  report_init "$SEC_OUT/${HOST}_$(date '+%Y%m%d_%H%M%S')"; SCORE_FILE="$OUT/scorecard.txt"; : >"$SCORE_FILE"
  say "security-posture $VERSION -> $OUT"
  h1 "Host"; host_controls
  h1 "Listener / Oracle Net"; network_controls
  local sids s; sids="$(db_instances | grep -vE '^\+ASM|^-MGMTDB|^\+APX')"; [ -n "$ONLY_SID" ] && sids="$ONLY_SID"
  for s in $sids; do
    h1 "Database $s"; say "database $s"
    sql_ok "$s" || { finding CRIT db "$s: cannot connect as sysdba"; continue; }
    sqlsec "$s" ctx "$s: version, CDB, audit mode" "select version_full, cdb from v\$instance, v\$database;
select 'unified auditing: '||value from v\$option where parameter='Unified Auditing';
select name, value from v\$parameter where name in ('audit_trail','audit_sys_operations','sec_case_sensitive_logon','remote_login_passwordfile','os_authent_prefix','remote_os_authent','ldap_directory_sysauth','wallet_root','tde_configuration','encrypt_new_tablespaces') order by 1;"
    db_controls "$s" "$s"; pdb_controls "$s"
    [ -n "$SEC_APP_SCHEMAS" ] && sqlsec "$s" appschemas "$s: privileges of application schemas ($SEC_APP_SCHEMAS)" "select grantee, privilege, admin_option from dba_sys_privs where grantee in (select regexp_substr(upper('$SEC_APP_SCHEMAS'),'[^,]+',1,level) from dual connect by regexp_substr(upper('$SEC_APP_SCHEMAS'),'[^,]+',1,level) is not null) order by 1,2;
select grantee, granted_role, admin_option from dba_role_privs where grantee in (select regexp_substr(upper('$SEC_APP_SCHEMAS'),'[^,]+',1,level) from dual connect by regexp_substr(upper('$SEC_APP_SCHEMAS'),'[^,]+',1,level) is not null) order by 1,2;"
  done
  h1 "WebLogic"; wls_controls
  # rebuild scorecard from the file (subshell writes) then counts
  SCORE=""; NPASS=0; NFAIL=0
  while IFS='|' read -r scope text st ev; do SCORE="${SCORE}| $scope | $text | $st | $(printf '%s' "$ev" | cut -c1-120) |"$'\n'; case "$st" in PASS) NPASS=$((NPASS+1));; FAIL) NFAIL=$((NFAIL+1));; esac; done < <(awk '!seen[$0]++' "$SCORE_FILE")
  findings_sync; write_scorecard
  report_finish "security-posture: $HOST $(date '+%Y-%m-%d')" "$MAKE_TAR" >/dev/null
  [ "$QUIET" = 1 ] || { echo; printf '%s PASS, %s FAIL\n' "$NPASS" "$NFAIL"; print_findings; }
  printf '\n%s\n%s\n' "$OUT/SCORECARD.md" "$OUT/REPORT.md"
}
main "$@"
