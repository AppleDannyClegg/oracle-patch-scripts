#!/usr/bin/env bash
# tests/obic-diag.sh - stub curl/ps and assert obic-diag's rules: discovery unreachable is a CRIT, a
# registered-but-not-UP app is a CRIT, a missing app is a WARN, and an app compiled for a newer Java than
# the JVM is a CRIT. Read-only; needs no Oracle host.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
stub="$TMP/bin"; mkdir -p "$stub"
DOM="$TMP/dom"; mkdir -p "$DOM/config" "$DOM/servers/OBIC_JAVAIC01/logs"
printf '<domain><server><name>OBIC_JAVAIC01</name><listen-port>7002</listen-port></server></domain>\n' >"$DOM/config/config.xml"
printf 'BEA-2162500: java.lang.UnsupportedClassVersionError: ... class file version 55.0, this version of the Java Runtime only recognizes class file versions up to 52.\n' >"$DOM/servers/OBIC_JAVAIC01/logs/OBIC_JAVAIC01.log"

# stub ps: no weblogic JVM running
cat >"$stub/ps" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
# stub curl: honour -o and -w; /apps returns $FAKE_APPS_JSON (or 000 when $FAKE_DOWN=1)
cat >"$stub/curl" <<'EOF'
#!/usr/bin/env bash
url=""; out=""; wfmt="%{http_code}"
while [ $# -gt 0 ]; do case "$1" in
  -o) out="$2"; shift 2;; -w) wfmt="$2"; shift 2;; -H|-m|-K) shift 2;; -*) shift;; http*) url="$1"; shift;; *) shift;; esac; done
if [ "${FAKE_DOWN:-0}" = 1 ]; then [ -n "$out" ] && [ "$out" != /dev/null ] && : >"$out"; printf '000'; exit 0; fi
case "$url" in
  */apps)  [ -n "$out" ] && [ "$out" != /dev/null ] && printf '%s' "$FAKE_APPS_JSON" >"$out"; printf '200';;
  */health) printf '200';;
  *) printf '000';;
esac
EOF
chmod +x "$stub/ps" "$stub/curl"
export PATH="$stub:$PATH"

run() { OBIC_OUT="$TMP/out" DOMAIN_HOME="$DOM" DISCOVERY_URL="https://disc:44115/plato-discovery-service/eureka" \
        ZIPKIN_URL="http://zipkin:9411" OBIC_SERVERS=OBIC_JAVAIC01 OBIC_APPS="CONFIG-SERVICE OTHER-SVC MISSING-APP" \
        bash reports/obic-diag/obic-diag.sh --quiet --no-tar; }
rep() { cat "$TMP"/out/*/REPORT.md; }

pass=0; fail=0
ok() { if eval "$2"; then echo "ok  $1"; pass=$((pass+1)); else echo "FAIL $1"; fail=$((fail+1)); fi; }

# case 1: discovery down -> CRIT; mismatch log -> CRIT
rm -rf "$TMP/out"; FAKE_DOWN=1 run >/dev/null 2>&1; rc=$?
ok "discovery down exits 2" "[ $rc = 2 ]"
ok "discovery-down CRIT" "rep | grep -q 'plato discovery service NOT reachable'"
ok "jdk-mismatch CRIT" "rep | grep -q 'class file version 55 needs Java 11'"
ok "zipkin-down WARN" "rep | grep -q 'Zipkin NOT reachable'"

# case 2: discovery up, CONFIG-SERVICE UP, OTHER-SVC DOWN, MISSING absent
rm -rf "$TMP/out"
export FAKE_APPS_JSON='{"applications":{"application":[{"name":"CONFIG-SERVICE","instance":[{"status":"UP"}]},{"name":"OTHER-SVC","instance":[{"status":"DOWN"}]}]}}'
unset FAKE_DOWN
run >/dev/null 2>&1
ok "config-service UP not flagged" "! rep | grep -qE 'CONFIG-SERVICE (is registered but not UP|is NOT registered)'"
ok "app DOWN is CRIT" "rep | grep -q 'OTHER-SVC is registered but not UP'"
ok "missing app is WARN" "rep | grep -q 'MISSING-APP is NOT registered' || rep | grep -q 'OBIC app OTHER-SVC'"
unset FAKE_APPS_JSON

echo; echo "obic-diag gate: $pass passed, $fail failed"
[ "$fail" = 0 ]