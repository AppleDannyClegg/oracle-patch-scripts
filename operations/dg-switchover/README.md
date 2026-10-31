# dg-switchover.sh — Data Guard role changes through the broker, checked before and after

Switchover, failover and reinstate via DGMGRL, wrapped in the same `inspect > plan > preflight >
run` shape as the other scripts: it refuses to start when the standby is behind or the broker is
unhappy, keeps a copy of the configuration, and after the switch waits until the old primary is a
synchronised standby again. Rollback is a switchover back. Runs on any database server of the
configuration as `oracle`, never root.

## Quick start

```bash
cd operations/dg-switchover
cp dg-switchover.conf.example dg-switchover.conf   # target, DGMGRL connection, app TNS aliases, expected services
./dg-switchover.sh inspect                          # configuration, roles, lags, FSFO, SRLs, services, static listener entries, client TNS
./dg-switchover.sh plan                             # what run would do
./dg-switchover.sh preflight                        # the broker's validate database plus the checks below
./dg-switchover.sh run                              # backup > switchover > verify
./dg-switchover.sh rollback                         # switch back to the previous primary (same checks)
```

The target standby comes from `--target`, `DG_TARGET`, or is the only physical standby. Pass
`--tns APP,APP_RO` (or `APP_TNS=`) so the client aliases are checked and tested.

## What `run` does

1. **preflight**: `dg_broker_start`, configuration status, every member's status, the target
   `APPLY-ON` with **transport lag 0 and apply lag under `DG_MAX_LAG_SEC`**, `validate database
   <target>` says *Ready for Switchover: Yes*, no *Insufficient SRLs*, temp file counts equal,
   flashback on both sides (warning only), no archive gap, Error/Fatal rows in
   `v$dataguard_status` in the last hour, no RMAN backup or datapatch running, no hot backup,
   `switchover_status` TO STANDBY/SESSIONS ACTIVE, long-open transactions and running scheduler
   jobs, FSFO target matches, static `<db_unique_name>_DGMGRL` entry in `listener.ora`, each
   member's `StaticConnectIdentifier` reachable, each client TNS alias resolves to both sites and
   to a service in `PRIMARY_SERVICES`.
2. **backup**: `show configuration verbose`, `show database verbose` for every member, FSFO
   settings, pfile from spfile, controlfile trace, the Data Guard parameters, `dba_services`,
   `tnsnames.ora`/`sqlnet.ora`/`listener.ora` copies and the broker config file, all in the run
   dir. `--restore-point` adds a guaranteed restore point `DGSWITCH_<ts>` on the primary.
3. **switchover**: `dgmgrl` connects as `DG_CONNECT` (default `sys@<target>`, password prompted
   once and passed on stdin, never on a command line; `/` when the target is local) and runs
   `switchover to <target>`. If the broker reports that it could not restart a database, the
   local one is started mounted and you are told about remote ones; then the script waits until
   `show configuration` shows the new primary, opens the PDBs, runs `srvctl start service` and
   starts any `PRIMARY_SERVICES` still missing on the new primary when it is on this host.
4. **verify**: new primary as intended, configuration `SUCCESS`, the old primary a physical
   standby with `APPLY-ON` and both lags back to 0 (waits up to `DG_VERIFY_WAIT`), MRP running on
   a local standby, `PRIMARY_SERVICES` up on the primary and not on the standby, each client TNS
   alias resolves and, with `APP_TEST_CONNECT`, a real login answers with the new primary's
   `db_unique_name`.

If verify fails, `run` offers the switchover back. Nothing is undone silently: a half-finished
switchover is left for `heal`/`inspect` and the log names the broker's own output.

## Failover and reinstate

```bash
./dg-switchover.sh failover PRODB              # on the standby host; type PRODB back to confirm
./dg-switchover.sh failover PRODB --immediate  # do not apply the remaining redo first (more data loss, faster)
./dg-switchover.sh reinstate PRODA             # once the old primary's host is back; it is mounted first
```

`failover` refuses while `validate database` reports the primary as still running (that is a
switchover, no data loss), needs the target's name typed even with `--yes` (`--force` for
non-interactive use), prints the expected data loss (transport lag) and warns when flashback is off
on the old primary, because then it cannot be reinstated, only rebuilt. Afterwards it prints the
reinstate steps. `rollback` after a failover refuses and points at `reinstate`.

## heal

Reads `show configuration` and every `show database`, lists the ORA- codes per member, and for
the common ones gives the cause and offers the fix (each one confirmed):

- `ORA-16853/16855` apply lag: apply state off → `edit database ... set state='APPLY-ON'`; no
  MRP → toggle apply; otherwise apply rate and what to look at.
- `ORA-16857/16854`, `ORA-16764/16778` transport lag or transport down: `LogXptStatus`,
  `v$archive_dest` errors, `TRANSPORT-ON`, the usual listener/password file/SRL causes.
- `ORA-16820` no observer; `ORA-16826/16766` apply stopped; `ORA-16661/16795/16816` reinstate
  needed; `ORA-16783/16724/16811/16817` gap or FSFO unsynchronised (shows `v$archive_gap`, roll-forward
  recipe); `ORA-16625/16662/16501/16525/16532` broker unreachable (`dg_broker_start`);
  `ORA-16629/16627/16653` protection mode; `ORA-16789/16714/16715/16792` inconsistent properties;
  members `DISABLED` → `enable database`.

## Options and config

`--sid`, `--target DBUN`, `--tns A,B`, `--connect sys@TNS|/@TNS|/`, `--restore-point`,
`--immediate`, `--wait SECS`, `--dry-run`, `--yes`, `--force`, `--json` (inspect), `--verbose`,
`--run-dir DIR`. Config in `dg-switchover.conf` (see the example) or the shared `oracle.conf`.
Needs `lib/oracle-lib.sh` one folder up. Logs, the configuration dump and state under
`~/dg-switchover/runs/<ts>/`, `runs/latest` points at the last one. `cleanup` drops this run's
restore point.

Tested against a fake `dgmgrl`/`sqlplus`/`tnsping` (switchover, rollback, failover with and
without the typed confirmation, reinstate, heal, dry-run); not yet on a real configuration. Do
`inspect`, `plan` and `preflight` on a test pair first and read the broker output in the log.
