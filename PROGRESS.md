# Progress (31 Oct 2026)

Done and committed, one folder each, all using `lib/oracle-lib.sh`:
wls-patch, apex-patch, ords-patch, oracle-diag (standalone, pre-lib), db-health-daily, perf-snapshot,
space-forecast, security-posture, patch-status, db-patch, dg-switchover.

Remaining, in order: rman-ops, db-refresh, account-ops, java-patch, cert-renew,
incident-pack, sr-draft, gg-ops, apex-export.

Then: update `get.sh` (fetch + chmod every script folder and `lib/`), rewrite the top-level
`README.md` index to list every folder, delete this file.

Conventions for the remaining scripts: see the header of `lib/oracle-lib.sh` and any finished
script (e.g. `db-patch/db-patch.sh` for change-making, `perf-snapshot/perf-snapshot.sh` for
read-only reports). Validate with `bash -n`, `shellcheck -S warning -x`, `--help`, and a smoke run
with fakes under the scratchpad. The full per-script specs are in basic-memory:
"Oracle DBA scripts repo - progress and remaining work".
