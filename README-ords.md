# ords-patch.sh — upgrade ORDS (standalone, or deployed in WebLogic)

Runs on the host where ORDS runs, as the ORDS owner. Download is public (`ords-latest.zip`).

```bash
./ords-patch.sh inspect     # mode (standalone / in WebLogic), version, Java, config, pools, running?
./ords-patch.sh plan        # exactly what 'run' would do; 'latest' downloads the zip to learn the exact version
./ords-patch.sh preflight   # Java pairing, config, pools, admin password, disk
./ords-patch.sh run         # latest > preflight > backup > stop > ords install --db-only per pool > switch > start > verify
```

- Keeps every release in its own directory (`ords-24.4.0`, `ords-26.3.0`) and points the `ORDS_HOME` symlink at the current one, so rollback is a symlink switch. Start scripts/systemd units keep using the same path.
- Upgrades the ORDS schema in every database pool with Oracle's documented command (`ords --config ... install --db-pool ... --admin-user SYS --db-only --password-stdin`).
- Checks the Java pairing (ORDS 25+ needs Java 17 or 21; 22 to 24 accept 11 too), backs up the config directory, creates a restore point when SQL access and ARCHIVELOG allow, runs `sys.validate_apex` afterwards if APEX is present (Oracle requires that after every ORDS upgrade).
- **Rollback**: symlink back and restart. The schema upgrade in the database stays unless you run `rollback --allow-flashback` (same warning as above: it rewinds the whole PDB).
- Pre-22.1 ORDS (the `java -jar ords.war` era) needs its config migrated first; the script says so and stops.

### ORDS inside WebLogic

If ORDS is deployed in WebLogic as `ords.war` (with `i.war` for the APEX images) rather than run
standalone, both scripts detect it from the domain's `config.xml` and switch mode:

- `ords-patch.sh`: stops the `ords` app with `weblogic.Deployer`, upgrades the schema per pool, builds the
  new war from the new release (`ords --config <dir> war`, or the stock war if the server uses
  `-Dconfig.url`), replaces the deployed file and redeploys. Rollback puts the previous war back and
  redeploys. Needs WebLogic admin credentials: `WLS_USERCONFIG`/`WLS_USERKEY` files made once with WLST's
  `storeUserConfig`, or `WLS_ADMIN_USER`/`WLS_ADMIN_PASSWORD`.
- `apex-patch.sh`: reads the images directory from `i.war`'s `weblogic.xml`, stops/starts the `ords` app
  with `weblogic.Deployer` around the upgrade, swaps the images directory in place (so `i.war` needs no
  change).
- Patching WebLogic itself with `wls-patch.sh` stops and starts the whole domain, which includes the
  ORDS app; nothing extra to do.

Run `ords-patch.sh inspect`: the first line says `Mode: deployed in WebLogic ...` or `standalone`.

## Caveats

Tested end to end against stand-ins (a fake `sqlplus` with a small in-memory database, a fake `ords`, local copies of the download zips) covering upgrade, failed upgrade, failed verify, rollback, flashback gating, already-current, dry-run and wrong-Java. Not yet run against a real database. The commands and script names are taken from the Oracle APEX 26.2 installation guide and the ORDS 24.4 installation guide. First real run: do `inspect` and `preflight` on a test database first, and keep the restore point until you are happy.
