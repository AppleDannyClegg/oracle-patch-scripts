# exascale-space.sh — "the vault is full": where the space went on Exascale and how to get some back

On Exadata Exascale the databases do not write to ASM diskgroups but to **vaults** (`@prodvault`)
carved out of **storage pools** (the cells' disks and flash). A vault has a provisioned ceiling
per media type (`spaceProvHC` for disk, `spaceProvEF` for flash) and the pool has a physical one.
"Out of space" is one of three things: the vault reached its ceiling, the pool is physically
full, or something is quietly keeping blocks alive (snapshots, thin clones, archivelogs nobody
deleted, files of a database that no longer exists, files still being deleted in the background).
This script tells you which, with sizes, and then does the safe fixes.

It talks to Exascale with `escli` (the Exascale CLI) using the Oracle user's wallet, and to each
running database for the view from inside (`V$EXA_VAULT`, `V$EXA_FILE`, the recovery area,
archivelogs RMAN has already backed up, guaranteed restore points, PDB snapshot copies). Without
`escli` on the host it still reports the database side. No network.

## Quick start

```bash
cd operations/exascale-space
./exascale-space.sh inspect                   # REPORT.md with FINDINGS; exit 2 CRIT / 1 WARN / 0 clean
./exascale-space.sh plan                      # what could be freed or grown, with the exact commands and sizes
./exascale-space.sh purge-archivelogs         # RMAN: delete archivelogs completed before sysdate-1 that are backed up to sbt
./exascale-space.sh grow prodvault --hc +2T   # chvault: 2 TB more HC provisioning (preflight: the pool must have it); rollback undoes it
./exascale-space.sh release --list ~/exascale-space/<run>/orphan-candidates.txt   # rmfile the files YOU reviewed; typed confirmation
./exascale-space.sh heal                      # inspect, then purge-archivelogs where a vault is over EXA_WARN_PCT (asks; --yes runs)
```

Report: `~/exascale-space/<host>_<ts>/REPORT.md` (FINDINGS first) plus `raw/*.txt` (every escli
and SQL output untruncated) and `raw/*.csv` (pools, vaults, files per vault, the summary table).
Hand the report to Claude as in [../../reports/oracle-diag/ANALYSE.md](../../reports/oracle-diag/ANALYSE.md).

## What inspect shows and the FINDINGS rules

- **Storage pools** (`lsstoragepool --detail`): raw, used, free %, provisionable, provisioned, data/reco
  ring status, pool disks not normal, a running pool operation. Free below `EXA_POOL_FREE_PCT`
  (12 %, Oracle's reserve for rebalancing after a disk loss on 12-disk cells; 20 % for 6-disk HC)
  is WARN, below 5 % CRIT. Provisioned above raw is WARN: the vaults together promise more than the
  pool holds, so a vault that looks fine can still hit a full pool.
- **Vaults** (`lsvault --detail`, and `lsvault --provision` per pool on 26.1+): used vs provisioned per
  media type, ≥ `EXA_WARN_PCT` (85) WARN, ≥ `EXA_CRIT_PCT` (95) CRIT. `unlimited` means the pool is the
  limit. Every run appends used/provisioned to `EXA_HISTORY/<host>/*.csv`; the slope over
  `EXA_WINDOW` days gives days-to-full (≤ 30 WARN, ≤ 7 CRIT). Run it daily from cron and the
  forecast becomes real.
- **Inside each vault** (`lsfile @vault/* --detail --include-being-deleted`): tables by file type,
  by database (`usedBy`), by top-level path, and the biggest files. Findings: files still being deleted
  (INFO: the space comes back by itself, do not delete more), locked snapshot files (INFO), files
  older than `EXA_ORPHAN_DAYS` that no database claims (WARN, with the warning that a closed
  database still owns its files), archivelogs older than `EXA_ARCH_DAYS` (WARN: purge them once
  backed up), backup/flashback files (INFO). `--no-files` skips this on a vault with a million files.
- **Block volumes** (`lsvolume`, `lsvolumesnapshot`, `lsacfsfilesystem`): size vs space used (three
  mirrors), volumes being deleted, volumes with many snapshots.
- **Cluster alerts** (`lsclusteralert`) that mention space or capacity.
- **Database side** for every running instance whose file destinations start with `@`: file
  destination parameters, `V$EXA_VAULT`, `V$EXA_FILE` by vault/container/file type and by
  database, the recovery area on the vault (used, reclaimable, archivelogs backed up vs not),
  flashback and guaranteed restore points, PDB snapshot copies (`v$pdbs.snapshot_parent_con_id`).
  Findings: recovery area over `EXA_WARN_PCT` not reclaimable (WARN), archivelogs not backed up
  (WARN: back up before purging), archivelogs backed up and still on the vault (INFO), a
  guaranteed restore point older than a week (WARN), thin clones (INFO: Oracle sizes 20–25 % of the
  parent per updateable clone), datafiles at their autoextend maximum or with autoextend off.

## The fixes

| Command | What it does | Safety |
|---|---|---|
| `plan` | Per vault: the `grow` command if the pool has provisionable space, archivelogs/backups/being-deleted/locked-snapshot sizes, a reviewed list of files no database claims saved to `orphan-candidates.txt`; per database: recovery-area reclaimable, restore points, thin clones, the `purge-archivelogs` line | read-only |
| `grow <vault> --hc SIZE` (`--ef`, `--xt`; `+2T`, `220T`, `unlimited`; `--pool` on 26.1+) | `chvault @vault --provision storagePool=...,spaceProv=...` on 26.1+, `--attributes spaceProvHC=...` before; preflight refuses more than the pool has provisionable (`--force` sends it anyway); `verify` re-reads the vault; `rollback` puts the old value back | asks; old value saved in the run dir |
| `purge-archivelogs [--sid] [--days N] [--obsolete]` | RMAN `crosscheck archivelog all; delete expired; delete noprompt archivelog all completed before 'sysdate-N' backed up EXA_ARCH_BACKED_UP times to device type EXA_ARCH_DEVICE`; `--obsolete` adds `delete obsolete` | RMAN only deletes what it has backed up; archivelogs with no backup stay and are a WARN |
| `release <@vault/file ...>` or `--list FILE` | `rmfile --nowait` for the files named, each shown with size and `usedBy` first; refuses a file a database claims (`--force` overrides) | typed `delete`; never a heuristic bulk delete |
| `heal` / `run` | `inspect`, then `purge-archivelogs` for every database when a vault or pool is over `EXA_WARN_PCT`; prints the `plan` line | grow and release are never automatic |

What it will not do for you: free a full pool (delete data, add cells, or move a database to another
pool), remove snapshots or thin clones (drop the PDB clone, `rmfile --with-snapshots` after
`lssnapshots <file> --tree` shows what depends on it), or drop a guaranteed restore point.
`plan` prints those as commands for you to run.

## Options

| Option | Meaning |
|---|---|
| `--vault NAME` | one vault |
| `--sid SID` | one database (default: every running instance) |
| `--days N` | archivelog age for `purge-archivelogs` and the archivelog finding (default `EXA_ARCH_DAYS`=1) |
| `--top N` | rows in the biggest-files tables (25) |
| `--no-files`, `--no-db`, `--no-escli` | skip the per-file listing / the database side / escli entirely |
| `--out DIR`, `--no-tar`, `--dry-run`, `--yes`, `--force`, `--verbose`, `--quiet` | |

Config (`exascale-space.conf` next to the script or the shared `oracle.conf`): `ESCLI` (binary; default
the first of `escli` on PATH, `/opt/oracle/cell/cellsrv/bin/escli`, `/opt/oracle/dbserver/dbms/bin/escli`,
`/usr/sbin/escli`), `EXA_WALLET` (default: escli's own search path `$OSSCONF/eswallet`,
`$ORACLE_BASE/admin/eswallet`, `/etc/oracle/cell/network-config/eswallet`), `EXA_CTRL` (ERS host:port when
the wallet has none), `EXA_TIMEOUT` (120 s per escli call), `EXA_WARN_PCT`, `EXA_CRIT_PCT`,
`EXA_POOL_FREE_PCT`, `EXA_WARN_DAYS`, `EXA_CRIT_DAYS`, `EXA_WINDOW`, `EXA_ORPHAN_DAYS`, `EXA_ARCH_DAYS`,
`EXA_ARCH_BACKED_UP`, `EXA_ARCH_DEVICE` (`sbt` for ZDLRA/tape, `disk`), `EXA_OUT`, `EXA_HISTORY`,
`RUN_BASE`, `SQL_CONNECT`, `RMAN_CMD`, `RMAN_CATALOG_CONNECT`, `RMAN_TIMEOUT`.

Notes. escli prints humanised sizes (`193.0000T`, `24k`); the script converts them to bytes, so the
tables and CSVs are exact. The wallet's user decides what you see: a database user sees its own
vault, a cluster administrator sees every pool and vault, and `grow` needs a user with vault
administration rights. On Exascale a file's `spaceUsed` is about three times its `size` (high
redundancy = three mirrors). Oracle's capacity rule for thin clones: reserve 20–25 % of the parent
datafiles per updateable clone. Daily history: `crontab -e` and add
`30 6 * * * /path/operations/exascale-space/exascale-space.sh inspect --quiet --no-tar >/dev/null 2>&1`.

Needs `lib/oracle-lib.sh` two folders up and bash 4+. Runs as the Oracle software owner, never root.
