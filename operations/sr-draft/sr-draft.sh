#!/usr/bin/env bash
# sr-draft.sh - the text of a My Oracle Support SR, drafted from an incident-pack, an oracle-diag report, or just
# the error you have: product/version/platform/patch level, the error stack and problem keys, first occurrence
# and frequency, recent changes (patches, packages, sqlpatch, deployments), environment facts, what is attached;
# laid out in the MOS template sections with a severity justification, the MOS search strings and the knowledge
# documents to read first. Also writes CLAUDE-PROMPT.md: everything an analyst (Claude) needs to review the SR
# and suggest the likely cause before you file it. No network access; with nothing to read it is a template.
#
# Usage: sr-draft.sh [--pack DIR] [--report DIR] [--error "text"] [options]
#
#   --pack DIR            an incident-pack directory (the best source: FACTS.txt, MANIFEST.md, log windows, ADR)
#   --report DIR          an oracle-diag output directory (REPORT.md) when there is no pack
#   --error "..."         the error text as you have it (repeatable); with --pack it becomes the headline error
#   --error-file FILE     a file holding the error text / stack / screenshot transcript
#   --sid SID             the database (facts are read live from sqlplus/opatch when no pack or report is given)
#   --product P           db|wls|ords|apex|gg|exa|other (default: from the error prefix: ORA/TNS db, BEA wls, ORDS, OGG)
#   --severity 1-4        SR severity (default 2 when --prod, else 3); --prod / --nonprod says which environment it is
#   --business-impact "…" the impact in the customer's words (users affected, since when, workaround or none)
#   --title "…"           the SR problem summary line (default built from the error and product)
#   --steps "…"           steps to reproduce / what was being done
#   --contact "…"         name, phone, hours (MOS asks for it)
#   --out DIR             where SR.md, CLAUDE-PROMPT.md and MOS-SEARCH.txt go (default <pack>/sr or ~/sr-draft/<ts>)
#   --verbose
#
# Config: sr-draft.conf, ~/.sr-draft.conf or the shared oracle.conf: SR_CONTACT, SR_CSI (support identifier),
# SR_ENVIRONMENT (prod|nonprod), SR_COMPANY, SR_OUT.

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="sr-draft"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

PACK=""; REPORT_DIR=""; ERRORS_GIVEN=""; ERROR_FILE=""; SID=""; PRODUCT=""; SEVERITY=""; ENVTYPE="${SR_ENVIRONMENT:-}"; IMPACT=""; TITLE=""; STEPS=""; CONTACT="${SR_CONTACT:-}"; OUTDIR="${SR_OUT:-}"
SR_CSI="${SR_CSI:-}"; SR_COMPANY="${SR_COMPANY:-}"
FACTS_FILE=""; STATS=""; HEADLINE=""; HEAD_CODE=""; HEAD_ARG=""; PROBLEM_KEYS=""; FIRST_SEEN=""; LAST_SEEN=""; NERR=0; TARBALL=""

usage() { usage_from_header "$0"; }
parse_opts() {
  while [ $# -gt 0 ]; do case "$1" in
    --pack) PACK="${2%/}"; shift 2;; --report) REPORT_DIR="${2%/}"; shift 2;; --error) ERRORS_GIVEN="${ERRORS_GIVEN:+$ERRORS_GIVEN$'\n'}$2"; shift 2;; --error-file) ERROR_FILE="$2"; shift 2;;
    --sid) SID="$2"; shift 2;; --product) PRODUCT="$2"; shift 2;; --severity) SEVERITY="$2"; shift 2;; --prod) ENVTYPE=prod; shift;; --nonprod) ENVTYPE=nonprod; shift;;
    --business-impact) IMPACT="$2"; shift 2;; --title) TITLE="$2"; shift 2;; --steps) STEPS="$2"; shift 2;; --contact) CONTACT="$2"; shift 2;; --out) OUTDIR="$2"; shift 2;;
    --verbose) VERBOSE=1; shift;; -h|--help) usage; exit 0;; *) die "Unknown option: $1";; esac; done
}
fact() { [ -f "$FACTS_FILE" ] || return 1; sed -n "s/^$1=//p" "$FACTS_FILE" | head -1 | grep .; }
facts_like() { [ -f "$FACTS_FILE" ] || return 1; grep -E "^$1" "$FACTS_FILE"; }
lower() { tr 'A-Z' 'a-z'; }

# ---------------------------------------------------------------------------
# error mining
# ---------------------------------------------------------------------------
ERR_RE='(ORA|TNS|BEA|ORDS|OGG|PLS|RMAN|DGM|CRS|OCI|LRM|KUP|UDE|UDI|RMAN|NNO|NNL|OKV|CLSU)-[0-9]+|java\.[a-z.]+[A-Za-z]+(Exception|Error)|OutOfMemoryError|StackOverflowError'
# error_stats <file...>: code|count|first|last|sample  (timestamps from the line or the last timestamp line before it)
error_stats() {
  cat "$@" 2>/dev/null | awk -v re="$ERR_RE" '
    BEGIN{split("JAN FEB MAR APR MAY JUN JUL AUG SEP OCT NOV DEC",m," "); for(i=1;i<=12;i++) mon[m[i]]=sprintf("%02d",i)}
    function tsof(line,   s,a,hh,rest){
      if (match(line,/^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9][T ][0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) { s=substr(line,1,19); sub(/T/," ",s); return s }
      if (match(line,/^[0-9][0-9]-[A-Z][A-Z][A-Z]-[0-9][0-9][0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]/)) { s=substr(line,1,20); return substr(s,8,4)"-"mon[substr(s,4,3)]"-"substr(s,1,2)" "substr(s,13,8) }
      if (match(line,/^####<[A-Z][a-z][a-z] [0-9]+, [0-9][0-9][0-9][0-9],? [0-9]+:[0-9][0-9]:[0-9][0-9]/)) { s=substr(line,6,RLENGTH-5); split(s,a,/[ ,:]+/); hh=a[4]+0; rest=substr(line,RLENGTH+1,12); if (rest ~ /PM/ && hh<12) hh+=12; if (rest ~ /AM/ && hh==12) hh=0; return sprintf("%s-%s-%02d %02d:%s:%s",a[3],mon[toupper(substr(a[1],1,3))],a[2],hh,a[5],a[6]) }
      return "" }
    { t=tsof($0); if (t!="") last=t
      line=$0; while (match(line,re)) { c=substr(line,RSTART,RLENGTH); n[c]++; if (!(c in first)) { first[c]=last; sample[c]=$0 } lastseen[c]=last; line=substr(line,RSTART+RLENGTH) } }
    END{ for (c in n) { s=sample[c]; gsub(/\|/,"/",s); printf "%s|%d|%s|%s|%s\n", c, n[c], first[c], lastseen[c], substr(s,1,220) } }' | sort -t'|' -k2,2nr
}
internal_arg() { # first argument of ORA-600 / ORA-7445 in a text
  printf '%s\n' "$1" | grep -oE 'ORA-0?0?600:[^[]*\[[^]]+\]|ORA-0?7445:[^[]*\[[^]]+\]' | head -1 | sed 's/.*\[//; s/\]$//'
}
pack_sources() { # the files worth mining for errors, in priority order
  { ls "$PACK"/db/*/alert/*.window "$PACK"/db/*/sql/errors_window.txt "$PACK"/db/listener/*.window "$PACK"/wls/*/*/*.window "$PACK"/wls/*/*/*.out "$PACK"/ords/logs/* "$PACK"/ords/journal.txt "$PACK"/gg/*.window "$PACK"/extra/*.window 2>/dev/null; } | grep .
}
mine_errors() {
  local src="" given
  given="$ERRORS_GIVEN"; [ -n "$ERROR_FILE" ] && given="$given$([ -n "$given" ] && echo)$(cat "$ERROR_FILE")"
  if [ -n "$PACK" ]; then src="$(pack_sources)"; fi
  { [ -n "$given" ] && printf '%s\n' "$given"; [ -n "$src" ] && { printf '%s\n' "$src" | while IFS= read -r f; do cat "$f"; done; }; } >"$OUTDIR/.errsrc"
  STATS="$(error_stats "$OUTDIR/.errsrc")"; NERR="$(printf '%s' "$STATS" | grep -c .)"
  # headline: the error given, else the most serious, else the most frequent
  if [ -n "$given" ]; then HEADLINE="$(printf '%s\n' "$given" | grep -E "$ERR_RE" | head -1)"; [ -z "$HEADLINE" ] && HEADLINE="$(printf '%s\n' "$given" | head -1)"
  else local c; for c in ORA-00600 ORA-07445 ORA-00700 ORA-04031 ORA-04030 ORA-00257 ORA-01578 ORA-00494 ORA-29770 ORA-03113 ORA-12514 TNS-12541 OutOfMemoryError BEA-000337 ORDS-; do HEADLINE="$(printf '%s\n' "$STATS" | grep "^$c" | head -1 | cut -d'|' -f5)"; [ -n "$HEADLINE" ] && break; done
    [ -z "$HEADLINE" ] && HEADLINE="$(printf '%s\n' "$STATS" | head -1 | cut -d'|' -f5)"; fi
  HEAD_CODE="$(printf '%s' "$HEADLINE" | grep -oE "$ERR_RE" | head -1)"; HEAD_ARG="$(internal_arg "$HEADLINE")"
  [ -z "$HEAD_ARG" ] && [ -n "$HEAD_CODE" ] && HEAD_ARG="$(internal_arg "$(grep -h "$HEAD_CODE" "$OUTDIR/.errsrc" | head -3)")"
  local row; row="$(printf '%s\n' "$STATS" | grep "^${HEAD_CODE:-__none__}|" | head -1)"; FIRST_SEEN="$(printf '%s' "$row" | cut -d'|' -f3)"; LAST_SEEN="$(printf '%s' "$row" | cut -d'|' -f4)"
  if [ -n "$PACK" ]; then PROBLEM_KEYS="$(cat "$PACK"/db/*/adr/problems.txt 2>/dev/null | awk '/^PROBLEM_ID/{h=1;next} /^INCIDENT_ID|^$/{h=0} h&&/^[0-9]+ +[A-Za-z]/&&!/rows fetched/{ $1=""; sub(/ +[0-9]+ +[0-9T:.+-]+$/,""); sub(/^ +/,""); print }' | sort -u | head -5)"
    [ -z "$PROBLEM_KEYS" ] && PROBLEM_KEYS="$(cat "$PACK"/db/*/sql/incidents.txt 2>/dev/null | grep -oE 'ORA [0-9]+ \[[^]]*\]|ORA [0-9]+' | sort -u | head -5)"; fi
  rm -f "$OUTDIR/.errsrc"
}

# ---------------------------------------------------------------------------
# facts from the sources
# ---------------------------------------------------------------------------
live_facts() { # no pack/report: what sqlplus/opatch on this host say
  FACTS_FILE="$OUTDIR/.facts"; : >"$FACTS_FILE"
  { echo "HOST=$HOST"; echo "FQDN=$(hostname -f 2>/dev/null || hostname)"; echo "OS=$(sed -n 's/^PRETTY_NAME="\(.*\)"/\1/p' /etc/os-release 2>/dev/null | head -1 || uname -sr) kernel $(uname -r)"
    local sid; for sid in ${SID:-$(db_instances)}; do sql_ok "$sid" || continue
      echo "DB_VERSION_$sid=$(sql_val "$sid" "(select version_full from v\$instance)" 2>/dev/null)"; echo "DB_NAME_$sid=$(sql_val "$sid" "(select name||' role='||database_role||' cdb='||cdb||' platform='||platform_name from v\$database)" 2>/dev/null)"
      echo "DB_PATCHES_$sid=$(sql_lines "$sid" "select listagg(patch_id||':'||substr(description,1,60),' | ') within group (order by action_time) from (select * from (select patch_id, description, action_time from dba_registry_sqlpatch where status='SUCCESS' order by action_time desc) where rownum<=5);" 2>/dev/null | head -1)"
      local h; h="$(db_home_of "$sid")"; [ -x "$h/OPatch/opatch" ] && echo "OPATCH_$sid=$(to 120 "$h/OPatch/opatch" lspatches -oh "$h" 2>/dev/null | grep -vE '^OPatch|^$|succeeded' | head -5 | cut -c1-70 | tr '\n' '|')"
    done
    local w; for w in $(wls_homes); do echo "WLS_VERSION=$(wls_version "$w") ($w)"; done
    ords_detect >/dev/null 2>&1 && echo "ORDS_VERSION=${ORDS_VER:-?} home=$ORDS_HOME"
  } >>"$FACTS_FILE" 2>/dev/null
}
report_facts() { # oracle-diag REPORT.md: host, versions it printed, its findings
  FACTS_FILE="$OUTDIR/.facts"; local r="$REPORT_DIR/REPORT.md"; [ -f "$r" ] || die "$r not found"
  { echo "HOST=$(sed -n 's/.*on `\([^`]*\)`.*/\1/p' "$r" | head -1)"; echo "GENERATED=$(sed -n 's/.*generated: `\([^`]*\)`.*/\1/p' "$r" | head -1)"
    grep -E 'OPEN|Oracle Database|version_full|Release [0-9]' "$r" | grep -oE '(1[1-9]|2[0-9])\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -u | head -3 | awk '{print "DB_VERSION_seen_"NR"="$0}'
    grep -oE 'WebLogic Server[^0-9]*[0-9.]+' "$r" | head -1 | sed 's/^/WLS_VERSION=/'; grep -oE 'ORDS [0-9]+\.[0-9]+\.[0-9]+' "$r" | head -1 | sed 's/^/ORDS_VERSION=/'
    echo "DIAG_FINDINGS=$(grep -E '^# FINDINGS' "$r" | head -1 | sed 's/^# //')"
  } >"$FACTS_FILE"
}
product_of() {
  [ -n "$PRODUCT" ] && { printf '%s' "$PRODUCT"; return; }
  case "$HEAD_CODE" in ORA-*|TNS-*|PLS-*|RMAN-*|DGM-*|KUP-*|UDE-*|UDI-*) echo db;; BEA-*|*OutOfMemory*|java.*) echo wls;; ORDS-*) echo ords;; OGG-*) echo gg;; CRS-*|CLSU-*) echo gi;; *) [ -n "$(fact WLS_VERSION)" ] && [ -z "$(facts_like DB_VERSION)" ] && echo wls || echo db;; esac
}
product_name() { case "$1" in db) echo "Oracle Database";; wls) echo "Oracle WebLogic Server";; ords) echo "Oracle REST Data Services";; apex) echo "Oracle APEX";; gg) echo "Oracle GoldenGate";; exa) echo "Exadata Database Machine";; gi) echo "Oracle Grid Infrastructure";; *) echo "Oracle";; esac; }
product_version() {
  case "$1" in db|gi|exa) facts_like 'DB_VERSION_' | head -1 | cut -d= -f2;; wls) fact WLS_VERSION | sed 's/ (.*//';; ords) fact ORDS_VERSION | awk '{print $1}';; apex) facts_like 'APEX_' | head -1 | cut -d= -f2 | awk '{print $1}';; gg) fact GG_HOME | grep -oE '[0-9]+(\.[0-9]+)+' | head -1;; esac
}
recent_changes() {
  local n=0
  [ -n "$PACK" ] || return 0
  local sid f; for f in "$PACK"/db/*/opatch/lsinventory.txt; do [ -f "$f" ] || continue; sid="$(basename "$(dirname "$(dirname "$f")")")"; grep -E '^Patch +[0-9]+ *: applied on' "$f" | head -5 | sed "s/^/- $sid opatch: /"; done
  for f in "$PACK"/db/*/sql/registry.txt; do [ -f "$f" ] || continue; sid="$(basename "$(dirname "$(dirname "$f")")")"; awk '/PATCH_ID/{h=1;next} h&&/^[0-9]+ /{print}' "$f" | tail -3 | cut -c1-140 | sed "s/^/- $sid sqlpatch: /"; done
  [ -f "$PACK/host/packages.txt" ] && { awk '/rpm -qa --last/{h=1;next} /^\$|yum history/{h=0} h&&NF{print}' "$PACK/host/packages.txt" | head -8 | sed 's/^/- rpm: /'; awk '/yum history/{h=1;next} h&&/^ *[0-9]+ *\|/{print}' "$PACK/host/packages.txt" | head -5 | sed 's/^/- yum: /'; }
  for f in "$PACK"/db/*/sql/instance.txt; do [ -f "$f" ] || continue; grep -iE 'STARTUP_TIME|^[A-Z0-9_]+ +[a-zA-Z0-9.-]+ +[0-9.]+ +OPEN' "$f" | head -2 | cut -c1-160 | sed "s/^/- instance: /"; done
  for f in "$PACK"/wls/*/config/config.xml; do [ -f "$f" ] || continue; [ "$(grep -c '<app-deployment>' "$f")" != 0 ] && printf -- '- WebLogic %s: %s deployment(s): %s\n' "$(basename "$(dirname "$(dirname "$f")")")" "$(grep -c '<app-deployment>' "$f")" "$(grep -A2 '<app-deployment>' "$f" | grep -oE '<name>[^<]*' | sed 's/<name>//' | head -8 | tr '\n' ' ')"; done
  fact UPTIME | sed 's/^/- host uptime: /'
}
attached() {
  [ -n "$PACK" ] || { echo "- (nothing yet: run ../incident-pack/incident-pack.sh <SR> and upload the tarball)"; return; }
  TARBALL=""; local t; for t in "$(dirname "$PACK")/$(basename "$PACK")".tar.gz*; do [ -f "$t" ] && { TARBALL="$t"; break; }; done
  printf -- '- incident pack `%s`%s\n' "$(basename "$PACK")" "${TARBALL:+ uploaded as \`$(basename "$TARBALL")\` (sha256 in $(basename "$PACK").sha256)}"
  local d; for d in 00_oracle-diag tfa db wls ords gg exadata host extra; do [ -d "$PACK/$d" ] && printf -- '- `%s/` %s file(s)%s\n' "$d" "$(find "$PACK/$d" -type f | wc -l | tr -d ' ')" "$(case $d in db) echo ": alert log + window, traces named by it, ADR ips packages $(find "$PACK"/db -path '*/adr/*.zip' 2>/dev/null | sed 's#.*/##' | tr '\n' ' '), SQL snapshots, pfile, opatch$(ls "$PACK"/db/*/awr/* >/dev/null 2>&1 && echo ', AWR/ASH')$(ls "$PACK"/db/*/hang/* >/dev/null 2>&1 && echo ', hanganalyze/systemstate')";; wls) echo ': config (redacted), server log windows, .out, JVM facts'"$(ls "$PACK"/wls/*/*/jvm/threads_* >/dev/null 2>&1 && echo ', thread dumps')";; host) echo ': system, dmesg, journal, messages, sar, OSWatcher window';; tfa) echo ': tfactl diagcollect';; esac)"; done
  [ -n "$(fact TFA_COLLECTION)" ] && printf -- '- TFA collection: %s\n' "$(fact TFA_COLLECTION)"
}
severity_text() {
  local s="$1"; case "$s" in 1) echo "Severity 1: complete loss of service in production, work cannot reasonably continue, no workaround; 24x7 contact available";; 2) echo "Severity 2: severe loss of service - production is impaired, no acceptable workaround, business operations are at risk";; 3) echo "Severity 3: minor loss of service - the problem is worked around or the environment is not production";; *) echo "Severity 4: no loss of service - question, documentation or enhancement";; esac
}
mos_search() {
  local p="$1" v="$2" ver; ver="$(printf '%s' "$v" | cut -d. -f1-2)"
  [ -n "$HEAD_ARG" ] && case "$HEAD_CODE" in ORA-00600|ORA-0600|ORA-600) printf 'ORA-600 [%s]\nORA-600 [%s] %s\n' "$HEAD_ARG" "$HEAD_ARG" "$ver";; ORA-07445|ORA-7445) printf 'ORA-7445 [%s]\nORA-7445 [%s] %s\n' "$HEAD_ARG" "$HEAD_ARG" "$ver";; esac
  [ -n "$PROBLEM_KEYS" ] && printf '%s\n' "$PROBLEM_KEYS"
  printf '%s\n' "$STATS" | head -6 | cut -d'|' -f1 | while IFS= read -r c; do [ -n "$c" ] || continue; case "$c" in BEA-*|java.*|*OutOfMemory*|*StackOverflow*) printf '%s WebLogic %s\n' "$c" "$(fact WLS_VERSION | grep -oE '^[0-9.]+' | cut -d. -f1-3)";; ORDS-*) printf '%s ORDS %s\n' "$c" "$(fact ORDS_VERSION | grep -oE '^[0-9.]+' | cut -d. -f1-2)";; OGG-*) printf '%s GoldenGate\n' "$c";; *) printf '%s %s %s\n' "$c" "$(product_name "$p")" "$ver";; esac; done
  [ -n "$PACK" ] && { cat "$PACK"/db/*/traces/*.trc "$PACK"/db/*/hang/*.trc 2>/dev/null | grep -oE '[Bb]ug [0-9]{7,9}' | sort -u | head -5 | sed 's/^/Bug /; s/[Bb]ug //'; }
  true
}
mos_docs() {
  local p="$1"
  echo "- Doc ID 2118136.2 - Database patching and the latest Release Update list (check whether the fix is in a newer RU)"
  case "$HEAD_CODE" in
    ORA-00600|ORA-600|ORA-07445|ORA-7445|ORA-00700) echo "- Doc ID 153788.1 - ORA-600/ORA-7445/ORA-700 Error Look-up Tool (first argument + version -> known bugs)"; echo "- Doc ID 1088239.1 - Master Note for Diagnosing ORA-600 and ORA-7445 internal errors"; echo "- Doc ID 452358.1 / 1363422.1 - creating and uploading the ADR incident package (adrci ips) Support asks for";;
    ORA-04031|ORA-04030) echo "- Doc ID 1088239.1 - Master Note for diagnosing internal errors; ORA-4031/4030 memory diagnostics (SGA/PGA heap dumps) are requested through it";;
    ORA-00257|ORA-19815|ORA-19809) echo "- Doc ID 1374367.1 - Diagnostic collection with AHF/TFA for SRs; FRA/archiver issues: v\$recovery_file_dest, RMAN retention";;
    ORA-03113|ORA-03135|ORA-12170|TNS-*) echo "- Doc ID 1050693.1 - Master Note: Troubleshooting connectivity, listener and SQL*Net issues (TNS/ORA-3113)";;
  esac
  case "$p" in
    db|gi|exa) echo "- Doc ID 1050693.1 - Master Note: Troubleshooting Database Hang / performance issues (hanganalyze, systemstate, AWR/ASH)"; echo "- Doc ID 1374367.1 - AHF / Trace File Analyzer: tfactl diagcollect for an SR";;
    wls) echo "- WebLogic Server SRDC: thread dumps (3 x 10 s apart), server logs, config.xml; OutOfMemory: heap dump + GC log; Doc ID 1374367.1 for collection with AHF where installed";;
    ords|apex) echo "- ORDS/APEX: ords version, ords config list, pool.xml, standalone/access logs, APEX version/patch level, browser HAR for page errors";;
    gg) echo "- GoldenGate: report files, ggserr.log, parameter files, info all/detail, checkpoint files; MA: deployment logs";;
  esac
  echo "- The product's SRDC (Service Request Data Collection) note for this error type: search MOS for 'SRDC $HEAD_CODE' before filing, attach what it lists"
}

# ---------------------------------------------------------------------------
write_sr() {
  local p pn pv sev env impact title hostline
  p="$(product_of)"; pn="$(product_name "$p")"; pv="$(product_version "$p")"; env="${ENVTYPE:-}"; [ -z "$env" ] && { printf '%s' "$(facts_like DB_NAME | head -1)$HOST" | lower | grep -qE 'prod|prd|live' && env=prod || env=nonprod; }
  sev="${SEVERITY:-$([ "$env" = prod ] && echo 2 || echo 3)}"
  title="${TITLE:-$pn ${pv:+$pv }- ${HEAD_CODE:-incident}${HEAD_ARG:+ [$HEAD_ARG]} on $(fact HOST 2>/dev/null || echo "$HOST")${FIRST_SEEN:+ since $FIRST_SEEN}}"
  impact="${IMPACT:-TODO: who/what is affected (users, batch, interfaces), since when, workaround in place or none, deadline (e.g. month-end run)}"
  { printf '# SR draft - %s\n\n' "$title"
    printf -- '- drafted: `%s` by %s %s from %s\n' "$(ts)" "$TOOL" "$VERSION" "$([ -n "$PACK" ] && echo "incident pack $(basename "$PACK")" || { [ -n "$REPORT_DIR" ] && echo "oracle-diag report $REPORT_DIR" || echo "the error text only (no pack: facts are a template)"; })"
    printf -- '- fill every TODO; paste each section into the matching MOS field. Lines starting with > are notes for you, not for the SR.\n\n'
    printf '## Problem Summary\n\n%s\n\n' "$title"
    printf '## Problem Description\n\n'
    printf 'On %s (%s%s) %s reported:\n\n```\n%s\n```\n\n' "$(fact HOST || echo "$HOST")" "$pn" "${pv:+ $pv}" "$([ "$p" = db ] && echo "the database $(facts_like DB_NAME | head -1 | cut -d= -f2 | awk '{print $1}' | grep . || echo '(TODO name)')" || echo "the $pn instance")" "${HEADLINE:-TODO: the exact error text}"
    [ -n "$FIRST_SEEN" ] && printf 'First occurrence in the collected logs: %s; last: %s; %s occurrence(s) of %s in the window%s.\n\n' "$FIRST_SEEN" "${LAST_SEEN:-?}" "$(printf '%s\n' "$STATS" | grep "^$HEAD_CODE|" | cut -d'|' -f2)" "$HEAD_CODE" "$([ -n "$(fact WINDOW)" ] && echo " ($(fact WINDOW))")"
    [ -n "$PROBLEM_KEYS" ] && printf 'ADR problem key(s): %s\n\n' "$(printf '%s' "$PROBLEM_KEYS" | tr '\n' ';')"
    [ -n "$(fact DIAG_FINDINGS)" ] && printf 'oracle-diag health check at collection time: %s (details in 00_oracle-diag/REPORT.md of the pack).\n\n' "$(fact DIAG_FINDINGS)"
    printf '%s\n\n' "${STEPS:-TODO: what was running when it happened (job, deployment, user action), whether it reproduces, what has been tried (restart, retry, failover) and the result.}"
    printf '> Keep it factual and short: what, where, when, how often, what changed, what you tried. Support reads the first three lines.\n\n'
    printf '## Error Codes / Messages\n\n'
    if [ -n "$STATS" ]; then printf '| code | count | first | last | sample |\n|---|---|---|---|---|\n'; printf '%s\n' "$STATS" | head -15 | while IFS='|' read -r c n f l s; do printf '| %s | %s | %s | %s | %s |\n' "$c" "$n" "${f:-?}" "${l:-?}" "$(printf '%s' "$s" | sed 's/|/\//g' | cut -c1-140)"; done; echo
    else printf 'TODO: paste the error stack (every line, including the arguments in brackets).\n\n'; fi
    printf '## Steps to Reproduce\n\n%s\n\n' "${STEPS:-TODO: 1. ... 2. ... (or: not reproducible on demand; happens N times a day under normal load)}"
    printf '## Business Impact and Severity\n\n%s\n\nRequested severity: **%s** - %s.\nEnvironment: **%s**.%s\n\n> Severity 1 needs a 24x7 contact and means you work it 24x7 too. Say so only when it is true. State a deadline if there is one.\n\n' "$impact" "$sev" "$(severity_text "$sev")" "$env" "${CONTACT:+ Contact: $CONTACT.}"
    printf '## Environment\n\n'
    printf -- '- Product: %s %s\n' "$pn" "${pv:-TODO version}"
    [ -n "$(facts_like DB_VERSION)" ] && facts_like 'DB_VERSION_|DB_NAME_|DB_PATCHES_|OPATCH_' | sed 's/^\([A-Z_]*\)_\([A-Za-z0-9]*\)=/- \2 \1: /; s/_/ /' | cut -c1-300
    [ -n "$(fact WLS_VERSION)" ] && printf -- '- WebLogic: %s; JDK: %s\n' "$(fact WLS_VERSION)" "$(fact WLS_JAVA || echo '?')"
    [ -n "$(fact ORDS_VERSION)" ] && printf -- '- ORDS: %s\n' "$(fact ORDS_VERSION)"; [ -n "$(facts_like APEX_)" ] && printf -- '- APEX: %s\n' "$(facts_like APEX_ | head -1 | cut -d= -f2)"
    [ -n "$(fact GG_HOME)" ] && printf -- '- GoldenGate home: %s\n' "$(fact GG_HOME)"; [ -n "$(fact EXADATA)" ] && printf -- '- Exadata: %s\n' "$(fact EXADATA)"
    printf -- '- Host: %s (%s), OS: %s\n' "$(fact HOST || echo "$HOST")" "$(fact FQDN || hostname)" "$(fact OS || echo 'TODO OS release and kernel')"
    [ -n "$(facts_like LISTENER_)" ] && printf -- '- Listeners: %s\n' "$(facts_like LISTENER_ | cut -d= -f1 | sed 's/LISTENER_//' | tr '\n' ' ')"
    printf -- '- RAC / Data Guard / Exadata / ZDLRA / OKV in use: TODO\n- Support Identifier (CSI): %s\n- Company / site: %s\n\n' "${SR_CSI:-TODO}" "${SR_COMPANY:-TODO}"
    printf '## Recent Changes\n\n'; local ch; ch="$(recent_changes)"; [ -n "$ch" ] && printf '%s\n' "$ch" || echo "- TODO: patches, parameter changes, deployments, OS updates, hardware/network changes in the last 30 days (none known?)"; echo
    printf '## Diagnostics Attached\n\n'; attached; echo
    printf '## MOS search strings\n\n```\n'; mos_search "$p" "$pv"; printf '```\n\n'
    printf '## Knowledge documents to check before/while filing\n\n'; mos_docs "$p"; echo
    printf '> Search MOS with the strings above first: a matching bug with a fix in a later RU/patch turns the SR into a patch request and saves days.\n'
  } >"$OUTDIR/SR.md"
  { echo "# MOS search strings for $title"; mos_search "$p" "$pv"; echo; echo "# Documents"; mos_docs "$p"; } >"$OUTDIR/MOS-SEARCH.txt"
}
write_prompt() {
  local alert; alert="$(ls "$PACK"/db/*/alert/*.window 2>/dev/null | head -1)"
  { printf '# Prompt for Claude: review this Oracle SR draft before it is filed\n\n'
    printf 'You are a senior Oracle DBA reviewing a draft Service Request. Below are the draft (SR.md), the facts gathered on the host, the error statistics, and excerpts of the evidence. The full incident pack is at `%s`%s.\n\n' "${PACK:-n/a}" "${TARBALL:+ (tarball $(basename "$TARBALL"))}"
    printf 'Please answer, in this order:\n1. Most likely cause(s), ranked, each with the evidence line that supports it and what would confirm or rule it out.\n2. Whether this looks like a known bug: which MOS searches (exact strings) and which knowledge documents to read, and what fix level (RU, one-off, parameter) would normally resolve it.\n3. What is missing from the pack that Support will ask for on the first update, and the exact commands to collect it.\n4. A rewritten Problem Summary and Problem Description (short, factual, first three lines carry the message), and whether the requested severity is justified.\n5. Immediate mitigation the DBA can take now without Support, and what NOT to do (e.g. restarts that destroy evidence).\n\n'
    printf '## SR.md\n\n'; sed 's/^#/##/' "$OUTDIR/SR.md"; echo
    [ -f "$FACTS_FILE" ] && { printf '## FACTS\n\n```\n'; cut -c1-300 "$FACTS_FILE"; printf '```\n\n'; }
    [ -n "$STATS" ] && { printf '## Error statistics (code|count|first|last|sample)\n\n```\n'; printf '%s\n' "$STATS" | head -30 | cut -c1-300; printf '```\n\n'; }
    [ -n "$alert" ] && { printf '## Alert log window (%s, first 120 lines)\n\n```\n' "${alert#"$PACK"/}"; head -120 "$alert" | cut -c1-300; printf '```\n\n'; }
    local rep; rep="$([ -n "$PACK" ] && find "$PACK/00_oracle-diag" -name REPORT.md 2>/dev/null | head -1)"; [ -n "$rep" ] && { printf '## oracle-diag FINDINGS\n\n'; sed -n '/^# FINDINGS/,/^---/p' "$rep" | head -60; echo; }
    [ -n "$PACK" ] && { printf '## Pack layout\n\n```\n'; (cd "$PACK" && find . -type f | sed 's#^\./##' | sort | head -150); printf '```\n\n'; }
    [ -n "$PACK" ] && { local t; for t in $(ls "$PACK"/db/*/traces/*.trc 2>/dev/null | head -2); do printf '## Trace excerpt %s (first 80 lines)\n\n```\n' "$(basename "$t")"; head -80 "$t" | cut -c1-300; printf '```\n\n'; done; }
    local sess; sess="$([ -n "$PACK" ] && find "$PACK/db" -path '*/sql/sessions.txt' 2>/dev/null | head -1)"; [ -n "$sess" ] && { printf '## Sessions / waits / blockers at collection time (first 80 lines)\n\n```\n'; head -80 "$sess" | cut -c1-250; printf '```\n'; }
  } >"$OUTDIR/CLAUDE-PROMPT.md"
}

main() {
  load_config; parse_opts "$@"
  [ -n "$PACK" ] || [ -n "$REPORT_DIR" ] || [ -n "$ERRORS_GIVEN" ] || [ -n "$ERROR_FILE" ] || { usage; exit 1; }
  [ -n "$PACK" ] && { [ -d "$PACK" ] || { [ -f "$PACK" ] && die "$PACK is a file: give the pack directory (untar it first)"; die "$PACK not found"; }; }
  [ -n "$OUTDIR" ] || OUTDIR="$([ -n "$PACK" ] && echo "$PACK/sr" || echo "$HOME/sr-draft/$(date '+%Y%m%d-%H%M%S')")"; mkdir -p "$OUTDIR" || die "cannot create $OUTDIR"
  if [ -n "$PACK" ]; then FACTS_FILE="$PACK/FACTS.txt"; [ -f "$FACTS_FILE" ] || warn "$PACK has no FACTS.txt (not an incident-pack directory?) - facts will be thin"
  elif [ -n "$REPORT_DIR" ]; then report_facts; else live_facts; fi
  mine_errors
  write_sr; write_prompt; rm -f "$OUTDIR/.facts"
  say "SR draft: $OUTDIR/SR.md  (headline: ${HEADLINE:-none}; $NERR distinct error code(s); product $(product_name "$(product_of)") $(product_version "$(product_of)"))"
  say "for Claude: $OUTDIR/CLAUDE-PROMPT.md   search strings: $OUTDIR/MOS-SEARCH.txt"
  grep -c TODO "$OUTDIR/SR.md" | sed 's/^/TODOs left in SR.md: /' >&2
  sed -n '/^## Problem Summary/,/^## Error Codes/p' "$OUTDIR/SR.md" | grep -vE '^## Error Codes|^>' | sed '/^$/N;/^\n$/D'
}
main "$@"
