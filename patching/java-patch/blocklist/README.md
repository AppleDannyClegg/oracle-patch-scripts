# java-blocklist: stopgap for the eMudhra CA compromise (CVE-2026-91403)

Oracle's Java Security Alert of 21 Oct 2026 (CVE-2026-91403, CVSS 9.1) distrusts eMudhra intermediate CA
certificates whose private keys were compromised. The real fix is a patched JDK, applied with
`../java-patch.sh`:

| Line | Fixed in |
|---|---|
| Java 8 | 8u511-b33 or later (8u511-b32 and earlier are still affected, CVE-2026-114820) |
| Java 17 | the build after 17.0.21 named in the alert's MOS document |

Until that JDK is in, this script adds the certificates' SHA-256 fingerprints to the JDK's **own** blocklist,
so TLS chains through them are refused. It changes one text file per JDK and nothing else.

| JDK | File |
|---|---|
| Java 8 JDK | `<jdk>/jre/lib/security/blacklisted.certs` |
| Java 8 JRE | `<jre>/lib/security/blacklisted.certs` |
| Java 11 and later | `<jdk>/lib/security/blocked.certs` |

## Use

```bash
./java-blocklist.sh /path/to/jdk                              # dry run: what it would add, changes nothing
./java-blocklist.sh /path/to/jdk --apply                      # backup beside the file, then append
./java-blocklist.sh /path/to/jdk --apply --with-alternates    # also the 32 alternate encodings
./java-blocklist.sh /path/to/jdk --rollback                   # restore the newest backup
```

Then **restart every JVM that runs from that JDK** (WebLogic servers, Node Manager, ORDS). The list is read at
start-up; a running JVM keeps trusting the certificates until it restarts. `../java-patch.sh inspect` lists
every JDK on the host and who uses it.

The script refuses (exit 1, file untouched) if the file's first line is not `Algorithm=SHA-256`, no
blocklist file is found, or a fingerprint list is missing from beside it. It adds only fingerprints the file
lacks, so a second run adds nothing. The JDK reads the file as a Java properties file and looks a certificate
up by its **uppercase** SHA-256, so every line it writes is uppercase, and a lowercase copy already in the
file does not count as present (it blocks nothing). If the
fingerprint count after the append is not what it expected, it restores the backup.

## The lists

- `emudhra-16.sha256`: the 16 intermediates (DV, OV, EV TLS and OV code-signing CA, each G3B and G3C, each
  issued by emSign's G3 root and cross-signed by Sectigo's AAA Certificate Services). The same 16 values are
  published by two independent write-ups.
- `emudhra-32-alternates.sha256`: 32 alternate DER and malleable ECDSA encodings of the same certificates.
  Published by one source only, so it is opt-in.

Neither list was copied from Oracle's own file. Before relying on it, compare with the `blacklisted.certs` /
`blocked.certs` inside a patched Oracle JDK (8u511-b33 or later): every line here should be in it.

This stopgap keeps the roots in `cacerts` and blocks only the intermediates. Do not delete the roots by hand
instead: removing `comodoaaaca` (AAA Certificate Services) breaks ordinary sites that chain through Sectigo.
Be aware that Oracle's **final** fix (CVE-2026-114820) does delete four roots from `cacerts`: `emsigneccrootcag3`,
`emsignrootcag1`, `emsignrootcag2` and `comodoaaaca`. So after the patched JDK goes in, an outbound TLS call to a
server whose chain ends at one of those roots fails, which is intended. Test the integrations that matter after
the JDK upgrade. `java-patch.sh` never carries those four back from the old `cacerts`.

Tested against fake JDK layouts only (`tests/java-blocklist.sh`), not a real JDK.
