# tests

Behavioural and static gates for the scripts in this repo. All of them need no database and run
anywhere with bash; the container harness is the only one that needs docker. See the "Gates" section
of the top-level [README](../README.md) for the full description of what each one proves.

Run them all at once with `bash tests/run-all.sh` (or name a few: `bash tests/run-all.sh wls-quarter optchk-gate`). It runs
every offline gate in parallel plus get-patches.ps1 (when pwsh is installed) and the tree-wide shellcheck, then prints
one line per gate with its time and exit code. The docker gates are left out. false-success-gate is the long pole
(about 22 minutes); the rest finish within about 2 minutes.

| Gate | Kind | Proves |
|---|---|---|
| `check-parse.sh` | static | every value option's `case` arm calls `optchk` |
| `optchk-gate.sh` | static | every documented value option runs as the last argument and is not swallowed before `--dry-run` |
| `secret-argv-gate.sh` | static | a credential never reaches argv/environ/log/run dir; it arrives on the claimed route |
| `ru-date.sh` | static | patch-status's RU-date extractors read the real lspatches / registry line shapes (19c yymmdd, 23ai YY.MM with the trailing patch id); an empty date is a silent UNKNOWN |
| `patch-manifest.sh` | behavioural | `patching/patch-manifest.sh` emits the lines `get-patches.ps1` reads, a failing `opatch lspatches` writes no manifest and exits non-zero, and a db/client home's version is found when `sqlplus -V` says nothing (inventory, then install path) - never a silent empty field |
| `get-patches.ps1` | behavioural | `patching/get-patches.ps1` reads that manifest, picks the newest WLS PSU / Stack Patch Bundle / FMW Platform Bundle / Coherence / JDK / Database RU, skips look-alikes, verifies SHA-256, and warns-and-skips (does not abort) a home whose version or MOS release is missing. Needs pwsh |
| `ohs-patch.sh` | behavioural | `patching/ohs-patch/ohs-patch.sh preflight` is READY on a ready standalone OHS home and blocks, each on its own, an OPatch below the README minimum, a DB19C bundle on a plain-line home (KB585169), missing stored node manager credentials, a failed conflict prereq (whose output carries the 'Conflicts/Supersets' header), and a domain with no OHS component; an unreadable ps or a failed lspatches is exit 2, never READY. `run`: backup (read back) then stop, apply, lspatches, start, ports, in that order; refused with nothing stopped or backed up on a blocking/unreadable preflight, `--no-backup`, no `--yes` without a terminal, a WebLogic server from the home, a missing backup dir; already installed is a no-op; a dry run on a zip-only folder changes nothing; a stop not proved (a process left, a failed stop, ps unreadable after it) applies nothing and starts again; a failed or no-op apply, or a home that will not start, is restored from this run's backup, the level proved and started (never recorded applied); a restore that fails is exit 3 with nothing started; no curl skips the port check; `rollback` restores a good run. Fake home only: a real host's preflight is the proof of the layout |
| `wls-patch-conflict.sh` | behavioural | wls-patch preflight's conflict check: a failed `CheckConflictAgainstOHWithDetail` prereq, or any 'Conflict with' line, is a blocking problem even though OPatch's output carries the 'Conflicts/Supersets' header; a superset with no failure is a warning only |
| `wls-patch-discovery.sh` | behavioural | wls-patch's patch discovery from real zips: an SPB or patch one directory deeper than the bare layout is found; `plan --dry-run` sees inside a never-unzipped zip without touching the patch folder; a zip with no patch layout is reported with what it holds, never as 'holds no patch zips' |
| `db-patch-opatch-kit.sh` | behavioural | db-patch's OPatch kit (p6880880) install: a newer kit is swapped in and the old OPatch kept in the run dir; with no unzip on PATH, or a kit that unzips to no runnable opatch, the home keeps its working OPatch and nothing is moved; a kit that is not newer is left alone |
| `okv-rotate.sh` | behavioural | okv-rotate.sh's check/verify exit codes (not-rotated, missing wallet, expiring cert, a wallet not OPEN, a PHYSICAL_STANDBY with no MRP row, a failed sqlplus) and its wait 0/1/2 contract (switched, do-not-proceed, clean-read-still-old) against a fake OKV_HOME |
| `okv-diag.sh` | behavioural | okv-diag.sh probes an explicit `SERVER=host:PORT` on PORT (not the 5696 default); a config with no `SERVER=` is a CRIT, never a clean exit 0; `--okv-home` names the path in the no-config message; and TERM stops the run (rc=143). Plus a static guard against the GNU-only sed BRE `\+`, which BSD sed cannot match - the docker harness runs GNU sed and never signals, so neither is visible there |
| `dry-run-gate.sh` | behavioural | no DDL/DML/flashback/PL-SQL/patch/restart/switch/ggsci verb reaches a tool under `--dry-run` |
| `false-success-gate.sh` | behavioural | a change command that fails does not exit 0 or record a success state |
| `unreadable-gate.sh` | behavioural | a report whose reads failed does not print a clean verdict or exit 0 |
| `oracle-free-container.sh` | end-to-end | the seven read-only reports (the six DB reports plus `okv-diag`, with an okvclient.ora fixture so its OKV half is exercised) against a real Oracle Free instance (needs docker) |

## Running

```bash
tests/check-parse.sh
tests/optchk-gate.sh
tests/secret-argv-gate.sh
tests/ru-date.sh
tests/patch-manifest.sh       # fake Oracle homes + opatch stubs; no database
tests/get-patches.ps1         # pwsh; canned MOS answers, no network
tests/okv-rotate.sh            # fake OKV_HOME + stubs; no database
tests/okv-diag.sh              # local OKV fixtures + a real TERM; no database, no docker
tests/dry-run-gate.sh          # whole tree; [script...] for one
tests/false-success-gate.sh    # whole tree; [script...] for one; --selftest
tests/unreadable-gate.sh       # whole gate; [script...] for one
tests/oracle-free-container.sh # docker
```

## The stub world

`dry-run-gate.sh` and `false-success-gate.sh` build a PATH of stub tools (sqlplus, rman, opatch,
srvctl, dgmgrl, ggsci, escli, ps and the rest) that log their argv and stdin and answer from a canned
table. `tests/dry-run-env/<script>.sh` describes the world a script needs: fake homes and run dirs,
`ARGS_<cmd>`, `FAIL_<cmd>`, `OK_<cmd>`, and the `pattern|answer` table. Set `CASE` (and `CASES_<cmd>`)
to drive an extra named run of one command, e.g. `CASES_stop='ps_unreadable'`.

A command that ended before any tool, or before any changing call, is **NOT-EXERCISED** - not a pass.
Read the NOT-EXERCISED list on every run: a case that moves from `ok` to NOT-EXERCISED is a regression
signal even when the FAIL count does not move.

## `PS_FAIL=1` / `$T/ps.fail`: two gates, two meanings

Both behavioural gates honour a process-list-fails switch, but only one use is a proof:

- **`dry-run-gate.sh`** - the command refuses before any tool call, so the run is reported as
  NOT-EXERCISED. It proves "the command stops on an unreadable process list", not "the outcome changed".
- **`false-success-gate.sh`** - the run is real (`--yes`, no `--dry-run`). A pre-fix script records a
  success state (`stopped=ok`, `applied=`, `verified=1`) on the failing ps; the fix does not. Run the
  gate and env from HEAD against the pre-fix script for the mutation proof. This is what the
  `CASES_<cmd>='ps_unreadable'` cases in `tests/dry-run-env/` do.

The same distinction applies to the gates generally: a green gate is a statement about the paths the
stubs drive. Say **NOT-EXERCISED**, not "pass", for a command the gate could not reach, and hand-prove
what a stub cannot see (`ln`/`mv`/`rm`/`cp` outcomes, a real database).
