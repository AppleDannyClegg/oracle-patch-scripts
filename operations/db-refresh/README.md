# db-refresh.sh — TEST from PROD, and safe to be a test again

Refreshes a test database from production and then does the part people forget: production
service names gone, data masked, accounts locked, database links to production dropped, APEX
mail pointed at the test relay, scheduler jobs disabled, directories remapped, and the users,
grants, links and schemas that only existed on the old TEST put back. Runs on the **TEST**
server as `oracle`. It refuses to run on a host that matches `PROD_HOST_PATTERN` or on a
database whose name contains PROD/PRD/LIVE.

## Quick start

```bash
cd operations/db-refresh
cp db-refresh.conf.example db-refresh.conf && chmod 600 db-refresh.conf   # PDB names, link, mask script, whitelist...
./db-refresh.sh inspect        # TEST and PROD (through the link): versions, charset, compatible, TDE, sizes, space, links
./db-refresh.sh plan           # the 13 steps with the actual names
./db-refresh.sh preflight      # would it work (nothing changed)
./db-refresh.sh run            # the whole thing, one question before the old TEST is destroyed
./db-refresh.sh run --keep-old # same, but the old TEST PDB is renamed <PDB>_OLD so 'rollback' can bring it back
```

Every step is also a command (`backup`, `drop`, `create`, `rename-services`, `mask`, `relock`,
`fix-dblinks`, `fix-apex`, `fix-scheduler`, `fix-directories`, `reimport`, `verify`) so a failed
run can be continued by name in the same run dir (`--run-dir ~/db-refresh/runs/latest`).

## Two ways to copy

- **pdb-clone** (default): `create pluggable database TESTPDB from PRODPDB@PRODLINK` — a hot
  clone over a database link from TEST's `CDB$ROOT` to PROD's root (common user with `CREATE
  PLUGGABLE DATABASE`; PROD in ARCHIVELOG with local undo). With `--refreshable` the script keeps
  a **refreshable golden copy** `TESTPDB_GOLD`: the first run copies it in full, later runs only
  `alter pluggable database ... refresh` (redo since last time) and clone TEST from it locally
  (`--snapshot` for a snapshot copy on ACFS/ZFS/NFS). TDE sources get `keystore identified by`
  (`KEYSTORE_PASSWORD`, prompted). `CLONE_OPTIONS` passes `create_file_dest` /
  `file_name_convert` when the CDB is not OMF.
- **rman-duplicate**: `shutdown abort`, `startup nomount pfile`, then `duplicate target database
  to TESTSID from active database using backupset section size 32G` (SYS password of PROD
  prompted, handed to RMAN on stdin) or, with `--from-backup DIR`, `duplicate database ... backup
  location`. `--noarchivelog` afterwards. No `--keep-old` here: the whole database is overwritten.

## What `run` does

1. **preflight**: mask script present when required; link exists and PROD answers through it;
   TEST release ≥ PROD; link user has `CREATE PLUGGABLE DATABASE`; PROD ARCHIVELOG + local undo;
   charset equal (AL32UTF8 superset warned); `compatible` TEST ≥ PROD; encrypted tablespaces on
   PROD need an open keystore here; space: PROD PDB size (+ temp) against the file destination
   (ASM diskgroup or filesystem) minus what dropping the old TEST frees (doubled on the first
   refreshable run); who is connected to the TEST PDB; no leftover `_OLD`. rman: password file,
   `tnsping` both aliases, backup dir, pfile.
2. **backup** (preservation, into the run dir): `dbms_metadata` DDL of the TEST PDB's
   non-Oracle profiles, roles, users, system/role/object grants, quotas, database links and
   directories; account states; services; scheduler job states; APEX instance parameters
   (SMTP, print server, URLs, wallet); `expdp` of `PRESERVE_SCHEMAS` when `EXP_CONNECT` is
   set; pfile; `tnsnames.ora`.
3. **drop**: kill sessions, close, `drop pluggable database ... including datafiles`; or with
   `--keep-old` open restricted, `rename global_name to TESTPDB_OLD`, close.
4. **create**: as above; open read write, save state; plug-in violations reported.
5. **rename-services**: every service in the clone that matches `SERVICE_MAP`, contains the
   PROD PDB name or `PROD_HOST_PATTERN` is deleted and re-created under the test name
   (`dbms_service`). Clusterware services are not copied by a clone: add them with `srvctl`.
6. **mask**: `MASK_SCRIPT` in the PDB with `whenever sqlerror exit`; then `MASK_VERIFY_SQL`
   must return `OK`. With `REQUIRE_MASK=yes` a failure **closes the PDB again** and stops the run.
7. **relock**: every non-Oracle account not in `ACCOUNT_WHITELIST`/`TEST_ACCOUNTS` is locked;
   test accounts get `TEST_ACCOUNT_PASSWORD` and are unlocked.
8. **fix-dblinks**: links in `DBLINK_MAP` are re-created pointing at the test target (password
   prompted); every other link whose host matches `PROD_HOST_PATTERN` is dropped (private links
   that SYS cannot drop are reported).
9. **fix-apex**: the old TEST's saved instance parameters restored, then `APEX_PARAMS`
   applied via `apex_instance_admin.set_parameter`. URLs inside applications are data: put them
   in the mask script.
10. **fix-scheduler**: `DISABLE_JOBS=ALL` disables every enabled non-Oracle job, then
    re-enables the ones the old TEST had enabled; or a list; or `NONE`.
11. **fix-directories**: `DIRECTORY_MAP` prefixes applied with `create or replace directory`.
12. **reimport**: replays the preserved DDL (existing objects raise expected errors), `impdp`
    of the preserved schemas with `table_exists_action=replace`, `utlrp`.
13. **verify**: PDB READ WRITE and no plug-in violations; `MASK_VERIFY_SQL` is `OK`; no link
    matches `PROD_HOST_PATTERN`; only whitelisted/test accounts open; no service still carrying
    the PROD name; enabled jobs and invalid objects counted; `APEX_TEST_URL` answers 200/30x;
    ORDS/APEX service accounts open.

The last line is `SUCCESS ...` or `FINISHED WITH ERRORS` naming the log. `rollback` works only
after `--keep-old` (drop the new PDB, rename `_OLD` back). `cleanup` drops `_OLD`, `cleanup
--all` also the golden copy.

## Options and config

`--method`, `--sid`, `--prod-pdb`, `--test-pdb`, `--link`, `--refreshable`, `--snapshot`,
`--from-backup DIR`, `--no-drop`, `--keep-old`, `--preserve-schemas A,B`, `--require-mask`,
`--noarchivelog`, `--skip step,step`, `--dry-run`, `--yes`, `--force`, `--verbose`, `--run-dir`.
Everything else in `db-refresh.conf` (see the example; mode 600). Passwords (PROD SYS, keystore,
test accounts, re-pointed links, `EXP_CONNECT`) come from the file or a prompt, never from a
command line. Needs `lib/oracle-lib.sh` one folder up. Logs, the preservation DDL and state under
`~/db-refresh/runs/<ts>/`.

Tested against a fake `sqlplus` (hot clone, keep-old + rollback, refreshable golden copy first
and second run, failed mask closing the PDB, dry-run, cleanup); rman-duplicate only dry-run. Not
yet on a real database: do `inspect`, `plan`, `preflight` and then a `--keep-old` run first.
