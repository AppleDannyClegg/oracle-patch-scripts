# OKV endpoint certificate rotation — quickstart for Gen

**Status (Gen, 1 Nov 2026 22:32):** every prod endpoint is on its new certificate (valid to Oct/Nov 2027) and the console's "rotation in progress" banner has cleared. The old certificates expire **9 Nov 2026 ~14:17–14:23 GMT**; keep the old `ssl/ewallet.p12` files until well after that. To prove it, run `okv-rotate.sh verify` on each node before 9 Nov 14:23 GMT (exit 0 = new certificate, TDE `OPEN` everywhere). This page is the procedure for next time, with the script that now does the checking and waiting.

Source of the procedure: your runbook (OKV 21.8, 4-node multi-master cluster, 19c RAC endpoints, TDE `KEYSTORE_CONFIGURATION=OKV|FILE`) and your follow-up of 1 Nov 22:32 (the client refreshes its config about **once an hour**, not on every `okvutil` run).

The script for this is **`operations/okv-rotate/okv-rotate.sh`** ([README](../../operations/okv-rotate/README.md)). It does steps 1, 3, 4 and 5 below for one node; step 2 is the console click and stays manual. Run it on the node, as the oracle user, one node at a time.

```bash
cd operations/okv-rotate
cp okv-rotate.conf.example okv-rotate.conf && chmod 600 okv-rotate.conf   # OKV_HOME, OKV_WALLET_PASSWORD
```

## 1. Check where the node is (read-only)

```bash
./okv-rotate.sh inspect          # SSL_WALLET_LOC rotated or not, OKV_HOSTNAME, UPDATE_TIMESTAMP, cert notAfter, TDE OPEN, standby MRP
./okv-rotate.sh plan             # the ordered steps for THIS node with the live values filled in
./okv-rotate.sh preflight        # okvclient.ora, okvutil, openssl, wallet password, an instance to check TDE against
```

What it reads:

- **`SSL_WALLET_LOC`** — ends at `/ssl` = **not rotated**; a path after `/ssl/` = **rotated**. This is the switch test.
- **`OKV_HOSTNAME`** / **`UPDATE_TIMESTAMP`** — the Key Vault node last talked to, and when the client last refreshed.
- **endpoint certificate `notAfter`** — read when `OKV_WALLET_PASSWORD` is set (in the 600-mode conf or the environment; it reaches openssl through a 600-mode file, never a command line). Without it you get the wallet-age heuristic: **WARN ≥ 300 days, CRIT ≥ 365**.
- **CRIT if `SSL_WALLET_LOC` points at a missing `ewallet.p12`.**
- `gv$encryption_wallet` on every `inst_id` (any `OPEN*` passes; `OPEN_UNKNOWN_MASTER_KEY_STATUS` on a mounted standby's PDB rows is normal), and on a physical standby the `MRP` process and apply lag.
- Those rows come from the database that **owns** this `okvclient.ora` (its `wallet_root` matches the file's path). With more than one instance on the node and no match you get a WARN naming the SID it used; `--sid` (or `OKV_SID`) picks it explicitly.

Exit code: **2** CRIT, **1** WARN, **0** clean. The same facts appear as `okv/...` rows in `reports/oracle-diag/oracle-diag.sh` (`REPORT.md`) and as audit controls in `reports/security-posture/security-posture.sh --cis` (`SCORECARD.md`).

## 2. Rotate in the Key Vault console (manual)

Log in on the Key Vault node shown as `OKV_HOSTNAME` for this endpoint and rotate its certificate. The console banner "Certificate rotation in progress" and "Last active = now" do **not** mean the endpoint has switched — it runs on the old certificate until expiry.

## 3. Wait for the switch

```bash
./okv-rotate.sh wait --rotated-from okv01     # the Key Vault node you clicked on
```

`wait` runs `okvutil list -v 4` **once**, then polls `okvclient.ora` (every 60 s, up to an hour by default) keyed on `UPDATE_TIMESTAMP`. Running `okvutil` again and again does not help: the client refreshes about once an hour, and it only switches on a refresh that lands on the node that generated the certificate. The new wallet appears in a subfolder of `ssl/` (seen: `ssl/19700101000000000000/ewallet.p12`) and `SSL_WALLET_LOC` is repointed at it.

| `wait` exit | Meaning | Do |
|---|---|---|
| **0** | switched: `SSL_WALLET_LOC` under `ssl/`, its `ewallet.p12` present, `okvutil` ran clean | go to step 4 |
| **1** | **stop, do not start the next node**: repointed but the new wallet is missing, or `okvutil` failed (a failed read is not a confirmed switch) | read the message; keep the old `ssl/ewallet.p12`; raise it before touching another node |
| **2** | reads are clean but still on the old wallet after the timeout | `UPDATE_TIMESTAMP` unchanged: re-rotate from the node in `OKV_HOSTNAME`, or wait about an hour for the next refresh. Changed but still `/ssl`: the refresh hit the wrong node; re-rotate from the node now shown as `OKV_HOSTNAME`. Then run `wait` again (it runs `okvutil` straight after, which is what worked on the last node). 2–3 re-rotations without a switch → Sev 2 SR |

## 4–5. Verify the certificate and TDE

```bash
./okv-rotate.sh verify           # the runbook's step 4/5 as pass/fail; exit 2 CRIT / 1 WARN / 0
./okv-rotate.sh report           # the same as REPORT.md + raw/ under $CERT_OUT (default <output dir>/okv-rotate), for the change record
```

`verify` is `inspect` with the assertions escalated: a node still on `/ssl` is CRIT, a TDE wallet that is not `OPEN` on some instance is CRIT, a `PHYSICAL_STANDBY` with no `MRP` row is CRIT, and a `gv$encryption_wallet` read that fails is a WARN saying the assertion was **not evaluated** (never a pass). `apply` = `wait` then `verify`; `run` = `inspect`, `wait`, `verify`.

By hand, the same checks are: `openssl pkcs12 -in <SSL_WALLET_LOC>/ewallet.p12 -nokeys -clcerts | openssl x509 -noout -serial -enddate` (add `-legacy` on RC2 errors; `orapki 19.4` prints no dates); `select inst_id, status, wallet_type from gv$encryption_wallet;`; standby `MRP0` `APPLYING_LOG`/`WAIT_FOR_LOG` and a non-growing apply lag in `v$dataguard_stats`.

## Don'ts (the script does none of these)

- Never move, edit or delete `$OKV_HOME/conf/ewallet.p12` — it is the TDE secret store, not the endpoint certificate.
- Keep the old `$OKV_HOME/ssl/ewallet.p12` until well after 9 Nov as rollback.
- Do not hand-edit `SERVER=` in `okvclient.ora`; no keystore close/reopen, instance restart or re-enrol as a workaround.
- After the window: leave the Key Vault certificate-expiry alerts **enabled** (Reports > Alerts > Configure; other alert types can be unticked or have their Limit/days changed there). No script in the tree watches OKV expiry day-to-day; oracle-diag and security-posture are on-demand runs, so the console alert is the standing check until the next rotation.
- `okv-rotate.sh backup` snapshots `okvclient.ora` into its run dir; `rollback` is advisory: it prints the manual recovery steps and the backed-up `SSL_WALLET_LOC` and writes nothing. The script makes no write under `$OKV_HOME` and never touches either `ewallet.p12`.

## Which script does what

| Script | Use |
|---|---|
| `operations/okv-rotate/okv-rotate.sh` | the per-node driver above: `inspect`/`plan`/`preflight` before, `wait` for the switch after the console click, `verify` and `report` after; `backup` snapshots `okvclient.ora` into the run dir, `rollback` prints the recovery steps (writes nothing) |
| `reports/oracle-diag/oracle-diag.sh` | the whole-host report; its `okv/...` rows (`okv_endpoint_cert`, `diag_okv`) are the same facts as `inspect`: `SSL_WALLET_LOC` rotated/not, `OKV_HOSTNAME`, cert `notAfter` or age, 5696, `okvutil list` |
| `reports/security-posture/security-posture.sh --cis` | the same checks as audit PASS/FAIL controls, plus `$OKV_HOME/conf/ewallet.p12` listed as do-not-touch |
| `patching/cert-renew/cert-renew.sh` | **`inspect okv` only**: the endpoint wallet's expiry/age in the host-wide certificate list. There is no `plan`/`preflight`/`apply`/`verify`/`rollback` for okv (`apply okv` exits with "unknown target"); the wallet is rewritten by the Key Vault client during the console rotation, not by cert-renew |

All of these are read-only (sqlplus selects, file reads, `okvutil list`, TCP probes) and redact passwords by default; nothing here writes under `$OKV_HOME`.

## Gaps / notes

- No script reads the endpoint certificate expiry **without** `OKV_WALLET_PASSWORD`; it falls back to wallet age (300/365 days). Set the password when you want the real date.
- No script talks to the Key Vault console or REST API; the click is yours. The scripts detect the switch by parsing `SSL_WALLET_LOC` in `okvclient.ora`.
- Nothing watches the endpoint certificate's expiry between runs; the Key Vault console alerts do that. Keep them on.
- `cert-renew`'s `okv` target only inspects. Nothing in the tree rebuilds or rotates the endpoint wallet, by design: the runbook says never hand-edit `okvclient.ora` or touch `conf/ewallet.p12`, and the Key Vault client writes the new wallet itself.
