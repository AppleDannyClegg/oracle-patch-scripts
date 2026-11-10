#!/usr/bin/env bash
# Run the read-only report scripts against a real database: Oracle Database Free in a local container
# (gvenzl/oracle-free:23-slim, ~700 MB to pull, arm64 and x86_64). The repo is mounted read-only at /scripts and
# the scripts run inside as the oracle user, exactly as they would on a server. Reports are copied to tests/out/.
#
# Usage: tests/oracle-free-container.sh [--keep] [--trace]
#   --keep    leave the container running afterwards (re-runs are then seconds, not minutes)
#   --trace   route every sqlplus call through a wrapper that records statements and answers in
#             tests/out/sqltrace.{in,out}; grep the .out for ORA-/SP2- to find SQL the scripts swallow
# Needs docker. The slim image has no ps/hostname/free; the first run installs procps-ng into the container.
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/tests/out"; NAME=oradba-test; IMG=gvenzl/oracle-free:23-slim; KEEP=0; TRACE=0
for a in "$@"; do case "$a" in --keep) KEEP=1;; --trace) TRACE=1;; *) echo "unknown option $a"; exit 2;; esac; done
command -v docker >/dev/null || { echo "docker not found"; exit 1; }
# serialize: two runs share NAME and OUT and would clobber each other (kind of Docker: ONE oradba-test). mkdir is atomic.
# Added after three seats raced the same container (Legion/GERTY 10:35). rm -rf this lock if a run died holding it.
LOCK="${TMPDIR:-/tmp}/tests-oracle-free-container.lock"
mkdir "$LOCK" 2>/dev/null || { echo "another tests/oracle-free-container.sh holds $LOCK - refusing to race it (rm -rf that lock if stale)"; exit 2; }
trap 'rmdir "$LOCK" 2>/dev/null' EXIT
CREATED=0
if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null 2>&1
  docker run -d --name "$NAME" -p 1521:1521 -e ORACLE_PASSWORD=Oracle_123 -v "$REPO":/scripts:ro "$IMG" >/dev/null || exit 1
  CREATED=1
fi
# readiness is checked even when this run attached to a container another run just created: docker run -d returns
# as soon as the container exists, so "in docker ps" means started, not ready (Vision 10:35:41 finding #1).
echo "waiting for the database (first start of this image takes a few minutes)"
for _ in $(seq 1 120); do docker logs "$NAME" 2>&1 | grep -q "DATABASE IS READY TO USE" && break; sleep 5; done
docker logs "$NAME" 2>&1 | grep -q "DATABASE IS READY TO USE" || { echo "database did not come up"; docker logs --tail 30 "$NAME"; exit 1; }
# what a real server has and the slim image lacks: an oratab entry, a home for oracle, procps, and a /u01 the
# oracle user can write. Without /u01 a script that keeps a run dir (okv-diag) stops at "Cannot create run dir
# /u01/oracle-patch-scripts/..." before it writes its report: lib/oracle-lib.sh uses the server base on Linux even
# when it cannot be written, on purpose, so the container must supply it rather than the library fall back. Creating
# it keeps the DEFAULT output location under test, which setting ORACLE_OUTPUT_DIR for these runs would bypass.
# Plus an okvclient.ora
# fixture so okv-diag's OKV half (discovery, reachability, cert age, okvutil) is EXERCISED, not a "no okvclient.ora
# found" WARN that the rc<=2 pass rule records as green (Vision/Jocasta 10:34).
docker exec -u root "$NAME" bash -c 'grep -q "^FREE:" /etc/oratab 2>/dev/null || echo "FREE:$ORACLE_HOME:N" >>/etc/oratab; mkdir -p /home/oracle /u01 && chown oracle /home/oracle /u01
  command -v ps >/dev/null || microdnf install -y procps-ng hostname which >/dev/null 2>&1 || echo "procps install failed (no network?) - the scripts fall back to /proc"'
docker exec -u oracle -e HOME=/home/oracle "$NAME" bash -c 'mkdir -p /home/oracle/okv/conf /home/oracle/okv/ssl /home/oracle/okv/bin
  printf "SERVER=127.0.0.1:1\nSSL_WALLET_LOC=/home/oracle/okv/ssl\n" > /home/oracle/okv/conf/okvclient.ora
  [ -f /home/oracle/okv/ssl/ewallet.p12 ] || : > /home/oracle/okv/ssl/ewallet.p12
  printf "#!/bin/sh\necho \"OKV-00001: Cannot connect to the Oracle Key Vault server\"\n" > /home/oracle/okv/bin/okvutil; chmod +x /home/oracle/okv/bin/okvutil' \
  || { echo "could not create the okvclient.ora fixture in $NAME - refusing to run: okv-diag would take its no-fixture branch and pass green"; exit 1; }
# re-check the fixture exists and is non-empty, so a failed exec cannot silently recreate the false green it exists to prevent
docker exec -u oracle -e HOME=/home/oracle "$NAME" test -s /home/oracle/okv/conf/okvclient.ora \
  || { echo "okvclient.ora fixture missing or empty in $NAME"; exit 1; }
mkdir -p "$OUT"
SQLCMD=""
if [ "$TRACE" = 1 ]; then
  docker exec -i -u oracle "$NAME" bash -c 'cat >/home/oracle/sqlplus-trace <<"W"
#!/bin/bash
tee -a /home/oracle/sqltrace.in | "$ORACLE_HOME/bin/sqlplus" -S "$@" | tee -a /home/oracle/sqltrace.out
exit "${PIPESTATUS[1]}"
W
chmod +x /home/oracle/sqlplus-trace; rm -f /home/oracle/sqltrace.*'; SQLCMD=/home/oracle/sqlplus-trace
fi
docker exec -u oracle "$NAME" bash -c 'cd /scripts && bash lib/oracle-lib.sh selftest' 2>&1 | tail -1
fail=0
run() { local name=$1; shift; echo "== $name: $*"
  docker exec -u oracle -e HOME=/home/oracle -e OFFLINE=1 ${SQLCMD:+-e SQL_CMD=$SQLCMD} "$NAME" bash -c "cd /scripts && $*" >"$OUT/$name.log" 2>&1
  local rc=$?; echo "   exit $rc  ($OUT/$name.log)"; grep -E '^- (CRIT|WARN)|^# FINDINGS|[0-9]+ critical, [0-9]+ warnings' "$OUT/$name.log" | head -8 | sed 's/^/   /'; [ "$rc" -gt 2 ] && fail=1; }
run db-health    reports/db-health-daily/db-health-daily.sh --out /home/oracle/dbh --no-tar
run perf         reports/perf-snapshot/perf-snapshot.sh --last 30m --no-pack --out /home/oracle/perf --no-tar
run space        reports/space-forecast/space-forecast.sh --out /home/oracle/space --no-tar
run security     reports/security-posture/security-posture.sh --out /home/oracle/sec --no-tar
run patch-status patching/patch-status/patch-status.sh --no-net --report --out /home/oracle/ps
run oracle-diag  reports/oracle-diag/oracle-diag.sh --skip wls --skip ords --skip apex --out /home/oracle/diag --no-tar
run okv-diag     reports/okv-diag/okv-diag.sh --okv-home /home/oracle/okv --out /home/oracle/okvdiag --no-tar
# run() only reads rc, and a no-fixture / nothing-probed okv-diag still exits 1 (WARN) -> a PASS. Assert the
# OKV half actually ran, or a future regression that skips it would stay green (Vision 10:44:52 finding 2).
# The probe line lives in REPORT.md/raw, not the captured log, so read the report tree in the container.
if grep -qE 'no okvclient.ora found|reachability NOT checked' "$OUT/okv-diag.log"; then
  echo "   FAIL okv-diag: OKV client section was NOT exercised (no fixture, or nothing was probed)"; fail=1
elif ! docker exec -u oracle "$NAME" grep -rqE '^  [^ ]+:[0-9]+ (OK|UNREACHABLE)$' /home/oracle/okvdiag; then
  echo "   FAIL okv-diag: no server-reachability probe line in the report - the OKV half did not run"; fail=1
fi
rm -rf "$OUT/reports"; docker cp "$NAME:/home/oracle" "$OUT/reports" >/dev/null 2>&1 && echo "reports: $OUT/reports/{dbh,perf,space,sec,ps,diag,okvdiag}"
if [ "$TRACE" = 1 ]; then
  docker cp "$NAME:/home/oracle/sqltrace.out" "$OUT/sqltrace.out" >/dev/null 2>&1; docker cp "$NAME:/home/oracle/sqltrace.in" "$OUT/sqltrace.in" >/dev/null 2>&1
  echo "SQL errors in the trace (APEX views are expected to be missing in this image):"
  grep -n -B6 -E '^(ORA-|SP2-|PLS-)' "$OUT/sqltrace.out" | grep -E '^[0-9]+[-:](select|alter|with|ORA-|SP2-|PLS-)' | cut -c1-200
fi
if [ "$KEEP" = 1 ]; then :
elif [ "$CREATED" = 1 ]; then docker rm -f "$NAME" >/dev/null; echo "container removed (--keep to leave it running)"   # only remove what this run created
else echo "container left running (not created by this run)"; fi
exit $fail
