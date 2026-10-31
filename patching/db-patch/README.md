# db-patch.sh — database Release Update patching, with the SQL side done too

Applies an Oracle Database Release Update (and OJVM, and the Grid Infrastructure RU with
`--grid`) to a home with OPatch, restarts the databases, runs **datapatch** in every container,
recompiles, verifies, and rolls back by itself if any step fails. Same shape as `wls-patch.sh`.
Runs on the database server as `oracle`, never root.

## Quick start

```bash
cd patching/db-patch
./db-patch.sh inspect                           # home, RU level, OPatch, databases, roles, datapatch level per container
./db-patch.sh latest                            # MOS: newest RU + OJVM for this release (needs ~/.netrc)
./db-patch.sh download /u01/patches/oct2026     # fetch them (adds the OPatch kit p6880880 if OPatch is old)
./db-patch.sh plan /u01/patches/oct2026         # what run would do, changes nothing
./db-patch.sh preflight /u01/patches/oct2026    # conflicts, OPatch minimum, disk, roles, datapatch prereqs
./db-patch.sh run /u01/patches/oct2026          # backup > stop > apply > start > datapatch > verify; rollback on failure
./db-patch.sh cleanup                           # drop the restore points, prune old backups, when you are happy
```

No internet on the server: download the zips on a laptop and put them in the folder; everything
after `download` is the same.

## What `run` does

1. **preflight**: patch zips unpacked and recognised; OPatch at the version each patch's README
   asks for (upgrades it from `p6880880_*.zip` if present); `opatch prereq
   CheckConflictAgainstOHWithDetail` per patch; release match; disk for `.patch_storage` and the
   backup; every database reachable; **Data Guard primary refused until the standby is patched**
   (`DG_STANDBY_FIRST=yes`, `--force` overrides); failed `dba_registry_sqlpatch` rows; invalid
   SYS objects; hot-backup mode; running RMAN; closed PDBs; RAC without `--rolling` warned as a
   full outage; `--grid` needs `sudo -n opatchauto`.
2. **backup**: `tar` of ORACLE_HOME and the central inventory to `BACKUP_DIR`; per database a
   pfile, a controlfile copy and trace, and a **guaranteed restore point** `DBPATCH_<ts>` (if
   ARCHIVELOG and primary; `--no-restore-point` to skip).
3. **stop**: `srvctl stop database` when Grid is there (one instance only with `--rolling`), else
   `shutdown immediate` (abort after `STOP_TIMEOUT`); the listener of this home. Records what ran.
4. **apply**: `opatch apply -silent` per patch, skipping what is already installed; `--grid`
   adds `opatchauto apply` for the GI patches; `--oop NEWHOME` clones the home first, patches the
   clone, then switches `/etc/oratab` and `srvctl` to it (shorter outage, instant fallback).
5. **start**: what was running, listener, `alter pluggable database all open`.
6. **datapatch**: `datapatch -verbose` per database (all open PDBs; standbys skipped, they get it
   via redo), then `utlrp` in root and the CDB.
7. **verify**: patch ids in `opatch lspatches`; the RU description present with SUCCESS in
   `cdb_registry_sqlpatch` for every open container; no failed rows; invalid SYS objects; PDBs
   open; services; MRP running on standbys; listener up.

On failure: apply → `opatch rollback` in reverse, restart, `datapatch` again (reverts the SQL
side), and `restore` from the tar if the home is broken. datapatch → asks whether to roll back
now or leave it for `heal`, and prints the flashback commands for the restore points. verify →
asks before rolling back.

## Other commands

- `rollback [id ...]`: this run's patches in reverse (or the ids given), restart, datapatch.
  Out-of-place runs roll back by pointing oratab/srvctl at the old home.
- `restore`: replace ORACLE_HOME with this run's tar (databases must be down).
- `heal`: stale OPatch lock, failed datapatch rows (shows the logfile each one names, offers to
  re-run), invalid SYS objects (`utlrp`), closed PDBs, oratab pointing at another home, a
  datapatch still running.
- `cleanup`: drop restore points, delete old backups and `.broken.*` homes.
- `--rolling` on RAC: this node's instances only; run the script on each node in turn (the patch
  must be rolling-capable, preflight checks).

## Options and config

`--home DIR`, `--sid A,B`, `--grid`, `--oop NEWHOME`, `--rolling`, `--no-restore-point`,
`--no-backup`, `--patches ID,ID`, `--release X`, `--latest`, `--dry-run`, `--yes`, `--force`,
`--json`, `--verbose`, `--run-dir DIR`. Config in `db-patch.conf` (see the example) or the shared
`oracle.conf`; MOS login as for `wls-patch`. Needs `lib/oracle-lib.sh` one folder up. Logs and
state under `~/db-patch/runs/<ts>/`, `runs/latest` points at the last one.

Tested against a mock home (fake `opatch`, `sqlplus`); not yet on a real database. Do `inspect`,
`plan`, `preflight` on a test box first and read the log.
