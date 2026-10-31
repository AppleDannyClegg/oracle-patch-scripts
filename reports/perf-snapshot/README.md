# perf-snapshot.sh — "it was slow between 09:00 and 10:30"

Read-only. Collects the performance evidence for a time window from every running database on the
host (and the host itself), so a tuning DBA or Claude can say *why* without logging in:

- **Always (v$ views, no licence needed)**: instance and memory, resource limits, temp and PGA
  spills, wait-class profile and top events since startup, single-block read and `log file sync`
  latency, top SQL in the cursor cache by elapsed and by gets, statements with several plans,
  child-cursor explosions, hard-parse rate, blocking tree, long ops, long transactions, I/O by
  file, redo switches per hour, sessions by machine/module, per-PDB top SQL, and **live sampling
  of `v$session`** (10 samples 2 s apart by default): the poor man's ASH, with average active
  sessions, top sql_id, top events and blockers.
- **With the Diagnostics Pack** (detected from `control_management_pack_access`, or `PERF_PACK=yes|no`,
  or `--no-pack`): top SQL in the window from `dba_hist_sqlstat` deltas, DB time and DB CPU, plan
  flips in the window, wait classes and events in the window, OS load per snapshot, ASH in the
  window (average active sessions, top events/SQL/modules/blockers, minute-by-minute AAS), and with
  `--awr` the full **AWR, ASH and ADDM text reports** into `raw/`.
- **`--sql-id`**: one statement in depth: full text, children, `dbms_xplan.display_cursor` with
  peeked binds and outline, execution history per snapshot for 7 days, every plan hash ever seen
  and when, bind captures, profile/baseline/patch, the tables it touches with their statistics
  and staleness, and `display_awr` for every historical plan.
- **Host**: `vmstat`, `iostat -x`, top processes, HugePages, OSWatcher archive for the window if
  AHF/OSWatcher keeps one.
- **`--threads`**: three thread dumps 10 s apart of every WebLogic server and ORDS JVM, with the
  most common stack frames across the dumps, BLOCKED/STUCK counts and heap info.

FINDINGS rules: CPU saturated or swapping now, device utilisation ≥90 %, read or `log file sync`
latency >10 ms, PGA over-allocation, plan flips, statements taking ≥25 % of DB time in the window,
a wait class at ≥60 % of wait time, blocked sessions now or ≥5 min of blocking in the window,
processes ≥80 %, temp spills, redo switching >12/hour, child cursors >100, stale stats on the
`--sql-id` tables, bind-sensitive cursors.

## Quick start

```bash
cd reports/perf-snapshot
./perf-snapshot.sh --last 2h                                 # last two hours, every database
./perf-snapshot.sh --from "2026-10-31 09:00" --to "2026-10-31 10:30" --awr   # with AWR/ASH/ADDM text
./perf-snapshot.sh --sid PRODDB --sql-id 7hk6a3gbs2c9z         # one statement in depth
./perf-snapshot.sh --last 30m --threads                      # WebLogic/ORDS slow: thread dumps too
```

Output: `~/perf-snapshot/<host>_<ts>/REPORT.md` (FINDINGS first), `raw/` (AWR/ASH/ADDM text, the
sampled session lines, full query output) and a `.tar.gz`. Hand it to Claude as in
[../oracle-diag/ANALYSE.md](../oracle-diag/ANALYSE.md), with the complaint: *"users say APEX was
slow 09:00-10:30; here is the perf-snapshot for that window"*.

## Licensing

`dba_hist_*`, `v$active_session_history`, AWR, ASH and ADDM reports are **Oracle Diagnostics Pack**
features (ADDM also needs the Tuning Pack for some advice). The script only uses them when the
database says the pack is enabled (`control_management_pack_access` contains DIAGNOSTIC) or you
set `PERF_PACK=yes`; `--no-pack` forces the v$-only path. Running the reports on a database that
is not licensed is an audit problem, so it refuses by default.

## Options

| Option | Meaning |
|---|---|
| `--from`, `--to` | window, `"YYYY-MM-DD HH:MI"` |
| `--last 2h` | `30m`, `2h`, `1d`: window ending now (default last 60 minutes) |
| `--sid`, `--pdb` | one database; make sure a PDB is covered |
| `--sql-id ID` | deep-dive one statement |
| `--awr` | AWR + ASH + ADDM text reports (pack) |
| `--no-pack` | never read `dba_hist_*` / ASH |
| `--threads` | JVM thread dumps |
| `--samples N` | live `v$session` samples (default 10) |
| `--out DIR`, `--lines N`, `--quiet`, `--no-tar` | |

Config keys (`perf-snapshot.conf` or the shared `oracle.conf`): `PERF_OUT`, `PERF_TOP`, `PERF_PACK`,
`SQL_CONNECT`, `PDB`. Needs `lib/oracle-lib.sh` one folder up.
