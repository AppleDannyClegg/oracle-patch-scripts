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
if ! docker ps --format '{{.Names}}' | grep -qx "$NAME"; then
  docker rm -f "$NAME" >/dev/null 2>&1
  docker run -d --name "$NAME" -p 1521:1521 -e ORACLE_PASSWORD=Oracle_123 -v "$REPO":/scripts:ro "$IMG" >/dev/null || exit 1
  echo "waiting for the database (first start of this image takes a few minutes)"
  for _ in $(seq 1 120); do docker logs "$NAME" 2>&1 | grep -q "DATABASE IS READY TO USE" && break; sleep 5; done
  docker logs "$NAME" 2>&1 | grep -q "DATABASE IS READY TO USE" || { echo "database did not come up"; docker logs --tail 30 "$NAME"; exit 1; }
  # what a real server has and the slim image lacks: an oratab entry, a home for oracle, procps
  docker exec -u root "$NAME" bash -c 'grep -q "^FREE:" /etc/oratab 2>/dev/null || echo "FREE:$ORACLE_HOME:N" >>/etc/oratab; mkdir -p /home/oracle && chown oracle /home/oracle
    command -v ps >/dev/null || microdnf install -y procps-ng hostname which >/dev/null 2>&1 || echo "procps install failed (no network?) - the scripts fall back to /proc"'
fi
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
rm -rf "$OUT/reports"; docker cp "$NAME:/home/oracle" "$OUT/reports" >/dev/null 2>&1 && echo "reports: $OUT/reports/{dbh,perf,space,sec,ps,diag}"
if [ "$TRACE" = 1 ]; then
  docker cp "$NAME:/home/oracle/sqltrace.out" "$OUT/sqltrace.out" >/dev/null 2>&1; docker cp "$NAME:/home/oracle/sqltrace.in" "$OUT/sqltrace.in" >/dev/null 2>&1
  echo "SQL errors in the trace (APEX views are expected to be missing in this image):"
  grep -n -B6 -E '^(ORA-|SP2-|PLS-)' "$OUT/sqltrace.out" | grep -E '^[0-9]+[-:](select|alter|with|ORA-|SP2-|PLS-)' | cut -c1-200
fi
[ "$KEEP" = 1 ] || { docker rm -f "$NAME" >/dev/null; echo "container removed (--keep to leave it running)"; }
exit $fail
