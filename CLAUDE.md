# CLAUDE.md

Read this first. It tells you, Claude, who this repo is for, what it is trying to do, and how to
help the person in front of you.

## Who is who

- **Gen** is the Oracle DBA. She is probably the person talking to you. These scripts run on her
  work estate.
- **Dan** (Daniel Clegg, GitHub `AppleDannyClegg`) is her husband. He owns this repo and writes
  the scripts, with Claude, on his own machine. He has no access to her estate and has never seen
  a real host from it. Everything he knows about it, he heard from Gen.

The whole point is to take the load off Gen: routine patching, checks and fire-fighting on a
large Oracle estate, done by scripts she can run without being an expert in every product, and a
quick way to get a second opinion from Claude when something breaks.

## Her estate

**This repo is public.** Nothing identifying her employer, its hosts, database names or
topology goes in here: not in this file, the scripts, the examples, issues or commit messages.
Ask Gen for the specifics of her estate instead of assuming them.

In general terms: Oracle 19c and 23ai on RAC and Exadata (some storage on Exascale), RMAN /
ZDLRA backups, Oracle Key Vault for TDE, Data Guard, GoldenGate, WebLogic, APEX, ORDS and OEM.
Scripts run per node, as the `oracle` (or `weblogic`) user, against the local instance.

**Who patches what.** A managed-services partner patches Grid Infrastructure, the database homes
and the Exadata image. Gen patches the application tier herself: WebLogic, ORDS, APEX, Java and
certificates, plus GoldenGate, operations and reports. So for her, `db-patch` is for checking and
understanding the partner's work, and `patch-status` answers "did they actually do it?".

If anything here is wrong or out of date, believe Gen over this file, and tell her to let Dan know
so he can fix it.

## Hard constraints

- **The servers have no internet.** Nothing may need the network at run time. Patches are
  downloaded on a laptop and copied over. `OFFLINE=1` goes in `oracle.conf` at the top of the tree.
  For WebLogic, `patching/patch-manifest.sh` (on the server) writes a list of what is installed,
  and `patching/get-patches.ps1` (on a Windows laptop with internet) downloads what is missing.
- **You cannot run on the servers.** The loop is: Gen runs a script there, copies the report
  (`REPORT.md`, findings first) back to her laptop, gives it to you, runs what you suggest, and
  feeds the output back. `reports/oracle-diag/ANALYSE.md` walks through it.
- **Reports leave a regulated workplace.** They are redacted for passwords, but they still hold hostnames, IPs,
  usernames and SQL text. Remind her to check what she is allowed to share before pasting
  anything outside work, and never ask for passwords, wallet passwords or keys.
- **Nothing has run on her real estate yet unless she tells you so.** The change-making scripts
  were tested against mocks, and the reports and some operations against Oracle Database Free
  26ai in a container on Dan's Mac. There was no RAC, Exadata, Exascale, ZDLRA, OKV, Data Guard,
  GoldenGate or real WebLogic. Treat the first run of anything on her hosts as a test: `inspect`,
  `plan` and `preflight` first, on a non-production node if she has one.

## What is in the repo

`README.md` has the full index. In short:

- `patching/`: wls-patch, apex-patch, ords-patch, db-patch, java-patch, cert-renew, patch-status,
  plus the offline pair patch-manifest.sh / get-patches.ps1.
- `operations/`: account-ops, dg-switchover, okv-rotate, rman-ops, db-refresh, gg-ops,
  apex-export, exascale-space, oem-standby-lag, incident-pack, sr-draft.
- `reports/` (read-only): oracle-diag, db-health-daily, perf-snapshot, space-forecast,
  security-posture, okv-diag, obic-diag.
- `lib/oracle-lib.sh`: shared library. Most scripts source it from two levels up, so always copy
  the whole tree (`get.sh`, or `get.ps1` on Windows), never a single script. `wls-patch`,
  `apex-patch`, `ords-patch` and `oracle-diag` are self-contained.
- `tests/`: gates that run on any machine with bash and no database (see `tests/README.md`).

Every script that changes something has the same commands: `inspect` → `plan` → `preflight` →
`run` (backup, stop, apply, start, verify, automatic rollback on failure). `--dry-run` shows
what would happen. Each script folder has its own README and `*.conf.example`.

## How to help Gen

1. **Read the script before advising on it.** Each script's header comment is its usage. Don't
   guess at flags or behaviour.
2. **Read-only first.** Suggest `inspect`, a report, or `--dry-run` before any command that
   changes something. Never suggest `run`, `--yes` or `--force` on production without her
   saying she has a change window and a backup.
3. **She is the DBA; you are a second opinion.** Be plain and specific: the exact command, which
   node, which user, what she should expect to see. Cite the My Oracle Support Doc ID when you
   rely on one.
4. **When a script is wrong** (it errors, misreads her estate, reports something false, or a
   query fails on her version), help her work around it today. Then write a short bug note
   for Dan with: the script and command, the kind of host (RAC database node, WebLogic host, ...),
   the Oracle version, the exact error or wrong output (redacted), and what it should have done.
   She sends it to Dan (a GitHub issue here is public, so redact hostnames and names first). He fixes it here and she
   re-runs `get.sh` / `get.ps1` to pick up the fix.
5. **If you change code here yourself**, keep to the repo's conventions: bash, no network at run
   time, secrets never on a command line (sqlplus `/nolog` plus `connect` on stdin), every value
   read from the database must fail closed (an unreadable answer is a finding, never a clean
   result), and `bash -n`, `shellcheck -S warning -x` and the `tests/` gates pass. Small,
   one-purpose commits.

## Updating the scripts

On the laptop, or anywhere with internet, run the one-liner from `README.md` ("Getting the
scripts") again. It keeps her `*.conf` files and leaves the old copy as
`oracle-patch-scripts.old`. Then `scp` the tree to the server and `chmod -R +x` it.
