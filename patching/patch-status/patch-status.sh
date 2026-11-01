#!/usr/bin/env bash
# patch-status.sh - every Oracle home on this host against the current quarter. Read-only.
# Database and Grid homes (RU / MRP / OJVM level and date, datapatch applied per database and PDB),
# WebLogic / FMW homes (PSU, Coherence, ADF/OPSS bundles), ORDS and APEX versions vs the newest
# public release, every JDK in use, GoldenGate, EM agent, AHF, kernel / Ksplice. One table:
# product, home, installed level, its date, how many Critical Patch Updates behind, status.
#
# Usage: patch-status.sh [options]
#   --mos             ask My Oracle Support (by patch name) for the newest RU / PSU for each release;
#                     needs ~/.netrc or MOS_USER/MOS_PASSWORD. Without it "latest" is derived from the
#                     CPU calendar (third Tuesday of Jan/Apr/Jul/Oct) and the public ORDS/APEX sites.
#   --no-net          no network at all (skip the ORDS/APEX public probes too)
#   --json | --csv    machine-readable table on stdout
#   --report          also write REPORT.md with FINDINGS to PATCH_OUT/<host>_<ts>/ (and tar.gz)
#   --out DIR  --quiet
#
# Config: patch-status.conf or the shared oracle.conf: PATCH_OUT, MOS_USER, MOS_PASSWORD, SQL_CONNECT.
# Status: CURRENT = patched to the latest CPU; "N behind" = N CPUs published since the installed
# level's date; UNKNOWN = no date could be read. Datapatch pending and EOL Java are CRIT.

# shellcheck disable=SC2034  # QUIET/VERBOSE read by the lib
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="patch-status"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

PATCH_OUT="${PATCH_OUT:-$HOME/patch-status}"; USE_MOS=0; NO_NET=0; FMT=table; DO_REPORT=0; MAKE_TAR=1
ROWS=""   # product|home|installed|date|latest|behind|status|note
LATEST_CPU="$(latest_cpu_date)"

usage() { usage_from_header "$0"; }
parse_args() {
  while [ $# -gt 0 ]; do case "$1" in
    --mos) USE_MOS=1; shift;; --no-net) NO_NET=1; shift;; --json) FMT=json; QUIET=1; shift;; --csv) FMT=csv; QUIET=1; shift;;
    --report) DO_REPORT=1; shift;; --out) optchk "$@"; PATCH_OUT="$2"; shift 2;; --quiet) QUIET=1; shift;; --no-tar) MAKE_TAR=0; shift;; --verbose) VERBOSE=1; shift;;
    -h|--help) usage; exit 0;; *) die "Unknown option: $1";; esac; done
}
# row <product> <home> <installed> <date YYYY-MM-DD|""> <latest> <note> ; status from the date
row() {
  local prod="$1" home="$2" inst="$3" date="$4" latest="$5" note="$6" behind status
  if [ -z "$date" ]; then behind="?"; status="UNKNOWN"
  else behind="$(quarters_behind "$date")"; case "$behind" in 0) status="CURRENT";; 1) status="1 behind";; *) status="$behind behind";; esac; fi
  ROWS="${ROWS}$prod|$home|$inst|${date:-?}|${latest:-?}|$behind|$status|$note"$'\n'
  [ "$DO_REPORT" = 1 ] && { case "$behind" in 0|\?) ;; 1) finding WARN patch "$prod ($home) is one CPU behind: $inst ($date)";; *) finding CRIT patch "$prod ($home) is $behind CPUs behind: $inst ($date)";; esac; }
  return 0
}
# dates: "Database Release Update 19.24.0.0.240716" -> 2024-07-16 ; "WLS PATCH SET UPDATE 12.2.1.4.240415" -> 2024-04-15
date_from_desc() { local d; d="$(printf '%s' "$1" | grep -oE '\.[0-9]{6}\b' | tail -1 | tr -d .)"; [ -n "$d" ] && yymmdd_to_date "$d"; }

# ---------------------------------------------------------------------------
db_homes() { # ru/mrp/ojvm per oratab home + datapatch per database
  local h; for h in $(grep -hvE '^\s*#|^\s*$' /etc/oratab /var/opt/oracle/oratab 2>/dev/null | cut -d: -f2 | sort -u); do
    [ -x "$h/OPatch/opatch" ] || { row "Database home" "$h" "?" "" "" "no OPatch in this home - patch level unknown"; continue; }
    local lsp; lsp="$(to 180 "$h/OPatch/opatch" lspatches 2>/dev/null)"
    local isgrid=0; [ -x "$h/bin/crsctl" ] && isgrid=1
    local ru ruline; ruline="$(printf '%s\n' "$lsp" | grep -iE 'Database Release Update|DATABASE RELEASE UPDATE|Grid Infrastructure Release Update|OCW RELEASE UPDATE|DATABASE BUNDLE PATCH|DATABASE PATCH SET UPDATE' | grep -viE 'OJVM|MONTHLY' | sort -t';' -k2 | tail -1)"
    ru="$(printf '%s' "$ruline" | cut -d';' -f2 | sed 's/^ *//')"; local rudate; rudate="$(date_from_desc "$ruline")"
    local mrp; mrp="$(printf '%s\n' "$lsp" | grep -iE 'MONTHLY RECOMMENDED PATCHES|MRP' | tail -1 | cut -d';' -f2)"
    local ojvm ojvmdate; ojvm="$(printf '%s\n' "$lsp" | grep -iE 'OJVM' | tail -1 | cut -d';' -f2 | sed 's/^ *//')"; ojvmdate="$(date_from_desc "$ojvm")"
    local base; base="$("$h/bin/sqlplus" -V 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; [ -z "$base" ] && base="$(sed -n 's/.*name="Oracle Database[^"]*"[^>]*version="\([0-9.]*\)".*/\1/p' "$h/inventory/registry.xml" 2>/dev/null | head -1)"
    local prod="Database home"; [ "$isgrid" = 1 ] && prod="Grid Infrastructure home"
    local opv; opv="$("$h/OPatch/opatch" version 2>/dev/null | sed -n 's/^OPatch Version: *//p')"
    row "$prod" "$h" "${ru:-no RU found (base $base)}" "$rudate" "$(mos_latest_db "$base")" "OPatch $opv${mrp:+; $mrp}"
    [ -n "$ojvm" ] && row "OJVM ($(basename "$h"))" "$h" "$ojvm" "$ojvmdate" "" ""
    printf '%s\n' "$lsp" >"$RAW/lspatches_$(basename "$h").txt" 2>/dev/null
  done
  # datapatch per running database
  local sid; for sid in $(db_instances | grep -vE '^\+ASM|^-MGMTDB|^\+APX'); do
    sql_ok "$sid" || { row "Database $sid" "$(db_home_of "$sid")" "cannot connect" "" "" "sqlplus / as sysdba failed"; continue; }
    local rows; rows="$(sql_lines "$sid" "select con||'|'||nvl(max(case when status='SUCCESS' then description end),'none')||'|'||nvl(to_char(max(case when status='SUCCESS' then action_time end),'YYYY-MM-DD'),'-')||'|'||sum(case when status not in ('SUCCESS','IGNORED') then 1 else 0 end) from (select (select name from v\$containers c where c.con_id=p.con_id) con, p.* from cdb_registry_sqlpatch p where p.action='APPLY' and p.description not like '%OJVM%') group by con order by con;" 2>/dev/null)"
    [ -z "$rows" ] && rows="$(sql_lines "$sid" "select '$sid|'||nvl(max(case when status='SUCCESS' then description end),'none')||'|'||nvl(to_char(max(case when status='SUCCESS' then action_time end),'YYYY-MM-DD'),'-')||'|'||sum(case when status not in ('SUCCESS','IGNORED') then 1 else 0 end) from dba_registry_sqlpatch where action='APPLY' and description not like '%OJVM%';" 2>/dev/null)"
    local home; home="$(db_home_of "$sid")"; local homeru; homeru="$(to 120 "$home/OPatch/opatch" lspatches 2>/dev/null | grep -iE 'Database Release Update|DATABASE RELEASE UPDATE' | grep -viE 'OJVM|MONTHLY' | tail -1 | cut -d';' -f2 | sed 's/^ *//')"
    while IFS='|' read -r con desc when bad; do   # no pipe: row() must run in this shell
      [ -z "$con" ] && continue
      local note="" d; d="$(date_from_desc "$desc")"
      if [ -n "$homeru" ] && [ "$desc" != "$homeru" ]; then note="DATAPATCH PENDING: home has '$homeru'"; [ "$DO_REPORT" = 1 ] && finding CRIT patch "$sid/$con: binary RU is '$homeru' but datapatch level is '$desc' - run datapatch -verbose"; fi
      [ "${bad:-0}" != 0 ] && note="${note:+$note; }$bad failed/partial datapatch entries"
      row "datapatch $sid/$con" "$home" "$desc" "$d" "" "$note"
    done <<<"$rows"
    local v; v="$(sql_val "$sid" "(select version_full from v\$instance)" 2>/dev/null)"; [ -z "$v" ] && v="$(sql_val "$sid" "(select version from v\$instance)" 2>/dev/null)"
    [ -n "$v" ] && [ "$DO_REPORT" = 1 ] && kv "$sid version_full" "$v" && kv_end
    # premier-support reminder for old releases
    case "$v" in 11.*|12.1*|12.2*|18.*) [ "$DO_REPORT" = 1 ] && finding CRIT patch "$sid is release $v - out of Premier Support, no more RUs without Extended/Market-driven support";; esac
  done
}
mos_latest_db() { # <base version>: newest "Database Release Update <major>" from MOS if --mos, else expected from the CPU calendar
  local base="$1"; [ -z "$base" ] && return
  local major="${base%%.*}"
  if [ "$USE_MOS" = 1 ] && [ -n "${MOS_CURL[*]:-}" ]; then
    local r; r="$(mos_name_search "Database Release Update $major" 2>/dev/null | grep -iE "Database Release Update $major\.[0-9]+" | awk -F'|' '{match($2,/[0-9]{6}\)?$/); print substr($2,RSTART,6) "|" $0}' | sort -r | head -1 | cut -d'|' -f2-)"
    [ -n "$r" ] && { printf '%s' "$r" | cut -d'|' -f2 | sed 's/^ *//'; return; }
  fi
  printf 'RU of %s' "$LATEST_CPU"
}

fmw_homes() {
  local h; for h in $(wls_homes); do
    [ -x "$h/OPatch/opatch" ] || { row "WebLogic (BSU era)" "$h" "$(wls_version "$h")" "" "" "BSU-based home: patching by bsu.sh, out of support"; continue; }
    local lsp; lsp="$(to 180 "$h/OPatch/opatch" lspatches 2>/dev/null)"; printf '%s\n' "$lsp" >"$RAW/lspatches_$(basename "$h").txt" 2>/dev/null
    local v; v="$(wls_version "$h")"
    local psu; psu="$(printf '%s\n' "$lsp" | grep -i 'WLS PATCH SET UPDATE' | sort | tail -1 | cut -d';' -f2 | sed 's/^ *//')"
    local latest=""; if [ "$USE_MOS" = 1 ] && [ -n "${MOS_CURL[*]:-}" ]; then local short="${v%.*}"; case "$v" in 14.1.*) short="${short%.*}";; esac; latest="$(mos_name_search "WLS PATCH SET UPDATE $short" 2>/dev/null | grep -E "WLS PATCH SET UPDATE $short(\.0)?\.[0-9]{6} *$" | awk -F'|' '{match($2,/[0-9]{6}$/); print substr($2,RSTART,6) "|" $2}' | sort -r | head -1 | cut -d'|' -f2)"; fi
    [ -z "$latest" ] && latest="PSU of $LATEST_CPU"
    row "WebLogic $v" "$h" "${psu:-no PSU}" "$(date_from_desc "$psu")" "$latest" "OPatch $("$h/OPatch/opatch" version 2>/dev/null | sed -n 's/^OPatch Version: *//p')"
    case "$v" in 12.1.*|10.3.*) [ "$DO_REPORT" = 1 ] && finding CRIT patch "WebLogic $v in $h is out of Premier Support";; 12.2.1.3*) [ "$DO_REPORT" = 1 ] && finding CRIT patch "WebLogic 12.2.1.3 in $h: no more PSUs (upgrade to 12.2.1.4 / 14.1.x)";; esac
    local b; while read -r b; do
      [ -z "$b" ] && continue; local d; d="$(printf '%s' "$b" | cut -d';' -f2 | sed 's/^ *//')"
      row "FMW bundle ($(basename "$h"))" "$h" "$d" "$(date_from_desc "$d")" "" ""
    done < <(printf '%s\n' "$lsp" | grep -iE 'Coherence|ADF BUNDLE|OPSS BUNDLE|OWSM BUNDLE|SOA BUNDLE|OSB BUNDLE|OHS|FMW PLATFORM|JDEV|WebCenter|OAM BUNDLE|OIM BUNDLE|FORMS|REPORTS|BI PATCH' | grep -viE 'WLS PATCH SET UPDATE')
    local j; j="$(wls_java_home "$h")"; [ -n "$j" ] && java_row "$j" "WebLogic $(basename "$h")"
  done
}

java_row() { # <java_home> <used by>
  local j="$1" by="$2"; [ -x "$j/bin/java" ] || return 0
  local v d; v="$(java_version_of "$j")"; [ -z "$v" ] && return 0
  d="$("$j/bin/java" -version 2>&1 | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}' | head -1)"
  [ -z "$d" ] && d="$(sed -n 's/^JAVA_VERSION_DATE="\([^"]*\)".*/\1/p' "$j/release" 2>/dev/null)"
  [ -z "$d" ] && { local bd; bd="$(file_mtime "$j/bin/java" | cut -c1-10)"; d="$bd"; }
  local major; major="$(java_major_of "$j")"; local note="used by $by"
  case "$major" in 6|7) note="$note; EOL"; [ "$DO_REPORT" = 1 ] && finding CRIT patch "JDK $v ($j) used by $by is end-of-life";; 8) note="$note; JDK 8 - extended support only";; esac
  local vendor; vendor="$(sed -n 's/^IMPLEMENTOR="\([^"]*\)".*/\1/p' "$j/release" 2>/dev/null)"
  row "Java $major ($vendor)" "$j" "$v" "$d" "CPU of $LATEST_CPU" "$note"
}
other_products() {
  if ords_detect; then
    local latest=""; [ "$NO_NET" = 0 ] && latest="$(to 30 curl -sSL -r 0-200000 https://download.oracle.com/otn_software/java/ords/ords-latest.zip -o "$RAW/ords-head.zip" 2>/dev/null && unzip -p "$RAW/ords-head.zip" 'README*' 2>/dev/null | grep -oE 'ORDS [0-9]+\.[0-9]+\.[0-9]+' | head -1 | awk '{print $2}')"
    [ -z "$latest" ] && [ "$NO_NET" = 0 ] && latest="$(to 30 curl -sSI https://download.oracle.com/otn_software/java/ords/ords-latest.zip 2>/dev/null | grep -i 'content-disposition' | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    local d=""; [ -n "$ORDS_VER" ] && d="$(ords_release_date "$ORDS_VER")"
    row "ORDS" "${ORDS_HOME:-running pid $ORDS_PID}" "${ORDS_VER:-unknown}" "$d" "${latest:-(public site not checked)}" "$([ -n "$latest" ] && [ -n "$ORDS_VER" ] && ! version_ge "$ORDS_VER" "$latest" && echo "newer release available: $latest")"
    [ -n "$latest" ] && [ -n "$ORDS_VER" ] && ! version_ge "$ORDS_VER" "$latest" && [ "$DO_REPORT" = 1 ] && finding WARN patch "ORDS $ORDS_VER installed, $latest is the current release (ords-patch.sh)"
    local pids p; pids="$ORDS_PID"; for p in $pids; do local j; j="$(dirname "$(dirname "$(readlink -f "/proc/$p/exe" 2>/dev/null)")")"; [ -x "$j/bin/java" ] && java_row "$j" "ORDS"; done
  fi
  local sid; for sid in $(db_instances | grep -vE '^\+ASM|^-MGMTDB|^\+APX'); do
    sql_ok "$sid" || continue
    local pdbs=""; db_is_cdb "$sid" && pdbs="$(db_pdbs "$sid")" || pdbs="$sid"
    local p; for p in $pdbs; do
      local av; av="$(with_pdb "$p" sql_val "$sid" "(select version_no||'|'||to_char(patch_applied_on,'YYYY-MM-DD') from apex_release)" 2>/dev/null)"
      [ -z "$av" ] && continue
      local latest=""; [ "$NO_NET" = 0 ] && latest="$(to 30 curl -sS https://download.oracle.com/otn_software/apex/ 2>/dev/null | grep -oE 'apex_[0-9]+\.[0-9]+(\.[0-9]+)?' | sed 's/apex_//' | sort -V | tail -1)"
      [ -z "$latest" ] && [ "$NO_NET" = 0 ] && latest="$(to 30 curl -sSI https://download.oracle.com/otn_software/apex/apex-latest.zip 2>/dev/null | grep -i 'content-disposition' | grep -oE '[0-9]+\.[0-9]+' | head -1)"
      row "APEX $sid/$p" "$sid" "${av%%|*}" "${av#*|}" "${latest:-(public site not checked)}" "$([ -n "$latest" ] && ! version_ge "${av%%|*}" "$latest" && echo "newer release available: $latest")"
      [ -n "$latest" ] && ! version_ge "${av%%|*}" "$latest" && [ "$DO_REPORT" = 1 ] && finding WARN patch "APEX ${av%%|*} in $sid/$p, $latest is current (apex-patch.sh)"
    done
  done
  if ogg_detect && [ -x "${OGG_HOME:-/nonexistent}/ggsci" ]; then
    local gv; gv="$(ggsci "versions" 2>/dev/null | grep -oE 'Version [0-9][0-9.]+' | head -1 | awk '{print $2}')"; [ -z "$gv" ] && gv="$(to 30 "$OGG_HOME/ggsci" -v 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    local gd; gd="$(printf '%s' "$gv" | grep -oE '[0-9]{6}$')"; [ -n "$gd" ] && gd="$(yymmdd_to_date "$gd")"
    [ -x "$OGG_HOME/OPatch/opatch" ] && { local gp; gp="$(to 120 "$OGG_HOME/OPatch/opatch" lspatches 2>/dev/null | tail -1 | cut -d';' -f2 | sed 's/^ *//')"; [ -n "$gp" ] && gd="$(date_from_desc "$gp")"; }
    row "GoldenGate" "$OGG_HOME" "${gv:-unknown}" "$gd" "" ""
  fi
  local ah; ah="$(ls -d /u01/app/oracle/agent*/agent_inst /u01/app/oracle/product/agent*/agent_inst /opt/oracle/agent*/agent_inst 2>/dev/null | head -1)"
  [ -x "$ah/bin/emctl" ] && { local ev; ev="$(to 60 "$ah/bin/emctl" status agent 2>/dev/null | sed -n 's/^Agent Version *: *//p')"; row "EM agent" "$ah" "${ev:-unknown}" "" "" ""; }
  local t; t="$(ls /opt/oracle.ahf/bin/tfactl /u01/app/oracle.ahf/bin/tfactl 2>/dev/null | head -1)"
  [ -n "$t" ] && { local av; av="$(to 60 "$(dirname "$t")/ahfctl" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; [ -z "$av" ] && av="$(to 60 "$t" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; row "AHF" "$(dirname "$(dirname "$t")")" "${av:-unknown}" "" "" "AHF is updated monthly; check MOS 2550798.1"; }
  local kd; kd="$(uptrack-uname -r 2>/dev/null)"; row "Kernel" "$(uname -r)" "${kd:-$(uname -r)}" "$(rpm -q --qf '%{INSTALLTIME:date}\n' kernel-uek 2>/dev/null | tail -1 | xargs -I{} date -d {} +%Y-%m-%d 2>/dev/null)" "" "$([ -n "$kd" ] && echo 'Ksplice effective kernel' || echo 'no Ksplice')"
  local j; for j in $(java_homes); do grep -q "|$j|" <<<"$ROWS" || java_row "$j" "found on host"; done
}
ords_release_date() { # ORDS x.y.z -> yy.q: 24.3 = 2024 Q3 release (Jul-Sep); treat as the CPU of that quarter
  local v="$1" yy q; yy="${v%%.*}"; q="$(printf '%s' "$v" | cut -d. -f2)"; case "$q" in 1) printf '20%s-01-15' "$yy";; 2) printf '20%s-04-15' "$yy";; 3) printf '20%s-07-15' "$yy";; 4) printf '20%s-10-15' "$yy";; esac
}

print_table() {
  case "$FMT" in
    csv) echo "product,home,installed,date,latest,cpus_behind,status,note"; printf '%s' "$ROWS" | awk -F'|' 'BEGIN{OFS=","} {for(i=1;i<=NF;i++) gsub(/,/,";",$i); $1=$1; print}';;
    json) printf '{"host":"%s","latest_cpu":"%s","rows":[' "$HOST" "$LATEST_CPU"; printf '%s' "$ROWS" | awk -F'|' 'NR>1{printf ","} {printf "{\"product\":\"%s\",\"home\":\"%s\",\"installed\":\"%s\",\"date\":\"%s\",\"latest\":\"%s\",\"behind\":\"%s\",\"status\":\"%s\",\"note\":\"%s\"}", $1,$2,$3,$4,$5,$6,$7,$8}'; echo "]}";;
    *) printf '\nPatch status for %s   (latest Critical Patch Update: %s)\n\n' "$HOST" "$LATEST_CPU"
       { echo "product|home|installed|date|latest|behind|status|note"; printf '%s' "$ROWS"; } | awk -F'|' '{printf "%-28s %-45s %-50s %-10s %-24s %-6s %-9s %s\n", substr($1,1,28), substr($2,1,45), substr($3,1,50), $4, substr($5,1,24), $6, $7, $8}';;
  esac
}

main() {
  load_config; parse_args "$@"
  if [ "$DO_REPORT" = 1 ]; then report_init "$PATCH_OUT/${HOST}_$(date '+%Y%m%d_%H%M%S')"; else RAW="$(mktemp -d)"; FINDINGS_FILE="$RAW/f.txt"; fi
  [ "$NO_NET" = 0 ] && ! net_ok && { NO_NET=1; USE_MOS=0; say "no internet from this host: newest ORDS/APEX not checked, MOS not asked (the CPU calendar still gives the quarter)"; }
  [ "$USE_MOS" = 1 ] && [ "$NO_NET" = 0 ] && { RUN_BASE="$RAW"; mos_login; }
  say "patch-status $VERSION (latest CPU $LATEST_CPU, mos=$USE_MOS)"
  db_homes; fmw_homes; other_products
  [ "$USE_MOS" = 1 ] && mos_cleanup
  print_table
  if [ "$DO_REPORT" = 1 ]; then
    findings_sync
    h1 "Patch status table"; table_head "product" "home" "installed" "date" "latest" "CPUs behind" "status" "note"
    printf '%s' "$ROWS" | while IFS='|' read -r a b c d e f g n; do [ -n "$a" ] && table_row "$a" "$b" "$c" "$d" "$e" "$f" "$g" "$n"; done; echo >>"$REPORT"
    h1 "opatch lspatches per home"; local f; for f in "$RAW"/lspatches_*.txt; do [ -f "$f" ] || continue; h3 "$(basename "$f" .txt)"; fence_start; cat "$f" >>"$REPORT"; fence_end; done
    para "Where to find the numbers: Database/GI RU and OJVM: MOS 2118136.2 (Primary Note for Database Proactive Patch Program). FMW/WebLogic: MOS 2806740.2 (CPU Patch Advisor). Java: the CPU advisory page. ORDS/APEX: public downloads. AHF: 2550798.1."
    report_finish "patch-status: $HOST $(date '+%Y-%m-%d')" "$MAKE_TAR" >/dev/null; printf '\n%s\n' "$OUT/REPORT.md"
  else rm -rf "$RAW"; fi
}
main "$@"
