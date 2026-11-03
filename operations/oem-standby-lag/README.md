# oem-standby-lag.sh — an OEM 13c metric extension for Data Guard standby lag

> **Status:** the wrapper and its gate are verified against **stubs only**. The SQL has been run on Oracle
> Database Free (a PRIMARY), but the standby path, the real `emcli` flag names on your EM release, and the
> metric in the console have **not** been exercised on this estate. Treat this as a reviewed starting point
> and prove it per (f) before you trust a green `verify`.

Enterprise Manager's built-in **Data Guard Performance** metric already reports Apply Lag and Transport Lag
on a standby. This metric extension exists for the cases that built-in metric does not make obvious:

- **A frozen `0`.** When the primary is unreachable, `v$dataguard_stats` can keep reporting a lag of `0`
  while nothing is arriving. The extension adds `primary_contact_age_sec` — `sysdate - datum_time` of the
  transport-lag row — so a lag that reads healthy next to a primary that has not been contacted for a while
  is **not** OK.
- **Apply not running.** `mrp_processes` counts `MRP%` in `gv$dataguard_process`; a standby that is
  mounted with no apply process reports `UNKNOWN`, not a lag of `0`.
- **A row that answers no question.** Any lag `NULL` or `mrp_processes = 0` collapses to
  `lag_status = UNKNOWN`, so a snapshot standby or a planned `APPLY-OFF` is visible in the console rather
  than silently green.
- **Switchover safety.** On a PRIMARY every lag/mrp column is `NULL` and `lag_status = PRIMARY`, so the
  same extension can be deployed to **both** sides of the configuration and survives a switchover.

The metric extension is built **once in the UI** (b), then this script carries it the rest of the way:
`import` → `publish` → `deploy` → `verify`, and `rollback` to undo it.

## The SQL it deploys

[`standby-lag.sql`](standby-lag.sql) is the metric extension's SQL adapter query: **one statement**, no
trailing semicolon, no comments, **one row**, seven columns in this order.

| Column | Meaning |
|---|---|
| `database_role` | `v$database.database_role` (`PRIMARY`, `PHYSICAL STANDBY`, …) |
| `open_mode` | `v$database.open_mode` |
| `transport_lag_sec` | (standby only) transport lag, seconds, from `v$dataguard_stats` |
| `apply_lag_sec` | (standby only) apply lag, seconds, from `v$dataguard_stats` |
| `primary_contact_age_sec` | (standby only) `round((sysdate - to_date(datum_time, 'MM/DD/YYYY HH24:MI:SS')) * 86400)` of the transport-lag row |
| `mrp_processes` | (standby only) count of `MRP%` in `gv$dataguard_process` |
| `lag_status` | `PRIMARY` on a primary; `UNKNOWN` if a lag is `NULL` or `mrp_processes = 0`; else `OK` |

The lag values are `to_dsinterval` from `v$dataguard_stats`, converted to whole seconds. `gv$` (not `v$`) is
used for the process count so a RAC standby counts the apply instance.

**Two things about `v$dataguard_stats` that the SQL has to work around** (found while proving the query on
Oracle Database Free, so they are not theoretical):

- `datum_time` is a **`VARCHAR2`**, not a `DATE`. `sysdate - datum_time` raises `ORA-00932`; the query
  converts it with `to_date(datum_time, 'MM/DD/YYYY HH24:MI:SS')`. That mask is not a guess: Oracle's own
  `$ORACLE_HOME/rdbms/admin/recover.bsq` computes the same quantity for the same view with
  `TO_DATE(MAX(datum_time), 'MM/DD/YYYY HH24:MI:SS')`. If a standby returns a different string shape, this
  is the line to change — confirm it with `select name, value, datum_time from v$dataguard_stats` on a real
  standby (the row itself is unverified here; see (f)).
- The apply-process column is **`NAME`**, not `PROCESS` (`v$dataguard_process` / `gv$dataguard_process` have
  `NAME`, `ROLE`, `TYPE`; selecting `PROCESS` is `ORA-00904`). `MRP0` lands in `NAME` on a standby.

Prove it on a database before deploying: **`oem-standby-lag.sh sql-test`** runs exactly this query through
`sqlplus` and applies the thresholds locally (see below).

## Quick start

```bash
cd operations/oem-standby-lag
cp oem-standby-lag.conf.example oem-standby-lag.conf && chmod 600 oem-standby-lag.conf  # ME_ARCHIVE, OMR_CONNECT, thresholds

./oem-standby-lag.sh sql-test  --sid STBYA     # the metric's own SQL + thresholds on one standby
./oem-standby-lag.sh preflight --targets STBYA,STBYB   # logged in? flags exist? targets exist? names safe?
./oem-standby-lag.sh import    --yes           # emcli import_metric_extension -file_name=<ME_ARCHIVE>
./oem-standby-lag.sh publish   --yes           # save_metric_extension_draft + publish_metric_extension
./oem-standby-lag.sh deploy    --targets STBYA,STBYB --yes   # deploy, then record the targets for rollback
./oem-standby-lag.sh verify    --targets STBYA,STBYB         # the repository says each target is collecting
# ... later, to remove it ...
./oem-standby-lag.sh rollback  --yes           # undeploy exactly the targets the deploy recorded
```

`run` = `preflight` → `import` → `publish` → `deploy` → `verify`. It does **not** include `sql-test`; run that per
standby host first (it is the only step that needs `--sid` on the database).

The **operator logs in to `emcli` first**; the script never runs `emcli login`, so no password ever reaches
an argv or the environment.

## (a) Check the built-in metric first

Before building anything, look at the **Data Guard Performance** metric for the standby target
(Enterprise → Monitoring → Metric Extensions is where you build; the built-in metric is in the target's
Metrics page). If Data Guard Broker manages the configuration, `Apply Lag`/`Transport Lag` thresholds on
the built-in metric may already be enough, and you do not need this extension.

This extension is for the cases the built-in metric does not distinguish: a **frozen `0`** with the primary
gone (`primary_contact_age_sec`), **apply not running** (`mrp_processes`), and a lag the database has not
computed (`UNKNOWN`). If those are the failures you keep having to diagnose by hand, build it; if not, stop
here.

## (b) Build the metric extension once in the UI

Enterprise → Monitoring → **Metric Extensions** → **Create**:

1. **Target type:** `Database Instance`. **Adapter:** SQL.
2. Paste [`standby-lag.sql`](standby-lag.sql). **No key column.** Seven columns, in the order above, with
   types: `database_role` String, `open_mode` String, `transport_lag_sec` Number, `apply_lag_sec` Number,
   `primary_contact_age_sec` Number, `mrp_processes` Number, `lag_status` String.
3. **Thresholds** (this is what decides CRIT vs WARN in the console; the script's own thresholds are
   config, below, and do not have to match):

   | Column | Warning | Critical |
   |---|---|---|
   | `transport_lag_sec` | 300 | 900 |
   | `apply_lag_sec` | 900 | 3600 |
   | `primary_contact_age_sec` | 300 | 900 |
   | `mrp_processes` | — | `= 0` |
   | `lag_status` | — | matches `UNKNOWN` |

4. **Collection schedule:** every 5 minutes.
5. **Test it against a standby in the UI first.** This is the step the repo cannot do for you: it proves
   the SQL runs under the monitoring credential and the columns come back as typed.
6. **Save**, then **export the `.zip`** (`emcli export_metric_extension`) and keep it in this folder. That
   export is the `ME_ARCHIVE` the script imports — the UI is the source of truth for the extension
   definition and the SQL is kept here so a reviewer can read what will be deployed.

## (c) Credentials — read this before you point it at a mounted standby

- A **mounted** standby (no `OPEN` PDB) cannot be monitored by a plain `dbsnmp`: the SQL needs a connection
  that can read `v$`/`gv$` on a database that is not open. Use a **SYSDBA monitoring credential** for that
  target.
- An **Active Data Guard read-only** standby is open read-only, and `dbsnmp` is normally fine.
- `verify` reads the OEM repository over `OMR_CONNECT` (the `sysman` account), passed **on stdin**, never on
  a command line.
- **Version-specific and to be confirmed:** the exact monitoring-privilege requirements for a mounted
  standby vary by EM and DB release. Confirm on the release in front of you before relying on it.

## (d) The script steps

| Command | What it does | What it does **not** do |
|---|---|---|
| `plan` | prints the steps for these targets | change anything |
| `sql-test` | runs `standby-lag.sql` per target via `sql_lines`, prints the 7 columns and applies the thresholds locally | deploy anything |
| `preflight` | `emcli sync` (must be logged in), `emcli help <verb>` must list **every** flag the script passes, `get_targets` per target, target names must match `^[A-Za-z0-9_.:-]+$` | change anything |
| `import` | `emcli import_metric_extension -file_name=<ME_ARCHIVE>` | publish or deploy |
| `publish` | `emcli save_metric_extension_draft -name=$ME_NAME -version=1` then `publish_metric_extension` | deploy |
| `deploy` | `emcli deploy_metric_extension -target_type=oracle_database -name=$ME_NAME -version=1 -target_names=<a,b>`, then a read-back with `emcli get_metric_extension -name=$ME_NAME -version=1`; records `deployed_targets` **only after that read-back confirms the extension is visible** | trust `emcli`'s exit status alone |
| `verify` | reads `sysman.mgmt$metric_current` over `OMR_CONNECT` and checks each target has a current row | declare success from the deploy's exit code alone |
| `rollback` | `emcli undeploy_metric_extension … -target_names=<recorded targets>` — exactly what `deploy` recorded — then clears `deployed_targets` | undeploy targets it did not deploy |
| `run` | `preflight` → `import` → `publish` → `deploy` → `verify` | — |

**Preflight is the release guard.** `emcli` verb names and flags move between EM releases; a renamed flag
must fail here, before a half-finished deploy, not in the middle of one. If `preflight` dies naming a verb
and a flag, that is the check doing its job — read the flag name off `emcli help <verb>` on your release
and adjust the wrapper (or the release).

**`verify` is the deploy outcome, not the deploy.** `deploy` records its targets only after `emcli`
returns success **and** a read-back shows the extension, and `verify` then requires a current repository
row for each target. A missing target is
CRIT, a failed repository read is CRIT, and **no `OMR_CONNECT` is a WARN (`rc 1`) — never "verified"**. A
target reporting `lag_status = UNKNOWN` is CRIT.

## Thresholds and configuration

The script's thresholds are config, not the console's — `sql-test` and `run` apply them locally so you can
see a bad row without waiting for a collection.

| Key | Default | Meaning |
|---|---|---|
| `TRANSPORT_LAG_WARN` / `TRANSPORT_LAG_CRIT` | 300 / 900 | seconds |
| `APPLY_LAG_WARN` / `APPLY_LAG_CRIT` | 900 / 3600 | seconds |
| `CONTACT_AGE_WARN` / `CONTACT_AGE_CRIT` | 300 / 900 | seconds since the primary last updated the stats |
| `ME_ARCHIVE` | — | the exported metric-extension `.zip` from (b) |
| `ME_NAME` | `ME$STANDBY_LAG` | the extension's name in EM; deploy/undeploy/verify all key on it |
| `ME_TARGETS` | — | default comma-separated targets when `--targets` is not given |
| `ME_SID` | — | default instance for `sql-test` when `--sid` is not given |
| `ME_SQL_FILE` | `standby-lag.sql` beside the script | the metric SQL file |
| `OMR_CONNECT` | — | `sysman/<pw>@<omr>` for `verify`; read on stdin, never argv |
| `EMCLI_TIMEOUT` | 120 | seconds per `emcli` call |

CLI options: `--targets a,b`, `--sid SID`, `--sql-file FILE`, `--run-dir DIR`, `--timeout SECS`, and the
shared `--dry-run --yes --force --json --verbose --quiet`.

**On `--dry-run`:** it is meant to reach no changing `emcli` verb, and `deploy` is guarded that way — but
confirm it on the version in front of you before you rely on it for `import`, `publish`, `rollback` or
`run`, which is what [`tests/dry-run-gate.sh`](../../tests/dry-run-gate.sh) exists to check. A `--dry-run`
that still imports a draft, publishes it or undeploys from live targets is worse than no dry run.

See [`oem-standby-lag.conf.example`](oem-standby-lag.conf.example). Exit codes are the repo convention:
**2** CRIT, **1** WARN, **0** clean.

## (e) Rollback, blackouts and RAC

- **Rollback** undeploys from the `deployed_targets` recorded in the run dir. It does **not** delete the
  metric extension or its published definition — undeploy stops it collecting on those targets. Do the
  verification step after any rollback: **`verify` must fail for the undeployed target**; if it still
  passes, the undeploy did not take.
- **Blackouts:** a planned `APPLY-OFF`, or a snapshot standby, will show `lag_status = UNKNOWN` (CRIT).
  That is correct behaviour, not a fault — suppress the target during the window with an OEM blackout rather
  than raising a threshold.
- **RAC:** `mrp_processes` is counted over `gv$dataguard_process`, so the apply instance is included. Deploy
  to the **database instance** targets for the standby, and expect one row per instance; the repository
  check in `verify` is per target name.

## (f) What has and has not been verified

- **Verified against stubs:** the wrapper's control flow and its gates —
  [`tests/oem-standby-lag.sh`](../../tests/oem-standby-lag.sh) drives stub `emcli`/`sqlplus` to prove that an
  unreadable or `UNKNOWN` lag is never a clean exit, that a missing help flag or unknown target stops before
  any change, that a failed deploy records nothing, that rollback undeploys exactly the recorded targets,
  and that the repository password never reaches an argv. `--dry-run` safety is checked by
  [`tests/dry-run-gate.sh`](../../tests/dry-run-gate.sh) and the failure paths by
  [`tests/false-success-gate.sh`](../../tests/false-success-gate.sh) — run both on the version you deploy,
  they are the authority on whether `--dry-run` really refuses.
- **Run on a real database:** `standby-lag.sql` on Oracle Database Free as a PRIMARY (a row with
  `lag_status = PRIMARY`).
- **NOT exercised:** the standby path of the SQL, the real `emcli` flag names on your EM release, the
  metric in the console, and the threshold behaviour over a real lag. The flag names here come from the 13c
  CLI reference and are checked by `preflight` against your release; treat the rest as unverified until you
  run (b) and (d) on the estate.

## Don'ts

- Don't deploy to production targets before you have run `sql-test` and `preflight` on a standby host.
- Don't put the `OMR_CONNECT` password on a command line; it is read on stdin.
- Don't read a bare `deploy_metric_extension` success as "collecting" — `verify` is the outcome.
- Don't forget the undeploy check after a rollback.

## Related

- [`standby-lag.sql`](standby-lag.sql) — the SQL adapter query.
- [`oem-standby-lag.conf.example`](oem-standby-lag.conf.example) — config keys and defaults.
- [`tests/oem-standby-lag.sh`](../../tests/oem-standby-lag.sh) — the behavioural gate (the stub spec).
- [`lib/oracle-lib.sh`](../../lib/oracle-lib.sh) — `sql_lines`, `state_set`, `tmp_secret_file`, run dirs.
