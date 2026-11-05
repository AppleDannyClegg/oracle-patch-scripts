#!/usr/bin/env bash
# patch-status.sh - every Oracle home on this host against the current quarter. Read-only.
# Database and Grid homes (RU / MRP / OJVM level and date, datapatch applied per database and PDB),
# WebLogic / FMW homes (PSU, Coherence, ADF/OPSS bundles), ORDS and APEX versions vs the newest
# public release, every JDK in use, GoldenGate, Enterprise Manager OMS and agent (RU from lspatches; OMS_HOME /
# EM_AGENT_INST when not in the usual places), AHF, kernel / Ksplice. One table:
# product, home, installed level, its date, how many Critical Patch Updates behind, status.
#
# Usage: patch-status.sh [options]
#   --mos             ask My Oracle Support (by patch name) for the newest RU / PSU for each release;
#                     needs a MOS bearer token in MOS_TOKEN_FILE (default ~/.mos-token) or MOS_TOKEN. Without it "latest" is derived from the
#                     CPU calendar (third Tuesday of Jan/Apr/Jul/Oct) and the public ORDS/APEX sites.
#   --no-net          no network at all (skip the ORDS/APEX public probes too)
#   --json | --csv    machine-readable table on stdout
#   --report          also write REPORT.md with FINDINGS to PATCH_OUT/<host>_<ts>/ (and tar.gz)
#   --out DIR  --quiet
#
# Config: patch-status.conf or the shared oracle.conf: PATCH_OUT, MOS_TOKEN_FILE, SQL_CONNECT.
# Status: CURRENT = patched to the latest CPU; "N behind" = N CPUs published since the installed
# level's date; UNKNOWN = no date could be read; info = an FMW component bundle whose level has no CPU
# date to compare against (e.g. a Coherence Cumulative Patch, '...12.2.1.4.30'), so it is not date-scored.
# Datapatch pending and EOL Java are CRIT.
# Exit: 2 with a CRIT finding, 1 with a WARN, 0 clean. A home or database whose level could not be read (opatch lspatches
# failed, sqlplus failed, the registry could not be read) is a WARN in every output mode: unknown is never shown as current.

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
# row <product> <home> <installed> <date YYYY-MM-DD|""> <latest> <note> [level|info|reported|named]
# level = there is a level to read (an undated one WARNs); info = no level exists, never WARN;
# reported = the caller already raised the finding for this failed read; named = the caller raised a specific one.
# An EMPTY date is a real 'level unknown' -> '?' + UNKNOWN. An EMPTY latest is 'no comparison was
# available' (a bundle, a kernel, an agent with no RU), which is not the same thing -> '-', so a row
# does not read '?' for a value that was never meant to exist (Daniel 14:4x).
row() {
  local prod="$1" home="$2" inst="$3" date="$4" latest="$5" note="$6" kind="${7:-level}" behind status
  if [ -z "$date" ]; then behind="?"; status="UNKNOWN"
  else behind="$(quarters_behind "$date")"; case "$behind" in 0) status="CURRENT";; 1) status="1 behind";; *) status="$behind behind";; esac; fi
  ROWS="${ROWS}$prod|${home}|${inst}|${date:-?}|${latest:--}|$behind|$status|$note"$'\n'
  # A level that could not be dated is 'unknown', not clean. Without --report the findings are the only thing
  # that sets the exit code, so a table/cron run over a stale estate used to exit 0; say it in every mode.
  if [ "$behind" = "?" ]; then
    [ "$kind" = level ] && [ -n "$home" ] && finding WARN patch "$prod ($home): patch level unknown - $inst${note:+ ($note)}"
  elif [ "$DO_REPORT" = 1 ]; then case "$behind" in 0) ;; 1) finding WARN patch "$prod ($home) is one CPU behind: $inst ($date)";; *) finding CRIT patch "$prod ($home) is $behind CPUs behind: $inst ($date)";; esac; fi
  return 0
}
# lsp_read <opatch> <timeout>: the inventory on stdout, opatch's own status as the return. An lspatches that could not run
# (wrong ORACLE_HOME, broken inventory, timeout) printed nothing and every caller read that as 'no RU found' - a home it could
# not read shown as unpatched, the worst direction for this report (Multivac / TARS, 1 Nov 23:22). Callers run it in $(...),
# so the status comes back only as the return value - never through a variable set inside (a subshell cannot set one).
# opatch acts on $ORACLE_HOME, not on the binary's own path, so it is scoped to the home the binary belongs to
# (every caller passes <home>/OPatch/opatch); otherwise every home is read from the exported one.
lsp_read() { local out rc=0 home; home="$(dirname "$(dirname "$1")")"; out="$(ORACLE_HOME="$home" to "$2" "$1" lspatches 2>/dev/null)" || rc=$?; printf '%s\n' "$out"; return $rc; }
lsp_unreadable() { printf 'opatch lspatches unreadable (rc %s) - patch level unknown' "$1"; }
# dates: "Database Release Update 19.24.0.0.240716" -> 2024-07-16 ; "WLS PATCH SET UPDATE 12.2.1.4.240415" -> 2024-04-15
date_from_desc() { local d; d="$(printf '%s' "$1" | grep -oE '\.[0-9]{6}\b' | tail -1 | tr -d .)"; [ -n "$d" ] && yymmdd_to_date "$d"; }
# db_ru_date_from_desc <database/Grid RU description>: date_from_desc, plus the 23ai shape. 23ai RUs
# carry no 6-digit yymmdd - "23.6.0.24.10" is year 24 month 10, and the RU ships on that month's CPU
# Tuesday. Kept to the database-RU call sites, not widened inside date_from_desc, so an FMW/Coherence
# version ending in two 2-digit parts is never read as a date. (EM RUs are not versioned this way;
# their rows warn rather than render clean.)
db_ru_date_from_desc() {
  local d ym; d="$(date_from_desc "$1")"
  [ -n "$d" ] && { printf '%s' "$d"; return; }
  # the description ends in the patch id, so pull the 5-part version token out first, then take its YY.MM tail
  ym="$(printf '%s' "$1" | grep -oE '[0-9]+(\.[0-9]+){4}' | tail -1 | grep -oE '[0-9]{2}\.[0-9]{2}$')"
  case "${ym#*.}" in 0[1-9]|1[0-2]) cpu_date "20${ym%%.*}" "$((10#${ym#*.}))";; esac
}

# ---------------------------------------------------------------------------
db_homes() { # ru/mrp/ojvm per oratab home + datapatch per database
  local h; for h in $(grep -hvE '^\s*#|^\s*$' /etc/oratab /var/opt/oracle/oratab 2>/dev/null | cut -d: -f2 | sort -u); do
    [ -x "$h/OPatch/opatch" ] || { row "Database home" "$h" "?" "" "" "no OPatch in this home - patch level unknown"; continue; }
    local isgrid=0; [ -x "$h/bin/crsctl" ] && isgrid=1
    local lsp lrc=0; lsp="$(lsp_read "$h/OPatch/opatch" 180)" || lrc=$?
    [ "$lrc" = 0 ] || { local p2="Database home"; [ "$isgrid" = 1 ] && p2="Grid Infrastructure home"
      row "$p2" "$h" "$(lsp_unreadable "$lrc")" "" "" "opatch could not list the inventory - run $h/OPatch/opatch lspatches by hand" reported
      finding WARN patch "$p2 $h: opatch lspatches failed (rc $lrc) - its patch level is unknown, not unpatched"; continue; }
    local ru ruline; ruline="$(printf '%s\n' "$lsp" | grep -iE 'Database Release Update|DATABASE RELEASE UPDATE|Grid Infrastructure Release Update|OCW RELEASE UPDATE|DATABASE BUNDLE PATCH|DATABASE PATCH SET UPDATE' | grep -viE 'OJVM|MONTHLY' | sort -t';' -k2 | tail -1)"
    ru="$(printf '%s' "$ruline" | cut -d';' -f2 | sed 's/^ *//')"; local rudate; rudate="$(db_ru_date_from_desc "$ruline")"
    local mrp; mrp="$(printf '%s\n' "$lsp" | grep -iE 'MONTHLY RECOMMENDED PATCHES|MRP' | tail -1 | cut -d';' -f2)"
    local ojvm ojvmdate; ojvm="$(printf '%s\n' "$lsp" | grep -iE 'OJVM' | tail -1 | cut -d';' -f2 | sed 's/^ *//')"; ojvmdate="$(db_ru_date_from_desc "$ojvm")"
    # sqlplus reads its home from $ORACLE_HOME too: unscoped, the exported home's sqlplus fails and the base
    # version (and with it the latest-RU column) is lost
    local base; base="$(ORACLE_HOME="$h" LD_LIBRARY_PATH="$h/lib:${LD_LIBRARY_PATH:-}" "$h/bin/sqlplus" -V 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; [ -z "$base" ] && base="$(sed -n 's/.*name="Oracle Database[^"]*"[^>]*version="\([0-9.]*\)".*/\1/p' "$h/inventory/registry.xml" 2>/dev/null | head -1)"
    local prod="Database home"; [ "$isgrid" = 1 ] && prod="Grid Infrastructure home"
    local opv; opv="$(ORACLE_HOME="$h" "$h/OPatch/opatch" version 2>/dev/null | sed -n 's/^OPatch Version: *//p')"
    local latest note kind="level"; latest="$(mos_latest_db "$base")"; note="OPatch $opv${mrp:+; $mrp}"
    case "$base" in
      23.*|26.*) [ -n "$ru" ] || {
        # 23ai/26ai with no RU in lspatches: the release version IS the level, and it carries no yymmdd, so
        # there is no quarter to score it against - name the case instead of leaving a bare 'unknown'
        kind="named"; latest="-"; note="$note; release version $base, no RU in lspatches - 23ai/26ai levels carry no yymmdd, so the CPU quarter cannot be derived (not a failed read)"
        finding WARN patch "$prod $h: no RU in lspatches; the level is the release version $base and 23ai/26ai RUs are not yymmdd-dated - CPU quarter not derivable (not a failed read)"; } ;;
    esac
    row "$prod" "$h" "${ru:-no RU found (base $base)}" "$rudate" "$latest" "$note" "$kind"
    [ -n "$ojvm" ] && row "OJVM ($(basename "$h"))" "$h" "$ojvm" "$ojvmdate" "" ""
    printf '%s\n' "$lsp" >"$RAW/lspatches_$(basename "$h").txt" 2>/dev/null
  done
  # datapatch per running database. The loop head tests db_instances' status (lib b728ff6): a process list that cannot be read
  # is a row + CRIT, not an empty loop with no Database row (tests/unreadable-gate.sh ps mode, f7d2f83)
  local sids="" sid; if sids="$(db_instances)"; then sids="$(printf '%s\n' "$sids" | grep -vE '^\+ASM|^-MGMTDB|^\+APX')" || true
  else row "Database ?" "" "process list unreadable" "" "" "cannot read the process list (ps failed, $PROC_DIR unreadable) - no database was found or checked"
    finding CRIT patch "cannot read the process list (ps failed, $PROC_DIR unreadable) - no database was found or checked"; fi
  for sid in $sids; do
    sql_ok "$sid" || { row "Database $sid" "$(db_home_of "$sid")" "cannot connect" "" "" "sqlplus / as sysdba failed" reported; finding WARN patch "Database $sid: sqlplus / as sysdba failed - its datapatch level is unknown, not current"; continue; }
    # the registry read: cdb_registry_sqlpatch first (a non-CDB has no such view, so that read is allowed to fail), then
    # dba_registry_sqlpatch - and THAT read's status is kept: both used to be '2>/dev/null' with the status dropped, so a database
    # whose registry could not be read (ORA-00942, ORA-01031, SQL_TIMEOUT) had no datapatch row at all - the only report whose job is
    # 'every home against the quarter' omitted the database silently (Marvin 23:42 run, Multivac 23:45 line ref, 1 Nov)
    local rows rrc=0; rows="$(sql_lines "$sid" "select con||'|'||nvl(max(case when status='SUCCESS' then description end),'none')||'|'||nvl(to_char(max(case when status='SUCCESS' then action_time end),'YYYY-MM-DD'),'-')||'|'||sum(case when status not in ('SUCCESS','IGNORED') then 1 else 0 end) from (select (select name from v\$containers c where c.con_id=p.con_id) con, p.* from cdb_registry_sqlpatch p where p.action='APPLY' and p.description not like '%OJVM%') group by con order by con;" 2>/dev/null)" || true
    local rerr=""
    if [ -z "$rows" ]; then rows="$(sql_lines "$sid" "select '$sid|'||nvl(max(case when status='SUCCESS' then description end),'none')||'|'||nvl(to_char(max(case when status='SUCCESS' then action_time end),'YYYY-MM-DD'),'-')||'|'||sum(case when status not in ('SUCCESS','IGNORED') then 1 else 0 end) from dba_registry_sqlpatch where action='APPLY' and description not like '%OJVM%';" 2>"$RAW/registry_$sid.err")" || rrc=$?
      rerr="$(grep -m1 -oE '(ORA|SP2)-[0-9]+[^|]*' "$RAW/registry_$sid.err" 2>/dev/null | cut -c1-80)"; fi
    local home; home="$(db_home_of "$sid")"
    [ "$rrc" = 0 ] || { row "Database $sid" "$home" "datapatch level unreadable (rc $rrc)" "" "" "registry_sqlpatch could not be read${rerr:+: $rerr} - run datapatch -prereq / query dba_registry_sqlpatch by hand" reported
      finding WARN patch "Database $sid: dba_registry_sqlpatch could not be read (rc $rrc${rerr:+, $rerr}) - its datapatch level is unknown, not current"; continue; }
    local homeru homelsp hrc=0 hnote=""; homelsp="$(lsp_read "$home/OPatch/opatch" 120)" || hrc=$?
    # a home whose lspatches failed cannot be compared with the registry: the row says so instead of rendering clean with an
    # empty note (Colossus 23:33 - warn() goes to the terminal and the log, never to the table or FINDINGS)
    [ "$hrc" = 0 ] || { hnote="binary RU unknown (opatch lspatches in $home failed, rc $hrc) - DATAPATCH PENDING cannot be judged"; finding WARN patch "$sid: opatch lspatches in $home failed (rc $hrc) - the binary RU is unknown, so datapatch state cannot be judged for this database"; }
    homeru="$(printf '%s\n' "$homelsp" | grep -iE 'Database Release Update|DATABASE RELEASE UPDATE' | grep -viE 'OJVM|MONTHLY' | tail -1 | cut -d';' -f2 | sed 's/^ *//')"
    while IFS='|' read -r con desc when bad; do   # no pipe: row() must run in this shell
      [ -z "$con" ] && continue
      local note="$hnote" d; d="$(db_ru_date_from_desc "$desc")"
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
    local v; v="$(wls_version "$h")"
    local lsp lrc=0; lsp="$(lsp_read "$h/OPatch/opatch" 180)" || lrc=$?
    [ "$lrc" = 0 ] || { row "WebLogic $v" "$h" "$(lsp_unreadable "$lrc")" "" "" "opatch could not list the inventory - run $h/OPatch/opatch lspatches by hand" reported
      finding WARN patch "WebLogic $h: opatch lspatches failed (rc $lrc) - its PSU level is unknown, not unpatched"; continue; }
    printf '%s\n' "$lsp" >"$RAW/lspatches_$(basename "$h").txt" 2>/dev/null
    local psu; psu="$(printf '%s\n' "$lsp" | grep -i 'WLS PATCH SET UPDATE' | sort | tail -1 | cut -d';' -f2 | sed 's/^ *//')"
    local latest=""; if [ "$USE_MOS" = 1 ] && [ -n "${MOS_CURL[*]:-}" ]; then local short="${v%.*}"; case "$v" in 14.1.*) short="${short%.*}";; esac; latest="$(mos_name_search "WLS PATCH SET UPDATE $short" 2>/dev/null | grep -E "WLS PATCH SET UPDATE $short(\.0)?\.[0-9]{6} *$" | awk -F'|' '{match($2,/[0-9]{6}$/); print substr($2,RSTART,6) "|" $2}' | sort -r | head -1 | cut -d'|' -f2)"; fi
    [ -z "$latest" ] && latest="PSU of $LATEST_CPU"
    row "WebLogic $v" "$h" "${psu:-no PSU}" "$(date_from_desc "$psu")" "$latest" "OPatch $(ORACLE_HOME="$h" "$h/OPatch/opatch" version 2>/dev/null | sed -n 's/^OPatch Version: *//p')"
    case "$v" in 12.1.*|10.3.*) [ "$DO_REPORT" = 1 ] && finding CRIT patch "WebLogic $v in $h is out of Premier Support";; 12.2.1.3*) [ "$DO_REPORT" = 1 ] && finding CRIT patch "WebLogic 12.2.1.3 in $h: no more PSUs (upgrade to 12.2.1.4 / 14.1.x)";; esac
    local b; while read -r b; do
      [ -z "$b" ] && continue; local d ddate; d="$(printf '%s' "$b" | cut -d';' -f2 | sed 's/^ *//')"; ddate="$(date_from_desc "$d")"
      if [ -n "$ddate" ]; then
        # a bundle has no CPU-calendar 'latest' to compare against, so pass '-' (not '' which row() shows as '?')
        row "FMW bundle ($(basename "$h"))" "$h" "$d" "$ddate" "-" ""
      else
        # a Coherence Cumulative Patch ('Coherence Cumulative Patch 12.2.1.4.30') carries no yymmdd, so it
        # cannot be date-compared - render '-/info' rather than '?', which reads as a failed read.
        ROWS="${ROWS}FMW bundle ($(basename "$h"))|$h|$d|-|-|-|info|no date in the bundle level (e.g. a Coherence Cumulative Patch) - not CPU-dated"$'\n'
      fi
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
    row "ORDS" "${ORDS_HOME:-running pid $ORDS_PID}" "${ORDS_VER:-unknown}" "$d" "${latest:-(public site not checked)}" "$([ -n "$latest" ] && [ -n "$ORDS_VER" ] && ! version_ge "$ORDS_VER" "$latest" && echo "newer release available: $latest")" "$([ -n "$d" ] && echo level || echo info)"
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
    local gnote=""
    [ -x "$OGG_HOME/OPatch/opatch" ] && { local gp glsp grc=0; glsp="$(lsp_read "$OGG_HOME/OPatch/opatch" 120)" || grc=$?; if [ "$grc" = 0 ]; then gp="$(printf '%s\n' "$glsp" | tail -1 | cut -d';' -f2 | sed 's/^ *//')"; [ -n "$gp" ] && gd="$(date_from_desc "$gp")"; else gnote="$(lsp_unreadable "$grc")"; gd=""; finding WARN patch "GoldenGate $OGG_HOME: opatch lspatches failed (rc $grc) - its patch level is unknown, not unpatched"; fi; }
    row "GoldenGate" "$OGG_HOME" "${gv:-unknown}" "$gd" "" "$gnote" "$([ "$grc" = 0 ] && echo level || echo reported)"
  fi
  # Enterprise Manager (the estate runs OEM 24ai: RU 10 = 24.1.0.10, OMS 39193593 / agent 39193599 in June 2026). The RU level is
  # the EM-OMS / EM-AGENT patch in opatch lspatches of the OMS home and the agent binaries home; emctl getversion needs no login
  local ah; ah="$(ls -d "${EM_AGENT_INST:-/nonexistent}" /u01/app/oracle/agent*/agent_inst /u01/app/oracle/product/agent*/agent_inst /opt/oracle/agent*/agent_inst 2>/dev/null | head -1)"
  if [ -x "$ah/bin/emctl" ]; then
    local est ev abin aru=""; est="$(to 60 "$ah/bin/emctl" status agent 2>/dev/null)"; ev="$(printf '%s\n' "$est" | sed -n 's/^Agent Version *: *//p' | head -1)"
    abin="$(printf '%s\n' "$est" | sed -n 's/^Agent Binaries *: *//p' | head -1)"; [ -z "$abin" ] && abin="$(ls -d "$(dirname "$ah")"/agent_[0-9]* 2>/dev/null | tail -1)"
    # a failed lspatches leaves aru holding the 'unreadable' text: the latest and note columns must not then claim an RU was read
    # (Colossus 23:32 - column 5 said 'RU of <quarter>' next to 'patch level unknown')
    local arc=0; [ -x "${abin:-/nonexistent}/OPatch/opatch" ] && { local alsp; alsp="$(lsp_read "$abin/OPatch/opatch" 120)" || arc=$?; printf '%s\n' "$alsp" >"$RAW/lspatches_em_agent.txt"
      if [ "$arc" = 0 ]; then aru="$(printf '%s\n' "$alsp" | grep -iE 'AGENT' | grep -iE 'RU|RELEASE UPDATE|BUNDLE' | sort | tail -1 | cut -d';' -f2 | sed 's/^ *//')"
      else aru="$(lsp_unreadable "$arc")"; finding WARN patch "EM agent $abin: opatch lspatches failed (rc $arc) - its RU level is unknown, not unpatched"; fi; }
    # an EM RU name (24.1.0.10) has no parsable date: warn rather than let row() render it UNKNOWN with no finding
    [ "$arc" = 0 ] && [ -n "$aru" ] && [ -z "$(date_from_desc "$aru")" ] && finding WARN patch "EM agent $ah: RU '$aru' has no parsable date (EM RUs are not yymmdd-versioned) - its CPU count is unknown, not current"
    if [ "$arc" = 0 ] && [ -z "$aru" ]; then
      # the agent binaries carry no RU in lspatches (agent RUs are applied by OMSPatcher, not here), so there
      # is no date to compare - render '-/info' rather than '?/UNKNOWN', same as an FMW bundle with no date
      ROWS="${ROWS}EM agent ${ev:-?}|$ah|${ev:-unknown}|-|-|-|info|no RU seen in the agent's lspatches (agent RUs are applied by OMSPatcher, not here) - not CPU-dated"$'\n'
    else
      row "EM agent ${ev:-?}" "$ah" "${aru:-${ev:-unknown}}" "$(date_from_desc "$aru")" "$([ "$arc" = 0 ] && [ -n "$aru" ] && echo "RU of $LATEST_CPU")" "$(if [ "$arc" != 0 ]; then echo "opatch could not list the inventory - run $abin/OPatch/opatch lspatches by hand"; elif [ -n "$aru" ]; then echo 'RU from opatch lspatches of the agent binaries'; else echo 'no RU seen in lspatches: agent patched with agent RUs, not here'; fi)" "$([ "$arc" = 0 ] && echo level || echo reported)"
    fi
  fi
  local oh; oh="$(for x in "${OMS_HOME:-/nonexistent}" /u01/app/oracle/middleware* /u01/app/oracle/em*/middleware /u01/app/oracle/product/em*/middleware /opt/oracle/middleware*; do [ -x "$x/bin/emctl" ] && [ -x "$x/OPatch/opatch" ] && echo "$x"; done 2>/dev/null | head -1)"
  if [ -n "$oh" ]; then
    local ov olsp oru; ov="$(to 60 "$oh/bin/emctl" getversion oms 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+){2,4}' | head -1)"
    local orc=0; olsp="$(lsp_read "$oh/OPatch/opatch" 180)" || orc=$?; printf '%s\n' "$olsp" >"$RAW/lspatches_em_oms.txt"
    if [ "$orc" = 0 ]; then oru="$(printf '%s\n' "$olsp" | grep -iE 'OMS|ENTERPRISE MANAGER' | grep -iE 'RU|RELEASE UPDATE|BUNDLE' | sort | tail -1 | cut -d';' -f2 | sed 's/^ *//')"
    else oru="$(lsp_unreadable "$orc")"; finding WARN patch "EM OMS $oh: opatch lspatches failed (rc $orc) - its RU level is unknown, not unpatched"; fi
    # an EM RU name (24.1.0.10) has no parsable date: warn rather than let row() render it UNKNOWN with no finding
    [ "$orc" = 0 ] && [ -n "$oru" ] && [ -z "$(date_from_desc "$oru")" ] && finding WARN patch "EM OMS $oh: RU '$oru' has no parsable date (EM RUs are not yymmdd-versioned) - its CPU count is unknown, not current"
    row "EM OMS ${ov:-?}" "$oh" "${oru:-no OMS RU in lspatches}" "$(date_from_desc "$oru")" "$([ "$orc" = 0 ] && echo "RU of $LATEST_CPU")" "$([ "$orc" = 0 ] && echo 'EM RUs come about monthly; the OMS RU and the agent RU are applied as a pair (OMSPatcher for the OMS)' || echo "opatch could not list the inventory - run $oh/OPatch/opatch lspatches by hand")" "$([ "$orc" = 0 ] && echo level || echo reported)"
    case "$ov" in 13.[0-4].*) [ "$DO_REPORT" = 1 ] && finding WARN patch "Enterprise Manager $ov in $oh: 13.4 and older are out of Premier Support (13.5 or 24ai)";; esac
  fi
  local t; t="$(ls /opt/oracle.ahf/bin/tfactl /u01/app/oracle.ahf/bin/tfactl 2>/dev/null | head -1)"
  [ -n "$t" ] && { local av; av="$(to 60 "$(dirname "$t")/ahfctl" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; [ -z "$av" ] && av="$(to 60 "$t" version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"; row "AHF" "$(dirname "$(dirname "$t")")" "${av:-unknown}" "" "" "AHF is updated monthly; check MOS 2550798.1" info; }
  local kd; kd="$(uptrack-uname -r 2>/dev/null)"; row "Kernel" "$(uname -r)" "${kd:-$(uname -r)}" "$(rpm -q --qf '%{INSTALLTIME:date}\n' kernel-uek 2>/dev/null | tail -1 | xargs -I{} date -d {} +%Y-%m-%d 2>/dev/null)" "" "$([ -n "$kd" ] && echo 'Ksplice effective kernel' || echo 'no Ksplice')" info
  local j; for j in $(java_homes); do grep -q "|$j|" <<<"$ROWS" || java_row "$j" "found on host"; done
}
ords_release_date() { # ORDS x.y.z -> yy.q: 24.3 = 2024 Q3 release (Jul-Sep); treat as the CPU of that quarter
  local v="$1" yy q; yy="${v%%.*}"; q="$(printf '%s' "$v" | cut -d. -f2)"; case "$q" in 1) printf '20%s-01-15' "$yy";; 2) printf '20%s-04-15' "$yy";; 3) printf '20%s-07-15' "$yy";; 4) printf '20%s-10-15' "$yy";; esac
}

print_table() {
  case "$FMT" in
    csv) echo "product,home,installed,date,latest,cpus_behind,status,note"; printf '%s' "$ROWS" | awk -F'|' 'BEGIN{OFS=","} {for(i=1;i<=NF;i++) gsub(/,/,";",$i); $1=$1; print}';;
    # JSON-escape each field (backslash first, then quote). HOST/CPU go through the environment, not
    # awk -v, which would interpret backslashes in the value. row() still joins on '|', so a field
    # containing a pipe is the one input this cannot save - that is the format's known ceiling.
    json) printf '%s' "$ROWS" | HOST="$HOST" CPU="$LATEST_CPU" awk -F'|' '
        function j(s){ gsub(/\\/,"\\\\",s); gsub(/"/,"\\\"",s); return s }
        BEGIN{ printf "{\"host\":\"%s\",\"latest_cpu\":\"%s\",\"rows\":[", j(ENVIRON["HOST"]), j(ENVIRON["CPU"]) }
        { if (NR>1) printf ","; printf "{\"product\":\"%s\",\"home\":\"%s\",\"installed\":\"%s\",\"date\":\"%s\",\"latest\":\"%s\",\"behind\":\"%s\",\"status\":\"%s\",\"note\":\"%s\"}", j($1),j($2),j($3),j($4),j($5),j($6),j($7),j($8) }
        END{ print "]}" }' ;;
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
  else findings_sync; rm -rf "$RAW"; fi
  # the exit code is the contract for anything that runs this unattended: 2 with a CRIT finding, 1 with a WARN, 0 clean. Without
  # --report the only findings are the reads that failed (a home or database whose level is unknown), so the table modes exit
  # non-zero exactly when a row says 'unreadable' or 'cannot connect' (Colossus 23:43: with output discarded, rc is the whole interface)
  findings_rc
}
main "$@"
