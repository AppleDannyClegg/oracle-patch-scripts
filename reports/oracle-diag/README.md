# oracle-diag.sh — read-only server diagnosis for off-box analysis

The patch scripts change things. `oracle-diag.sh` changes nothing: it runs on any Oracle host and
writes one Markdown report that you copy off the server and hand to Claude (Claude cannot run on
the servers themselves). It covers the host (memory, swap, hugepages, disk, inodes, limits, network,
OOM kills, failed units), every running database (listener, alert log, ADR incidents, tablespaces,
FRA, ASM, sessions, waits, backups, restore points, Data Guard, TDE/Key Vault, Database Vault,
audit, scheduler, invalid objects, per-PDB checks), APEX (release, accounts, jobs, page errors,
images-vs-database version), ORDS (config with passwords redacted, pools, logs, endpoint and TLS
check), WebLogic (homes, PSU level, domains, servers configured vs running, data sources,
deployments, certificates, server logs, node manager, admin ready-check) and whatever else it finds:
Grid Infrastructure / RAC / ASM, Data Guard broker, RMAN and ZDLRA, GoldenGate (classic and
Microservices), Enterprise Manager agent and OMS, AHF/TFA, Exadata (cellcli/dbmcli), Key Vault
client, Audit Vault agent, Connection Manager, OHS, OUD/OID, Forms/Reports, OBIEE/OAS, Tuxedo,
TimesTen, ODA, Secure Backup, and presence of EBS, PeopleSoft, Siebel, Hyperion, ODI, SOA/OSB,
OAM/OIM, WebCenter, FLEXCUBE, OBP and OFSAA.

```bash
# on the server, as the oracle (or weblogic) user - root not needed
./oracle-diag.sh                       # ~1-3 minutes; prints the report path and the findings
./oracle-diag.sh --days 7 --threads    # look back a week, add JVM thread dumps
./oracle-diag.sh --sid PRODDB --pdb APEXPDB --skip wls
```

It leaves `~/oracle-diag/<host>_<time>/REPORT.md` (plus `raw/` with the untruncated logs and command
output) and a `.tar.gz` of the lot. Copy the tarball off (`scp`), then give Claude the REPORT.md or
the whole archive and say **"analyse this oracle-diag report"** (step by step in [ANALYSE.md](ANALYSE.md)). The report starts with a FINDINGS
list from the script's own rules (disk/FRA/tablespace thresholds, locked APEX/ORDS accounts,
expired passwords, ORA-600/4031/257/1555 in the alert log, Data Guard lag, missing backups, OOM
kills, stuck threads, expiring certificates, offline cluster resources, GoldenGate abends and lag,
agent not uploading...) and then the evidence section by section, so Claude can confirm or dismiss
each finding and spot what the rules missed.

Passwords in copied config files (ORDS pools, WebLogic, Key Vault, JDBC URLs) are redacted by
default; `--no-redact` keeps them. Nothing it runs writes to the database or the middleware:
`sqlplus` selects, `lsnrctl status`, `opatch lspatches`, `crsctl stat`, `ggsci info all`,
`emctl status`, `cellcli list`, `dgmgrl show`, `rman show/list/report`, `curl` and file reads.
Things that need root (`dmesg`, `journalctl`, `ocrcheck`, `odacli`) run through `sudo -n` when
allowed and are skipped with a note otherwise. Every external command runs under a timeout so a
hung instance cannot hang the report.

## Options

| Option | Meaning |
|---|---|
| `--out DIR` | where to write (default `~/oracle-diag`) |
| `--days N` | log look-back, default 3 |
| `--lines N` | lines of any one log kept in REPORT.md, default 200 (`raw/` keeps up to 5000) |
| `--sid SID` | only this database (default: every running instance in `/etc/oratab`) |
| `--pdb NAME` | make sure this PDB is checked (open PDBs are found anyway) |
| `--skip host|db|apex|ords|wls` | leave a component out (repeatable) |
| `--threads` | add `jcmd Thread.print` + heap info for running WebLogic / ORDS JVMs |
| `--no-redact` | keep passwords in copied config files |
| `--no-tar` | leave the directory only |
| `--quiet` | no progress on the terminal |

Config: `oracle-diag.conf` next to the script or `~/.oracle-diag.conf` (see `oracle-diag.conf.example`);
`wls-patch.conf`, `apex-patch.conf` and `ords-patch.conf` next to the script are read as well.

## What the FINDINGS rules look for

- **Host**: filesystem ≥85/95 %, inodes ≥90 %, RAM <10 % available, swap >50 % used, load >2×CPUs,
  nofile <65536, THP `[always]` on a DB host, OOM kills, I/O errors, failed systemd units, >500
  CLOSE-WAIT sockets, OSWatcher absent.
- **Database**: instance in oratab with no pmon, no listener / no services, sysdba login failing,
  tablespace ≥90/97 % of max, FRA ≥85/95 %, ASM diskgroup ≥85 % or offline disks, processes/sessions
  ≥80/95 %, blocking >60 s, archive destination errors, hot-backup mode, datafiles needing recovery,
  >12 log switches/hour, PGA over-allocation, PDB not READ WRITE, NOARCHIVELOG, registry components
  invalid, no DB backup in 2/7 days, failed RMAN jobs, guaranteed restore points >7 days, Data Guard
  lag ≥30 min or gaps, no MRP on a standby, >200 archivelogs unbacked, TDE keystore not open, locked
  or expired APEX/ORDS accounts, passwords expiring within 14 days, public users on an expiring
  profile, >100 failed logons/day, aud$ >5M rows, failed scheduler jobs, invalid objects, outstanding
  alerts, AWR snapshots stale, auto stats off, >200 stale tables, alert-log patterns (ORA-257, 1555,
  60, 4031/4030, 20, 1653/1654, 600/7445, checkpoint not complete, instance termination, ORA-28365/
  28374 wallet), ADR incidents, RMAN `list failure`, ZDLRA configured but no SBT backup.
- **APEX**: component not VALID, broken APEX jobs, >50 page errors/day, invalid objects in the APEX
  schema, mail queue errors, images-on-disk version ≠ database version, several APEX schemas left.
- **ORDS**: not running, 503/404/no answer at the URL, ORA-28000/28001/01017 or TNS errors in the
  log, pool exhaustion, OutOfMemoryError, config files not owned by the ORDS user, images dir missing.
- **WebLogic**: no server JVM, Node Manager down, servers configured but not running (info), stale
  OPatch lock, PSU >200 days old, Demo keystore in use, TLS certificate expired / <30 days,
  OutOfMemory, stuck threads, too many open files, BEA-310003 low heap, deployment failures, JDBC
  pool failures, server FAILED, heap dumps and hs_err files, admin `/weblogic/ready` not 200.
- **Grid / RAC**: resources with TARGET=ONLINE not ONLINE, crsctl check failures, srvctl "not
  running", node eviction messages, ASM rebalance (info).
- **GoldenGate**: Manager down, ABENDED/STOPPED extracts and replicats, lag ≥15 min.
- **OEM**: agent not Running and Ready, last upload >1 h, heartbeat not Ok, OMS not Up.
- **Others**: AHF/TFA daemon down or repository full, Exadata critical alerts / disks not normal, Key
  Vault servers unreachable on 5696, Audit Vault agent down, mod_wl_ohs cannot reach WebLogic, OHS
  configured but no httpd, >20 day-old frmweb processes, ODA failed jobs, OSB failed jobs.

Everything else is evidence for the analyst; the rules are deliberately simple and a human (or
Claude) should read the sections rather than trust the list alone.
