# incident-pack.sh — one tarball with everything Oracle Support will ask for

The first SR update is always "please upload the alert log, the incident package, the trace
files, an AWR for the period, OSWatcher, opatch lsinventory…". This script collects all of it for
one incident window into a directory with a `MANIFEST.md`, tars it, splits it for the 2 GB MOS
upload limit, and prints the sha256. Read-only, apart from the optional dumps you ask for.
Runs as the Oracle software owner; `sr-draft.sh` turns the result into the SR text.

## Quick start

```bash
cd incident-pack
./incident-pack.sh 3-12345678901 --hours 6                    # the last 6 hours, everything detected
./incident-pack.sh ORA600-kdsgrp1 --since "2026-10-31 02:00" --until "2026-10-31 04:00" --sid PRODDB --awr
./incident-pack.sh 3-12345678901 --component wls --threads    # WebLogic only, three thread dumps 10 s apart
./incident-pack.sh 3-12345678901 --hang --yes                 # database hang: hanganalyze 3 + systemstate 258
```

Output: `~/incident-pack/<SR>_<host>_<ts>/` and `<SR>_<host>_<ts>.tar.gz` (+ `.partNN` above 2 GB
or with `--split`), `.sha256` next to it. `MANIFEST.md` lists the facts and every file;
`FACTS.txt` is the machine-readable summary `sr-draft.sh` reads.

## What goes in

| dir | content |
|---|---|
| `00_oracle-diag/` | the read-only health report (`../oracle-diag/oracle-diag.sh`) with its FINDINGS; `--no-diag` skips it |
| `tfa/` | `tfactl diagcollect -all -from .. -to ..` when AHF/TFA is installed (DB, GI, OS, OSWatcher for the window); then the alert/trace/host windows below are left to it. `--no-tfa` to collect directly instead |
| `db/<sid>/sql/` | instance, non-default parameters, registry + sqlpatch + invalid objects, sessions/waits/blockers, locks + long ops, scheduler failures in the window, storage/FRA/archive dests/redo, `v$diag_alert_ext` errors in the window, `v$diag_problem`/`v$diag_incident`, Data Guard, RAC |
| `db/<sid>/alert/` | the alert log lines inside the window (`.window`) and the full alert log (last `--cap-mb`) |
| `db/<sid>/traces/` | every trace file the windowed alert log names (`Errors in file ...`, 50 max); `traces_recent/` the .trc files modified in the window (30 max) |
| `db/<sid>/adr/` | `adrci show problem/incident` and `ips pack problem <id>` zips for the newest 5 problems |
| `db/<sid>/pfile/` | `create pfile from spfile` (or `v$spparameter` when that fails) |
| `db/<sid>/opatch/` | `opatch lsinventory`, `opatch lspatches` |
| `db/<sid>/awr/` | with `--awr`: AWR text for the snapshots spanning the window, ASH text for the window |
| `db/<sid>/hang/` | with `--hang --yes`: `oradebug hanganalyze 3` twice, `dump systemstate 258`, and the trace files (RAC: `-g all`) |
| `db/listener/` | listener log window, `lsnrctl status`, `listener.ora`/`sqlnet.ora`/`tnsnames.ora` |
| `wls/<domain>/` | `config.xml`, jdbc/jms/security modules, `setDomainEnv.sh`, `nodemanager.properties` (all redacted); per server: `<server>.log` window, `.out`, rotated logs, access log, diagnostic logs, `.dmp` files; JVM flags/uptime/heap; with `--threads` three `jcmd Thread.print -l` 10 s apart and a class histogram; with `--heap-dump --yes` a `GC.heap_dump` |
| `ords/` | config XML/properties (redacted, wallets excluded), logs modified in the window, `journalctl -u ords` for the window, process + JVM facts, HTTP codes |
| `db/<sid>/sql/apex_*.txt` | per PDB with APEX: version, instance parameters (no secrets), `apex_workspace_activity_log` errors in the window, debug messages, the service accounts' status |
| `gg/` | `ggsci info all / info * detail / send * status / view ggsevt`, `ggserr.log` window, reports and discards modified in the window, parameter files, trail sizes; MA deployment logs |
| `exadata/` | `imageinfo/imagehistory`, `dbmcli`/`cellcli list alerthistory` since the window start, `dcli` across `~/cell_group` when present |
| `host/` | system/limits/disk/ps/net/sysctl/packages, `dmesg`, `journalctl -p warning` for the window, OOM/segfault/I/O-error grep, `/var/log/messages` window, `sar` per day in the window, OSWatcher archive files modified in the window (`OSW_ARCHIVE` or the AHF/common paths) |
| `extra/` | `EXTRA_FILES` and the `EXTRA_LOGS` windows |

Log windows are cut by timestamp (alert ISO, listener `DD-MON-YYYY`, WebLogic `####<Mon d, yyyy, h:mm:ss AM>`,
syslog); continuation lines stay with their timestamped line. Any single file larger than
`--cap-mb` (100) is kept as its last N MB with a note on top. Passwords and `user/pass@` strings are
redacted in copied config files and logs (`--no-redact` keeps them). Hang dumps, heap dumps and the
`create pfile` are the only things that touch the system; the two dumps need `--yes`.

## Options and config

`--since`, `--until`, `--hours`, `--sid`, `--component db,wls,ords,apex,gg,host,exa`, `--awr`,
`--threads`, `--heap-dump`, `--hang`, `--no-diag`, `--no-tfa`, `--split`, `--out`, `--cap-mb`,
`--no-redact`, `--dry-run`, `--yes`, `--verbose`. Config in `incident-pack.conf` (see the example)
or the shared `oracle.conf`. Needs `lib/oracle-lib.sh` and `oracle-diag/` one folder up.

Tested against a fake Oracle home (sqlplus/adrci/opatch/lsnrctl/jcmd), an alert log with
`Errors in file` lines, listener and WebLogic logs, an OSWatcher archive and the real
`oracle-diag.sh` (windows, trace capture, size cap, ADR packing, AWR/hang paths, redaction,
manifest, tarball, dry-run); not yet on a real host.
