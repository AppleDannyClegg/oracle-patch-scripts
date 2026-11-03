#!/usr/bin/env bash
# obic-diag.sh - read-only check of the FLEXCUBE OBIC / "plato" microservice platform on a WebLogic host:
# the plato discovery service (Spring Cloud Eureka - the registry every OBIC service registers with),
# Zipkin (tracing), the OBIC-managed servers and their JVMs, and the class-version (JDK) mismatch that
# stops an OBIC deployment loading. Changes nothing.
#
# Usage: obic-diag.sh [options]
#   --out DIR  --lines N  --quiet  --no-tar  --verbose
#
# Config: obic-diag.conf or ~/.obic-diag.conf or the shared oracle.conf:
#   OBIC_OUT       where the report is written (default ~/obic-diag)
#   DISCOVERY_URL  the plato Eureka base, e.g. https://<other-node>:44115/plato-discovery-service/eureka
#   ZIPKIN_URL     the Zipkin base (default http://localhost:9411)
#   DOMAIN_HOME    the WebLogic domain holding the OBIC managed servers
#   OBIC_SERVERS   OBIC managed-server names (default: auto-detected from DOMAIN_HOME as OBIC_*)
#   OBIC_APPS      the Eureka application names that must be registered UP (e.g. CONFIG-SERVICE)
# Output: OBIC_OUT/<host>_<ts>/REPORT.md (FINDINGS first) + raw/ + tar.gz.
# Exit: 2 with a CRIT finding, 1 with a WARN, 0 clean. A discovery/Zipkin that cannot be reached is a
# finding, never a clean verdict.
#
# shellcheck disable=SC2034  # TOOL/VERSION are read by the lib's log/state names, VERBOSE by dbg
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="obic-diag"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

OBIC_OUT="${OBIC_OUT:-$HOME/obic-diag}"
DISCOVERY_URL="${DISCOVERY_URL:-}"
ZIPKIN_URL="${ZIPKIN_URL:-http://localhost:9411}"
DOMAIN_HOME="${DOMAIN_HOME:-}"
OBIC_SERVERS="${OBIC_SERVERS:-}"
OBIC_APPS="${OBIC_APPS:-}"
MAKE_TAR=1

usage() { usage_from_header "$0"; }
parse_args() {
  while [ $# -gt 0 ]; do case "$1" in
    --out) optchk "$@"; OBIC_OUT="$2"; shift 2;;
    --lines) optchk "$@"; DIAG_LINES="$2"; shift 2;;
    --discovery) optchk "$@"; DISCOVERY_URL="$2"; shift 2;;
    --zipkin) optchk "$@"; ZIPKIN_URL="$2"; shift 2;;
    --quiet) QUIET=1; shift;;
    --no-tar) MAKE_TAR=0; shift;;
    --verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1";; esac; done
}

# obic_servers(): the OBIC managed-server names. From config.xml's <server> blocks unless OBIC_SERVERS is
# set; a name is an OBIC one when it starts with OBIC_.
obic_servers() {
  if [ -n "$OBIC_SERVERS" ]; then printf '%s\n' $OBIC_SERVERS; return 0; fi
  [ -n "$DOMAIN_HOME" ] && [ -f "$DOMAIN_HOME/config/config.xml" ] || return 0
  awk '/<server>/{inblk=1;name=""} inblk&&name==""&&match($0,/<name>[^<]*<\/name>/){name=substr($0,RSTART+6,RLENGTH-13)}
       inblk&&/<\/server>/{inblk=0; if(name ~ /^OBIC_/) print name}' "$DOMAIN_HOME/config/config.xml" | sort -u
}

# eureka_apps <json>: one "NAME|STATUS[,STATUS]|instances" line per registered application.
eureka_apps() {
  python3 -c '
import sys,json
try: d=json.load(sys.stdin)
except Exception: sys.exit(3)
apps=((d.get("applications") or {}).get("application")) or []
if isinstance(apps,dict): apps=[apps]
for a in apps:
    inst=a.get("instance") or []
    if isinstance(inst,dict): inst=[inst]
    sts=sorted({i.get("status","?") for i in inst})
    print("%s|%s|%d" % (a.get("name","?"), ",".join(sts) or "none", len(inst)))
' 2>/dev/null
}

discovery_check() {
  h2 "plato discovery service (Spring Cloud Eureka)"
  if [ -z "$DISCOVERY_URL" ]; then
    finding WARN obic "DISCOVERY_URL is not set - the Eureka registry was not checked (set it in obic-diag.conf, e.g. https://<node>:44115/plato-discovery-service/eureka)"
    return 0
  fi
  kv "discovery url" "$DISCOVERY_URL"
  local tmp; tmp="$RAW/discovery_apps.json"
  local code; code="$(to 15 curl -sk -m 15 -H 'Accept: application/json' -o "$tmp" -w '%{http_code}' "$DISCOVERY_URL/apps" 2>/dev/null)"
  kv "GET /apps" "${code:-none}"
  if [ "${code:-000}" != 200 ]; then
    finding CRIT obic "plato discovery service NOT reachable: $DISCOVERY_URL/apps returned '${code:-000}' - every OBIC service needs the registry to register and to discover peers"
    return 0
  fi
  local rows; rows="$(eureka_apps <"$tmp")"
  if [ -z "$rows" ]; then
    finding WARN obic "discovery responded but no applications parsed from /apps - the registry has no registered services (or a shape the parser does not know)"
    return 0
  fi
  kv_end; h3 "registered applications"
  fence_start; printf '%s\n' "$rows" | awk -F'|' '{printf "  %-28s %-8s %s instance(s)\n", $1, $2, $3}' >>"$REPORT"; fence_end
  local app a name st
  for a in $OBIC_APPS; do
    name="$(printf '%s\n' "$a" | tr '[:lower:]' '[:upper:]')"
    st="$(printf '%s\n' "$rows" | awk -F'|' -v n="$name" 'toupper($1)==n{print $2}')"
    if [ -z "$st" ]; then finding WARN obic "OBIC app $name is NOT registered with the discovery service - the service is down or never registered"
    elif printf '%s' "$st" | grep -qv UP; then finding CRIT obic "OBIC app $name is registered but not UP (status: $st)"
    else say "OBIC app $name: UP"; fi
  done
}

zipkin_check() {
  h2 "Zipkin (tracing)"
  kv "zipkin url" "$ZIPKIN_URL"
  local code; code="$(url_code "$ZIPKIN_URL/health" 15)"
  kv "GET /health" "${code:-none}"
  case "${code:-000}" in
    200|302) say "Zipkin reachable";;
    *) finding WARN obic "Zipkin NOT reachable: $ZIPKIN_URL/health returned '${code:-000}' - the OBIC services log 'Connection refused' on localhost:9411 if it is down (tracing only; not usually fatal)";;
  esac
}

# jdk_of_pid <pid>: the JDK home a running JVM came from, via /proc/<pid>/exe
jdk_of_pid() {
  local exe; exe="$(readlink -f "${PROC_DIR:-/proc}/$1/exe" 2>/dev/null)" || return 1
  [ -n "$exe" ] || return 1
  local jh; jh="$(dirname "$(dirname "$exe")")"
  [ -x "$jh/bin/java" ] && printf '%s' "$jh"
}

# obic_jdk_mismatch <server>: the class-version failure that stops a deployment loading, read from the
# server's own log - independent of whether a JVM runs now (the failed start is why it is down)
obic_jdk_mismatch() {
  local s="$1" lg cv
  for lg in "$DOMAIN_HOME/servers/$s/logs/$s.log" "$DOMAIN_HOME/servers/$s/logs/$s.out"; do
    [ -f "$lg" ] || continue
    grep -qE 'UnsupportedClassVersionError|BEA-2162500' "$lg" 2>/dev/null || continue
    cv="$(grep -oE 'class file version [0-9]+' "$lg" | grep -oE '[0-9]+' | sort -rn | head -1)"
    finding CRIT obic "$s: app compiled for a NEWER Java than the server JVM (UnsupportedClassVersionError / BEA-2162500 in $(basename "$lg")) - class file version ${cv:-?} needs Java $(( (${cv:-0} - 44) )) or newer; rebuild it for this JDK or run the JVM on the version it needs"
    return 0
  done
  return 0
}

obic_servers_check() {
  h2 "OBIC managed servers"
  local names; names="$(obic_servers)"
  if [ -z "$names" ]; then
    finding WARN obic "no OBIC managed servers found (set OBIC_SERVERS or DOMAIN_HOME in obic-diag.conf)"
    return 0
  fi
  kv "obic servers" "$(printf '%s' "$names" | tr '\n' ' ')"
  kv_end
  local s pid jh ver rel cf
  for s in $names; do
    h3 "$s"
    obic_jdk_mismatch "$s"
    pid="$(ps -eo pid,args 2>/dev/null | grep "[w]eblogic.Server" | grep -- "-Dweblogic.Name=$s\b" | awk '{print $1}' | head -1)"
    if [ -z "$pid" ]; then
      # last Node Manager line for this server decides 'never started' vs 'last start FAILED'
      local nm last when; nm="${DOMAIN_HOME:-/nonexistent}/nodemanager/nodemanager.log"
      last="$(grep -F "<$s>" "$nm" 2>/dev/null | tail -1)"; when="$(printf '%s' "$last" | sed -n 's/^<\([^>]*\)>.*/\1/p')"
      if printf '%s' "$last" | grep -qiE 'will not be restarted|failed during startup|Server failed'; then
        finding CRIT obic "$s is NOT running and its last start FAILED${when:+ ($when)} - see servers/$s/logs/$s.out (OBIC services commonly fail on a JDK mismatch or a missing discovery service)"
      else
        finding WARN obic "$s is not running${when:+ (last Node Manager line: $when)} - not started, or stopped; the platform is incomplete without it"
      fi
      continue
    fi
    rel="$(ps -p "$pid" -o rss= 2>/dev/null | tr -d ' ')"; kv "pid" "$pid"; kv "rss" "$(( ${rel:-0} / 1024 )) MB"
    jh="$(jdk_of_pid "$pid")"; rel="$([ -n "$jh" ] && sed -n 's/^JAVA_VERSION="\([^"]*\)".*/\1/p' "$jh/release" 2>/dev/null)"
    kv "jdk" "${jh:-?}${rel:+ ($rel)}"
    cf="$(printf '%s' "$rel" | grep -oE '^1\.[0-9]+|[0-9]+' | head -1)"; [ "${cf:-0}" -ge 9 ] && cf="$(printf '%s' "$rel" | cut -d. -f1)" || cf="$(printf '%s' "$rel" | sed -n 's/^1\.\([0-9]*\).*/\1/p')"
    kv "jvm major" "${cf:-?}"
    kv_end
  done
}

main() {
  load_config; parse_args "$@"
  init_run_dir "obic-diag"
  report_init "$OBIC_OUT/${HOST}_$(date '+%Y%m%d_%H%M%S')"
  say "obic-diag $VERSION -> $OUT"
  h1 "Host"; kv "host" "$HOST"; kv "user" "$(id -un)"; kv "domain home" "${DOMAIN_HOME:-?}"; kv_end
  discovery_check
  zipkin_check
  obic_servers_check
  report_finish "obic-diag: $HOST $(date '+%Y-%m-%d')" "$MAKE_TAR" >/dev/null
  [ "$QUIET" = 1 ] || { echo; print_findings; }
  printf '\n%s\n' "$OUT/REPORT.md"
  findings_rc
}
main "$@"