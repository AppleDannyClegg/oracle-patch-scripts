# java-patch.sh — a new JDK build for WebLogic, ORDS and whatever else runs on it

Quarterly JDK updates are where WebLogic and ORDS CVEs actually get fixed, and where things
break: a JVM still running the old build after "the upgrade", a customer CA certificate missing
from the new `cacerts`, a version the product does not support. This script finds every JDK on
the host and every file that names it, checks the new tarball against the WebLogic and ORDS
matrices, carries the extra CA certificates across, switches the references (a symlink flip
when the JDK path is a link, otherwise the files), restarts what you tell it to, and proves with
`/proc/<pid>/exe` which JVMs really moved. Runs as the Oracle software owner.

## Quick start

```bash
cd java-patch
cp java-patch.conf.example java-patch.conf      # JAVA_HOME if auto-detection is ambiguous, RESTART_CMDS, CHECK_URLS
./java-patch.sh inspect                          # JDKs, who references which, running JVMs, matrix, cacerts count
./java-patch.sh latest && ./java-patch.sh download /u01/patches/jdk     # or copy jdk-8u421-linux-x64.tar.gz there yourself
./java-patch.sh plan /u01/patches/jdk
./java-patch.sh preflight /u01/patches/jdk
./java-patch.sh run /u01/patches/jdk --restart   # backup > apply > restart > verify (rollback on failure)
```

## What it looks at

- **JDKs**: every `bin/java` referenced by WebLogic (`oui/.globalEnv.properties`, `commEnv.sh`),
  running JVMs, `JAVA_HOME`, `/usr/java/*`, `/usr/lib/jvm/*`, `/opt/java/*`, the `java` on PATH.
- **References** to the target JDK: WebLogic `.globalEnv.properties`, `commEnv.sh`,
  `commExtEnv.sh`, every domain's `setDomainEnv.sh`, `setNMJavaHome.sh`, `setUserOverrides.sh`,
  `nodemanager.properties`; the ORDS systemd unit and drop-ins, `ords.env`; `/etc/profile.d`,
  `/etc/environment`, the owner's shell profiles; `EXTRA_REF_FILES`.
- **Consumers**: WebLogic version → allowed JDK major (12.2.1.4: 8; 14.1.1: 8/11; 14.1.2 and
  15: 17/21); ORDS version → (<22: 8/11; 22–24: 11/17/21; 25.1+: 17/21). GoldenGate
  Microservices and the EM agent are reported only: both ship their own JDK and are patched
  with their own patches.
- **Running JVMs** on the old JDK, named (WebLogic server name, ORDS, NodeManager, GG services).

## What `run` does

1. **preflight**: tarball contains `<top>/bin/java`; `release` gives the version; not the same
   build; same major unless `--force`; WebLogic/ORDS matrix for the new major; disk in
   `JAVA_BASE` (3× the tarball); `JAVA_BASE`, the symlink's parent and every reference file
   writable; who is running on the old JDK; the old `cacerts` opens with `CACERTS_PASSWORD`.
2. **backup**: every file to be edited copied to the run dir; the old JDK directory is never
   touched.
3. **apply**: `tar -xzf` into `JAVA_BASE` (skipped when already unpacked); `keytool` export +
   import of every trusted alias present in the old `cacerts` but not in the new one (your
   internal CAs); then `ln -sfn NEW JAVA_HOME` when `JAVA_HOME` is a symlink, else `sed` of the
   old path to the new in every reference file; `/usr/java/latest` updated if it pointed at the
   old JDK and is writable.
4. **restart** (with `--restart`): `RESTART_CMDS` in order, else the ORDS systemd unit; waits
   for `CHECK_URLS`/`ORDS_URL`.
5. **verify**: new `java -version`; symlink target or no file still naming the old JDK; JVMs
   still on the old JDK listed as a warning, JVMs on the new one listed; URLs answer; WLST
   starts on the new JDK.

`rollback` flips the symlink back / restores the files from the run dir and restarts; the new
JDK directory stays (harmless). `run` rolls back when apply fails and offers it when verify fails.

## Options and config

`--java-home DIR`, `--java-base DIR`, `--tar FILE`, `--restart`, `--force`, `--no-cacerts`,
`--dry-run`, `--yes`, `--json`, `--verbose`, `--run-dir`. Config in `java-patch.conf` (see the
example) or the shared `oracle.conf`; MOS login as for `wls-patch`. Needs `lib/oracle-lib.sh` one
folder up. Logs and backups under `~/java-patch/runs/<ts>/`.

Tip: make the product's `JAVA_HOME` a symlink once (`/u01/app/oracle/jdk -> jdk1.8.0_421`), and
every later update is an atomic link flip with a one-command rollback.

Tested against a fake JDK tree and WebLogic home (symlink flip, rollback, re-run, file-edit
variant, same-build refusal); not yet on a real host. Run `inspect` and `preflight` first.
