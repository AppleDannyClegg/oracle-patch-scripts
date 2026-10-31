# rman-ops.sh — is the backup any good?

Answers the question an auditor, a worried manager or a DBA on call actually asks: *from what
exists right now, what can we restore, back to when, and has anyone tried?* Read-only reports
(`REPORT.md`, FINDINGS first, raw RMAN output in `raw/`) plus three explicit commands that change
something and ask first. Runs on the database server as `oracle`.

## Quick start

```bash
cd rman-ops
cp rman-ops.conf.example rman-ops.conf   # catalog / ZDLRA connections, the window you promise, scratch dir
./rman-ops.sh inspect                    # configuration, last backups, history, obsolete / need backup, failures, corruption
./rman-ops.sh recovery-window            # earliest and latest restorable point, archivelog coverage per day, gaps
./rman-ops.sh validate                   # restore ... validate for controlfile, spfile, database, last day of archivelogs
./rman-ops.sh validate --until "2026-10-25 09:00"   # is that point in time restorable? (restore preview)
./rman-ops.sh zdlra                      # libra.so, wallet, port to the appliance, ra_database / incidents / restore ranges
./rman-ops.sh run                        # all of the above in one report (the evidence pack)
./rman-ops.sh restore-test --scratch /u01/restore_test   # really restore the smallest datafile + controlfile copy, verify, delete
```

Every database instance running on the host is covered; `--sid` picks one. The report path is the
last line; the exit code is 2 with critical findings, 1 with warnings, 0 otherwise (cron friendly).

## What each report contains

- **inspect**: `show all` and `v$rman_configuration`; retention, autobackup, device, deletion
  policy, optimisation; catalog in use; block change tracking; FRA; last COMPLETED job per input
  type with hours ago; job history for `--days` (default 30) with sizes and ratios; failed
  operations (`v$rman_status`) and RMAN/ORA lines still in `v$rman_output`; `list backup summary`,
  controlfile/spfile backups; backup sets per day/type/device; incremental efficiency (blocks read
  vs blocks in file, which shows whether BCT works); `report obsolete`; `report need backup`;
  `list failure`; corruption views; days since each datafile's last backup.
- **recovery-window**: earliest restorable point in time (the newest "oldest level 0" across all
  datafiles, moved forward past any archivelog gap), latest point with archived redo, the window
  you promise (`RECOVERY_WINDOW_DAYS`), archivelog coverage per day (logs, backed up, on disk
  only, **lost**), oldest/newest level 0 per datafile, incarnations, restore points. Controlfile
  view: anything older than `control_file_record_keep_time` only shows with a catalog.
- **validate**: `restore database preview summary` (and `until time` with `--until`), then
  `restore controlfile|spfile|database validate` and `restore archivelog from time 'sysdate-1'
  validate`: RMAN opens every backup piece a restore would need and checks it, writing nothing.
  `--full` adds `backup validate check logical database`, which reads every block of every
  datafile (long).
- **zdlra**: the SBT channel from `show all`: `libra.so` present, `RA_WALLET` has a
  `cwallet.sso`, `credential_alias` host:port reachable, `mkstore -listCredential`, `tnsping`;
  SBT jobs in 7 days; with `RA_CATALOG_CONNECT` the appliance's own view: `ra_database` (policy,
  recovery window goal, **unprotected window**), `ra_disk_restore_range`, ACTIVE
  `ra_incident_log` rows, `ra_task`, `ra_server`.

FINDINGS rules: NOARCHIVELOG, retention NONE or REDUNDANCY 1, autobackup OFF, incrementals
without BCT, FRA >85 %, no database backup in `RMAN_MAX_FULL_DAYS`, no archivelog backup in
`RMAN_MAX_ARCH_HOURS`, >24 archived logs never backed up, controlfile not backed up for 48 h,
failed jobs in 7 days, `report need backup` non-empty, Data Recovery Advisor CRITICAL/HIGH,
corrupt blocks, datafiles never backed up, no level 0 covering every datafile, archivelog gap,
restorable window shorter than promised, preview cannot find a backup (`RMAN-06026` etc.), a
validate failing or reporting corruption, `libra.so`/wallet missing, appliance port closed,
unprotected window over the archivelog limit, ACTIVE appliance incidents.

## Commands that change something

- **restore-test** (`--yes` to skip the question): picks the smallest datafile outside
  SYSTEM/SYSAUX/UNDO (or `--datafile N` / `--tablespace X`), checks space in `--scratch`
  (`RESTORE_SCRATCH_DIR`), then `run { set newname for datafile N to '<scratch>/rt_...dbf';
  restore datafile N; }` and `restore controlfile to '<scratch>/rt_...ctl'`. **No switch is ever
  issued**, so the running database keeps its own files; the script double-checks that
  `v$datafile` still does not mention the scratch path and refuses to delete anything if it
  does. The restored file is checked with `dbverify`, throughput is logged, and both files are
  deleted unless `--keep`. The last line is `SUCCESS ... in Ns` or an error naming the log.
- **crosscheck**: `crosscheck backup; crosscheck archivelog all;` then lists what is EXPIRED and
  offers `delete noprompt expired ...` (records only). Asks before both steps.
- **delete-obsolete**: refuses with retention NONE; shows `report obsolete`, asks, then `delete
  noprompt obsolete` and the FRA usage afterwards.

## Options and config

`--sid`, `--days N`, `--until "YYYY-MM-DD HH:MI"`, `--full`, `--datafile N`, `--tablespace X`,
`--scratch DIR`, `--keep`, `--window N`, `--out DIR`, `--lines N`, `--no-tar`, `--quiet`,
`--dry-run`, `--yes`, `--verbose`. Config in `rman-ops.conf` (see the example) or the shared
`oracle.conf`: `RMAN_CATALOG_CONNECT` is added as `connect catalog` on RMAN's stdin, never on a
command line; `RA_CATALOG_CONNECT` is the VPC user for the `ra_*` views. Needs `lib/oracle-lib.sh`
one folder up. Reports under `~/rman-ops/<host>_<command>_<ts>/`, change-making runs under
`~/rman-ops/runs/`.

Tested against a fake `rman`/`sqlplus`/`dbv` (evidence report, failing preview, restore-test,
crosscheck, delete-obsolete, dry-run); not yet on a real database. Run `inspect` and
`recovery-window` first; they only read.
