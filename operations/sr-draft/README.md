# sr-draft.sh — the SR text, drafted from the evidence

Filing a Service Request well is half the battle: product and exact version, the error with its
arguments, when it started and how often, what changed, what is attached, a severity you can
defend. This script writes that from an `incident-pack` directory (best), from an `oracle-diag`
report, or from just the error text, in the MOS template sections, with the search strings and
knowledge documents to check first, plus a prompt that lets Claude review the draft and suggest
the likely cause. No network access; what it cannot find becomes a `TODO:`.

## Quick start

```bash
cd operations/sr-draft
../incident-pack/incident-pack.sh 3-12345678901 --hours 6                 # collect first
./sr-draft.sh --pack <output dir>/incident-pack/3-12345678901_dbhost01_20261031_021500 --prod \
   --business-impact "Online banking login fails for ~40% of users since 02:10; no workaround" \
   --steps "Started after the 02:00 batch; reproduces on every login; restart of ORDS did not help"
# -> <pack>/sr/SR.md, CLAUDE-PROMPT.md, MOS-SEARCH.txt

./sr-draft.sh --report <output dir>/oracle-diag/dbhost01_20261031_090000 --error "ORA-04031: unable to allocate ..."
./sr-draft.sh --error "ORA-07445: exception encountered: core dump [kglLockHandle()+34] ..." --sid PRODDB --severity 1
```

## What it extracts

- **Headline error**: the one you gave, else the most serious code found (ORA-600/7445/700,
  4031/4030, 257, 1578, 494, 29770, 3113, 12514, OutOfMemory, BEA-000337 …), else the most
  frequent. ORA-600/7445 first arguments are pulled out for the search strings.
- **Error statistics** over the pack's alert/listener/WebLogic/ORDS/GoldenGate windows and your
  text: every `ORA-/TNS-/BEA-/ORDS-/OGG-/PLS-/RMAN-/DGM-/CRS-…` code and Java exception, with
  count, first and last timestamp (from the line, or the last timestamp line before it) and a
  sample line.
- **ADR problem keys** from `adrci show problem` / `v$diag_problem` in the pack.
- **Product, version, platform, patch level** from `FACTS.txt` (DB version, RU/OJVM from
  `dba_registry_sqlpatch` and `opatch lspatches`, WebLogic + JDK, ORDS, APEX, GoldenGate,
  Exadata image, OS, listeners); from an oracle-diag report what it printed; with nothing else,
  live from `sqlplus`/`opatch` on the host.
- **Recent changes**: `opatch lsinventory` "applied on" dates, the last `sqlpatch` rows,
  `rpm -qa --last`, `yum history`, instance startup time, WebLogic deployments, host uptime.
- **Diagnostics attached**: the pack's directories with file counts, the tarball name and its
  sha256 file, the TFA collection when there was one.
- **Severity**: `--severity 1-4`, default 2 for `--prod` (prod/prd/live in the DB or host name
  counts), 3 otherwise, each with MOS's definition so the justification is in the right words.

## Output

- `SR.md`: Problem Summary, Problem Description, Error Codes / Messages (table), Steps to
  Reproduce, Business Impact and Severity, Environment, Recent Changes, Diagnostics Attached, MOS
  search strings, Knowledge documents. `TODO:` marks what only you know; `>` lines are notes for
  you, not for the SR. The script prints how many TODOs are left.
- `MOS-SEARCH.txt`: the search strings (`ORA-600 [arg1]`, `ORA-600 [arg1] 19.23`, problem keys,
  `<code> <product> <version>`, bug numbers seen in traces) and the documents: 153788.1 (ORA-600/
  7445 lookup tool), 1088239.1 (master note for internal errors), 452358.1 / 1363422.1 (ADR
  incident packages), 1050693.1 (hang/performance), 1374367.1 (AHF/TFA collections), 2118136.2
  (patch list), and the SRDC note for the error type. Document titles are from memory; the IDs are
  what to search.
- `CLAUDE-PROMPT.md`: the review prompt with SR.md, FACTS, error statistics, the alert window,
  the oracle-diag findings, the pack layout, trace and session excerpts inline. Paste it to Claude.

## Options and config

`--pack DIR`, `--report DIR`, `--error "…"` (repeatable), `--error-file FILE`, `--sid`,
`--product db|wls|ords|apex|gg|exa|gi`, `--severity`, `--prod`/`--nonprod`, `--business-impact`,
`--title`, `--steps`, `--contact`, `--out`, `--verbose`. Config in `sr-draft.conf` (see the
example: `SR_CONTACT`, `SR_CSI`, `SR_COMPANY`, `SR_ENVIRONMENT`, `SR_OUT`) or the shared
`oracle.conf`. Needs `lib/oracle-lib.sh` one folder up.

Tested on an incident-pack built from fakes (ORA-600 + ORA-257 + a WebLogic OutOfMemory in the
same window), on its oracle-diag report alone, and on error text alone; not yet on a real SR.
