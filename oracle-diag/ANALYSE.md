# Getting an oracle-diag report analysed by Claude

Claude cannot run on the Oracle servers, so the loop is: run the script on the server, copy the
report to your laptop, give it to Claude, run the commands Claude suggests, feed the output back.

## 1. Run it on the server

```bash
# as the oracle (or weblogic) user
./oracle-diag.sh
```

The last line printed is the report path, e.g. `/home/oracle/oracle-diag/dbprod01_20261031_111559/REPORT.md`.
Next to that directory is `dbprod01_20261031_111559.tar.gz` containing the report and `raw/`.

Useful variations:

```bash
./oracle-diag.sh --days 7            # a problem that started last week
./oracle-diag.sh --threads           # WebLogic/ORDS hanging or slow: adds JVM thread dumps
./oracle-diag.sh --sid PRODDB        # one database only on a shared host
./oracle-diag.sh --lines 500         # more of each log in REPORT.md itself
```

## 2. Copy it off

```bash
# from your laptop
scp oracle@dbprod01:oracle-diag/dbprod01_20261031_111559.tar.gz ~/Downloads/
```

No `scp`? The report is plain text: `cat REPORT.md` in a terminal and copy it from the screen,
or attach it to the ticket and download it from there. REPORT.md alone is usually enough
(typically 200 KB to 2 MB); the tarball matters when Claude asks for a full log.

Before it leaves the estate: the script redacts passwords in copied config files, but the report
still contains hostnames, IPs, service names, usernames, SQL text of running statements and log
lines. Treat it as you would any support bundle sent to Oracle: check your data-classification
rules, and strip anything you are not allowed to send (`grep -n` for customer identifiers in
`raw/*.errors` and the APEX error section if the applications log personal data).

## 3. Give it to Claude

Any of these work; pick what you have.

**Claude Code on your laptop** (best: it can read the tarball, grep `raw/`, and write fix scripts)

```bash
mkdir -p ~/diag && tar -xzf ~/Downloads/dbprod01_20261031_111559.tar.gz -C ~/diag
cd ~/diag/dbprod01_20261031_111559
claude
```

then type: `analyse this oracle-diag report. REPORT.md first, raw/ has the full logs.`

**claude.ai (web or desktop app)**: start a new chat, attach `REPORT.md` with the paperclip (or
drag it in), and write the same sentence. Attach files from `raw/` later if asked. Use a Project
if you will do this regularly, so the previous reports and your fixes stay in context.

**No file upload available**: paste the FINDINGS block and the section you care about. The report
is Markdown, so sections are easy to cut at the `# ` / `## ` headings.

## 4. What to ask

The report already carries an instruction to the analyst at the top, so "analyse this" is
enough. Being specific gets better answers:

- `Users say APEX is slow since Tuesday. Analyse this oracle-diag report with that in mind.`
- `ORDS returns 503 on this box. Find the cause in the report and give me the exact fix.`
- `This is a standby. Is Data Guard healthy? What would I run to confirm?`
- `We patch next weekend. From this report, what should be fixed or cleaned up before patching?`
- `Compare these two reports (before and after the change) and tell me what got worse.`
- `Write the SR text for Oracle Support from the ORA-600 evidence in here, with the adrci commands to package it.`

Ask for output in the shape you need: a ticket update, a change request, a runbook, commands only.

## 5. Act on it, then feed back

Claude will give commands. Run them on the server yourself, paste the output back, and continue.
For anything that changes state (restart, resize, kill session, drop restore point), read the
command before running it and run it in the agreed window; the diag script never changes
anything, but Claude's fixes do.

After the fix, run `./oracle-diag.sh` again and hand Claude the new report with
"this is the report after the fix, confirm it is resolved and list anything still open".

## What Claude gets

- A **FINDINGS** list at the top: the script's own rules (thresholds and log patterns, listed in
  [README.md](README.md)) graded CRIT / WARN / INFO. Claude treats them as leads, not
  conclusions, and is asked to say which are noise.
- The **evidence**, one section per component (host, each database and PDB, APEX, ORDS,
  WebLogic domains, Grid/RAC, GoldenGate, OEM, Exadata, Key Vault, ...), each command shown with
  its output, each log with its error counts, most-frequent messages and tail.
- `raw/`: the same output untruncated, up to 5000 lines of every log, thread dumps if `--threads`.

## If the report is thin

- "sqlplus '/ as sysdba' failed": run as the database owner, or set `SQL_CONNECT` in
  `oracle-diag.conf`.
- Kernel/system log sections say "needs root": allow `sudo -n dmesg` and `sudo -n journalctl`
  for the oracle user, or run once as root.
- A component is missing: set its home in `oracle-diag.conf` (`ORDS_HOME`, `DOMAIN_HOME`, ...),
  see `oracle-diag.conf.example`.
- It took more than ten minutes: something is hung; the per-command timeout keeps the report
  coming, and the section that timed out is itself a finding worth telling Claude about.
