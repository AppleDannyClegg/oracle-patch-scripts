# cert-renew.sh — every certificate on the host, and the renewal of one

Certificates expire on a Saturday. This script lists every TLS certificate an Oracle host depends
on, sorted by days left, reading both the configured store **and** what the port really serves
(they differ when a renewal was never activated). Then it renews one target from your new
cert + key + chain: builds the keystore or wallet, backs the old one up, switches the product
config, restarts what you allow, and proves with `openssl s_client` that the port serves the new
serial. Runs as the Oracle software owner.

## Quick start

```bash
cd cert-renew
cp cert-renew.conf.example cert-renew.conf && chmod 600 cert-renew.conf   # keystore/wallet passwords, WebLogic creds
./cert-renew.sh inspect                                  # the table; add --report for REPORT.md + exit code for cron
./cert-renew.sh csr dbhost01 --cn dbhost01.bank.example --san dbhost01,dbhost01-vip   # key + CSR for the CA
./cert-renew.sh plan wls:base_domain:ms1 --cert issued.pem --key ~/cert-renew/csr/dbhost01/dbhost01.key --chain chain.pem
./cert-renew.sh run  wls:base_domain:ms1 --cert issued.pem --key ... --chain chain.pem --restart
```

## What inspect finds

| kind | source | how it is read |
|---|---|---|
| `wls` | every SSL-enabled server in every domain's `config.xml` | identity keystore (custom or demo) via `keytool`, plus the SSL port live |
| `nm` | `nodemanager.properties` | custom identity keystore, plus the NodeManager port live |
| `ords` | `standalone.properties` (`standalone.https.cert`, legacy `ssl.cert`) | the PEM, plus the HTTPS port live; no cert + https port = generated self-signed |
| `listener` | `WALLET_LOCATION` in `listener.ora`/`sqlnet.ora` of every listener/DB/grid home | `ewallet.p12` with `WALLET_PASSWORD` (openssl), else `orapki wallet export`; every TCPS port live |
| `ohs` | `ssl.conf` of each OHS instance (`SSLWallet`, `VirtualHost` port) | wallet as above, port live |
| `cacerts` | every JDK on the host | one row per JDK: count, expired and soon-expiring CA aliases |
| `okv` | `ssl/cert.pem` under `OKV_DIRS`, `OKV_HOME`, `WALLET_ROOT/okv`, common paths | the endpoint certificate (TDE stops when it expires) |
| `gg` | `etc/ssl/*.pem` under GoldenGate MA deployments | PEM files |
| `apex` | `WALLET_PATH` instance parameter of every open PDB | the APEX wallet |
| `port` | every other local TCP listener (`ss`/`lsof`), capped by `PORT_LIMIT` | `openssl s_client`; `--no-scan` skips it |

Findings: expired **CRIT**; < `WARN_DAYS` (30) **WARN**; < `INFO_DAYS` (90) **INFO**; demo/self-signed,
SHA-1/MD5 signature, RSA < 2048 **WARN**; live serial ≠ configured serial **WARN** (a restart or
activate is pending); unreadable store (unknown password, missing file, port down) **WARN**; EM agent
present **INFO** (its certificate is the OMS's business). `inspect --report` writes
`CERT_OUT/<host>_certs_<ts>/REPORT.md` and exits 2/1/0 for cron.

## Targets and what apply does

- **`wls:<domain>:<server>`** (or `wls:<domain>` for every SSL server): `openssl pkcs12` bundle of
  cert + key + chain → `keytool -importkeystore` into
  `<domain>/security/identity_<server>_<date>.jks` (`WLS_KS_TYPE=PKCS12` keeps the bundle); then
  WLST online (`WLS_USERCONFIG`/`WLS_USERKEY` or `WLS_ADMIN_USER`): `KeyStores`,
  `CustomIdentityKeyStore{FileName,Type,PassPhrase}`, `SSL ServerPrivateKey{Alias,PassPhrase}`,
  `activate()`. Trust mode is kept when custom; a demo server moves to
  `CustomIdentityAndJavaStandardTrust` (`--trust-mode CustomIdentityAndCustomTrust --wallet trust.jks`
  to use a custom trust store, into which the chain CAs are imported). With JavaStandardTrust the
  chain CAs are checked against the JDK cacerts and you are told when they are missing. Without
  credentials the keystore is still built and the console steps printed.
- **`nm:<domain>`**: same keystore, `nodemanager.properties` rewritten (pass phrases in clear until
  the NodeManager restarts and encrypts them).
- **`ords`**: `<config>/global/standalone/certs/<cn>_<date>.pem` (cert + chain) and `.der` (PKCS#8 DER
  private key, which is what ORDS standalone wants); `standalone.https.cert` / `.cert.key` set,
  `standalone.https.port` added when missing; ORDS restarted (`RESTART_CMDS ords=`, else the
  systemd unit).
- **`listener`**: new wallet in the run dir with `orapki wallet create -auto_login`, `import_pkcs12`
  (18c+), `add -trusted_cert` for each chain CA; `cwallet.sso`/`ewallet.p12` copied into the
  existing wallet directory so no `.ora` file changes; `lsnrctl reload`, and if the port still
  serves the old serial a `stop`/`start` (asked). Database server processes read the wallet per
  connection. `orapki` takes the wallet password as an argument (visible in `ps` for that second);
  there is no stdin option for `import_pkcs12`.
- **`ohs:<instance>`**: wallet as for the listener, then `RESTART_CMDS ohs:<inst>=` or
  `restartComponent.sh` (NodeManager credentials prompted).
- **`java:<JAVA_HOME>`**: trust only: every CA in `--chain` (or `--cert`) not already in cacerts
  (by SHA-256) is imported as `cert-renew-<cn>`.

`plan`/`preflight` check that `--key` matches `--cert`, the chain verifies, the cert is valid now,
`CHECK_HOST` is in CN/SAN, the tools and credentials are there and the files are writable.
`backup` copies the current keystore/wallet/properties/`config.xml` into
`~/cert-renew/runs/<ts>/backup/<target>/`; `apply` runs it first if it has not been done.
`verify <target>` probes the port: serial = the new cert, days left, hostname, chain (`-untrusted`
with what the server sends, against `--chain` or the system store). `rollback` restores the
files (WebLogic: WLST back to the previous keystore settings, prompting for the old keystore
password if `KS_PASSWORDS` did not open it) and restarts again. `run` chains it all and rolls back
when verify fails. Passwords travel in 600-mode temp files (`-storepass:file`) or on stdin; the
WLST script is written with mode 600 and deleted after the run (a redacted copy stays).

## Options and config

`--cert --key --chain`, `--cn --san --bits` (csr), `--alias`, `--wallet DIR|FILE`, `--trust-mode`,
`--restart`, `--no-scan`, `--report`, `--out DIR`, `--dry-run`, `--yes`, `--force`, `--json`,
`--verbose`, `--run-dir`. Config in `cert-renew.conf` (see the example) or the shared `oracle.conf`.
Needs `lib/oracle-lib.sh` one folder up and `openssl`; `keytool` for keystores, `orapki` for wallets.

Tested against a fake WebLogic domain, ORDS standalone config, listener wallet with a fake
`orapki`/`lsnrctl`, and `openssl s_server` ports (inspect, csr, ords run + rollback, listener run
+ reload/restart, WebLogic keystore build + WLST script + rollback, java import, dry-run); not
yet on a real host. Run `inspect` first, it only reads.
