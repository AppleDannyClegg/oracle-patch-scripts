# okv-rotate.sh — walk the OKV endpoint-certificate rotation and prove it happened

Every Oracle Key Vault **endpoint certificate** on this host has a one-year life. Rotating one is a
click in the Key Vault console, and the click is not the step that matters: the console can show
"Certificate rotation in progress" and "Last active = now" while the endpoint keeps running on the
**old** certificate. The endpoint only switches when the Key Vault client writes a new wallet and
repoints `SSL_WALLET_LOC` in `okvclient.ora` at it — which may take several `okvutil list -v 4` runs,
and (in a multi-master cluster) only happens on a run that reaches the node the certificate was
generated on.

This script owns the part around the console click, from Gen's runbook
([`reports/oracle-diag/OKV-endpoint-rotation.md`](../../reports/oracle-diag/OKV-endpoint-rotation.md)):

| Runbook step | Command |
|---|---|
| 1. check where the node is | `okv-rotate.sh inspect` |
| 2. rotate in the console | **manual** — this script cannot do it |
| 3. run `okvutil list -v 4` until it switches | `okv-rotate.sh wait` |
| 4. confirm the new certificate | `okv-rotate.sh verify` |
| 5. confirm TDE is OK (and standby apply) | `okv-rotate.sh verify` |
| record | `okv-rotate.sh report` |

**Read-only.** It never rotates anything and never writes into `$OKV_HOME`. It reads `okvclient.ora`,
reads the endpoint wallet with the wallet password, runs `okvutil list`, and runs `sqlplus` selects.

## Quick start

```bash
cd operations/okv-rotate
cp okv-rotate.conf.example okv-rotate.conf && chmod 600 okv-rotate.conf   # set OKV_HOME, OKV_WALLET_PASSWORD

./okv-rotate.sh inspect               # before: SSL_WALLET_LOC, OKV_HOSTNAME, cert notAfter, TDE OPEN
./okv-rotate.sh plan                  # the ordered steps for THIS node, with the live state filled in
./okv-rotate.sh preflight             # okvclient.ora, okvutil, openssl, password, instances - ready?
# ... rotate this node in the Key Vault console (log in on the node shown as OKV_HOSTNAME) ...
./okv-rotate.sh wait --rotated-from okv01    # okvutil once, then poll until SSL_WALLET_LOC moves under ssl/
./okv-rotate.sh verify                # step 4/5 as assertions for the change record
./okv-rotate.sh report                # REPORT.md + raw/ under $CERT_OUT
```

`apply` = `wait` then `verify`; `run` = `inspect` then `apply`. `backup` snapshots `okvclient.ora` into the
run dir and `rollback` restores it — neither touches `$OKV_HOME`.

Do **one node at a time**, and verify each node before starting the next. On a RAC pair, finish and
verify one node before the other.

## Commands

- **`inspect`** (alias `check`) — the runbook's step 1/4/5 for this host: `SSL_WALLET_LOC` (rotated? a subfolder of `ssl/`
  vs the bare `.../ssl`), `OKV_HOSTNAME`, `UPDATE_TIMESTAMP`, the ewallet and its age, the certificate
  `serial` and `notAfter` (when `OKV_WALLET_PASSWORD` is set; otherwise the 300/365-day age heuristic),
  `gv$encryption_wallet` `status` on every `inst_id` (any `OPEN*` passes — `OPEN_UNKNOWN_MASTER_KEY_STATUS`
  on a mounted standby's PDB rows is normal), and — on a physical standby — the `MRP` process and
  apply/transport lag. Exit **2** CRIT / **1** WARN / **0** clean.
- **`plan`** — the ordered rotation steps for this node, read-only, with the live state and the exact
  commands. The console step is manual.
- **`preflight`** — is this node ready: `okvclient.ora` readable and writable, `okvutil`, `openssl`, the
  wallet password, a database instance to check TDE against.
- **`wait`** — the runbook's step 3, corrected for the **~hourly** config refresh (Gen, 1 Nov 22:32): runs
  `okvutil list -v 4` **once**, then polls `okvclient.ora` keyed on `UPDATE_TIMESTAMP`. Running `okvutil`
  repeatedly does not help — the client only refreshes about once an hour, and only switches on a refresh
  that lands on the node that generated the certificate. Exit:
  - **0** — switched: `SSL_WALLET_LOC` is under `ssl/`, its `ewallet.p12` exists, and `okvutil` ran clean.
  - **1** — stop, do not go to the next node: repointed but the wallet is missing, or `okvutil` failed
    (a failed read is not a confirmed switch), or `okvutil` failed on every run.
  - **2** — reads are fine but still on the old wallet: re-rotate (from the node now shown as `OKV_HOSTNAME`)
    and re-run `wait`; 2–3 re-rotations with no switch → raise a Sev 2 SR.
- **`verify`** — `inspect` with the runbook's assertions escalated: an **unrotated** node is CRIT (the
  switch *is* the thing being verified), as is a wallet that is not `OPEN` anywhere, or a `PHYSICAL_STANDBY`
  with no `MRP` row (redo apply is not running). Exit 2/1/0 as for `inspect`.
- **`apply`** — `wait` then `verify` (the script's half of the rotation; the console click is manual).
- **`backup`** — snapshot `okvclient.ora` (the `SSL_WALLET_LOC` line) into the run dir, for the record.
- **`rollback`** — **advisory only**: prints the manual recovery steps and the backed-up `SSL_WALLET_LOC`. It
  does **not** write into `$OKV_HOME` — restoring the whole `okvclient.ora` would revert `SERVER=`,
  `OKV_HOSTNAME` and `UPDATE_TIMESTAMP` too, which the runbook forbids. Ask Gen/Oracle before repointing.
- **`run`** — `inspect`, then `wait`, then `verify`.
- **`report`** — `inspect` with `--report`: writes `REPORT.md` + `raw/` under `$CERT_OUT` (default
  `~/okv-rotate`).

There is deliberately **no** local certificate-issuing step: the rotation is a console action this script
does not perform, and rebuilding a wallet (`cert-renew.sh apply okv`) is a different, rarer job.

## Options

```
--okv-home DIR        $OKV_HOME (default: discovered)
--ora FILE            okvclient.ora (default: <okv-home>/conf/okvclient.ora)
--node NAME           node label in the report (default: hostname -s)
--rotated-from NAME   the OKV node the console rotation was started from
--timeout SECS        wait: give up after this long (default 3600; the client refreshes ~hourly)
--interval SECS       wait: seconds between okvclient.ora polls (default 60)
--max-runs N          wait: optional cap on polls (default 0 = no cap; rely on --timeout)
--out DIR             report output dir (default $CERT_OUT or ~/okv-rotate)
--report  --dry-run  --yes  --force  --json  --verbose  --run-dir DIR
```

## The rotated? test (why the wallet is not where you expect)

The rotation does **not** overwrite `$OKV_HOME/ssl/ewallet.p12`. The client writes the new wallet into a
**new subfolder** of `ssl/` (seen: `ssl/19700101000000000000/ewallet.p12`) and changes `SSL_WALLET_LOC`
in `okvclient.ora` to point at it. So `SSL_WALLET_LOC` ending at `/ssl` means **not rotated**; anything
after `/ssl/` means **rotated**. That one line is what `wait` polls and `verify` asserts.

`$OKV_HOME/conf/ewallet.p12` is the **TDE secret store** (the Key Vault password and HSM master key
entries), not the endpoint certificate. This script never reads or touches it.

## Don'ts (enforced by the runbook, and by not doing them here)

- Don't move, edit or delete `$OKV_HOME/conf/ewallet.p12` (the TDE secret store).
- Keep the old `$OKV_HOME/ssl/ewallet.p12` until well after the old certificate's expiry (rollback).
- Don't hand-edit `SERVER=` in `okvclient.ora`; the client rewrites the file on each refresh, and the
  database's TDE library reads the same file.
- Don't close/reopen the keystore, restart instances, or re-enrol endpoints as a workaround;
  re-enrolment is a last resort under change control.

## Related

- `reports/oracle-diag/OKV-endpoint-rotation.md` — the runbook in script terms, and which script does what.
- `reports/oracle-diag/oracle-diag.sh` — the host report, including `okv_endpoint_cert` (read-only).
- `reports/security-posture/security-posture.sh --cis` — the same checks as audit PASS/FAIL controls.
- `patching/cert-renew/cert-renew.sh` — rebuilds a wallet (`inspect okv`); not part of the console
  rotation.
