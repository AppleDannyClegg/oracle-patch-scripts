# ohs-quarter.sh — one outage brings an OHS 12.2.1.4 home CPU-current

`ohs-quarter.sh` applies the whole quarterly set for an Oracle HTTP Server 12.2.1.4 home (with a DB Client
19c) in **one** outage: one backup phase, one stop, one start. It has no patch logic of its own. It
calls `java-patch.sh`, `wls-patch.sh`, `dbclient-upgrade.sh` and `ohs-patch.sh` in a fixed order.
`ohs-quarter-stage.sh` sorts a `get-patches.ps1` download into the folders `ohs-quarter.sh` reads.

Everything here is taken from the two scripts' headers. Those headers are the reference, and `--help` prints them.

## The set, and the folders

One folder per step, under one patch root. The folder names carry the apply order:

| folder | what | applied by |
|---|---|---|
| `jdk/` | Java SE 8 (one `*.tar.gz`) | java-patch.sh |
| `wlspsu/` | WLS PSU | wls-patch.sh |
| `dbclient/` | DB Client 19c installer 34761383 (12c -> 19.14) | dbclient-upgrade.sh |
| `dbclientru/` | FMW DBCLIENT RU | ohs-patch.sh |
| `webgate/` | OAM WebGate DB19c (needs DBCLIENT for FMW 19.29 or later, so it comes after the RU) | ohs-patch.sh |
| `oss/` | OSS 19C bundle | ohs-patch.sh |
| `ohs/` | OHS (NATIVE) DB19c bundle | ohs-patch.sh |
| `fmwbp/` | FMW Platform BP | ohs-patch.sh |
| `jdbc/` | JDBC | ohs-patch.sh |
| `libovd/` | LibOVD | ohs-patch.sh |
| `fmwthirdparty/` | FMW third-party | ohs-patch.sh |
| `perl/` `libdms2/` `libiau/` | PERL, LIBDMS2, LIBIAU | ohs-patch.sh |
| `cloningspu/` | Cloning SPU | ohs-patch.sh |
| `rda/` | RDA (see below) | ohs-patch.sh |

The patch numbers are the October 2026 row of MOS Doc 2806740.2, listed in the head of `ohs-quarter.sh`.
They change every quarter, and MOS has no query that returns them. So each quarter, write that quarter's
numbers into a file, one `<number> <folder>` per line (`#` comments). Pass the same file to
`get-patches.ps1 -OhsSet <file>` and to `ohs-quarter-stage.sh --map <file>`. Do not edit the numbers into a
copy of a script.

**RDA is unverified.** Nobody here has read its README, so it is not known whether it is an OPatch patch. If
it is not, `ohs-patch.sh` preflight refuses it before the outage ("no patch in <dir> ..."). Then install it
by hand and pass `--skip rda`.

**Every folder must be there, or be named in `--skip`.** A missing or empty folder is not applied, and the
script will not decide that for you. It stops before anything changes and prints the `--skip` list to add.
Naming a folder in `--skip` that has content is refused too.

## The order you run it in

1. **Fetch the scripts**: `get.ps1` on the Windows machine with internet, and the same tree on the server
   (`get.sh`, or a copy of the tree with its `lib/`). The root README's "Getting the scripts" has the lines.
   Run the server side as the Oracle software owner, never root.
2. **On the server, write the manifest** (read-only, no internet needed):
   `patching/patch-manifest.sh` writes `manifest-<host>.txt` (`--out FILE` to choose).
3. **On the Windows machine, download the patches:**
   ```powershell
   .\get-patches.ps1 -Manifest .\manifest-<host>.txt -OhsSet .\ohs-set.txt -PlanOnly   # what it would fetch
   .\get-patches.ps1 -Manifest .\manifest-<host>.txt -OhsSet .\ohs-set.txt             # fetch it
   ```
   It needs a MOS token: log in to My Oracle Support, open
   `https://updates.oracle.com/Orion/GenToken/get_token`, press Generate token (valid 60 minutes) and save it
   as `%USERPROFILE%\.mos-token` (or pass `-TokenFile`). Every file is SHA-256 checked. A number the home
   already has is not downloaded.
4. **Copy the download tree to the server.**
5. **Stage it** into a new patch root. `get-patches.ps1` files downloads by patch kind (`wls/ spb/ db/ ohs/
   jdk/ dbclient/ ...`), which is not this runbook's layout:
   ```bash
   patching/ohs-quarter/ohs-quarter-stage.sh plan <download-dir> <patch-root> [--map ohs-set.txt]   # changes nothing
   patching/ohs-quarter/ohs-quarter-stage.sh run  <download-dir> <patch-root> [--map ohs-set.txt]   # moves the files
   ```
   It reads the patch number from each `p<number>_<release>_<platform>.zip` and puts the file in that
   number's folder. It ends by naming the folders that are still empty and the exact `--skip` list
   `ohs-quarter.sh` would need. Leaving them out is your call, made by typing `--skip`.
6. **Dry run:**
   ```bash
   patching/ohs-quarter/ohs-quarter.sh <patch-root> --dry-run [--skip ...]
   ```
   `--dry-run` is passed to every child, so each one does its own dry run.
7. **The real run, in the change window:**
   ```bash
   patching/ohs-quarter/ohs-quarter.sh <patch-root> [--skip ...] [--remove-12c IDS] [--keep-patches IDS]
   ```
   It runs every child's preflight first, then asks once for the whole outage (`--yes` skips the question; with
   no terminal and no `--yes` it refuses). Then: backup, stop, apply in the order above, start, verify.
   The last line is `OHS QUARTER OK` (or `OHS QUARTER OK, PARTIAL BY REQUEST` with the `--skip` list).

## Staging: what it refuses

`ohs-quarter-stage.sh` moves nothing until every file has a destination and every destination is clear. It
refuses, before any change:
- a patch zip whose number is not in the table (`--leave-unknown` leaves it where it is and lists it instead)
- two different files for one destination name, or more than one JDK tarball
- a destination folder that already holds something else. `ohs-patch.sh` applies every patch in its folder,
  so last quarter's zip left there would be applied again.

A JDK is the one `*.tar.gz`; the zip it was unpacked from is left. A zip under `spb/` whose number the table
does not name is a WLS Stack Patch Bundle. It is left where it is and named, because the OHS home takes the WLS
PSU instead. `--copy` copies instead of moving (it needs the space twice).

`ohs-quarter.sh` itself refuses a patch root that still holds `wls/`, `db/` or `spb/`: that is an unsorted
download tree, so stage it first.

## The 12c Database Client patches: `--remove-12c` and `--keep-patches`

The 19c installer step refuses while any installed patch is neither removed nor kept:
- `--remove-12c IDS` (comma list): the 12c Database Client patches to roll back before the 19c installer.
  Passed to `dbclient-upgrade.sh` as `--remove-patches`. It rolls back only the ids named, after the backup
  and the stop, proves each gone, and restores on failure. Default: none.
- `--keep-patches IDS` (comma list): patches in the home that you have checked are **not** 12c Database
  Client patches. Passed to `dbclient-upgrade.sh`, which takes them on your word.

## Other options

| Option | Meaning |
|---|---|
| `--patch-root DIR` | the staging root (default `OUTPUT_DIR` if set, else `/u01/patches`; or the positional argument) |
| `--oracle-home DIR` | the OHS home, passed to every child |
| `--java-home DIR` | the JDK to replace (java-patch and wls-patch) |
| `--run-dir DIR` | this outage's run dir (default `$RUN_BASE/<stamp>-ohs-quarter`) |
| `--backup-dir DIR` | where the backups go (wls-patch and the installer) |
| `--skip LIST` | folders this outage deliberately leaves out, comma list |
| `--no-cacerts` | do not carry CA aliases across (java-patch) |
| `--force` | passed to java-patch and wls-patch, the two children that have one |
| `--yes`, `--dry-run` | as the children |

## Failure and rollback

The flow is:
1. preflight every present child
2. one confirmation
3. one backup phase
4. stop once
5. apply in order
6. start once
7. verify all

A failure in preflight, the confirmation, the backup or the stop ends the run with nothing patched
("nothing changed" / "nothing patched"), exit 1.

On any failure **after the backup** (an apply, the start or a verify), the script stops the components and
restores every child that was attempted, in reverse order. The opatch rows and the installer go back to the
one shared home+inventory backup, the WLS PSU to wls-patch's own backup, and the JDK through java-patch's
rollback. Then it starts once.

| Exit | Meaning |
|---|---|
| 0 | applied and verified (`OHS QUARTER OK`) |
| 1 | refused or failed. If it failed after the backup, the restore worked and the home is back where it was. If the outage's stop failed, nothing was patched and the components were started again |
| 3 | **recovery did not finish**: a restore failed, or the stop before the restores did (then nothing is restored), or the start after them did. Also when the outage's stop failed and starting the components again failed too (nothing was patched, but a component is DOWN). The components are NOT started and the home may be part-patched: fix it by hand from the backups the run made (the shared one is `<run-dir>/backup`) |

The shared backup is under the run dir's `backup/`. The run dir's `state` file records the patch root, what was
applied and what was left out.
