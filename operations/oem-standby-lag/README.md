# oem-standby-lag.sh — an OEM 13c metric extension for Data Guard standby lag

> **Status:** the wrapper and its gate are verified against **stubs only**. The SQL has been run on Oracle
> Database Free (a PRIMARY), but the standby path, the real `emcli` flag names on your EM release, and the
> metric in the console have **not** been exercised on this estate. In particular the **deploy path uses
> `emcli apply_template`**, and those flag names came from memory (the doc fetch used for the redesign did
> not return that verb's entry) — see (d) and (f). Treat this as a reviewed starting point and prove it per
> (f) before you trust a green `verify`.

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

The metric extension is built **once in the UI** (b). This script then carries it the rest of the way —
`import` → `publish` → `deploy` (apply a monitoring template that holds the extension and its thresholds)
→ `verify` — and `rollback` hands back the console steps to undeploy it.

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
cp oem-standby-lag.conf.example oem-standby-lag.conf && chmod 600 oem-standby-lag.conf  # ME_ARCHIVE, ME_TEMPLATE, OMR_CONNECT, thresholds

./oem-standby-lag.sh sql-test  --sid STBYA     # the metric's own SQL + thresholds on one standby
./oem-standby-lag.sh preflight --targets STBYA,STBYB   # logged in? flags exist? targets exist? names safe?
./oem-standby-lag.sh import    --yes           # emcli import_metric_extension -file_name=<ME_ARCHIVE>
./oem-standby-lag.sh publish   --yes           # save_metric_extension_draft + publish_metric_extension
./oem-standby-lag.sh deploy    --targets STBYA,STBYB --yes   # apply_template of the monitoring template
./oem-standby-lag.sh verify    --targets STBYA,STBYB         # the repository says each target is collecting
# ... later, to remove it ...
./oem-standby-lag.sh rollback  --yes           # prints the recorded targets + the console undeploy steps
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

## (b) Build the extension and its template once in the UI

**1. The metric extension.** Enterprise → Monitoring → **Metric Extensions** → **Create**:

- **Target type:** `Database Instance`. **Adapter:** SQL.
- Paste [`standby-lag.sql`](standby-lag.sql). **No key column.** Seven columns, in the order above, with
  types: `database_role` String, `open_mode` String, `transport_lag_sec` Number, `apply_lag_sec` Number,
  `primary_contact_age_sec` Number, `mrp_processes` Number, `lag_status` String.
- **Collection schedule:** every 5 minutes.
- **Test it against a standby in the UI** before saving. This is the step the repo cannot do for you: it
  proves the SQL runs under the monitoring credential and the columns come back as typed.
- **Save**, then **export the `.zip`** (`emcli export_metric_extension`). That export is the `ME_ARCHIVE`
  the script imports — keep it, it is how the extension is moved to another EM.

**2. The monitoring template.** The extension is **deployed by applying a monitoring template**, not by a
metric-extension verb. Create (or reuse) a template — `` ME_TEMPLATE ``, default `STANDBY_LAG` — that:

- includes this metric extension, and
- carries the **thresholds**. For a template deployment the template is the place thresholds live:
  `transport_lag_sec` 300/900, `apply_lag_sec` 900/3600, `primary_contact_age_sec` 300/900,
  `mrp_processes` critical at `= 0`, `lag_status` critical on `UNKNOWN`.

The template is built **per EM** (it is a console object, not the exported `.zip`); the `.zip` is the
artifact you carry between EMs and the template is what `deploy` applies to the targets.

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
| `preflight` | `emcli sync` (must be logged in), `emcli help <verb>` must list **every** flag the script passes (including `apply_template -name -targets`), `get_targets` per target, target names must match `^[A-Za-z0-9_.:-]+$` | change anything |
| `import` | `emcli import_metric_extension -file_name=<ME_ARCHIVE>` | publish or deploy |
| `publish` | `emcli save_metric_extension_draft -target_type=oracle_database -name=<ME_NAME> -version=1` then `publish_metric_extension` | deploy |
| `deploy` | `emcli apply_template -name=<ME_TEMPLATE> -targets="<a>:oracle_database;<b>:oracle_database"`; records `deployed_targets` **only after `emcli` returns 0** | prove the metric is collecting (that is `verify`) |
| `verify` | reads `sysman.mgmt$metric_current` over `OMR_CONNECT` and checks each target has a current `lag_status` row | declare success from the deploy's exit code alone |
| `rollback` | prints the targets `deploy` recorded and the **console** undeploy steps (Enterprise → Monitoring → Metric Extensions → the extension → Actions → Undeploy From Targets). **No `emcli` call**, changes no state, never says "undeployed" | undeploy anything itself |
| `run` | `preflight` → `import` → `publish` → `deploy` → `verify` | — |

**Preflight is the release guard.** `emcli` verb names and flags move between EM releases; a renamed flag
must fail here, before a half-finished deploy, not in the middle of one. If `preflight` dies naming a verb
and a flag, that is the check doing its job — read the flag name off `emcli help <verb>` on your release
and adjust the wrapper (or the release). **`apply_template`'s flags in particular were written from
memory** for the redesign and have not been checked against a real `emcli help apply_template` — that is
the first thing `preflight` will tell you.

**`verify` is the deploy outcome, not the deploy.** `apply_template` exiting 0 means the template was
applied, not that the extension is collecting. `deploy` records its targets only after `emcli` returns
success, and `verify` then requires a current repository row for each target. A missing target is CRIT, a
failed repository read is CRIT, and **no `OMR_CONNECT` is a WARN (`rc 1`) — never "verified"**. A target
reporting `lag_status = UNKNOWN` is CRIT. Always run `verify` after `deploy`.

## Thresholds and configuration

The script's thresholds are config, and they mirror the template's — `sql-test` and `run` apply them locally
so you can see a bad row without waiting for a collection. The **console thresholds are the template's**
(see (b)); if the two drift, the console is what fires.

| Key | Default | Meaning |
|---|---|---|
| `TRANSPORT_LAG_WARN` / `TRANSPORT_LAG_CRIT` | 300 / 900 | seconds |
| `APPLY_LAG_WARN` / `APPLY_LAG_CRIT` | 900 / 3600 | seconds |
| `CONTACT_AGE_WARN` / `CONTACT_AGE_CRIT` | 300 / 900 | seconds since the primary last updated the stats |
| `ME_ARCHIVE` | — | the exported metric-extension `.zip` from (b) |
| `ME_NAME` | `ME$STANDBY_LAG` | the extension's name in EM; import/publish key on it |
| `ME_TEMPLATE` | `STANDBY_LAG` | the monitoring template `deploy` applies |
| `ME_TARGETS` | — | default comma-separated targets when `--targets` is not given |
| `ME_SID` | — | default instance for `sql-test` when `--sid` is not given |
| `ME_SQL_FILE` | `standby-lag.sql` beside the script | the metric SQL file |
| `OMR_CONNECT` | — | `sysman/<pw>@<omr>` for `verify`; read on stdin, never argv |
| `EMCLI_TIMEOUT` | 120 | seconds per `emcli` call |

CLI options: `--targets a,b`, `--sid SID`, `--sql-file FILE`, `--run-dir DIR`, `--timeout SECS`, and the
shared `--dry-run --yes --force --json --verbose --quiet`.

**On `--dry-run`:** every changing call goes through one guard, so a dry run reaches no changing `emcli`
verb — `import`, `publish` and `deploy` no-op, `run` reaches none of theirs, and `rollback` makes no
`emcli` call at all. `preflight` and `verify` still run in a dry run because they change nothing (a
`sync` probe and a repository read).
[`tests/dry-run-gate.sh`](../../tests/dry-run-gate.sh) is what proves that on the version in front of you
(it reports the guarded commands as NOT-EXERCISED there because they make no tool call under `--dry-run`,
which is the correct reading). A `--dry-run` that still imports a draft, publishes it or applies a
template is worse than no dry run.

## (e) Rollback, blackouts and RAC

- **Rollback** is **advisory**: it prints the recorded targets and the console undeploy steps and changes
  nothing. Do the undeploy in the console (Actions → Undeploy From Targets), then **run `verify`: it must
  fail for the undeployed target** — if it still passes, the undeploy did not take.
- **Blackouts:** a planned `APPLY-OFF`, or a snapshot standby, will show `lag_status = UNKNOWN` (CRIT).
  That is correct behaviour, not a fault — suppress the target during the window with an OEM blackout rather
  than raising a threshold.
- **RAC:** `mrp_processes` is counted over `gv$dataguard_process`, so the apply instance is included.
  `apply_template -targets` names the **database instance** targets for the standby, and `verify` checks the
  repository per target name.

## (f) What has and has not been verified

- **Verified against stubs:** the wrapper's control flow and its gates —
  [`tests/oem-standby-lag.sh`](../../tests/oem-standby-lag.sh) drives stub `emcli`/`sqlplus` to prove that an
  unreadable or `UNKNOWN` lag is never a clean exit, that a missing help flag or unknown target stops before
  any change, that a failed deploy records nothing, and that the repository password never reaches an argv.
  `--dry-run` safety is checked by [`tests/dry-run-gate.sh`](../../tests/dry-run-gate.sh) and the failure
  paths by [`tests/false-success-gate.sh`](../../tests/false-success-gate.sh) — run both on the version you
  deploy, they are the authority on whether `--dry-run` really refuses.
- **Run on a real database:** `standby-lag.sql` on Oracle Database Free as a PRIMARY (a row with
  `lag_status = PRIMARY`).
- **NOT exercised:** the standby path of the SQL, the real `emcli` flag names on your EM release, the metric
  in the console, and the threshold behaviour over a real lag. The **`apply_template` flags were written
  from memory** during the redesign (the doc fetch returned no entry for that verb) and no EM has run them;
  `preflight` is what checks them on your release. Treat the deploy path as unverified until (b) and (d)
  have been run on the estate.
- **Redesign history, for the record:** an earlier revision deployed with `emcli deploy_metric_extension` /
  `undeploy_metric_extension` and read back with `get_metric_extension`; the 13.5 metric-extension verb list
  does not document those three, so the deploy moved to `apply_template` and `rollback` to console guidance.
  That is why there is no read-back verb here.

## Don'ts

- Don't deploy to production targets before you have run `sql-test` and `preflight` on a standby host.
- Don't put the `OMR_CONNECT` password on a command line; it is read on stdin.
- Don't read a bare `apply_template` success as "collecting" — `verify` is the outcome.
- Don't expect `rollback` to undeploy anything; it hands you the console steps.
- Don't forget the undeploy check after a rollback.

## Related

- [`standby-lag.sql`](standby-lag.sql) — the SQL adapter query.
- [`oem-standby-lag.conf.example`](oem-standby-lag.conf.example) — config keys and defaults.
- [`tests/oem-standby-lag.sh`](../../tests/oem-standby-lag.sh) — the behavioural gate (the stub spec).
- [`lib/oracle-lib.sh`](../../lib/oracle-lib.sh) — `sql_lines`, `state_set`, `tmp_secret_file`, run dirs.
