# gg-ops.sh — GoldenGate status, lag, errors and the usual fixes

The 02:00 call is "replication is behind" or "the replicat abended". This script shows every
process with its lag, checkpoints, latest stats, discards and TCP stats, the database side
(integrated capture/apply, apply errors, GGADMIN, supplemental logging, the archivelogs the
extract still needs and whether RMAN has already deleted them, long open transactions,
heartbeat lag), the last errors in the reports and `ggserr.log`, and then does the standard
fixes with the evidence shown first: start/stop/restart, skip a transaction, resync a replicat to
a trail position, handlecollisions, trail cleanup, add trandata, and `heal` for the abends it
recognises. Classic (`ggsci`) and Microservices (`adminclient`, password on stdin or prompted).
Database logins only through `dblogin useridalias`. Runs as the GoldenGate owner.

## Quick start

```bash
cd operations/gg-ops && cp gg-ops.conf.example gg-ops.conf && vi gg-ops.conf     # OGG_HOME, GG_ALIAS, GG_SID
./gg-ops.sh inspect                      # table + findings; --report writes REPORT.md (exit 2 CRIT / 1 WARN / 0), --json for monitoring
./gg-ops.sh plan                         # what heal would do, read-only
./gg-ops.sh heal                         # manager down -> start; abends -> read the report and act (asks before each step)
./gg-ops.sh restart REPA                 # or start|stop <group|all>; --force kills a stop that hangs; --mgr includes the manager in "all"
./gg-ops.sh skip-transaction REPB        # shows the failing transaction (report, discard, checkpoint) and needs the group name typed
./gg-ops.sh resync REPB --from 12 --rba 0       # alter replicat extseqno/extrba, start; or --atcsn SCN
./gg-ops.sh handlecollisions REPB on     # send replicat ... handlecollisions (runtime; off again when the load is applied)
./gg-ops.sh trail-cleanup                # trail files below every reader's checkpoint minus GG_TRAIL_KEEP; --apply removes them
./gg-ops.sh trandata APP.ORDERS          # dblogin useridalias + add trandata; --schema for add schematrandata
```

## What inspect checks (FINDINGS)

- **Processes**: manager not running (CRIT); extract/replicat ABENDED with the last real error from
  the report (CRIT); STOPPED unless in `GG_EXPECTED_STOPPED` (WARN); lag at checkpoint above
  `GG_MAX_LAG_MIN` (WARN, 3x = CRIT); no checkpoint for that long (WARN); "In recovery"; discards
  in `stats latest`; discard file grown in the last `GG_ERR_HOURS`; extract `showtrans` with
  transactions open longer than `GG_MAX_TXN_HOURS` (the recovery checkpoint cannot pass them).
- **Trails**: size, file count, filesystem % (85 WARN / 95 CRIT), every reader's position;
  `mgr.prm` without `PURGEOLDEXTRACTS` (WARN) or `AUTORESTART` (INFO).
- **ggserr.log**: ERROR/WARNING counts in the window with the top messages.
- **Database** (`--sid` or every instance): `enable_goldengate_replication`, minimal supplemental
  logging, force logging, GGADMIN locked/expiring, `dba_capture`/`dba_apply` not ENABLED,
  `dba_apply_error` rows, integrated capture lag, `streams_pool_size` under 1 GB with integrated
  extract, open transactions older than `GG_MAX_TXN_HOURS`, **archivelogs after the capture's
  `required_checkpoint_scn` that are no longer on disk** (with the RMAN restore command),
  heartbeat lag and age from `GGADMIN.gg_lag` (INFO when there is no heartbeat table), tables in
  the captured schemas without supplemental log groups.

`--report` writes `GG_OUT/<host>_gg_<ts>/REPORT.md` (FINDINGS first, then every section, raw
output in `raw/`); `--json` prints processes and findings for a monitoring hook.

## heal

For each ABENDED (or unexpectedly STOPPED) process the last errors in its report decide:

| error | action |
|---|---|
| `OGG-00446` / `OGG-02028` missing archivelog | prints `restore archivelog from logseq N until logseq M thread T;` (M = current max on disk) and, if you confirm, runs it through RMAN, then starts the extract |
| `ORA-01031` / `OGG-00665` insufficient privileges, `ORA-01017` | prints the `dbms_goldengate_auth.grant_admin_privilege` / grants and the credential-store command; not restarted |
| `OGG-01296` / `OGG-01154` / `ORA-00001` / `ORA-01403` data conflict | shows the transaction (report, discard, checkpoint) and the options: fix the row, `skip-transaction`, `handlecollisions`, `REPERROR`. Never automatic |
| `OGG-01668`/`OGG-00868`/`ORA-03113`/`ORA-03135`/`TNS-` connection lost | start again |
| `OGG-01161` / `OGG-00919` / `OGG-00212` parameter or mapping | points at the param file; not restarted |
| no error in the report | starts it unless listed in `GG_EXPECTED_STOPPED` |

Running processes with lag over `GG_MAX_LAG_MIN` get `send status` and the usual places to look
(replicat: apply throughput, target waits, BATCHSQL/PARALLELISM; extract: long transaction, redo
volume, pump TCP stats). `plan` is `heal` with `--dry-run --yes`. Exit 1 while anything is still
down.

## Safety

`skip-transaction` and `resync` need the group name typed (non-interactive: `--force`), after the
transaction/position is printed and saved in the run dir. `stop` waits 3 s and refuses to kill
unless `--force`. `start`, `restart`, `resync` and `skip-transaction` re-read `info all` two
seconds after the start and exit 1 for a group that is not RUNNING (a process that abends on its
first record was "started" before); `stop` and `restart` exit 1 for a group still running. A
`ggsci` that exits non-zero (missing libraries, wrong `ORACLE_HOME`, timeout) is a failure even
when its output has no `ERROR` line. `trail-cleanup` only deletes with `--apply`, only files below the oldest
checkpoint minus `GG_TRAIL_KEEP`, and says that `PURGEOLDEXTRACTS` is the right fix. It refuses
`--group` and refuses to run when any extract or replicat's `info detail` shows no checkpoint
line, naming the group: the oldest position must come from every reader, read successfully, or a
file a pump still needs is "unneeded". Every
ggsci/adminclient change is logged (`RUN_BASE/<ts>-<cmd>/gg-ops.log`); `--dry-run` prints them.
The MA password goes to adminclient on stdin, never on the command line.

## Options and config

`--group`, `--sid`, `--from`, `--rba`, `--atcsn`, `--schema`, `--mgr`, `--apply`, `--report`,
`--out`, `--dry-run`, `--yes`, `--force`, `--json`, `--verbose`. Config keys in
`gg-ops.conf.example` (OGG_HOME, GG_RPT_DIR/GG_PRM_DIR, GG_ALIAS, GG_DOMAIN, GG_SCHEMA, GG_SID,
GG_MA_URL/GG_MA_DEPLOYMENT/GG_MA_USER/GG_MA_PASSWORD/ADMINCLIENT, GG_MAX_LAG_MIN, GG_MAX_TXN_HOURS,
GG_TRAIL_KEEP, GG_ERR_HOURS, GG_EXPECTED_STOPPED, GG_OUT, RMAN_CMD, RUN_BASE). Needs
`lib/oracle-lib.sh` one folder up.

Tested against a fake `ggsci`/`adminclient`/`sqlplus`/`rman` (abends for each heal pattern, lag,
stuck stop, trail checkpoints, discard growth, MA login via stdin); not yet on a real GoldenGate.
