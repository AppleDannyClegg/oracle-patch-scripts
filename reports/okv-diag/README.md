# okv-diag.sh — the Oracle Key Vault client check

Read-only. Answers "is this host's Key Vault client healthy, and will TDE still reach it?" without
the rotation workflow: every `okvclient.ora` on the host, the endpoint certificate (age, and
`notAfter` when the wallet password is available), server reachability, `okvutil` connectivity, the
PKCS#11 library, and the database side (`v$encryption_wallet` OPEN per instance). Changes nothing.

## Quick start

```bash
cd reports/okv-diag
./okv-diag.sh
# prints the findings and writes REPORT.md
```

Output under `<output dir>/okv-diag/<host>_<ts>/`: `REPORT.md` (FINDINGS first) + `raw/` + a `.tar.gz`.
Hand `REPORT.md` to Claude with *"this is an okv-diag report; tell me which endpoints are at risk
of losing Key Vault access and the exact rotation steps, in order"*.

## What it checks

- **Every `okvclient.ora`** found under `WALLET_ROOT`, the usual OKV client paths, `OKV_HOME`, or
  `<ORACLE_HOME>/flex_tde_wallet/okv` (or one with `--okv-home DIR`): the config (passwords
  redacted), the client `bin/`, `ssl/` and `lib/`, and the `SERVER=` endpoints.
- **Server reachability**: a 5s TCP probe per `SERVER=host:port` (default 5696). No reachable
  server is a CRIT; some unreachable is a WARN (HA degraded).
- **The endpoint certificate**: `ewallet.p12` under `SSL_WALLET_LOC` - whether `SSL_WALLET_LOC`
  has moved to a subfolder of `ssl/` (rotated) or not, the file age, and, with
  `OKV_WALLET_PASSWORD`, the real `notAfter`. Endpoint certificates live one year; 365 days is a
  CRIT, 300 a WARN, and an unreadable date is a WARN plus the age - never silence.
- **`okvutil list`**: the client's own view of Key Vault. A missing `okvutil` or a failed list is a
  WARN.
- **PKCS#11**: `liborapkcs.so` in `ORACLE_HOME/lib` or `/opt/oracle/extapi/64/hsm/oracle/1.0.0/`.
- **Database TDE**: per instance (or `--sid SID`), `v$encryption_wallet` status, `wallet_root` and
  `tde_configuration`. A keystore not OPEN, or a database that cannot be read, is a finding - a
  failed read is never a clean verdict.

## Options

`--sid SID`, `--okv-home DIR`, `--out DIR`, `--lines N`, `--quiet`, `--no-tar`, `--verbose`.
Config: `okv-diag.conf` (or the shared `oracle.conf`) with `OKV_OUT`, `SQL_CONNECT`, `OKV_HOME`,
and `OKV_WALLET_PASSWORD` (env or config only - it reaches `openssl` through a 600-mode file in the
run dir, never on a command line).

Exit: 2 with a CRIT finding, 1 with a WARN, 0 clean - so a cron caller reads a failed read as
non-zero.

## Rotation

This reports; it does not rotate. For the rotation workflow see
[`operations/okv-rotate`](../../operations/okv-rotate/README.md) and the runbook
[`oracle-diag/OKV-endpoint-rotation.md`](../oracle-diag/OKV-endpoint-rotation.md).
