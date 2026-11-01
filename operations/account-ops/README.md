# account-ops.sh — the service accounts that take the stack down

`APEX_PUBLIC_USER` expires and every APEX page is a 503. `DBSNMP` locks and OEM goes blind.
`GGADMIN` gets a new password in the database but not in the credential store and replication
abends. This script knows those accounts, shows where each password is stored on the host, and
changes it **everywhere at once** with a rollback. Runs as `oracle` on the database host (and the
ORDS / WebLogic / GoldenGate host, when that is the same machine).

Built-in list: `APEX_PUBLIC_USER ORDS_PUBLIC_USER ORDS_METADATA APEX_LISTENER
APEX_REST_PUBLIC_USER DBSNMP SYSMAN GGADMIN C##GGADMIN RMAN RCAT RCOWNER`; add your own with
`SERVICE_ACCOUNTS=` or `--user`.

## Quick start

```bash
cd operations/account-ops
cp account-ops.conf.example account-ops.conf     # ORDS paths, WebLogic credentials, GoldenGate alias map
./account-ops.sh inspect                          # per container: status, expiry, profile, last login, failed logins, STORED_IN
./account-ops.sh expiring --days 30               # everything that expires within 30 days, or is already expired/locked
./account-ops.sh heal                             # "ORDS is 503": find the locked/expired account, fix it, restart ORDS, verify
./account-ops.sh reset --user APEX_PUBLIC_USER --generate   # new password in the DB + ORDS pool + WebLogic DS + GG store
./account-ops.sh profile                          # move the service accounts to a no-expiry profile so it never happens again
./account-ops.sh verify                           # accounts OPEN, ORDS pools answer, testPool, ggsci dblogin
```

## Commands

- **inspect**: for every running instance and open container (`--sid`, `--pdb` to narrow):
  `USER STATUS EXPIRES PROFILE LAST_LOGIN FAILED24 STORED_IN`. Failed logins come from
  `dba_audit_trail` or the unified audit trail (return codes 1017/28000). `STORED_IN` is
  found by looking: ORDS `pool.xml` files whose `db.username` matches (`ords:<pool>`),
  WebLogic JDBC modules in every domain (`wls:<domain>/<file>(<jndi>)`), GoldenGate
  `info credentialstore` aliases (`gg:<alias>`), wallets listed with `mkstore`
  (`wallet:<dir>`), and a note for DBSNMP/SYSMAN (OEM). `--json` for machines.
- **expiring**: accounts expiring within `--days` (default 14), expired or locked, and the
  profiles that still have a `PASSWORD_LIFE_TIME`.
- **unlock**: `account unlock` with a question per account; warns when the account is also
  expired (unlock alone does not help then).
- **reset**: asks for the new password twice (or `--generate` makes a 20-character one and shows
  it **once**); saves the old hash from `dbms_metadata` (`identified by values`) into the run
  dir (mode 600); `alter user ... identified by ... account unlock` (`container=all` for common
  users in the root); then, unless `--no-propagate`: `ords --config ... config --db-pool <pool>
  secret --password-stdin db.password` for every pool using the account (old `pool.xml` and
  wallet backed up) and an ORDS restart (`ORDS_SERVICE`/`ORDS_STOP_CMD`+`ORDS_START_CMD`,
  `--no-restart` to skip); WebLogic data sources via a generated WLST script
  (`setPassword` in an edit session, `activate`), credentials from `WLS_USERCONFIG`/`WLS_USERKEY`
  or `WLS_ADMIN_USER`; GoldenGate `alter credentialstore replace user ... alias ...`
  (`dircrd` backed up). For DBSNMP and SYSMAN the OEM-side command is printed (`emcli
  modify_target` / `emctl config oms -change_repos_pwd`), because those must be done there.
  Passwords travel on stdin or in a 600-mode temp file, never on a command line.
- **profile**: creates `SA_PROFILE` (default `SERVICE_ACCOUNTS`: `PASSWORD_LIFE_TIME
  UNLIMITED`, `FAILED_LOGIN_ATTEMPTS 10`, `PASSWORD_GRACE_TIME UNLIMITED`) if missing and moves
  the accounts onto it, one question each. An already expired account still needs `reset`.
- **verify**: every target OPEN; ORDS root and per-pool HTTP codes (503 = pool cannot connect)
  and `ords config --db-pool X verify`; WebLogic `testPool()` through WLST for each data source
  using the account; `ggsci dblogin useridalias` for each alias.
- **rollback**: `alter user ... identified by values '<old hash>'` for every reset account in
  the run dir, ORDS `pool.xml`/wallet restored and ORDS restarted, GoldenGate `dircrd` restored;
  WebLogic JDBC backups are named (the encrypted password inside is domain-specific). It prints
  how old the saved verifiers are first: the applications have used the new password since then.
- **cleanup**: shreds what `reset` keeps for rollback: `old_hashes.txt` (the previous password
  verifiers, a credential by another name), the ORDS wallet backups and the GoldenGate `dircrd`
  backup. Nothing removes them otherwise, and `verify` passing does not make a reset final (a
  nightly job only logs in tomorrow), so run `cleanup` yourself once the new password is confirmed
  everywhere; `rollback` refuses after it. Until then the file sits in the run dir, mode 600.
- **heal** (= `run`): the ORDS-503 case end to end: HTTP code, every service account's state;
  LOCKED → shows the lock time, where the account is used (the thing with the old password that
  keeps locking it) and offers unlock; EXPIRED(GRACE) → offers the profile move; EXPIRED →
  offers `reset --generate` with propagation; then restarts ORDS if it was 503 and runs `verify`.
  All accounts open but still 503 → points at the pool password / listener and greps the ORDS
  logs for ORA-01017/28000/28001/12514.

## Options and config

`--user A,B`, `--sid`, `--pdb`, `--days N`, `--generate`, `--no-expiry`, `--no-propagate`,
`--no-restart`, `--dry-run`, `--yes`, `--force`, `--json`, `--verbose`, `--run-dir`. Config in
`account-ops.conf` (see the example, mode 600) or the shared `oracle.conf`. Needs
`lib/oracle-lib.sh` one folder up. Each `unlock`/`reset`/`profile`/`heal` gets its own run dir
under `~/account-ops/runs/`; `verify`, `rollback` and `cleanup` use the latest one (or `--run-dir`).

Tested against a fake `sqlplus`/`ords` (inspect, expiring, reset + rollback, heal for EXPIRED
and LOCKED, profile, dry-run); WebLogic and GoldenGate propagation only by inspection. Not yet
on a real system: run `inspect` and `expiring` first, they only read.
