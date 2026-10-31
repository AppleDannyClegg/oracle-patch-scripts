# patch-status.sh — "are we exposed?" in one table

Read-only. Every Oracle home on the host against the current Critical Patch Update (CPU: third
Tuesday of January, April, July, October), in one table:

| product | home | installed | date | latest | CPUs behind | status | note |
|---|---|---|---|---|---|---|---|

Rows: database and Grid Infrastructure homes (Release Update, Monthly Recommended Patch, OJVM,
OPatch version), **datapatch level per database and per PDB** (a binary RU that `datapatch` has
not applied yet is CRIT: the classic "we patched but the SQL side didn't happen"), WebLogic
homes (PSU, Coherence, ADF/OPSS/OWSM/SOA/OSB bundles), every JDK in use and who uses it, ORDS and
APEX versions vs the newest public release, GoldenGate, EM agent, AHF, kernel and Ksplice.

`behind` is the number of CPUs published after the installed patch's date (read from the patch
description, e.g. `19.24.0.0.240716` → 2024-07-16). `CURRENT` = patched to this quarter;
`N behind` ≥ 2 is CRIT in `--report` mode. Out-of-support releases (DB 11g/12c/18c, WebLogic
12.1/12.2.1.3, Java 6/7) are CRIT too.

## Quick start

```bash
cd patching/patch-status
./patch-status.sh                     # table on the terminal, no network needed except the ORDS/APEX probes
./patch-status.sh --no-net            # air-gapped
./patch-status.sh --mos               # ask My Oracle Support for the newest RU / PSU names (needs ~/.netrc)
./patch-status.sh --csv > patches.csv # for the risk register
./patch-status.sh --report            # REPORT.md with FINDINGS + every `opatch lspatches`, for Claude
```

`--mos` uses the same name search as `wls-patch.sh latest` (`~/.netrc` line for
`updates.oracle.com`, or `MOS_USER`/`MOS_PASSWORD` in the conf). Without it the "latest" column
says which CPU the home should be at; the actual patch numbers come from MOS Doc 2118136.2
(database) and 2806740.2 (Fusion Middleware), which the report links.

## Options

| Option | Meaning |
|---|---|
| `--mos` | look up newest RU/PSU names on MOS |
| `--no-net` | no network calls at all |
| `--json`, `--csv` | machine-readable output |
| `--report` | write `REPORT.md` + `raw/` + tar.gz under `PATCH_OUT` (default `~/patch-status`) |
| `--out DIR`, `--quiet`, `--no-tar` | |

Config keys: `PATCH_OUT`, `MOS_USER`, `MOS_PASSWORD`, `SQL_CONNECT`. Needs `lib/oracle-lib.sh`
one folder up. The next step for each row is the matching script: `db-patch`, `wls-patch`,
`ords-patch`, `apex-patch`, `java-patch`.

## Without internet

Works as is: the current quarter comes from the CPU calendar (third Tuesday of Jan/Apr/Jul/Oct),
so "N behind" needs no network. Only `--mos` (exact newest patch numbers) and the newest public
ORDS/APEX version need the internet; when the host has none (or `OFFLINE=1` is set) those columns
say so and the rest of the table is unchanged.
