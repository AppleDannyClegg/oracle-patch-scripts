# obic-diag.sh - the FLEXCUBE OBIC / "plato" microservice platform, checked from one WebLogic host

Read-only. It answers "why is an OBIC service not up?" by checking the four things that platform needs:

1. **plato discovery service** (Spring Cloud **Eureka**) - the registry every OBIC service registers with
   and discovers peers through. `GET <DISCOVERY_URL>/apps`, list the registered applications and their
   status, and flag any in `OBIC_APPS` that is missing or not `UP`.
2. **Zipkin** - tracing; the OBIC services log `Connection refused` on `localhost:9411` when it is down.
3. **The OBIC managed servers** - are their JVMs running, which JDK, and (if not running) whether the Node
   Manager says they were ever started or their last start **failed**.
4. **A JDK mismatch** - the class-version failure that stops an OBIC deployment loading: an app built for a
   newer Java than the server JVM (`UnsupportedClassVersionError` / `BEA-2162500`). On the firm's estate the
   `OBIC_JAVAIC` build is **Java 11** and the domain is **JDK 8**, so it cannot load.

## Quick start

```bash
cd reports/obic-diag
cp obic-diag.conf.example obic-diag.conf     # set DISCOVERY_URL / DOMAIN_HOME for this host
./obic-diag.sh                                # -> <output dir>/obic-diag/<host>_<ts>/REPORT.md, exit 2/1/0
```

Options: `--discovery URL`, `--zipkin URL`, `--out DIR`, `--lines N`, `--quiet`, `--no-tar`, `--verbose`.

## Config

`obic-diag.conf` (this folder), `~/.obic-diag.conf`, or the shared `oracle.conf`: `OBIC_OUT`,
`DISCOVERY_URL`, `ZIPKIN_URL`, `DOMAIN_HOME`, `OBIC_SERVERS` (default: auto-detect `OBIC_*` from
`DOMAIN_HOME`), `OBIC_APPS` (the Eureka names that must be `UP`).

## Exit / findings

`2` with a CRIT, `1` with a WARN, `0` clean. A discovery service or Zipkin that cannot be reached is a
finding, never a clean verdict. It changes nothing on the host.

## Note

The discovery/Zipkin endpoints are the firm's FLEXCUBE "plato" stack on the flex nodes; they are **not**
part of `oracle-patch-scripts`. This script only checks that they are reachable and that the OBIC
services are registered and loadable.
