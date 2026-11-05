# wls-patch.sh — WebLogic patching without needing to be a WebLogic expert

One script, runs on the WebLogic server itself, no agent needed (internet only for the optional downloads).
It works out which WebLogic you have (12.2.1.x or 14.1.x), checks the patches you
downloaded actually fit, backs everything up, stops WebLogic, applies the patches,
starts WebLogic, checks it came back, and **undoes everything by itself if any step fails**.

## Quick start (the four commands)

Run these on the WebLogic server as the `oracle` user, from the folder with the script.

```bash
# 1. What have I got?                      (changes nothing)
./wls-patch.sh inspect

# 2. What would be applied?                (changes nothing; needs the MOS login for --latest)
./wls-patch.sh plan --latest              # or: ./wls-patch.sh plan /u01/patches/latest

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

First time only: `cp wls-patch.conf.example wls-patch.conf`; for `latest`/`download` put a My Oracle
Support token in `~/.mos-token` (see the file). The detail is below.

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
   never as root. For `latest`/`download`, generate a My Oracle Support token (log in to MOS, open
   `https://updates.oracle.com/Orion/GenToken/get_token`, Generate token, 60 minutes) and save it in
   `~/.mos-token`, chmod 600 (or name the file in `wls-patch.conf`, see `wls-patch.conf.example`):

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

## Stack Patch Bundles (SPB)

Oracle increasingly ships a quarter as a **WLS Stack Patch Bundle** (a `WLS_SPB_<version>_<ddMMMyy>`
folder, patch id in the 40-million range) instead of separate PSU zips. It brings its own patches,
its own OPatch upgrade, and its own installer, `SPBAT`.

Put the SPB zip in the patch folder exactly like a patch zip; nothing else changes.

```bash
./wls-patch.sh preflight /u01/patches/oct2026    # names the SPB, runs its precheck when OPatch allows
./wls-patch.sh run /u01/patches/oct2026          # backup > stop > SPBAT apply > start > verify
```

What is different from a normal patch run:

- The SPB is applied by `SPBAT` (`tools/spbat/generic/SPBAT/spbat.sh`), in its `apply` phase, not by
  `opatch apply` one patch at a time. The patches inside the SPB are never applied individually.
- Preflight runs SPBAT's `precheck` phase **only when OPatch is 13.9.4.2.13 or newer** (Oracle's
  requirement for it). On an older OPatch it says it is skipping the precheck: the `apply` phase
  upgrades OPatch itself, from any version.
- An SPB must not be mixed with individual patch zips in the same folder: the individual patches are
  ignored with a warning, because SPBAT applies the bundle as one unit. Use a separate folder for them.
- Rollback of an SPB is Oracle's own `opatch nrollback -idFile binary_patches/rollback_patchlist.txt`,
  which rolls back every patch in present and past bundles. That does **not** undo the OPatch upgrade,
  and does not re-apply overlay patches you added afterwards; the only complete rollback is restoring
  the pre-patch backup (`restore`). The script does the `nrollback` and says this.

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
| A server will not stop | Stops and tells you; `--force` kills it. Stopped means the pid is gone **and** no JVM with that `-Dweblogic.Name` is in `ps` any more (a stop script that returned with its server up, or a server NodeManager restarted under a new pid while the script waited, is "still running after stop", exit 1) |
| An SPB is in the folder with individual patches | Applies the SPB only; says the individual patches were ignored |
| An SPB's SPBAT precheck fails | Stops before anything changes, with the SPBAT output in the log |
| An SPB's SPBAT apply fails | Stops and rolls back: `opatch nrollback -idFile` for the bundle, `restore` if that is not enough |
| `opatch rollback` exits 0 but the patch is still in `opatch lspatches` | Not recorded as rolled back; rollback exits 1 and points at `restore` (same re-read as apply, which trusts the inventory, not the exit status) |

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
apply <patch-dir>       patches only (servers must already be stopped); an SPB goes through SPBAT
verify                  patches in inventory, servers up, console answering
rollback [ids]          opatch rollback (last run's patches, or the ids given); an SPB uses nrollback -idFile
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
- Downloads use Oracle's `updates.oracle.com` patch service with a bearer token, the same mechanism
  as the "wget script" button on the patch page (the password login stopped working in 2026). It
  needs a My Oracle Support account with a Support Identifier that covers WebLogic. If the service
  changes again the script says the token was rejected; download by hand and carry on from `preflight`.
- `latest` reads the Recommended patch list for the WebLogic release from that service (the old
  patch name search is gone). Checked against the live service on 1 Nov 2026: WLS 14.1.2 returned the
  PSU 14.1.2.0.260922 and the Stack Patch Bundle. If it prints nothing, use `--patches` with the
  numbers from the CPU Patch Advisor document.
- Patches that require database schema changes (some ADF/OPSS bundles say "run the Upgrade
  Assistant" in their README) are applied, but the schema step is not automated. The README
  says if it is needed.

## Without internet

The servers have no internet, so `latest`, `download`, `--latest` and `--patches` are for a machine
that has MOS access (set `OFFLINE=1` in `oracle.conf` on the servers and they refuse at once with
the instruction). Download the `p<ID>_<release>_Generic.zip` files there, copy them into one
directory on the server and run `wls-patch.sh run <that-dir>`; `inspect`, `plan` and `preflight`
show what the directory holds before anything changes.
