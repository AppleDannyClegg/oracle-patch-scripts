# apex-patch.sh — upgrade Oracle APEX in the database

APEX lives inside the database, so this runs on the database server as `oracle` (or anywhere
SQL*Plus/SQLcl can connect as SYS). Downloads are public (no My Oracle Support login).

```bash
./apex-patch.sh inspect        # APEX version/schema/type, DB, ORDS, images dir, restore points, newest release
./apex-patch.sh plan           # exactly what 'run' would do: from -> to, script, images dir, ORDS, rollback
./apex-patch.sh preflight 26.2 # checks + plan, changes nothing (after 'download 26.2' or let 'run' do it)
./apex-patch.sh run            # latest > download > preflight > backup > stop ORDS > apexins > images > start > verify
```

What it does for you:
- Detects the release (`apex_release`), schema (`dba_registry`), full vs runtime install, the PDB, ARCHIVELOG mode, ORDS version, and the images folder ORDS serves (`standalone.static.path`).
- Finds the newest release by probing `download.oracle.com/otn_software/apex/apex_YY.N.zip` (public, verified).
- Refuses what Oracle refuses: database older than 19c, APEX older than 18.1 (needs a hop), ORDS older than 23.3, connected to `CDB$ROOT` instead of the PDB.
- **Backup = rollback readiness**: keeps (or downloads) the *previous* release's files because Oracle's documented revert is `apxdwngrd.sql` from the previous release; creates a guaranteed restore point if the database is in ARCHIVELOG mode; tars the images folder.
- Runs `apexins.sql SYSAUX SYSAUX TEMP /i/` (or `apxrtins.sql` for runtime installs), swaps the images folder, restarts ORDS, verifies version, registry status, invalid objects (recompiles), and the ORDS URL.
- **Rollback** (automatic if apply or verify fails): `apxdwngrd.sql` from the previous release, images back, ORDS up, and offers to drop the abandoned new schema (`DROP USER APEX_xxxxxx CASCADE`, as the docs say).
- If even `apxdwngrd.sql` fails, the restore point is the last resort: `rollback --allow-flashback` flashes the PDB back. It never does that on its own, because it discards *everything* in that PDB since the restore point, including other applications' data.
- `cleanup` (a week or two later, once happy): drops the restore point (it holds flashback logs) and the old APEX schema.

Not covered: fresh installs, APEX in `CDB$ROOT`, the "maximum uptime" three-phase upgrade, APEX patch-set bundles from My Oracle Support (apply those by hand with `catpatch.sql`), and ORDS running on a different host (set `APEX_IMAGES_DIR` there by hand, or run `ords-patch.sh` on that host).

## Caveats

Tested end to end against stand-ins (a fake `sqlplus` with a small in-memory database, a fake `ords`, local copies of the download zips) covering upgrade, failed upgrade, failed verify, rollback, flashback gating, already-current, dry-run and wrong-Java. Not yet run against a real database. The commands and script names are taken from the Oracle APEX 26.2 installation guide and the ORDS 24.4 installation guide. First real run: do `inspect` and `preflight` on a test database first, and keep the restore point until you are happy.
