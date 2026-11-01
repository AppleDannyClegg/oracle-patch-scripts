# security-posture.sh — the audit-shaped security check

Read-only. Produces a **scorecard** (scope, control, PASS / FAIL / INFO, evidence) that can go
straight into an audit response, plus the usual FINDINGS list and evidence sections. Covers the
database (every instance and every open PDB), Oracle Net and the listener, the host, APEX instance
settings and WebLogic domains. `--cis` adds the approximate CIS Oracle Database 19c Benchmark
section numbers to each control.

## Quick start

```bash
cd reports/security-posture
./security-posture.sh --cis
# prints PASS/FAIL counts and the findings; writes SCORECARD.md and REPORT.md
```

Output under `~/security-posture/<host>_<ts>/`: `SCORECARD.md` (FAIL rows first, then INFO, then
PASS), `REPORT.md` (scorecard + FINDINGS + evidence), `raw/`, and a `.tar.gz`. Hand `REPORT.md`
to Claude with *"this is a security-posture report; write the remediation plan ordered by risk,
with the exact SQL/commands, and tell me which FAILs are acceptable with a documented exception"*.

## What it checks

**Database (per container)**
- Parameters: `remote_os_authent`, `remote_login_passwordfile`, `o7_dictionary_accessibility`,
  `sql92_security`, `remote_os_roles`, `os_roles`, `sec_case_sensitive_logon`,
  `audit_sys_operations`, `sec_return_server_release_banner`, `global_names`,
  `sec_protocol_error_further_action`, `sec_max_failed_login_attempts`, `utl_file_dir`
- Auditing: `audit_trail` or unified policies, `ORA_LOGON_FAILURES` and `ORA_SECURECONFIG`
  enabled, SYS auditing, a purge job for the audit trail, failed logons in the last 7 days
- Accounts: default passwords (`dba_users_with_defpwd`), sample schemas, SYSDBA/SYSOPER/SYSBACKUP
  holders, DBA role members outside `SEC_ALLOWED_DBA`, `%ANY%` privileges, `ALTER SYSTEM` /
  `BECOME USER` / `EXEMPT ACCESS POLICY` / `GRANT ANY`, `WITH ADMIN OPTION`, proxy users,
  `UNLIMITED TABLESPACE`, `SELECT ANY DICTIONARY`, users on `SYSTEM` tablespace, 10G password
  versions, 90-day dormant accounts, passwords older than a year
- Profiles: `PASSWORD_LIFE_TIME UNLIMITED` on human accounts, missing verify function,
  `FAILED_LOGIN_ATTEMPTS` > 5, humans on DEFAULT
- PUBLIC: execute on `UTL_FILE`/`UTL_HTTP`/`UTL_TCP`/`DBMS_SCHEDULER`/`DBMS_SQL`/`DBMS_JAVA`/...,
  roles granted to PUBLIC, object grants on application tables, PUBLIC DB links, network ACLs
  for PUBLIC or host `*`
- Data: TDE coverage and keystore state, Database Vault status, directory objects on system
  paths, scheduler credentials and external jobs, Java in the database, logon/DDL triggers

**Oracle Key Vault endpoints** (every `okvclient.ora` found: `WALLET_ROOT`, the usual client
paths, `<ORACLE_HOME>/flex_tde_wallet/okv`, or `wallet_root` from the database). The endpoint
certificate lives one year, and a console rotation does not replace `ssl/ewallet.p12`: the client
writes the new wallet into a subfolder of `ssl/` and repoints `SSL_WALLET_LOC` only when `okvutil
list` reaches the node that generated it. Controls: where `SSL_WALLET_LOC` points (rotated or
not), `OKV_HOSTNAME` / `UPDATE_TIMESTAMP`, the pointed-to wallet exists (CRIT when not), the
certificate's `notAfter` when `OKV_WALLET_PASSWORD` is set (CRIT expired or under 30 days, FAIL
under 90; the password reaches openssl through a 600-mode file), otherwise the wallet file's age
(CRIT at 365 days, FAIL from 300), and the TDE secret store `conf/ewallet.p12` is listed as
do-not-touch with its mode. An unreadable wallet or date is a FAIL plus the age check, never
silence.
- APEX: `REQUIRE_HTTPS`, `ACL_ENABLED`, `ALLOW_HOSTNAMES`, `PLSQL_EDITING`, demo objects,
  strong admin password, login failure and account lifetime settings, instance admins, apps with
  session state protection off or no authentication

**Oracle Net / listener (per running listener)**: `ALLOWED_LOGON_VERSION_SERVER`, native
encryption and checksum REQUIRED, AES only, `EXPIRE_TIME`, `INBOUND_CONNECT_TIMEOUT`, valid node
checking, `ADMIN_RESTRICTIONS`, local OS authentication, TCPS endpoint, listener on 0.0.0.0,
wallet directory and password file permissions, `bin/oracle` mode, world-writable files under
ORACLE_HOME.

**Host**: umask, sshd `PermitRootLogin`/`PasswordAuthentication`, SELinux, firewall, `/etc/oratab`
mode, Ksplice/kernel, `oracle` with `NOPASSWD: ALL`, sudoers rules (needs `sudo -n`).

**WebLogic (per domain)**: production mode, Demo keystore, administration port, plain-text listen
ports, console exposure, anonymous admin lookup, web service test page, hostname verification,
JDBC passwords not `{AES}`-encrypted, `boot.properties` mode, HTTP tunneling, T3 exposure note,
console answering on plain HTTP.

## Options

| Option | Meaning |
|---|---|
| `--sid`, `--pdb` | one database; make sure a PDB is covered |
| `--cis` | add CIS benchmark section labels |
| `--out DIR`, `--lines N`, `--quiet`, `--no-tar` | |

Config keys: `SEC_OUT`, `SEC_ALLOWED_DBA` (default `SYS,SYSTEM`), `SEC_APP_SCHEMAS` (comma list;
their privileges are listed for review), `SQL_CONNECT`, `PDB`. Needs `lib/oracle-lib.sh` one
folder up. The CIS numbers are approximate pointers, not a certified benchmark run.
