# db-health-daily.sh — the one-minute daily check, built for cron

Read-only. Runs on the database server as `oracle`, looks at every running database (and the
listener, ORDS, WebLogic, Grid Infrastructure and GoldenGate if they are there), and leaves three
files per run under `~/db-health-daily/<timestamp>/`:

| File | What it is |
|---|---|
| `SUMMARY.md` | one screen: a status line per database, then the CRIT/WARN findings |
| `DELTA.md` | what changed since the previous run: new findings, cleared findings, still open, and only the **new** alert-log error lines (it keeps a byte offset per alert log and per WebLogic server log) |
| `REPORT.md` + `raw/` | the evidence, in the same shape as `oracle-diag` |

Exit code: 2 if anything is CRIT, 1 if WARN, 0 when clean, so cron/monitoring can act on it.

## Quick start

```bash
cd reports/db-health-daily
./db-health-daily.sh                      # prints SUMMARY.md, writes the files
./db-health-daily.sh --install-cron 07:00 # prints the crontab line; paste it into `crontab -e`
```

The crontab line it prints:

```
00 07 * * * /path/to/db-health-daily/db-health-daily.sh --cron --mail dba@example.com >/dev/null 2>&1
```

`--mail` sends `SUMMARY.md` with `mailx` only when there is something CRIT or WARN
(`--always-mail` for every day). Needs `lib/oracle-lib.sh` one level up (copy the repo, or the two
folders `db-health-daily/` and `lib/`).

## Options

| Option | Meaning |
|---|---|
| `--out DIR` | where runs go (default `~/db-health-daily`) |
| `--sid SID` | one database only |
| `--pdb NAME` | make sure this PDB is checked (open PDBs are found anyway) |
| `--mail ADDR`, `--always-mail` | email the summary |
| `--cron` | no terminal output, just files and the exit code |
| `--install-cron HH:MM` | print the crontab line |
| `--quiet`, `--no-tar` | |

Thresholds live in `db-health-daily.conf` (or the shared `oracle.conf`): `FS_WARN=85 FS_CRIT=95
TS_WARN=85 TS_CRIT=95 FRA_WARN=85 FRA_CRIT=95 BACKUP_WARN_DAYS=2 BACKUP_CRIT_DAYS=7
DG_LAG_WARN_MIN=30 PROC_WARN=80 MAIL_TO=...`.

## What it checks

- **Host**: RAM available, swap, load vs CPUs, filesystems and inodes, failed systemd units, OOM
  kills / I/O errors in the last day (needs `sudo -n journalctl`), and a **process inventory
  delta**: anything that was running last time (pmon, listener, WebLogic servers, ORDS, Node
  Manager, CRS daemons, GoldenGate manager, EM agent, TFA) and is gone now is CRIT.
- **Exascale** (when `escli` is on the host): every vault's used vs provisioned space per media type against `FS_WARN`/`FS_CRIT`, every storage pool's free % against `EXA_POOL_FREE_PCT` (12); plus `V$EXA_VAULT` from inside each database. The full picture and the fixes are in `operations/exascale-space`.
- **Listener**: responding, services registered.
- **Each database**: connect as sysdba, instance/open mode/role, sessions and processes vs limits,
  FRA, last DB and archivelog backup, failed RMAN jobs, blocked sessions, invalid objects (and the
  delta against last run), failed scheduler runs, outstanding alerts, Data Guard lags, archive
  destination errors, guaranteed restore points, PDBs not open, tablespaces at or over the
  thresholds (container and each PDB), ASM diskgroups, TDE keystore, APEX/ORDS public accounts
  locked or expired, passwords expiring within a week, hot-backup mode, APEX jobs broken.
- **Alert log**: only the lines written since the previous run, counted by message, with the usual
  patterns graded (ORA-257, 4031/4030, 20, 1653/1654, 600/7445, 1555, 60, checkpoint not
  complete, wallet errors, instance termination).
- **Middleware**: ORDS process + HTTP code, WebLogic servers running, Node Manager, admin
  ready-check, new `<Error>`/OOM/STUCK lines per server log since last run; Grid resources with
  TARGET=ONLINE that are not; GoldenGate manager and ABENDED/STOPPED groups.

## Handing it to Claude

Paste `DELTA.md` (small) with "here is today's db-health-daily delta, what needs doing?", or
attach `REPORT.md` for the detail. See [../oracle-diag/ANALYSE.md](../oracle-diag/ANALYSE.md).
