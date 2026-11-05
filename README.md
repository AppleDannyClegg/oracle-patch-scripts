# Oracle operations scripts: WebLogic, APEX, ORDS, Database

Stand-alone bash scripts for running and patching an Oracle estate (WebLogic, APEX, ORDS, Database,
Data Guard, RMAN, GoldenGate) without being an expert in each product. Twenty scripts in three
folders, `patching/`, `operations/` and `reports/`, one sub-folder per script with its
`*.conf.example` and its own README. Everything except `wls-patch`, `apex-patch`, `ords-patch` and
`oracle-diag` sources `lib/oracle-lib.sh` from the top of the tree (two levels up), so copy the whole
tree (`get.sh`, or `get.ps1` on Windows, does it) or a script folder together with `lib/`, never a single file.
`get.sh` lays the tree down in `$PATCH_BASE/scripts` (default `/u01/patches/scripts`; `get.ps1` uses `%USERPROFILE%\patches\scripts`).
`$PATCH_BASE` is also where every download lands - the manifest and the patch zips, one subfolder per
kind - so one folder holds everything (see [Where to put the files](#servers-without-internet-access)).

```bash
export PATCH_BASE=~/patches       # optional; default /u01/patches
curl -fsSL https://raw.githubusercontent.com/AppleDannyClegg/oracle-patch-scripts/main/get.sh | bash
```

On Windows the same fetch is one line too (PowerShell or a plain `cmd`/`tar` form) - see
[Getting the scripts](#getting-the-scripts).

Every script that changes something has the same shape:

| Step | Command | Changes anything? |
|---|---|---|
| look | `inspect` | no |
| what would happen | `plan` | no |
| would it work | `preflight` | no (downloads/unzips only) |
| do it | `run` | yes: backup, stop, apply, start, verify, **automatic rollback on failure** |

Report scripts have no commands: run them, read `REPORT.md`, or hand it to Claude.

## patching/

| Script | What it patches | Guide |
|---|---|---|
| `patching/wls-patch/wls-patch.sh` | WebLogic Server 12.2.1.x / 14.1.x: quarterly PSU + Coherence via OPatch, downloads from My Oracle Support | [README](patching/wls-patch/README.md) |
| `patching/apex-patch/apex-patch.sh` | APEX in the database: full release upgrades from Oracle's public download site, `apxdwngrd.sql` rollback | [README](patching/apex-patch/README.md) |
| `patching/ords-patch/ords-patch.sh` | ORDS, standalone or deployed inside WebLogic: schema upgrade per pool, symlink or war switch | [README](patching/ords-patch/README.md) |
| `patching/db-patch/db-patch.sh` | Oracle Database Release Updates: OPatch + datapatch, standby-first on Data Guard, out-of-place option, Grid with `--grid` | [README](patching/db-patch/README.md) |
| `patching/java-patch/java-patch.sh` | The JDK under WebLogic and ORDS: finds every JDK and who uses it, checks the support matrix, carries cacerts across, flips the references, verifies the JVMs | [README](patching/java-patch/README.md) |
| `patching/cert-renew/cert-renew.sh` | TLS certificates: every cert on the host by days left (WebLogic, NodeManager, ORDS, listener/OHS wallets, cacerts, OKV, GoldenGate), CSR, renewal of one target with rollback | [README](patching/cert-renew/README.md) |
| `patching/patch-status/patch-status.sh` | Nothing: every Oracle home on the host against the current quarter (RU/PSU level, datapatch, ORDS/APEX versions, JDKs), how many CPUs behind | [README](patching/patch-status/README.md) |

## operations/

| Script | What it does | Guide |
|---|---|---|
| `operations/account-ops/account-ops.sh` | Service accounts that take the stack down when they expire or lock (APEX_PUBLIC_USER, ORDS_PUBLIC_USER, DBSNMP, GGADMIN...): status, expiry, where each password lives, unlock, reset propagated to ORDS pools / WebLogic data sources / GoldenGate, `heal` for the ORDS 503 | [README](operations/account-ops/README.md) |
| `operations/dg-switchover/dg-switchover.sh` | Data Guard role changes through the broker: switchover, failover, reinstate, with preflight, verify, reverse switchover as rollback, `heal` for the usual ORA-168xx broker states | [README](operations/dg-switchover/README.md) |
| `operations/okv-rotate/okv-rotate.sh` | Oracle Key Vault endpoint-certificate rotation, per node, around the manual console click: `inspect`/`plan`/`preflight` before, `wait` for the switch (one `okvutil list -v 4`, then poll `okvclient.ora` for `SSL_WALLET_LOC` to move under `ssl/`; the client refreshes about hourly; exit 0 switched / 1 stop, do not go to the next node / 2 still on the old wallet, re-rotate), `verify` (cert `notAfter`, TDE `OPEN` on every instance, standby MRP) and `report` for the change record; `backup` snapshots `okvclient.ora`, `rollback` is advisory and writes nothing | [README](operations/okv-rotate/README.md) |
| `operations/rman-ops/rman-ops.sh` | Is the backup any good: RMAN configuration and history, restore validate, recovery window, ZDLRA link, a real small restore to scratch space, crosscheck and delete-obsolete | [README](operations/rman-ops/README.md) |
| `operations/db-refresh/db-refresh.sh` | Refresh a TEST database from PROD (PDB hot clone over a link or RMAN duplicate) and make it safe again: services renamed, data masked, accounts locked, links to PROD removed, APEX repointed, jobs disabled | [README](operations/db-refresh/README.md) |
| `operations/gg-ops/gg-ops.sh` | GoldenGate: every process with lag, checkpoints, stats, discards, the database side (capture/apply, apply errors, archivelogs the extract still needs vs on disk, long transactions, heartbeat), start/stop/restart, skip-transaction, resync, handlecollisions, trail cleanup, trandata, `heal` for the usual abends | [README](operations/gg-ops/README.md) |
| `operations/apex-export/apex-export.sh` | APEX applications in git: split exports of every app, workspace and instance definitions, commit only on change with who changed what, nightly cron, diff reports, restore an application from any commit or date | [README](operations/apex-export/README.md) |
| `operations/exascale-space/exascale-space.sh` | Exascale "the vault is full": storage pools (raw/used/provisionable, rebalance reserve), vaults used vs provisioned with days-to-full, what is in each vault by file type / database / path, snapshots and thin clones, files still being deleted, files no database claims, volumes, the database side (`V$EXA_VAULT`, `V$EXA_FILE`, FRA, archivelogs RMAN has backed up, restore points, PDB snapshot copies); `plan` with the exact commands, `grow` (chvault with rollback), `purge-archivelogs`, `release` (rmfile of files you reviewed) | [README](operations/exascale-space/README.md) |
| `operations/incident-pack/incident-pack.sh` | One tarball for the SR: oracle-diag report, TFA or ADR incident packages, alert/listener/WebLogic/ORDS/GoldenGate log windows, the traces the alert log names, SQL snapshots, pfile, opatch, optional AWR/ASH, thread and heap dumps, hanganalyze/systemstate, host and Exadata evidence, `MANIFEST.md`, split at 2 GB | [README](operations/incident-pack/README.md) |
| `operations/sr-draft/sr-draft.sh` | The SR text from a pack, an oracle-diag report or the error alone: product and patch level, error statistics with first/last occurrence, ADR problem keys, recent changes, attachments, severity wording, MOS search strings and Doc IDs, plus a prompt for Claude to review it | [README](operations/sr-draft/README.md) |

## reports/ (read-only)

| Script | What it reports | Guide |
|---|---|---|
| `reports/oracle-diag/oracle-diag.sh` | Full health check of the host: database, APEX, ORDS, WebLogic, Grid/RAC, Data Guard, GoldenGate, OEM, Exadata, ZDLRA, Key Vault and more, in one `REPORT.md` with FINDINGS first | [README](reports/oracle-diag/README.md), [sending it to Claude](reports/oracle-diag/ANALYSE.md) |
| `reports/db-health-daily/db-health-daily.sh` | The 60-second daily check for cron: `SUMMARY.md` plus `DELTA.md` against yesterday, exit 2 on CRIT, 1 on WARN, optional mail | [README](reports/db-health-daily/README.md) |
| `reports/perf-snapshot/perf-snapshot.sh` | "It was slow between 09:00 and 10:30": top SQL, plan changes, waits, blocking, I/O, memory, OS stats for a window; AWR/ASH/ADDM with the Diagnostics Pack | [README](reports/perf-snapshot/README.md) |
| `reports/space-forecast/space-forecast.sh` | Growth and days-to-full for tablespaces, FRA, ASM, filesystems and archivelog; keeps its own history so it needs no licensed views | [README](reports/space-forecast/README.md) |
| `reports/security-posture/security-posture.sh` | Auditor-shaped scorecard (PASS/FAIL/INFO with evidence) for database, listener, host and WebLogic, following the CIS Oracle 19c benchmark | [README](reports/security-posture/README.md) |
| `reports/okv-diag/okv-diag.sh` | Oracle Key Vault client health: every `okvclient.ora`, the endpoint certificate (age and `notAfter`), server reachability, `okvutil`, the PKCS#11 library and TDE keystore OPEN per instance | [README](reports/okv-diag/README.md) |
| `reports/obic-diag/obic-diag.sh` | FLEXCUBE OBIC / "plato" microservice platform: the plato discovery service (Eureka), Zipkin, the OBIC-managed servers and their JVMs, and the class-version (JDK) mismatch that stops an OBIC deployment loading | [README](reports/obic-diag/README.md) |

## Shared library

`lib/oracle-lib.sh` (logging, run directories, config loading, SQL*Plus/SQLcl helpers, PDB
iteration, report and FINDINGS helpers, redaction, WebLogic/ORDS/GoldenGate/Java discovery,
TLS checks, MOS download). `bash lib/oracle-lib.sh selftest` checks it on a new host.

Each script has a matching `*.conf.example`; copy it to `*.conf` next to the script only if
auto-detection needs a hint or you want to store credentials. Settings shared by several scripts
(`OFFLINE=1`, `SQL_CONNECT`, `ORDS_URL`, MOS login...) can go once in `oracle.conf` at the top of the tree (copy `oracle.conf.example`) or
`~/.oracle.conf`. Real `*.conf` files are git-ignored.

Requirements on the server: bash 4+, curl, unzip, tar. Database-side scripts need SQL*Plus or SQLcl
with SYS access; the ORDS and Java scripts need Java. Run everything as the Oracle software owner, never root.

Logs: every run writes to `~/<script>/runs/<timestamp>/`, with `runs/latest` pointing at the most
recent one. The last line of `run` is either `SUCCESS ...` or an error naming the log file.

## Getting the scripts

One line fetches everything into `$PATCH_BASE/scripts` (`/u01/patches/scripts` by default, `%USERPROFILE%\patches\scripts` on Windows), no git or GitHub account needed.

**Mac, Linux or WSL** (bash):

```bash
curl -fsSL https://raw.githubusercontent.com/AppleDannyClegg/oracle-patch-scripts/main/get.sh | bash
```

**Windows - PowerShell** (Windows Terminal's default profile):

```powershell
irm https://raw.githubusercontent.com/AppleDannyClegg/oracle-patch-scripts/main/get.ps1 | iex
```

**Windows - Command Prompt** (no PowerShell; uses the built-in `curl.exe` and `tar.exe`, Windows 10 1803+):

```cmd
curl -fsSL -o "%TEMP%\ops.zip" https://github.com/AppleDannyClegg/oracle-patch-scripts/archive/refs/heads/main.zip && tar -xf "%TEMP%\ops.zip" -C . && ren oracle-patch-scripts-main oracle-patch-scripts & del "%TEMP%\ops.zip"
```

Run the same line again whenever you want the newest version. `get.sh` and `get.ps1` keep your
`*.conf` files and leave the old copy as `<dest>.old`. The plain `cmd` line is
download-and-extract only: it carries nothing across, checks no `lib/`, and errors if
`oracle-patch-scripts` already exists, so delete it (or use `get.ps1`) before re-running. (The trailing `& del` is a single ampersand,
so the temp zip is removed even when an earlier step fails.) It also
assumes the archive unpacks to `oracle-patch-scripts-main` (GitHub names the folder `<repo>-<branch>`),
so adjust the `ren` if the repository or default branch is renamed.

For anything that reads My Oracle Support (the patch tools' `latest`/`download`, and `get-patches.ps1`), the
bearer token needs a browser login. On Windows, `patching\get-mos-token.ps1` opens the token page, takes the
token from the clipboard (or `-Paste`), writes `%USERPROFILE%\.mos-token` where the tools look, and checks it
against MOS before you run anything.

The scripts are bash, so to *run* them on Windows use Git Bash or WSL; `get.ps1` skips the library
self-test on Windows for that reason. It also prints the server-side `chmod -R +x` you need after
`scp`-ing the tree from Windows, which has no Unix executable bit.

## Servers without internet access

The database and application servers normally have no route to the internet. Nothing here needs
one at run time: the scripts read, patch, restart and verify locally. Only three things ever
reach out, and each has an offline path:

| Need | Where it comes from | What to do on an air-gapped server |
|---|---|---|
| the scripts themselves | GitHub (`get.sh`, or `get.ps1` on Windows) | run `get.sh` on your laptop, then `scp -r $PATCH_BASE/scripts oracle@server:$PATCH_BASE/scripts` |
| patch files | My Oracle Support (bearer token from the get_token page, 60 minutes) or download.oracle.com (public) | download on the laptop (get-patches.ps1 lands them in `$PATCH_BASE/<host>`), `scp -r $PATCH_BASE/<host>/* oracle@server:$PATCH_BASE/`, run the script without `latest`/`download`/`--latest`/`--patches` |
| "is there a newer release" probes | download.oracle.com | put `OFFLINE=1` in `oracle.conf` (top of the tree) so no script waits on a blocked connection; without it each script probes once for 5 s and then carries on offline |

Where to put the files:

| Script | Download on the laptop | Put it at | Then |
|---|---|---|---|
| `patching/wls-patch` | the PSU / Coherence zips `p<ID>_<release>_Generic.zip` from MOS (patch numbers from the quarter's *Critical Patch Update Availability Document*, or `patch-status.sh` on a host with MOS) | `$PATCH_BASE/wls/` (default `/u01/patches/wls`; `download` with no directory uses it) | `wls-patch.sh run $PATCH_BASE/wls` |
| `patching/db-patch` | the RU, OJVM and (if needed) the OPatch kit `p6880880_*.zip` from MOS | `$PATCH_BASE/db/` (default `/u01/patches/db`) | `db-patch.sh run $PATCH_BASE/db` |
| `patching/java-patch` | the JDK `jdk-<ver>_linux-x64_bin.tar.gz` from MOS (or java.oracle.com) | `$PATCH_BASE/jdk/` (default `/u01/patches/jdk`) | `java-patch.sh run $PATCH_BASE/jdk/<tar.gz>` |
| `patching/apex-patch` | `apex_<version>.zip` from download.oracle.com (public) | `APEX_BASE/downloads/` (default `/opt/oracle/apex-releases/downloads/`) | `apex-patch.sh run <version>` (or `run`, it picks the newest zip on disk) |
| `patching/ords-patch` | `ords-latest.zip` from download.oracle.com (public) | `ORDS_BASE/downloads/` | `ords-patch.sh run` (it uses the newest `ords*.zip` on disk) |
| `patching/patch-status` | nothing | - | works offline: the quarter comes from the CPU calendar; `--mos` and the newest ORDS/APEX versions need the internet |

`inspect`, `plan` and `preflight` of every script, the operations scripts and every report work
with no network at all. The MOS search strings and Doc IDs that `sr-draft` prints are for you to
use on a machine that can reach support.oracle.com.

## Running each script

Copy the whole tree to the server (the folders need `lib/` next to them), then run each script from
inside its folder as the Oracle software owner. Every command prints what it found or did, and
`run` asks before it changes anything unless you add `--yes`. The four most used are spelled out
below; the others follow the same `inspect`, `plan`, `preflight`, `run` pattern and their folder
README has the exact lines.

```bash
scp -r $PATCH_BASE/scripts oracle@server:/u01/patches/scripts
ssh oracle@server
chmod +x /u01/patches/scripts/*/*.sh
cd /u01/patches/scripts
```

### 1. WebLogic (`wls-patch.sh`) — on the WebLogic server

```bash
cd patching/wls-patch
cp wls-patch.conf.example wls-patch.conf     # first time; MOS token in ~/.mos-token for latest/download
./wls-patch.sh inspect                       # version, PSU level, OPatch, JDK, domain, running servers
./wls-patch.sh plan --latest                 # which PSU / Coherence patch would be applied
./wls-patch.sh download --patches latest    # into /u01/patches/wls
./wls-patch.sh preflight /u01/patches/wls   # OPatch version, release match, JDK, conflicts, disk
./wls-patch.sh run /u01/patches/wls         # backup > stop > apply > start > verify (auto-rollback on failure)
```

No internet on the server: download the zips on a laptop from support.oracle.com into the folder
and skip the `download` step. Extra bundle patches (ADF, OPSS, OWSM) go in by number: `--patches 38111111,38555555`.

### 2. APEX (`apex-patch.sh`) — on the database server, as `oracle`

```bash
cd patching/apex-patch
cp apex-patch.conf.example apex-patch.conf   # only if sqlplus / the PDB / images dir need a hint
./apex-patch.sh inspect                      # APEX version, schema, PDB, ORDS, images dir, newest release
./apex-patch.sh plan                         # from -> to, script, images dir, rollback path
./apex-patch.sh download 26.2                # public zip, no login
./apex-patch.sh preflight 26.2               # DB/APEX/ORDS minimums, tablespaces, ARCHIVELOG, previous release for rollback
./apex-patch.sh run 26.2                     # backup (restore point + images) > stop ORDS > apexins > images > start > verify
./apex-patch.sh cleanup                      # a week later: drop the restore point and the old APEX schema
```

### 3. ORDS (`ords-patch.sh`) — on the host that runs ORDS

```bash
cd patching/ords-patch
cp ords-patch.conf.example ords-patch.conf   # ORDS_HOME/ORDS_CONFIG, SYS password, WebLogic creds if deployed there
./ords-patch.sh inspect                      # standalone or in WebLogic, version, Java, pools, running?
./ords-patch.sh plan                         # what 'run' would do (downloads the zip to learn the exact version)
./ords-patch.sh preflight                    # Java pairing, config, pools, admin password, disk
./ords-patch.sh run                          # backup > stop > ords install --db-only per pool > switch > start > verify
```

### 4. Health check (`oracle-diag.sh`) — any Oracle host, read-only

```bash
cd reports/oracle-diag
./oracle-diag.sh                             # writes ~/oracle-diag/<host>_<timestamp>/REPORT.md and a .tar.gz
./oracle-diag.sh --days 7 --pdb APEXPDB      # longer look-back, include one PDB's queries
./oracle-diag.sh --skip wls --no-tar         # leave out a component, keep the folder only
```

Changes nothing (details in [reports/oracle-diag/README.md](reports/oracle-diag/README.md)). Copy `REPORT.md` (or the tarball) off the box and hand it to Claude with
"analyse this oracle-diag report". Passwords in copied config are redacted unless `--no-redact`.

### Order when patching the whole stack

`patch-status.sh` first to see what is behind. Then database (`db-patch`), WebLogic (`wls-patch`,
it restarts everything including ORDS if it is deployed there), JDK (`java-patch`), ORDS, then APEX.
ORDS must be new enough for the APEX release (`apex-patch.sh preflight` checks this), so do not do APEX before ORDS.
Run `oracle-diag.sh` before and after to have a record of what the box looked like.

### If something goes wrong

`run` rolls back on its own when apply or verify fails. To undo later by hand: `./<script> rollback`.
Logs for every run are in `~/<script>/runs/latest/`. The APEX and ORDS rollbacks never flash the
database back on their own; that needs an explicit `rollback --allow-flashback`.

## Status

The change-making scripts are tested end to end against mocks (fake OPatch, fake My Oracle Support,
fake `sqlplus`, fake `ords`, fake WebLogic deployer, local copies of the download zips) covering
upgrade, failed apply, failed verify, rollback, flashback gating, already-current, dry-run and
wrong-Java paths. Do `inspect`, `plan` and `preflight` on a test box first.

What has run against a real database (Oracle Database Free 26ai in a local container, with ORDS
standalone on https in front of it; rman-ops against the full image, which has `rman`):

- the read-only reports: db-health-daily, perf-snapshot (with `--awr`), space-forecast,
  security-posture, patch-status, oracle-diag, incident-pack and sr-draft, also against a
  deliberately broken database (full tablespace, ORA-1652, blocking session, invalid objects,
  failed job, default password, DBA role and PUBLIC grants) to see that the findings appear
- operations: account-ops inspect/expiring/unlock/reset/verify/rollback/heal (the ORDS pool user's
  password rotated into the pool and back), db-refresh pdb-clone end to end with `--keep-old`,
  a preserved schema (expdp/impdp), relock, fix-dblinks (also another user's link), fix-scheduler,
  fix-directories, rollback and cleanup; rman-ops inspect/validate/recovery-window/crosscheck/
  delete-obsolete/evidence/restore-test on a database with a real backup
- patching: ords-patch run as a real upgrade (26.2.3 to 26.3.0: schema upgrade, symlink switch,
  verify, rollback, run again, cleanup), java-patch run with restart (same build with `--force`,
  and 17 to 21 with `--force`, ORDS moved and moved back), cert-renew on the ORDS certificate
  (CA-signed cert with chain, `run`, verify, rollback) and the cacerts trust import, plus the
  refusal paths (key does not match, expired, failed restart, read-only cacerts), and cert-renew on
  a listener wallet (TCPS endpoint on 2484: wallet swap, `lsnrctl reload`, stop/start when the port
  still served the old certificate, verify, rollback, a sysdba login over TCPS after each step)

`tests/oracle-free-container.sh` repeats the six reports on any machine with docker (pulls
`gvenzl/oracle-free:23-slim`, about 700 MB, runs the scripts inside as `oracle`, copies the
reports to `tests/out/`). `--trace` records every SQL statement and answer so errors the scripts
swallow still show up; `--keep` leaves the container running for the next run. No WebLogic, APEX,
Data Guard, RAC, Exadata, ZDLRA or OKV there, and no `rman` or OPatch in the slim image, so
db-patch apply and everything WebLogic are still mock-tested only. `orapki` and `mkstore` are in
the slim image but fail for want of `$ORACLE_HOME/jlib/oraclepki.jar`; the jar from Maven Central
(`com.oracle.database.security:oraclepki`, same version as the database) makes them work.
None of the scripts takes a lock on its run directory, so two change runs started at the same
time do not stop each other.

Reviewed on 1 Nov 2026 by several independent readers (pi, DeepSeek, Qwen, Claude sonnet and three
Claude Code sessions on a shared message board), every finding checked against the source before
it was touched. Fixed from that review: every value option dies when its value is missing or is
another option (before, `--sid` as the last word made the option loop spin forever and `--sid
--dry-run` took `--dry-run` as the SID); the SQL runner put every statement, passwords inside, on
a `bash -c` process's command line; db-refresh's PROD-side rewrite was case-sensitive and silently
compared PROD with itself on an uppercase `FROM`; account-ops, dg-switchover, apex-export,
java-patch and cert-renew recorded `rollback ok` or `restore ok` before the outcome was known;
exascale-space `release` let an escli error pass its ownership guard; gg-ops read GoldenGate
errors with the wrong pattern and returned success. Findings that turned out to be wrong after
reading the code were left alone (the GoldenGate password is on stdin; `--keep-old` does rename
the PDB; `--as-new-id` is honoured). oracle-diag now reports the Oracle Key Vault endpoint
certificate state per `okvclient.ora` (rotated or not, node last talked to, wallet age or real
expiry with `OKV_WALLET_PASSWORD`), written from the first production rotation; `operations/okv-rotate` walks that rotation per node (wait for
the switch, verify, report) around the console click it cannot make.

Seven gates need no database and run anywhere with bash. Four read the scripts: `tests/check-parse.sh`
(every value option's `case` arm calls `optchk`), `tests/optchk-gate.sh` (every documented value
option run as the last argument and followed by `--dry-run`: none may hang or swallow the flag) and
`tests/secret-argv-gate.sh` (every function that hands a credential to sqlplus, SQLcl, expdp/impdp
or ggsci, run against a stub that records its argv, environment and stdin with a canary password:
the canary must be absent from argv and environ and present on the route the function claims, plus
the `--verbose` log and the run directory must not hold it, and the java APEX export must refuse) and
`tests/ru-date.sh` (patch-status's RU-date extractors, sourced out of the script and run on the lines opatch
lspatches and dba_registry_sqlpatch really produce - `id;Database Release Update : 23.6.0.24.10 (id)` - because
an unreadable date renders UNKNOWN with no finding, and the first 23ai fix matched a bare version but never a real line).
Three run the scripts against stub tools (sqlplus, rman, opatch, srvctl, dgmgrl, ggsci, escli and the
rest log their argv and stdin and answer from a canned table): `tests/dry-run-gate.sh` runs every
command of every script with `--dry-run` and fails on any DDL, DML, flashback, PL/SQL, patch, restart,
switch or GoldenGate verb that reached a tool; `tests/false-success-gate.sh` runs every change command
for real, makes the first changing call and every later one fail, and fails on exit 0 or on a state
line that claims success (`applied=`, `verified=1`, `rolled_back=1`, `<step>=ok` and the rest);
`tests/unreadable-gate.sh` runs the six read-only reports and the two collectors whole-script on a PATH
whose domain tools fail - sqlplus cannot connect, or every statement but the probe answers ORA-00942,
or `ps` exits 1 with `PROC_DIR` on an empty directory - and fails any script that read nothing and still
printed a clean verdict or exited 0 (`incident-pack` and `sr-draft` are included; a run that makes no
sqlplus call at all is NOT-EXERCISED). The first two read `tests/dry-run-env/<script>.sh` for the world a script needs (fake homes, run dirs, answers,
`ARGS_<cmd>`, `FAIL_<cmd>`, `OK_<cmd>`); the stub answers a query from the first `pattern|answer` line
that matches it, so an unanswered or empty answer must be written as an explicit `pattern|` line - deleting
a line only lets a more general one (`count\(\*\)|0`) answer instead. A command that ended before any
tool, or before any changing call, is listed as NOT-EXERCISED, which is not a pass - it says the gate could
not see that command. `tests/unreadable-gate.sh` uses its own stub world (failing domain tools, real coreutils).

`PS_FAIL=1` (or a `$T/ps.fail` the env file creates) is a switch in both `tests/dry-run-gate.sh` and
`tests/false-success-gate.sh`, but it means two different things and only one is a proof. In the dry-run
gate it makes the command refuse *before any tool call*, which the gate reports as NOT-EXERCISED - it proves
'the command stops on an unreadable process list', not 'the outcome changed'. The mutation proof for a
ps-unreadable fix belongs in the false-success gate, where the pre-fix commit records a success state
(`stopped=ok`, `applied=`, `verified=1`) and the fix does not; run it with the gate and env from HEAD against
the pre-fix script, as `tests/dry-run-env/<script>.sh`'s `CASES_<cmd>='ps_unreadable'` cases do.
What a tool cannot see (ln, mv, rm, cp outcomes) is proved by hand with the same env and a read-only
directory, and the commit says so. `lib/oracle-lib.sh selftest` covers the library's own helpers. Secrets never go on a command line:
sqlplus and SQLcl are started with `/nolog` and get `connect` on stdin, Data Pump reads `userid=`
from a 600-mode parfile under `$TMPDIR` that is removed when the tool exits, ggsci reads its
commands on stdin, `read_secret` no longer exports what it read, and `dbg`/`redact` mask
`identified by` and `connect user/password`.
