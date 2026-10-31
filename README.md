# Oracle patching scripts: WebLogic, APEX, ORDS

Three stand-alone bash scripts (plus a read-only health check) for keeping an Oracle middleware stack patched without being an
expert in each product. Same shape everywhere:

| Step | Command | Changes anything? |
|---|---|---|
| look | `inspect` | no |
| what would happen | `plan` | no |
| would it work | `preflight` | no (downloads/unzips only) |
| do it | `run` | yes: backup, stop, apply, start, verify, **automatic rollback on failure** |

| Script | What it patches | Guide |
|---|---|---|
| `wls-patch.sh` | Oracle WebLogic Server 12.2.1.x / 14.1.x (quarterly PSU + Coherence via OPatch, downloads from My Oracle Support) | [wls-patch/README.md](wls-patch/README.md) |
| `apex-patch.sh` | Oracle APEX in the database (full release upgrades from Oracle's public download site) | [apex-patch/README.md](apex-patch/README.md) |
| `ords-patch.sh` | Oracle REST Data Services, standalone or deployed inside WebLogic | [ords-patch/README.md](ords-patch/README.md) |
| `oracle-diag.sh` | Nothing: read-only health check of the whole host (database, APEX, ORDS, WebLogic, Grid/RAC, Data Guard, GoldenGate, OEM, Exadata, ZDLRA, Key Vault and more) written to one report for Claude to analyse | [oracle-diag/README.md](oracle-diag/README.md), [sending it to Claude](oracle-diag/ANALYSE.md) |

Each script has a matching `*.conf.example`; copy it to `*.conf` next to the script only if
auto-detection needs a hint or you want to store credentials. Real `*.conf` files are git-ignored.

Requirements on the server: bash 4+, curl, unzip, tar. The APEX script needs SQL*Plus or SQLcl
with SYS access; the ORDS script needs Java. Run everything as the Oracle software owner, never root.

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

Each script lives in its own folder with its `*.conf.example` and guide: copy the folder to the
server, make the script executable, run it from inside that folder as the Oracle software owner. Every command prints what it found or did, and
`run` asks before it changes anything unless you add `--yes`.

```bash
scp -r wls-patch apex-patch ords-patch oracle-diag oracle@server:~/
ssh oracle@server
chmod +x ~/*/*.sh
```

### 1. WebLogic (`wls-patch.sh`) — on the WebLogic server

```bash
cd ~/wls-patch
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
cd ~/apex-patch
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
cd ~/ords-patch
cp ords-patch.conf.example ords-patch.conf   # ORDS_HOME/ORDS_CONFIG, SYS password, WebLogic creds if deployed there
./ords-patch.sh inspect                      # standalone or in WebLogic, version, Java, pools, running?
./ords-patch.sh plan                         # what 'run' would do (downloads the zip to learn the exact version)
./ords-patch.sh preflight                    # Java pairing, config, pools, admin password, disk
./ords-patch.sh run                          # backup > stop > ords install --db-only per pool > switch > start > verify
```

### 4. Health check (`oracle-diag.sh`) — any Oracle host, read-only

```bash
cd ~/oracle-diag
./oracle-diag.sh                             # writes ~/oracle-diag/<host>_<timestamp>/REPORT.md and a .tar.gz
./oracle-diag.sh --days 7 --pdb APEXPDB      # longer look-back, include one PDB's queries
./oracle-diag.sh --skip wls --no-tar         # leave out a component, keep the folder only
```

Changes nothing (details in [oracle-diag/README.md](oracle-diag/README.md)). Copy `REPORT.md` (or the tarball) off the box and hand it to Claude with
"analyse this oracle-diag report". Passwords in copied config are redacted unless `--no-redact`.

### Order when patching the whole stack

WebLogic first (it restarts everything, including ORDS if it is deployed there), then ORDS, then APEX.
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
