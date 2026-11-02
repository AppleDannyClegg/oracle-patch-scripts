# tests

Behavioural and static gates for the scripts in this repo. All of them need no database and run
anywhere with bash; the container harness is the only one that needs docker. See the "Gates" section
of the top-level [README](../README.md) for the full description of what each one proves.

| Gate | Kind | Proves |
|---|---|---|
| `check-parse.sh` | static | every value option's `case` arm calls `optchk` |
| `optchk-gate.sh` | static | every documented value option runs as the last argument and is not swallowed before `--dry-run` |
| `secret-argv-gate.sh` | static | a credential never reaches argv/environ/log/run dir; it arrives on the claimed route |
| `ru-date.sh` | static | patch-status's RU-date extractors read the real lspatches / registry line shapes (19c yymmdd, 23ai YY.MM with the trailing patch id); an empty date is a silent UNKNOWN |
| `okv-rotate.sh` | behavioural | okv-rotate.sh's check/verify exit codes (not-rotated, missing wallet, expiring cert, a wallet not OPEN, a PHYSICAL_STANDBY with no MRP row, a failed sqlplus) and its wait 0/1/2 contract (switched, do-not-proceed, clean-read-still-old) against a fake OKV_HOME |
| `dry-run-gate.sh` | behavioural | no DDL/DML/flashback/PL-SQL/patch/restart/switch/ggsci verb reaches a tool under `--dry-run` |
| `false-success-gate.sh` | behavioural | a change command that fails does not exit 0 or record a success state |
| `unreadable-gate.sh` | behavioural | a report whose reads failed does not print a clean verdict or exit 0 |
| `oracle-free-container.sh` | end-to-end | the six read-only reports against a real Oracle Free instance (needs docker) |

## Running

```bash
tests/check-parse.sh
tests/optchk-gate.sh
tests/secret-argv-gate.sh
tests/ru-date.sh
tests/okv-rotate.sh            # fake OKV_HOME + stubs; no database
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
