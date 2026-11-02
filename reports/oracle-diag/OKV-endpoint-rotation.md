# OKV endpoint certificate rotation — quickstart for Gen

**Deadline:** the 9–10 Nov 2025 endpoint certificates expire **9 Nov 2026 14:23 GMT**. Every node must be rotated before then.

Source of the procedure: your runbook (OKV 21.8, 4-node multi-master cluster, 19c RAC endpoints, TDE `KEYSTORE_CONFIGURATION=OKV|FILE`).

## 1. Check where each node is (read-only — run on the node, as the oracle user)

```bash
cd reports/oracle-diag && ./oracle-diag.sh            # full report (~1-3 min)
# or, as audit controls:
cd reports/security-posture && ./security-posture.sh --cis
```

In the report (`REPORT.md`, or `SCORECARD.md` for security-posture) find the **`okv/...`** rows:

- **`SSL_WALLET_LOC`** — ends at `/ssl` = **not rotated**; a path after `/ssl/` = **rotated**. This is the switch test.
- **`OKV_HOSTNAME`** / `UPDATE_TIMESTAMP` — the node last talked to.
- **endpoint certificate `notAfter`** — set `OKV_WALLET_PASSWORD` so the script can read the real date (read via a 600-mode file, never on a command line):
  ```bash
  OKV_WALLET_PASSWORD='...' ./oracle-diag.sh
  ```
  Without it you get the wallet-age heuristic: **WARN ≥ 300 days, CRIT ≥ 365**.
- **CRIT if `SSL_WALLET_LOC` points at a missing `ewallet.p12`.**
- TCP 5696 reachability and `okvutil list` are in the same section.

## 2. Rotate one node at a time (your runbook)

1. Rotate in the Key Vault console.
2. Run `okvutil list -v 4` until `SSL_WALLET_LOC` in `okvclient.ora` moves to a **subfolder of `ssl/`** (the client writes the new wallet into `ssl/19700101000000000000/ewallet.p12` and repoints). The console banner "Certificate rotation in progress" and "Last active = now" do **not** mean it has switched — it runs on the old cert until expiry.
3. Verify:
   - `SSL_WALLET_LOC` is a subfolder, not `/ssl`.
   - `openssl pkcs12 -in <SSL_WALLET_LOC>/ewallet.p12 -nokeys -clcerts | openssl x509 -noout -serial -enddate` (add `-legacy` on RC2 errors; `orapki 19.4` prints no dates).
   - `select inst_id, status, wallet_type from gv$encryption_wallet;` → `OPEN` on every row (works on a mounted standby).
   - standby `MRP0` `APPLYING_LOG`/`WAIT_FOR_LOG` and a non-growing apply lag in `v$dataguard_stats`.
4. Do **not** move/edit `$OKV_HOME/conf/ewallet.p12` (the TDE secret store). Keep the old `$OKV_HOME/ssl/ewallet.p12` until well after 9 Nov for rollback. Do not hand-edit `SERVER=` in `okvclient.ora`; no keystore close/reopen, instance restart or re-enrol as a workaround.

## 3. Re-check

Re-run step 1. The row should read **rotated**, and `notAfter` should be the new certificate's date.

## Which script does what

| Script | Use |
|---|---|
| `reports/oracle-diag/oracle-diag.sh` | the read-only check in step 1 (`okv_endpoint_cert`, `diag_okv`): `SSL_WALLET_LOC` rotated/not, `OKV_HOSTNAME`, cert `notAfter` or age, 5696, `okvutil list` |
| `reports/security-posture/security-posture.sh --cis` | the same checks as audit PASS/FAIL controls, plus `$OKV_HOME/conf/ewallet.p12` listed as do-not-touch |
| `patching/cert-renew/cert-renew.sh` | if a node's endpoint wallet needs rebuilding rather than just the console rotation: `cert-renew.sh inspect okv`, `plan okv`, `preflight okv`, `apply okv`, `verify okv` — with backup and rollback (`BACKUP_KEEP_HOURS`, default 168) |

Both check scripts are read-only (sqlplus selects, file reads, `okvutil list`, TCP probes) and redact passwords by default.

## Gaps / notes

- No script reads the endpoint certificate expiry **without** `OKV_WALLET_PASSWORD`; it falls back to wallet age (300/365 days). Set the password when you want the real date.
- The scripts detect the rotation by parsing `SSL_WALLET_LOC` in `okvclient.ora`; they do not talk to the Key Vault console. The switch still happens the way your runbook describes (`okvutil list -v 4` until `SSL_WALLET_LOC` changes).
- `cert-renew`'s `okv` target inspects/rotates the endpoint certificate; it is separate from the console-driven rotation above, for when the wallet itself must be rebuilt.
