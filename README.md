# Oracle operations scripts: WebLogic, APEX, ORDS, Database

Stand-alone bash scripts for running and patching an Oracle estate (WebLogic, APEX, ORDS, Database,
Data Guard, RMAN) without being an expert in each product. One folder per script, with its
`*.conf.example` and its own README. Everything except `wls-patch`, `apex-patch`, `ords-patch` and
`oracle-diag` shares `lib/oracle-lib.sh`, so copy the whole tree (or `get.sh` does it) rather than a
single file.

Every script that changes something has the same shape:

| Step | Command | Changes anything? |
|---|---|---|
| look | `inspect` | no |
| what would happen | `plan` | no |
| would it work | `preflight` | no (downloads/unzips only) |
| do it | `run` | yes: backup, stop, apply, start, verify, **automatic rollback on failure** |

Report scripts have no commands: run them, read `REPORT.md`, or hand it to Claude.

## Patching

| Script | What it patches | Guide |
|---|---|---|
| `wls-patch/wls-patch.sh` | WebLogic Server 12.2.1.x / 14.1.x: quarterly PSU + Coherence via OPatch, downloads from My Oracle Support | [README](wls-patch/README.md) |
| `apex-patch/apex-patch.sh` | APEX in the database: full release upgrades from Oracle's public download site, `apxdwngrd.sql` rollback | [README](apex-patch/README.md) |
| `ords-patch/ords-patch.sh` | ORDS, standalone or deployed inside WebLogic: schema upgrade per pool, symlink or war switch | [README](ords-patch/README.md) |
| `db-patch/db-patch.sh` | Oracle Database Release Updates: OPatch + datapatch, standby-first on Data Guard, out-of-place option, Grid with `--grid` | [README](db-patch/README.md) |
| `java-patch/java-patch.sh` | The JDK under WebLogic and ORDS: finds every JDK and who uses it, checks the support matrix, carries cacerts across, flips the references, verifies the JVMs | [README](java-patch/README.md) |
| `cert-renew/cert-renew.sh` | TLS certificates: every cert on the host by days left (WebLogic, NodeManager, ORDS, listener/OHS wallets, cacerts, OKV, GoldenGate), CSR, renewal of one target with rollback | [README](cert-renew/README.md) |
| `patch-status/patch-status.sh` | Nothing: every Oracle home on the host against the current quarter (RU/PSU level, datapatch, ORDS/APEX versions, JDKs), how many CPUs behind | [README](patch-status/README.md) |

## Operations

| Script | What it does | Guide |
|---|---|---|
| `account-ops/account-ops.sh` | Service accounts that take the stack down when they expire or lock (APEX_PUBLIC_USER, ORDS_PUBLIC_USER, DBSNMP, GGADMIN...): status, expiry, where each password lives, unlock, reset propagated to ORDS pools / WebLogic data sources / GoldenGate, `heal` for the ORDS 503 | [README](account-ops/README.md) |
| `dg-switchover/dg-switchover.sh` | Data Guard role changes through the broker: switchover, failover, reinstate, with preflight, verify, reverse switchover as rollback, `heal` for the usual ORA-168xx broker states | [README](dg-switchover/README.md) |
| `rman-ops/rman-ops.sh` | Is the backup any good: RMAN configuration and history, restore validate, recovery window, ZDLRA link, a real small restore to scratch space, crosscheck and delete-obsolete | [README](rman-ops/README.md) |
| `db-refresh/db-refresh.sh` | Refresh a TEST database from PROD (PDB hot clone over a link or RMAN duplicate) and make it safe again: services renamed, data masked, accounts locked, links to PROD removed, APEX repointed, jobs disabled | [README](db-refresh/README.md) |

## Reports (read-only)

| Script | What it reports | Guide |
|---|---|---|
| `oracle-diag/oracle-diag.sh` | Full health check of the host: database, APEX, ORDS, WebLogic, Grid/RAC, Data Guard, GoldenGate, OEM, Exadata, ZDLRA, Key Vault and more, in one `REPORT.md` with FINDINGS first | [README](oracle-diag/README.md), [sending it to Claude](oracle-diag/ANALYSE.md) |
| `db-health-daily/db-health-daily.sh` | The 60-second daily check for cron: `SUMMARY.md` plus `DELTA.md` against yesterday, exit 2 on CRIT, 1 on WARN, optional mail | [README](db-health-daily/README.md) |
| `perf-snapshot/perf-snapshot.sh` | "It was slow between 09:00 and 10:30": top SQL, plan changes, waits, blocking, I/O, memory, OS stats for a window; AWR/ASH/ADDM with the Diagnostics Pack | [README](perf-snapshot/README.md) |
| `space-forecast/space-forecast.sh` | Growth and days-to-full for tablespaces, FRA, ASM, filesystems and archivelog; keeps its own history so it needs no licensed views | [README](space-forecast/README.md) |
| `security-posture/security-posture.sh` | Auditor-shaped scorecard (PASS/FAIL/INFO with evidence) for database, listener, host and WebLogic, following the CIS Oracle 19c benchmark | [README](security-posture/README.md) |

Each script has a matching `*.conf.example`; copy it to `*.conf` next to the script only if
auto-detection needs a hint or you want to store credentials. Settings shared by several scripts
(`SQL_CONNECT`, `ORDS_URL`, MOS login...) can go once in `oracle.conf` at the top of the tree or
`~/.oracle.conf`. Real `*.conf` files are git-ignored.

Requirements on the server: bash 4+, curl, unzip, tar. Database-side scripts need SQL*Plus or SQLcl
with SYS access; the ORDS and Java scripts need Java. Run everything as the Oracle software owner, never root.

Logs: every run writes to `~/<script>/runs/<timestamp>/`, with `runs/latest` pointing at the most
recent one. The last line of `run` is either `SUCCESS ...` or an error naming the log file.

## Getting the scripts

On your own machine (Mac, Linux or WSL), one line fetches everything into `./oracle-patch-scripts`,
no git or GitHub account needed:

```bash
curl -fsSL https://raw.githubusercontent.com/AppleDannyClegg/oracle-patch-scripts/main/get.sh | bash
```

Run the same line again whenever you want the newest version; it keeps your `*.conf` files and
leaves the old copy as `oracle-patch-scripts.old`.

## Running each script

Copy the whole tree to the server (the folders need `lib/` next to them), then run each script from
inside its folder as the Oracle software owner. Every command prints what it found or did, and
`run` asks before it changes anything unless you add `--yes`. The four most used are spelled out
below; the others follow the same `inspect`, `plan`, `preflight`, `run` pattern and their folder
README has the exact lines.

```bash
scp -r oracle-patch-scripts oracle@server:~/
ssh oracle@server
chmod +x ~/oracle-patch-scripts/*/*.sh
cd ~/oracle-patch-scripts
```

### 1. WebLogic (`wls-patch.sh`) — on the WebLogic server

```bash
cd wls-patch
cp wls-patch.conf.example wls-patch.conf     # first time: My Oracle Support login (or put it in ~/.netrc)
./wls-patch.sh inspect                       # version, PSU level, OPatch, JDK, domain, running servers
./wls-patch.sh plan --latest                 # which PSU / Coherence patch would be applied
./wls-patch.sh download /u01/patches/latest --patches latest
./wls-patch.sh preflight /u01/patches/latest # OPatch version, release match, JDK, conflicts, disk
./wls-patch.sh run /u01/patches/latest       # backup > stop > apply > start > verify (auto-rollback on failure)
```

No internet on the server: download the zips on a laptop from support.oracle.com into the folder
and skip the `download` step. Extra bundle patches (ADF, OPSS, OWSM) go in by number: `--patches 38111111,38555555`.

### 2. APEX (`apex-patch.sh`) — on the database server, as `oracle`

```bash
cd apex-patch
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
cd ords-patch
cp ords-patch.conf.example ords-patch.conf   # ORDS_HOME/ORDS_CONFIG, SYS password, WebLogic creds if deployed there
./ords-patch.sh inspect                      # standalone or in WebLogic, version, Java, pools, running?
./ords-patch.sh plan                         # what 'run' would do (downloads the zip to learn the exact version)
./ords-patch.sh preflight                    # Java pairing, config, pools, admin password, disk
./ords-patch.sh run                          # backup > stop > ords install --db-only per pool > switch > start > verify
```

### 4. Health check (`oracle-diag.sh`) — any Oracle host, read-only

```bash
cd oracle-diag
./oracle-diag.sh                             # writes ~/oracle-diag/<host>_<timestamp>/REPORT.md and a .tar.gz
./oracle-diag.sh --days 7 --pdb APEXPDB      # longer look-back, include one PDB's queries
./oracle-diag.sh --skip wls --no-tar         # leave out a component, keep the folder only
```

Changes nothing (details in [oracle-diag/README.md](oracle-diag/README.md)). Copy `REPORT.md` (or the tarball) off the box and hand it to Claude with
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

Tested end to end against mocks (fake OPatch, fake My Oracle Support, fake `sqlplus`, fake `ords`,
fake WebLogic deployer, local copies of the download zips) covering upgrade, failed apply, failed
verify, rollback, flashback gating, already-current, dry-run and wrong-Java paths. Not yet run
against real systems. Do `inspect`, `plan` and `preflight` on a test box first.
