# space-forecast.sh — days-to-full for everything that fills up

Read-only. One table, sorted by days to 100 %, covering tablespaces (container and every PDB),
FRA, ASM diskgroups, filesystems, plus archivelog generation per day and the fastest-growing
segments. Built for the monthly capacity review and for the "will we make it to the weekend"
question.

How it forecasts: every run appends today's used/max per object to its own history
(`<output dir>/space-forecast/history/<host>/*.csv`). The slope is a least-squares line over the last
`--window` days (default 30); days-to-90 % and days-to-100 % come from that slope. With the
Diagnostics Pack it also pulls up to 30 days from `dba_hist_tbspc_space_usage` and
`dba_hist_seg_stat` on the first run, so it is useful immediately; without the pack it needs a few
daily runs (`--install-cron 06:30` prints the crontab line).

## Quick start

```bash
cd reports/space-forecast
./space-forecast.sh                     # every running database + filesystems, prints findings and the report path
./space-forecast.sh --csv > space.csv   # the forecast table as CSV for a spreadsheet
./space-forecast.sh --sid PRODDB --window 14
./space-forecast.sh --install-cron 06:30
```

Output: `<output dir>/space-forecast/<host>_<ts>/REPORT.md` (FINDINGS first, then the forecast table, the
archivelog-per-day table, biggest segments, segment growth, audit/APEX log/recyclebin/temp/undo
sizes) and `raw/forecast.csv`, `raw/segments.csv`.

FINDINGS: full in ≤7 days CRIT, ≤30 days WARN (`SPACE_CRIT_DAYS`, `SPACE_WARN_DAYS`), ≥95 % now
CRIT, ≥90 % WARN, datafiles at their autoextend maximum, autoextend off, datafile count near
`db_files`, archivelog generation in the last 24 h more than twice the window average, `aud$`
over 5 GB, APEX activity/debug logs over 5 GB, recyclebin over 5 GB.

## Options

| Option | Meaning |
|---|---|
| `--window N` | days of history to fit (default 30) |
| `--sid`, `--pdb` | one database; make sure a PDB is covered |
| `--csv` | print the forecast table as CSV instead of the summary |
| `--history DIR` | where the history lives (default `<output dir>/space-forecast/history`) |
| `--no-pack` | do not read `dba_hist_*` |
| `--out DIR`, `--quiet`, `--no-tar`, `--install-cron HH:MM` | |

Config keys (`space-forecast.conf` or the shared `oracle.conf`): `SPACE_OUT`, `SPACE_HISTORY`,
`SPACE_WINDOW`, `SPACE_WARN_DAYS`, `SPACE_CRIT_DAYS`, `SQL_CONNECT`, `PDB`. Needs
`lib/oracle-lib.sh` one folder up. For analysis by Claude see
[../oracle-diag/ANALYSE.md](../oracle-diag/ANALYSE.md).
