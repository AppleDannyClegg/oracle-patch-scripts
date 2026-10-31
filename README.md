# Oracle patching scripts: WebLogic, APEX, ORDS

Three stand-alone bash scripts, same shape: `inspect` (look), `latest` (what is new), `preflight` (would it work),
`run` (do it, with automatic rollback). WebLogic is first; APEX and ORDS are further down.

# wls-patch.sh — WebLogic patching without needing to be a WebLogic expert

One script, runs on the WebLogic server itself, no agent or internet access needed.
It works out which WebLogic you have (12.2.1.x or 14.1.x), checks the patches you
downloaded actually fit, backs everything up, stops WebLogic, applies the patches,
starts WebLogic, checks it came back, and **undoes everything by itself if any step fails**.

## Quick start (the four commands)

Run these on the WebLogic server as the `oracle` user, from the folder with the script.

```bash
# 1. What have I got?                      (changes nothing)
./wls-patch.sh inspect

# 2. What is Oracle offering for it?       (changes nothing, needs the MOS login)
./wls-patch.sh latest

# 3. Would it work?                        (downloads only; checks everything; changes nothing on WebLogic)
./wls-patch.sh download /u01/patches/latest --patches latest
./wls-patch.sh preflight /u01/patches/latest

# 4. Do it.                                (backup > stop > apply > start > verify, auto-rollback on failure)
./wls-patch.sh run /u01/patches/latest
```

Or steps 2 to 4 in one go once you trust it: `./wls-patch.sh run /u01/patches/latest --latest`
(it shows the patch numbers it found and asks before touching anything).

If `latest` cannot find the numbers, or Oracle lists extra bundle patches for your installation
(ADF, OPSS, OWSM...), pass them by hand: `--patches 38111111,38555555`. Everything else is the same.

First time only: `cp wls-patch.conf.example wls-patch.conf` and put your My Oracle Support login in
(or in `~/.netrc`, see the file). The detail is below.

## What you do

1. **Find the patch numbers for this quarter.** `./wls-patch.sh latest` asks My Oracle Support,
   by patch name, for the newest **WLS Patch Set Update (PSU)** and **Coherence** patch for the
   release it detected, compares them with what is installed, and prints the numbers (or says you
   are already current). It is deliberately narrow: PSU names follow a strict pattern
   (`WLS PATCH SET UPDATE 12.2.1.4.260715`) so it cannot pick the wrong thing, and it always shows
   you what it found before anything is downloaded.

   What it cannot find: bundle patches for *other* products in the same Oracle home (ADF, OPSS,
   OWSM, SOA...). Those are listed in the *CPU Patch Advisor for Oracle Fusion Middleware*
   (My Oracle Support Doc ID 2806740.2); add them with `--patches`. If `latest` finds nothing at
   all (Oracle changed the search page, or the account has no WebLogic entitlement) it says so and
   you fall back to reading the numbers off that document.

2. **Copy `wls-patch.sh` to the server**, run it as the user that owns WebLogic (usually `oracle`),
   never as root. Put your My Oracle Support login in `~/.netrc` (safest) or in `wls-patch.conf`
   next to the script (see `wls-patch.conf.example`):

   ```bash
   chmod +x wls-patch.sh
   ./wls-patch.sh inspect
   ```

   `inspect` changes nothing. It prints what it found: WebLogic version, current PSU level,
   OPatch version, JDK, domains, which servers are running. If anything is wrong or blank,
   set `ORACLE_HOME`, `DOMAIN_HOME` or `JAVA_HOME` in `wls-patch.conf`.

3. **Download** (only what is missing):

   ```bash
   ./wls-patch.sh download /u01/patches/oct2026 35247514 35251219
   ```

   For each number it asks Oracle which files exist, picks the one for *your* release and platform,
   downloads it, checks the SHA-256, and skips anything already in the folder or already installed.
   If your OPatch is too old for current PSUs it adds the OPatch kit (28186730) by itself.
   No internet on the server? Download the zips on a laptop from support.oracle.com and copy them
   into the folder instead; everything after this is the same.

4. **Check the plan** (changes nothing):

   ```bash
   ./wls-patch.sh preflight /u01/patches/oct2026
   ```

   It unzips the patches, checks each one is for *this* WebLogic release and JDK, checks OPatch is
   new enough, runs Oracle's own conflict check, checks disk space, and prints a `PLAN` section in
   plain English with any advice. Red `[ERROR]` lines must be fixed before it will patch.

5. **Do it:**

   ```bash
   ./wls-patch.sh run /u01/patches/oct2026
   ```

   Or download-and-patch in one go: `./wls-patch.sh run /u01/patches/oct2026 --patches 35247514,35251219`
   (or put `PATCHES=...` in `wls-patch.conf` and just run `./wls-patch.sh run /u01/patches/oct2026`).

   Steps in order: download (missing only), inspect, heal, preflight, **backup**, stop, apply, start, verify.
   It asks once before stopping WebLogic. The last line is either
   `SUCCESS. Applied: ... PSU level now: ...` or an error with the log file path.

   Expect it to take a while: the backup is a full copy of the Oracle home and the
   WebLogic restart is as slow as it always is.

## What it does when something goes wrong

| Problem | What the script does |
|---|---|
| A patch fails to apply | Rolls back the patches it already applied (newest first), restarts WebLogic on the old binaries |
| WebLogic does not start after patching | Stops, rolls back, restarts on the old binaries |
| OPatch rollback itself fails | Restores the backup copy of the Oracle home (`restore`) |
| Patches conflict with something installed | Stops in preflight before changing anything and shows the conflicting patch numbers. This needs a person: Oracle supplies a merged patch, or the old one-off gets rolled back first |
| Patch is for the wrong release / wrong JDK | Stops in preflight: "Wrong download" / "needs JDK ..." |
| MOS login fails / account not entitled / corrupt download | Says which; nothing half-downloaded is kept (SHA-256 checked) |
| OPatch too old | Says so and which patch to download; if the OPatch kit is in the folder it installs it first |
| Stale OPatch lock from a previous crash | Removes it (only if no OPatch is actually running) |
| Leftover `.lok` files stopping a server starting | Removes them (only for servers that are not running) |
| Missing `oraInst.loc` | Creates one next to the Oracle home |
| A server will not stop | Stops and tells you; `--force` kills it |

Everything it runs is logged under `~/wls-patch/runs/<timestamp>/wls-patch.log`
(`~/wls-patch/runs/latest` points at the most recent run). OPatch's own logs are in
`$ORACLE_HOME/cfgtoollogs/opatch/`.

## Individual commands

```
inspect                 what is installed, nothing changed
latest                  newest PSU + Coherence patch numbers for this release (asks MOS)
download <dir> <ids>    fetch missing patches from My Oracle Support (ids, or --patches latest)
preflight <patch-dir>   check + plan, nothing changed
heal                    fix the known stuck states listed above
backup | restore        full tar of ORACLE_HOME + domains / put it back
stop | start            stop/start node manager, admin, managed servers
apply <patch-dir>       patches only (servers must already be stopped)
verify                  patches in inventory, servers up, console answering
rollback [ids]          opatch rollback (last run's patches, or the ids given)
run <patch-dir>         the whole thing with automatic rollback
```

Useful flags: `--dry-run` (print what would be done), `--yes` (no questions, for cron/ssh),
`--force` (kill servers that will not stop), `--json` (machine-readable `inspect`),
`--patches 1,2,3` (download these first), `--latest` (look the numbers up first), `--release 12.2.1.4.0`
(if a patch has several files and the script cannot tell which one you want).

## JDK

Oracle ships a JDK security update with every CPU and expects it installed alongside the PSU.
The script checks the JDK you have is the right *major* version for your WebLogic release
(12.2.1.4 → JDK 8, 14.1.1 → JDK 8 or 11, 14.1.2 → JDK 17 or 21) and refuses to patch if not,
but swapping the JDK is a separate job: install the new JDK, point `JAVA_HOME` at it
(normally in the domain's `bin/setDomainEnv.sh` or wherever your start scripts set it), restart.

## Limits

- OPatch-based WebLogic only: 12.1.3, 12.2.1.x, 14.1.1, 14.1.2. WebLogic 10.3.6 / 12.1.1 use
  BSU, which the script detects and refuses.
- One domain per run (the first registered one unless `DOMAIN_HOME` is set). Servers on other
  machines in a cluster are not touched; patch each machine's Oracle home separately, admin
  server machine first.
- Downloads use Oracle's own `updates.oracle.com` download service, the same mechanism as the
  "wget script" button on the patch page. It needs a My Oracle Support account with a Support
  Identifier that covers WebLogic. If Oracle ever changes that service the script will say the
  login failed; download by hand and carry on from `preflight`.
- `latest` uses the My Oracle Support patch *name* search, which has been stable for years but is a
  web page, not an API. It was tested against a stand-in copy of that page, not the live site, so
  the first real run is the proof: if it prints sensible numbers it works; if it prints nothing,
  use `--patches` with the numbers from the CPU Patch Advisor document.
- Patches that require database schema changes (some ADF/OPSS bundles say "run the Upgrade
  Assistant" in their README) are applied, but the schema step is not automated. The README
  says if it is needed.


---

# apex-patch.sh — upgrade Oracle APEX in the database

APEX lives inside the database, so this runs on the database server as `oracle` (or anywhere
SQL*Plus/SQLcl can connect as SYS). Downloads are public (no My Oracle Support login).

```bash
./apex-patch.sh inspect        # APEX version/schema/type, DB, ORDS, images dir, restore points
./apex-patch.sh latest         # newest release on download.oracle.com vs installed
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

---

# ords-patch.sh — upgrade ORDS (standalone mode)

Runs on the host where ORDS runs, as the ORDS owner. Download is public (`ords-latest.zip`).

```bash
./ords-patch.sh inspect     # product dir, version, Java, config, pools, running?
./ords-patch.sh latest      # downloads ords-latest.zip, unpacks it, tells you the version
./ords-patch.sh preflight   # Java pairing, config, pools, admin password, disk
./ords-patch.sh run         # latest > preflight > backup > stop > ords install --db-only per pool > switch > start > verify
```

- Keeps every release in its own directory (`ords-24.4.0`, `ords-26.3.0`) and points the `ORDS_HOME` symlink at the current one, so rollback is a symlink switch. Start scripts/systemd units keep using the same path.
- Upgrades the ORDS schema in every database pool with Oracle's documented command (`ords --config ... install --db-pool ... --admin-user SYS --db-only --password-stdin`).
- Checks the Java pairing (ORDS 25+ needs Java 17 or 21; 22 to 24 accept 11 too), backs up the config directory, creates a restore point when SQL access and ARCHIVELOG allow, runs `sys.validate_apex` afterwards if APEX is present (Oracle requires that after every ORDS upgrade).
- **Rollback**: symlink back and restart. The schema upgrade in the database stays unless you run `rollback --allow-flashback` (same warning as above: it rewinds the whole PDB).
- Pre-22.1 ORDS (the `java -jar ords.war` era) needs its config migrated first; the script says so and stops.

## Caveats for both

Tested end to end against stand-ins (a fake `sqlplus` with a small in-memory database, a fake `ords`, local copies of the download zips) covering upgrade, failed upgrade, failed verify, rollback, flashback gating, already-current, dry-run and wrong-Java. Not yet run against a real database. The commands and script names are taken from the Oracle APEX 26.2 installation guide and the ORDS 24.4 installation guide. First real run: do `inspect` and `preflight` on a test database first, and keep the restore point until you are happy.
