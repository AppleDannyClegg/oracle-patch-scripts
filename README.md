# Oracle patching scripts: WebLogic, APEX, ORDS

Three stand-alone bash scripts for keeping an Oracle middleware stack patched without being an
expert in each product. Same shape everywhere:

| Step | Command | Changes anything? |
|---|---|---|
| look | `inspect` | no |
| what would happen | `plan` | no |
| would it work | `preflight` | no (downloads/unzips only) |
| do it | `run` | yes: backup, stop, apply, start, verify, **automatic rollback on failure** |

| Script | What it patches | Guide |
|---|---|---|
| `wls-patch.sh` | Oracle WebLogic Server 12.2.1.x / 14.1.x (quarterly PSU + Coherence via OPatch, downloads from My Oracle Support) | [README-weblogic.md](README-weblogic.md) |
| `apex-patch.sh` | Oracle APEX in the database (full release upgrades from Oracle's public download site) | [README-apex.md](README-apex.md) |
| `ords-patch.sh` | Oracle REST Data Services, standalone or deployed inside WebLogic | [README-ords.md](README-ords.md) |

Each script has a matching `*.conf.example`; copy it to `*.conf` next to the script only if
auto-detection needs a hint or you want to store credentials. Real `*.conf` files are git-ignored.

Requirements on the server: bash 4+, curl, unzip, tar. The APEX script needs SQL*Plus or SQLcl
with SYS access; the ORDS script needs Java. Run everything as the Oracle software owner, never root.

Logs: every run writes to `~/<script>/runs/<timestamp>/`, with `runs/latest` pointing at the most
recent one. The last line of `run` is either `SUCCESS ...` or an error naming the log file.

## Status

Tested end to end against mocks (fake OPatch, fake My Oracle Support, fake `sqlplus`, fake `ords`,
fake WebLogic deployer, local copies of the download zips) covering upgrade, failed apply, failed
verify, rollback, flashback gating, already-current, dry-run and wrong-Java paths. Not yet run
against real systems. Do `inspect`, `plan` and `preflight` on a test box first.
