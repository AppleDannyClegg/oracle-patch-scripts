#!/usr/bin/env bash
# db-patch.sh - Oracle Database Release Update patching with OPatch + datapatch, with preflight,
# backup, Data Guard standby-first rule, automatic rollback, and out-of-place option.
# Runs on the database server as the oracle user. Grid Infrastructure patching (opatchauto, root)
# is supported only when `sudo -n opatchauto` is allowed and --grid is given.
#
# Usage: db-patch.sh <command> [args] [options]
#
# Commands
#   inspect                 Homes, RU level, OPatch, databases per home, RAC / Data Guard role
#   latest                  Ask My Oracle Support for the newest RU / OJVM / GI RU for each release (by name)
#   download <dir> [ids]    Fetch patches from MOS into <dir> (default: what 'latest' found)
#   plan <patch-dir>        Show exactly what run would do, touching nothing
#   preflight <patch-dir>   Patch zips sane, OPatch minimum, conflicts, disk, instances, standby-first, datapatch prereqs
#   backup                  Tar ORACLE_HOME + inventory, guaranteed restore point per database, spfile/controlfile copies
#   stop                    Stop databases (srvctl or sqlplus) and listener of this home; records what ran
#   apply <patch-dir>       opatch apply each patch (OPatch upgrade first if the zip is there)
#   start                   Start what was running
#   datapatch               datapatch -verbose in every database (all PDBs), then utlrp
#   verify                  lspatches shows the RU, dba_registry_sqlpatch SUCCESS everywhere, invalids, services, DG apply
#   rollback [id ...]       opatch rollback (this run's patches in reverse); offers flashback if datapatch failed
#   restore                 Restore ORACLE_HOME from this run's tar
#   cleanup                 Drop this run's restore points, delete old backups
#   heal                    Stale OPatch locks, hung datapatch, oratab mismatches
#   run <patch-dir>         [latest > download >] inspect > preflight > backup > stop > apply > start > datapatch > verify
#                           automatic rollback (and restore) if apply, datapatch or verify fails
#
# Options
#   --home DIR         ORACLE_HOME to patch (default: the one in /etc/oratab for --sid, or the only DB home)
#   --sid SID[,SID]    databases in this home to handle (default: all running from this home)
#   --grid             also patch the Grid home with opatchauto (needs sudo -n)        --oop NEWHOME  out-of-place: clone the home, patch the clone, switch
#   --rolling          RAC: this node only (run on each node in turn)                   --no-restore-point
#   --patches ID,ID    --release 19.0.0.0.0   --latest   --dry-run  --yes  --force  --json  --verbose  --run-dir DIR  --no-backup
#
# Config: db-patch.conf, ~/.db-patch.conf or the shared oracle.conf: ORACLE_HOME, ORACLE_SID, SQL_CONNECT,
# BACKUP_DIR, RUN_BASE, MOS_USER, MOS_PASSWORD, PATCHES, STOP_TIMEOUT, START_TIMEOUT, DG_STANDBY_FIRST=yes.

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="db-patch"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

BACKUP_DIR="${BACKUP_DIR:-$HOME/db-patch/backups}"; STOP_TIMEOUT="${STOP_TIMEOUT:-300}"; START_TIMEOUT="${START_TIMEOUT:-600}"
DG_STANDBY_FIRST="${DG_STANDBY_FIRST:-yes}"
HOME_DIR="${ORACLE_HOME:-}"; SIDS="${ORACLE_SID:-}"; GRID=0; OOP=""; ROLLING=0; NO_RP=0; NO_BACKUP=0; PATCHES="${PATCHES:-}"; PICK_RELEASE=""; USE_LATEST=0
# detected
DB_VERSION=""; RU_LEVEL=""; RU_DESC=""; OPATCH_VERSION=""; INSTALLED=""; GRID_HOME=""; IS_RAC=0; DB_ROLES=""

usage() { usage_from_header "$0"; }
parse_opts() {
  ARGS=()
  while [ $# -gt 0 ]; do case "$1" in
    --home) optchk "$@"; HOME_DIR="$2"; shift 2;; --sid) optchk "$@"; SIDS="${2//,/ }"; shift 2;; --grid) GRID=1; shift;; --oop) optchk "$@"; OOP="$2"; shift 2;; --rolling) ROLLING=1; shift;;
    --no-restore-point) NO_RP=1; shift;; --no-backup) NO_BACKUP=1; shift;; --patches) optchk "$@"; PATCHES="$2"; shift 2;; --release) optchk "$@"; PICK_RELEASE="$2"; shift 2;; --latest) USE_LATEST=1; shift;;
    --dry-run) DRY_RUN=1; shift;; --yes) ASSUME_YES=1; shift;; --force) FORCE=1; shift;; --json) JSON_OUT=1; shift;; --verbose) VERBOSE=1; shift;; --run-dir) optchk "$@"; RUN_DIR="$2"; shift 2;;
    -h|--help) usage; exit 0;; --*) die "Unknown option: $1";; *) ARGS+=("$1"); shift;; esac; done
}

# ---------------------------------------------------------------------------
# discovery
# ---------------------------------------------------------------------------
discover() {
  if [ -z "$HOME_DIR" ]; then
    local homes; homes="$(oratab_sids | while read -r s; do oratab_home "$s"; done | sort -u | while read -r h; do [ -x "$h/bin/sqlplus" ] && [ ! -x "$h/bin/crsctl" ] && echo "$h"; done)"
    [ "$(printf '%s\n' "$homes" | grep -c .)" = 1 ] && HOME_DIR="$homes"
    [ -z "$HOME_DIR" ] && [ -n "$SIDS" ] && HOME_DIR="$(oratab_home "${SIDS%% *}")"
    [ -z "$HOME_DIR" ] && die "Cannot pick the database home: pass --home DIR (oratab homes: $(printf '%s' "$homes" | tr '\n' ' '))"
  fi
  [ -x "$HOME_DIR/OPatch/opatch" ] || die "$HOME_DIR has no OPatch/opatch - not an OPatch home"
  [ -z "$SIDS" ] && SIDS="$(db_instances | while read -r s; do [ "$(oratab_home "$s")" = "$HOME_DIR" ] && echo "$s"; done | tr '\n' ' ')"
  [ -z "$SIDS" ] && SIDS="$(oratab_sids | while read -r s; do [ "$(oratab_home "$s")" = "$HOME_DIR" ] && echo "$s"; done | tr '\n' ' ')"
  DB_VERSION="$("$HOME_DIR/bin/sqlplus" -V 2>/dev/null | sed -n 's/^Version \([0-9.]*\).*/\1/p' | tail -1)"; [ -z "$DB_VERSION" ] && DB_VERSION="$("$HOME_DIR/bin/sqlplus" -V 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  OPATCH_VERSION="$("$HOME_DIR/OPatch/opatch" version 2>/dev/null | sed -n 's/^OPatch Version: *//p')"
  # opatch refuses homes without an OUI inventory ("not OUI based home"): keep its words for inspect/preflight instead of a blank version
  OPATCH_ERR=""; [ -z "$OPATCH_VERSION" ] && OPATCH_ERR="$("$HOME_DIR/OPatch/opatch" version 2>&1 | grep -vE '^\s*$|returns with error code' | head -1)"
  INSTALLED="$(to 180 "$HOME_DIR/OPatch/opatch" lspatches 2>/dev/null | grep -E '^[0-9]+;' || true)"
  RU_DESC="$(printf '%s\n' "$INSTALLED" | grep -iE 'Database Release Update|DATABASE RELEASE UPDATE' | grep -viE 'OJVM|MONTHLY' | sort -t';' -k2 | tail -1 | cut -d';' -f2 | sed 's/^ *//')"
  RU_LEVEL="$(printf '%s' "$RU_DESC" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  GRID_HOME="$(grid_home)"; is_rac && IS_RAC=1
  DB_ROLES=""; local s; for s in $SIDS; do db_instances | grep -qx "$s" || { DB_ROLES="${DB_ROLES}$s:DOWN "; continue; }; local r; r="$(sql_val "$s" "(select database_role||'/'||open_mode from v\$database)" 2>/dev/null)"; DB_ROLES="${DB_ROLES}$s:${r:-?} "; done
}
setup_env() { discover; export ORACLE_HOME="$HOME_DIR"; export PATH="$HOME_DIR/bin:$HOME_DIR/OPatch:$PATH"; }
opatch() { env ORACLE_HOME="$HOME_DIR" "$HOME_DIR/OPatch/opatch" "$@"; }
srvctl_db_name() { [ -n "$GRID_HOME" ] || return 1; "$GRID_HOME/bin/srvctl" config database 2>/dev/null | while read -r d; do [ "$("$GRID_HOME/bin/srvctl" config database -d "$d" 2>/dev/null | sed -n 's/^Oracle home: *//p')" = "$HOME_DIR" ] && echo "$d"; done; }
# opatch lock
opatch_locked() { [ -f "$HOME_DIR/.patch_storage/patch_locked" ]; }

cmd_inspect() {
  setup_env
  if [ "$JSON_OUT" = 1 ]; then
    printf '{"oracle_home":"%s","version":"%s","ru":"%s","ru_desc":"%s","opatch":"%s","grid_home":"%s","rac":%s,"databases":"%s","patches":[' "$HOME_DIR" "$DB_VERSION" "$RU_LEVEL" "$(json_escape "$RU_DESC")" "$OPATCH_VERSION" "$GRID_HOME" "$IS_RAC" "$DB_ROLES"
    printf '%s\n' "$INSTALLED" | awk -F';' 'NF>1{printf "%s{\"id\":\"%s\",\"description\":\"%s\"}", (NR>1?",":""), $1, $2}'; echo ']}'; return
  fi
  echo "ORACLE_HOME     : $HOME_DIR"; echo "Version         : $DB_VERSION"; echo "RU level        : ${RU_DESC:-none}"; echo "OPatch          : ${OPATCH_VERSION:-FAILED: ${OPATCH_ERR:-opatch version gave nothing}}"
  echo "Grid home       : ${GRID_HOME:-none}   RAC: $IS_RAC"; echo "Databases       : $DB_ROLES"
  echo "Patches         : $(printf '%s\n' "$INSTALLED" | grep -c .)"; printf '%s\n' "$INSTALLED" | sed 's/^/  /' | head -30
  opatch_locked && echo "WARNING         : stale OPatch lock present (heal)"
  echo "Datapatch       :"; local s; for s in $SIDS; do sql_ok "$s" || { echo "  $s: not reachable"; continue; }; sql_lines "$s" "select '  $s '||(select name from v\$containers c where c.con_id=p.con_id)||': '||nvl(max(case when status='SUCCESS' then description end),'none')||' ('||sum(case when status not in ('SUCCESS','IGNORED') then 1 else 0 end)||' failed)' from cdb_registry_sqlpatch p where action='APPLY' and description not like '%OJVM%' group by con_id order by con_id;" 2>/dev/null || sql_lines "$s" "select '  $s: '||nvl(max(description),'none') from dba_registry_sqlpatch where action='APPLY' and status='SUCCESS' and description not like '%OJVM%';"; done
}

cmd_latest() {
  setup_env; [ -n "$RUN_DIR" ] || init_run_dir latest
  local major="${DB_VERSION%%.*}" found="" rows
  mos_login
  log "Searching MOS for the newest Database Release Update $major"
  rows="$(mos_name_search "Database Release Update $major" | grep -iE "^[0-9]{8}\|Database Release Update $major\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+ *\(" || true)"   # plain RU rows: the " - CMAN" / " - GSM" variants are not for the database home
  if [ -n "$rows" ]; then
    local ru; ru="$(printf '%s\n' "$rows" | awk -F'|' '{match($2,/[0-9]{6}/); print substr($2,RSTART,6) "|" $0}' | sort -r | head -1 | cut -d'|' -f2-)"
    local ru_level; ru_level="$(printf '%s' "${ru#*|}" | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
    if [ -n "$RU_LEVEL" ] && version_ge "$RU_LEVEL" "$ru_level"; then log "  newest RU is ${ru%%|*} (${ru#*|}) - already at $RU_LEVEL"
    else log "  newest RU: ${ru%%|*}  ${ru#*|}  (installed: ${RU_LEVEL:-none})"; found="${ru%%|*}"; fi
  else warn "  no RU rows returned"; fi
  log "Searching MOS for the newest OJVM Release Update $major"
  rows="$(mos_name_search "OJVM RELEASE UPDATE $major" | grep -iE "OJVM RELEASE UPDATE:? ?$major\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+" || true)"
  if [ -n "$rows" ]; then local oj; oj="$(printf '%s\n' "$rows" | awk -F'|' '{match($2,/[0-9]{6}/); print substr($2,RSTART,6) "|" $0}' | sort -r | head -1 | cut -d'|' -f2-)"; local ojl; ojl="$(printf '%s' "${oj#*|}" | grep -oE '[0-9]{6}' | head -1)"; local have; have="$(printf '%s\n' "$INSTALLED" | grep -i OJVM | grep -oE '\.[0-9]{6}' | tr -d . | sort | tail -1)"; if [ -n "$have" ] && [ "$have" -ge "$ojl" ]; then log "  OJVM already at $have"; else log "  newest OJVM: ${oj%%|*}  ${oj#*|}"; found="${found:+$found,}${oj%%|*}"; fi; fi
  if [ "$GRID" = 1 ] && [ -n "$GRID_HOME" ]; then
    log "Searching MOS for the newest GI Release Update $major"
    rows="$(mos_name_search "GI Release Update $major" | grep -iE "GI RELEASE UPDATE $major\.[0-9]+|Grid Infrastructure Release Update $major" || true)"
    [ -n "$rows" ] && { local gi; gi="$(printf '%s\n' "$rows" | awk -F'|' '{match($2,/[0-9]{6}/); print substr($2,RSTART,6) "|" $0}' | sort -r | head -1 | cut -d'|' -f2-)"; log "  newest GI RU: ${gi%%|*}  ${gi#*|}"; found="${found:+$found,}${gi%%|*}"; }
  fi
  mos_cleanup
  [ -z "$found" ] && { [ -n "$rows" ] && { log "Nothing newer than installed."; return 0; }; err "Could not find the RU on MOS; get the number from Doc 2118136.2 and pass --patches"; return 1; }
  echo; echo "  Patches MOS says are current for $DB_VERSION: $found"; echo "  (OPatch kit 6880880 is added by download when OPatch is too old)"; echo
  PATCHES="${found}${PATCHES:+,$PATCHES}"; state_set latest "$found"
}

cmd_download() {
  setup_env; [ -n "$RUN_DIR" ] || init_run_dir download
  local dir="${ARGS[0]:-}"; [ -n "$dir" ] || die "download needs a directory"; shift_args=1
  local ids="${ARGS[*]:1}"; [ -z "$ids" ] && ids="${PATCHES//,/ }"; [ -z "$ids" ] && die "no patch ids: run 'latest' first or give them"
  mkdir -p "$dir"; local id todo=""
  for id in $ids; do
    printf '%s\n' "$INSTALLED" | grep -q "^$id;" && { log "$id already installed, skipping"; continue; }
    ls "$dir"/p"${id}"_*.zip >/dev/null 2>&1 && { log "$id already in $dir"; continue; }
    todo="$todo $id"
  done
  [ -n "$todo" ] && { mos_login "$dir"; for id in $todo; do mos_download "$id" "$dir" "${PICK_RELEASE:-$DB_VERSION}" || die "download of $id failed"; done; }
  # OPatch kit when too old (12.2.0.1.x needs 12.2.0.1.40+ for recent RUs) or when opatch cannot even report its version
  if ls "$dir"/p6880880_*.zip >/dev/null 2>&1; then log "OPatch kit already in $dir"
  elif [ -z "$OPATCH_VERSION" ] || ! version_ge "$OPATCH_VERSION" "12.2.0.1.40"; then
    log "OPatch ${OPATCH_VERSION:-version unknown (${OPATCH_ERR:-opatch failed})} - adding the OPatch kit (6880880)"; [ ${#MOS_CURL[@]} -gt 0 ] || mos_login "$dir"
    mos_download 6880880 "$dir" "${DB_VERSION%%.*}.0.0.0.0" || warn "could not download the OPatch kit; get p6880880 by hand"
  fi
  mos_cleanup; ls -la "$dir"
}

# patch dir: unzip anything zipped; list patch ids (dirs with etc/config/inventory.xml); OPatch kit separate
prepare_patch_dir() {
  local dir="$1"; [ -d "$dir" ] || die "patch dir $dir not found"
  local z; for z in "$dir"/p*.zip "$dir"/*.zip; do [ -f "$z" ] || continue
    local id; id="$(basename "$z" | grep -oE '^p?[0-9]{6,9}' | tr -d p)"
    [ "$id" = 6880880 ] && { OPATCH_ZIP="$z"; continue; }
    [ -d "$dir/$id" ] || { log "unzipping $(basename "$z")"; unzip -q -o "$z" -d "$dir" || die "unzip failed: $z"; }
  done
  PATCH_IDS="$(find "$dir" -mindepth 1 -maxdepth 4 -name inventory.xml -path '*/etc/config/*' 2>/dev/null | sed -E 's#/etc/config/inventory.xml##' | xargs -I{} basename {} | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ')"
  PATCH_PATHS="$(find "$dir" -mindepth 1 -maxdepth 4 -name inventory.xml -path '*/etc/config/*' 2>/dev/null | sed -E 's#/etc/config/inventory.xml##' | sort -u)"
  [ -n "$PATCH_IDS" ] || die "no OPatch patches found under $dir"
}
patch_desc() { sed -n 's/.*<description>\(.*\)<\/description>.*/\1/p' "$1/etc/config/inventory.xml" 2>/dev/null | head -1; }
patch_min_opatch() { grep -oE 'OPatch[^0-9]*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' "$1"/README.* "$1"/README.html 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | sort -V | tail -1; }
patch_is_rolling() { grep -qiE 'rolling="true"|<rolling>true' "$1"/etc/config/inventory.xml 2>/dev/null; }

# ---------------------------------------------------------------------------
# preflight / plan
# ---------------------------------------------------------------------------
cmd_preflight() {
  setup_env; [ -n "$RUN_DIR" ] || init_run_dir preflight
  local dir="${ARGS[0]:-}"; [ -n "$dir" ] || die "preflight needs <patch-dir>"
  prepare_patch_dir "$dir"; local fail=0 p
  log "Preflight for $HOME_DIR ($DB_VERSION, RU ${RU_LEVEL:-none}) with patches: $PATCH_IDS"
  [ "$(id -u)" = 0 ] && die "run as the oracle user, not root"
  [ "$(file_owner "$HOME_DIR")" = "$(id -un)" ] || warn "ORACLE_HOME is owned by $(file_owner "$HOME_DIR"), you are $(id -un)"
  opatch_locked && { err "stale OPatch lock $HOME_DIR/.patch_storage/patch_locked (run heal)"; fail=1; }
  # OPatch minimum
  local need=""; for p in $PATCH_PATHS; do local m; m="$(patch_min_opatch "$p")"; [ -n "$m" ] && { [ -z "$need" ] || version_ge "$m" "$need"; } && need="$m"; done
  if [ -n "$need" ] && ! version_ge "$OPATCH_VERSION" "$need"; then
    if [ -n "${OPATCH_ZIP:-}" ]; then log "OPatch $OPATCH_VERSION < $need; the kit $(basename "$OPATCH_ZIP") will be installed first"; else err "OPatch $OPATCH_VERSION is below $need and no p6880880 zip in $dir"; fail=1; fi
  else log "OPatch $OPATCH_VERSION ok (needs ${need:-n/a})"; fi
  # already installed / conflicts
  for p in $PATCH_PATHS; do
    local id; id="$(basename "$p")"
    if printf '%s\n' "$INSTALLED" | grep -q "^$id;"; then log "$id already installed: $(patch_desc "$p")"; continue; fi
    log "$id: $(patch_desc "$p") $(patch_is_rolling "$p" && echo '[rolling]' || echo '[NOT rolling]')"
    local out; out="$(to 600 opatch prereq CheckConflictAgainstOHWithDetail -ph "$p" 2>&1)"; printf '%s\n' "$out" >>"$LOG_FILE"
    if printf '%s' "$out" | grep -q 'Prereq "checkConflictAgainstOHWithDetail" passed'; then log "  no conflicts"
    elif printf '%s' "$out" | grep -qiE 'conflict'; then err "  CONFLICT: $(printf '%s' "$out" | grep -iE 'conflict|superset|subset' | head -3 | tr '\n' ' ')"; fail=1
    else warn "  prereq check gave no verdict (see log)"; fi
    # release match
    local prel; prel="$(grep -oE 'release="[0-9.]+"' "$p/etc/config/inventory.xml" 2>/dev/null | head -1 | cut -d'"' -f2)"; [ -n "$prel" ] && [ "${prel%.*}" != "${DB_VERSION%.*}" ] && { err "  patch is for release $prel, home is $DB_VERSION"; fail=1; }
  done
  [ "$ROLLING" = 1 ] && for p in $PATCH_PATHS; do patch_is_rolling "$p" || { err "$(basename "$p") is not rolling-capable; --rolling is unsafe"; fail=1; }; done
  # disk
  local need_mb free_mb; need_mb="$(du -sm "$dir" | cut -f1)"; need_mb=$((need_mb*2+2048)); free_mb="$(df -Pm "$HOME_DIR" | awk 'NR==2{print $4}')"
  [ "$free_mb" -lt "$need_mb" ] && { err "only ${free_mb} MB free on $HOME_DIR, want ${need_mb} MB (.patch_storage keeps rollback copies)"; fail=1; } || log "disk: ${free_mb} MB free on the home"
  [ "$NO_BACKUP" = 0 ] && { local hsz; hsz="$(du -sm "$HOME_DIR" | cut -f1)"; local bfree; bfree="$(df -Pm "$(mkdir -p "$BACKUP_DIR" && echo "$BACKUP_DIR")" | awk 'NR==2{print $4}')"; [ "$bfree" -lt "$((hsz+1024))" ] && { err "backup dir needs ${hsz} MB, has ${bfree} MB (--no-backup to skip)"; fail=1; }; }
  # databases: running, roles, standby-first, datapatch prereqs
  local s; for s in $SIDS; do
    if ! db_instances | grep -qx "$s"; then warn "$s is not running (datapatch needs it open; start it or it will be skipped)"; continue; fi
    sql_ok "$s" || { err "$s: cannot connect as sysdba"; fail=1; continue; }
    local role mode; role="$(sql_val "$s" "(select database_role from v\$database)")"; mode="$(sql_val "$s" "(select open_mode from v\$database)")"
    log "$s: $role, $mode, $(sql_val "$s" "(select count(*) from v\$session where type='USER')") user sessions"
    # an unreadable standby-destination count is not 'has a standby' (it was: '' != 0 said Data Guard PRIMARY of a database with no v$archive_dest answer)
    local sbd=""; [ "$role" = PRIMARY ] && [ "$DG_STANDBY_FIRST" = yes ] && { sbd="$(sql_val "$s" "(select count(*) from v\$archive_dest where target='STANDBY' and status='VALID')")"; [ -n "$sbd" ] || { err "$s: cannot read v\$archive_dest - cannot tell whether a standby exists (patch the standby first; --force to patch this one anyway)"; [ "$FORCE" = 1 ] || fail=1; }; }
    if [ "$role" = PRIMARY ] && [ "$DG_STANDBY_FIRST" = yes ] && [ -n "$sbd" ] && [ "$sbd" != 0 ]; then
      local sb; sb="$(sql_lines "$s" "select db_unique_name||':'||nvl(value,'?') from v\$dataguard_stats, (select db_unique_name from v\$database) where name='apply lag';" | head -1)"
      if [ "$FORCE" = 1 ]; then warn "$s is a Data Guard PRIMARY; --force given, patching before the standby (Oracle says standby first)"
      else err "$s is a Data Guard PRIMARY: patch the standby first (same patches, 'db-patch run' there), then here. --force to override"; fail=1; fi
    fi
    # an empty count is 'could not read', never 0: the registry gate fails closed, the advisory counts say so
    local inv; inv="$(sql_val "$s" "(select count(*) from dba_objects where status<>'VALID' and owner in ('SYS','SYSTEM','PUBLIC'))")"
    if [ -z "$inv" ]; then warn "$s: could not count invalid SYS/SYSTEM objects (dba_objects)"; elif [ "$inv" -gt 0 ]; then warn "$s: $inv invalid SYS/SYSTEM objects before patching - run utlrp first, datapatch may fail"; fi
    local bad; bad="$(sql_val "$s" "(select count(*) from dba_registry_sqlpatch where status not in ('SUCCESS','IGNORED'))")"
    if [ -z "$bad" ]; then err "$s: cannot read dba_registry_sqlpatch - not assuming every earlier datapatch succeeded"; fail=1; elif [ "$bad" -gt 0 ]; then err "$s: $bad failed datapatch entries in dba_registry_sqlpatch - fix before applying more"; fail=1; fi
    [ "$NO_RP" = 0 ] && [ "$(sql_val "$s" "(select log_mode from v\$database)")" != ARCHIVELOG ] && warn "$s: NOARCHIVELOG - no restore point possible, rollback is opatch only"
    local fra; fra="$(sql_val "$s" "(select round((space_used-space_reclaimable)*100/space_limit) from v\$recovery_file_dest where space_limit>0)" 2>/dev/null)"; [ -n "$fra" ] && [ "$fra" -gt 85 ] && warn "$s: FRA ${fra}% - a guaranteed restore point will grow it"
    local closed; closed="$(sql_val "$s" "(select count(*) from v\$pdbs where open_mode<>'READ WRITE' and name<>'PDB\$SEED')" 2>/dev/null)"; [ -z "$closed" ] && warn "$s: could not read the PDB open modes (v\$pdbs)"; [ -n "$closed" ] && [ "$closed" != 0 ] && warn "$s: $closed PDB(s) not READ WRITE - datapatch will skip them (apply later with datapatch -pdbs)"
    [ "$(sql_val "$s" "(select count(*) from v\$backup where status='ACTIVE')")" != 0 ] && { err "$s: datafiles in hot backup mode"; fail=1; }
    [ "$(sql_val "$s" "(select count(*) from v\$rman_backup_job_details where status='RUNNING')")" != 0 ] && { err "$s: an RMAN backup is running"; fail=1; }
  done
  [ "$GRID" = 1 ] && { [ -n "$GRID_HOME" ] || { err "--grid but no Grid home"; fail=1; }; $SUDO "$GRID_HOME/OPatch/opatchauto" version >/dev/null 2>&1 || { err "--grid needs 'sudo -n $GRID_HOME/OPatch/opatchauto' for this user"; fail=1; }; }
  [ "$IS_RAC" = 1 ] && [ "$ROLLING" = 0 ] && warn "RAC without --rolling: every instance of these databases will be stopped (full outage)"
  [ -n "$OOP" ] && { [ -e "$OOP" ] && { err "--oop target $OOP already exists"; fail=1; }; local pfree; pfree="$(df -Pm "$(dirname "$OOP")" | awk 'NR==2{print $4}')"; [ "$pfree" -lt "$(( $(du -sm "$HOME_DIR" | cut -f1) + 4096 ))" ] && { err "not enough space for the out-of-place clone at $OOP"; fail=1; }; }
  pgrep -f 'oracle.opatch.OPatch|OPatch/opatch|datapatch' >/dev/null 2>&1 && { err "another opatch/datapatch is running"; fail=1; }
  state_set preflight "$([ "$fail" = 0 ] && echo ok || echo failed)"
  [ "$fail" = 0 ] && { log "Preflight OK"; return 0; } || { err "Preflight FAILED - see $LOG_FILE"; return 1; }
}

cmd_plan() {
  setup_env; local dir="${ARGS[0]:-}"; [ -n "$dir" ] || die "plan needs <patch-dir>"; prepare_patch_dir "$dir"
  echo "PLAN for $HOME_DIR ($DB_VERSION, RU ${RU_LEVEL:-none}); databases: $SIDS"
  echo "  1. preflight    OPatch >= needed, conflicts, disk, roles (standby first: $DG_STANDBY_FIRST), datapatch prereqs"
  echo "  2. backup       tar $HOME_DIR -> $BACKUP_DIR; $([ "$NO_RP" = 1 ] && echo 'no restore points' || echo "guaranteed restore point DBPATCH_<ts> in each database"); spfile+controlfile copies"
  [ -n "$OOP" ] && echo "  3. clone        cp -a $HOME_DIR $OOP ; patch the clone ; then switch oratab/srvctl and restart (less downtime)"
  echo "  3. stop         $([ -n "$GRID_HOME" ] && echo 'srvctl stop database' || echo 'shutdown immediate') for: $SIDS $([ "$ROLLING" = 1 ] && echo '(this node only)') ; listener of this home"
  [ -n "${OPATCH_ZIP:-}" ] && echo "  4. opatch kit   unzip $(basename "$OPATCH_ZIP") over $HOME_DIR/OPatch"
  local p; for p in $PATCH_PATHS; do printf '  4. apply        %-10s %s%s\n' "$(basename "$p")" "$(patch_desc "$p")" "$(printf '%s\n' "$INSTALLED" | grep -q "^$(basename "$p");" && echo '  [already installed: skip]')"; done
  echo "  5. start        what was running; listener"
  echo "  6. datapatch    datapatch -verbose in each database (all open PDBs), utlrp"
  echo "  7. verify       opatch lspatches, dba_registry_sqlpatch SUCCESS per container, invalids, services$([ "$GRID" = 1 ] && echo ', GI via opatchauto (root)')"
  echo "  on failure      opatch rollback in reverse; datapatch failure -> offer flashback to the restore point; restore tar if the home is broken"
  echo "  dry-run         $DRY_RUN   yes: $ASSUME_YES"
}

# ---------------------------------------------------------------------------
# backup / stop / apply / start / datapatch / verify / rollback / restore
# ---------------------------------------------------------------------------
cmd_backup() {
  setup_env; reuse_or_init backup
  local ts fail=0; ts="$(date +%Y%m%d%H%M%S)"; mkdir -p "$BACKUP_DIR"
  if [ "$NO_BACKUP" = 0 ]; then
    local tarf; tarf="$BACKUP_DIR/oracle_home_$(basename "$HOME_DIR")_$ts.tar.gz"
    log "backing up $HOME_DIR to $tarf ($(du -sh "$HOME_DIR" | cut -f1))"
    # --exclude before the operands: after them bsdtar (and GNU tar under POSIXLY_CORRECT) reads each as a file name and fails
    [ "$DRY_RUN" = 1 ] || tar -czf "$tarf" --exclude='*/log/*' --exclude='*/diag/*' -C "$(dirname "$HOME_DIR")" "$(basename "$HOME_DIR")" || die "tar failed"
    local inv; inv="$(sed -n 's/^inventory_loc=//p' /etc/oraInst.loc 2>/dev/null)"
    if [ -d "$inv" ] && [ "$DRY_RUN" = 0 ]; then tar -czf "$BACKUP_DIR/oraInventory_$ts.tar.gz" -C "$(dirname "$inv")" "$(basename "$inv")" || { err "oraInventory backup ($inv) failed - a broken inventory could not be put back"; fail=1; }; fi
    state_set home_backup "$tarf"
  fi
  local s; for s in $SIDS; do
    db_instances | grep -qx "$s" || continue; sql_ok "$s" || continue
    mkdir -p "$RUN_DIR/$s"
    # each statement's output is read for ORA-: the pfile and controlfile copies went to the log unread and backup=ok followed
    # whatever they said (a run then stopped the database with no pfile backup and no controlfile copy, told the backup was fine)
    local stmt out; for stmt in "create pfile='$RUN_DIR/$s/init$s.ora.bak' from spfile;" "alter database backup controlfile to '$RUN_DIR/$s/control.bak' reuse;" "alter database backup controlfile to trace as '$RUN_DIR/$s/control.trc' reuse;"; do
      [ "$DRY_RUN" = 1 ] && { log "DRY-RUN: $s: $stmt"; continue; }
      out="$(sql_run "$s" "$stmt" 2>&1)"; printf '%s\n' "$out" >>"$LOG_FILE"
      printf '%s' "$out" | grep -qE 'ORA-[0-9]+' && { err "$s: $stmt failed: $(printf '%s\n' "$out" | grep -m1 -oE 'ORA-[0-9]+.*' | cut -c1-120)"; fail=1; }
    done
    if [ "$NO_RP" = 0 ] && [ "$(sql_val "$s" "(select log_mode from v\$database)")" = ARCHIVELOG ] && [ "$(sql_val "$s" "(select database_role from v\$database)")" = PRIMARY ]; then
      local rp="DBPATCH_$ts"; log "$s: creating guaranteed restore point $rp"
      if [ "$DRY_RUN" = 0 ]; then out="$(sql_run "$s" "create restore point $rp guarantee flashback database;" 2>&1)"; printf '%s\n' "$out" >>"$LOG_FILE"
        # the restore point is the undo 'run' promises for a bad datapatch; a run without one used to carry on after a warning.
        # Not having it is an error - --no-restore-point is the way to say so on purpose
        if printf '%s' "$out" | grep -qE 'ORA-[0-9]+'; then err "$s: restore point $rp NOT created: $(printf '%s\n' "$out" | grep -m1 -oE 'ORA-[0-9]+.*' | cut -c1-120) - fix it (FRA, flashback) or re-run with --no-restore-point"; fail=1
        else state_append restore_points "$s:$rp"; fi
      fi
    fi
  done
  if [ "$fail" = 0 ]; then state_set backup ok
  else state_set backup failed; err "backup INCOMPLETE: a copy or restore point above was not made - nothing has been changed, fix it before 'stop' or 'apply'"; return 1; fi
}

cmd_stop() {
  setup_env; reuse_or_init stop
  local running=""; local s; for s in $SIDS; do db_instances | grep -qx "$s" && running="$running $s"; done
  state_set was_running "${running# }"
  local dbn; for dbn in $(srvctl_db_name); do
    if [ "$ROLLING" = 1 ]; then local inst; inst="$(db_instances | grep -E "^${dbn}" | head -1)"; run_cmd "$GRID_HOME/bin/srvctl" stop instance -d "$dbn" -i "$inst" -o immediate; else run_cmd "$GRID_HOME/bin/srvctl" stop database -d "$dbn" -o immediate; fi
  done
  local fail=0
  for s in $running; do
    db_instances | grep -qx "$s" || continue
    log "shutdown immediate $s"; [ "$DRY_RUN" = 1 ] && continue
    ORACLE_SID="$s" ORACLE_HOME="$HOME_DIR" to "$STOP_TIMEOUT" "$HOME_DIR/bin/sqlplus" -S / as sysdba <<<"shutdown immediate" >>"$LOG_FILE" 2>&1
    db_instances | grep -qx "$s" && { warn "$s still up after immediate; shutdown abort"; ORACLE_SID="$s" ORACLE_HOME="$HOME_DIR" "$HOME_DIR/bin/sqlplus" -S / as sysdba <<<"shutdown abort" >>"$LOG_FILE" 2>&1; }
    # the proof is pmon gone (an abort's processes take a moment to go), not sqlplus's exit status: the shutdown output went to
    # the log unread and stopped=ok was written whatever ps said afterwards - 'run' then took opatch apply to a home with an instance up
    local w=0; while db_instances | grep -qx "$s" && [ "$w" -lt 20 ]; do sleep 2; w=$((w + 2)); done
    db_instances | grep -qx "$s" && { err "$s is STILL RUNNING after shutdown immediate and shutdown abort (see $LOG_FILE)"; fail=1; }
  done
  # process substitution, not '| while': a listener that would not stop must reach fail (opatch refuses a home whose listener runs: files in use)
  local h lsn; while read -r h lsn; do [ "$h" = "$HOME_DIR" ] || continue
    run_cmd env ORACLE_HOME="$h" "$h/bin/lsnrctl" stop "$lsn" || { err "lsnrctl stop $lsn failed - a listener from $HOME_DIR is still running"; fail=1; }; state_append listeners "$lsn"; done < <(listener_homes)
  [ "$DRY_RUN" = 1 ] || { local left; left="$(ps -eo args | grep -E "^ora_[a-z0-9]+_" | grep -E "$(printf '%s' "$SIDS" | sed 's/ /|/g')" | wc -l | tr -d ' ')"; [ "$left" != 0 ] && [ -n "$SIDS" ] && warn "$left oracle processes of these SIDs still running"; }
  if [ "$fail" = 0 ]; then state_set stopped ok
  else state_set stopped failed; err "stop INCOMPLETE: a database or listener of $HOME_DIR is still running - nothing in this home can be patched until it is down"; return 1; fi
}

cmd_apply() {
  setup_env; reuse_or_init apply
  local dir="${ARGS[0]:-}"; [ -n "$dir" ] || die "apply needs <patch-dir>"; prepare_patch_dir "$dir"
  local target="$HOME_DIR"
  if [ -n "$OOP" ]; then
    log "out-of-place: cloning $HOME_DIR to $OOP"; confirm "Clone the home to $OOP?" || die "aborted"
    [ "$DRY_RUN" = 1 ] || { cp -a "$HOME_DIR" "$OOP" || die "clone failed"; env ORACLE_HOME="$OOP" "$OOP/oui/bin/runInstaller" -silent -clone ORACLE_HOME="$OOP" ORACLE_HOME_NAME="OraDB_oop_$(date +%s)" ORACLE_BASE="${ORACLE_BASE:-$(dirname "$(dirname "$HOME_DIR")")}" >>"$LOG_FILE" 2>&1 || die "clone registration (runInstaller -clone) failed"; }
    target="$OOP"; state_set oop_home "$OOP"
  fi
  if [ -n "${OPATCH_ZIP:-}" ]; then
    local kitv; kitv="$(unzip -p "$OPATCH_ZIP" OPatch/version.txt 2>/dev/null | sed -n 's/^OPATCH_VERSION:*//p' | head -1)"
    if ! version_ge "$OPATCH_VERSION" "${kitv:-99}"; then log "upgrading OPatch to ${kitv:-?} in $target"; confirm "Replace $target/OPatch?" || die "aborted"
      [ "$DRY_RUN" = 1 ] || { mv "$target/OPatch" "$RUN_DIR/OPatch.old.$(date +%s)" && unzip -q "$OPATCH_ZIP" -d "$target" || die "OPatch kit install failed"; }; fi
  fi
  pgrep -f 'oracle.opatch.OPatch|OPatch/opatch' >/dev/null 2>&1 && die "another opatch is running"
  local p; for p in $PATCH_PATHS; do
    local id; id="$(basename "$p")"
    printf '%s\n' "$INSTALLED" | grep -q "^$id;" && [ -z "$OOP" ] && { log "$id already installed, skipping"; continue; }
    log "applying $id: $(patch_desc "$p")"; confirm "opatch apply $id to $target?" || die "aborted"
    if [ "$DRY_RUN" = 0 ]; then
      (cd "$p" && ORACLE_HOME="$target" to 3600 "$target/OPatch/opatch" apply -silent -ocmrf /dev/null 2>&1 || ORACLE_HOME="$target" to 3600 "$target/OPatch/opatch" apply -silent 2>&1) | tee -a "$LOG_FILE" | grep -E 'OPatch (succeeded|failed|completed)|Error|error|conflict|Patch [0-9]+ successfully applied' | tail -5
      if ! env ORACLE_HOME="$target" "$target/OPatch/opatch" lspatches 2>/dev/null | grep -q "^$id;"; then err "$id did not apply (see $LOG_FILE)"; state_set apply failed; return 1; fi
    fi
    state_append applied "$id"
  done
  if [ "$GRID" = 1 ] && [ -n "$GRID_HOME" ]; then
    local gi; for gi in $PATCH_PATHS; do grep -qiE 'Grid Infrastructure|OCW|ACFS|GI RELEASE' "$gi/etc/config/inventory.xml" 2>/dev/null || continue
      log "opatchauto apply $(basename "$gi") to the Grid home (as root via sudo)"; confirm "sudo opatchauto apply $(basename "$gi") -oh $GRID_HOME ?" || die "aborted"
      [ "$DRY_RUN" = 1 ] || $SUDO "$GRID_HOME/OPatch/opatchauto" apply "$gi" -oh "$GRID_HOME" >>"$LOG_FILE" 2>&1 || { err "opatchauto failed"; state_set apply failed; return 1; }
    done
  fi
  if [ -n "$OOP" ]; then
    log "switching databases to $OOP (oratab$( [ -n "$GRID_HOME" ] && echo ', srvctl'))"; confirm "Point $SIDS at $OOP?" || die "aborted"
    if [ "$DRY_RUN" = 0 ]; then cp /etc/oratab "$RUN_DIR/oratab.bak"; local s; for s in $SIDS; do sed -i "s#^$s:$HOME_DIR:#$s:$OOP:#" /etc/oratab 2>/dev/null || warn "could not edit /etc/oratab (root?) - fix $s by hand"; done
      local dbn; for dbn in $(srvctl_db_name); do "$GRID_HOME/bin/srvctl" modify database -d "$dbn" -oraclehome "$OOP" >>"$LOG_FILE" 2>&1; done
      cp -n "$HOME_DIR"/dbs/*.ora "$HOME_DIR"/dbs/orapw* "$HOME_DIR"/network/admin/*.ora "$OOP"/dbs/ 2>/dev/null; cp -n "$HOME_DIR"/network/admin/*.ora "$OOP"/network/admin/ 2>/dev/null; fi
    HOME_DIR="$OOP"; export ORACLE_HOME="$OOP"
  fi
  state_set apply ok
}

cmd_start() {
  setup_env; reuse_or_init start
  local oop; oop="$(state_get oop_home || true)"; [ -n "$oop" ] && HOME_DIR="$oop"
  local lsn; for lsn in $(state_get listeners || true); do run_cmd env ORACLE_HOME="$HOME_DIR" "$HOME_DIR/bin/lsnrctl" start "$lsn"; done
  local dbn; for dbn in $(srvctl_db_name); do
    if [ "$ROLLING" = 1 ]; then local inst; inst="$(state_get was_running | tr ' ' '\n' | grep -E "^${dbn}" | head -1)"; [ -n "$inst" ] && run_cmd "$GRID_HOME/bin/srvctl" start instance -d "$dbn" -i "$inst"; else run_cmd "$GRID_HOME/bin/srvctl" start database -d "$dbn"; fi
  done
  local s; for s in $(state_get was_running || echo "$SIDS"); do
    db_instances | grep -qx "$s" && continue
    log "startup $s"; [ "$DRY_RUN" = 1 ] && continue
    # the outcome is the open mode, not 'sqlplus connects': a startup that stopped at MOUNT (ORA-01157, a missing datafile) or
    # NOMOUNT still answers '/ as sysdba', and used to be started=ok
    local sout; sout="$(ORACLE_SID="$s" ORACLE_HOME="$HOME_DIR" to "$START_TIMEOUT" "$HOME_DIR/bin/sqlplus" -S / as sysdba <<<"startup" 2>&1)"; printf '%s\n' "$sout" >>"$LOG_FILE"
    printf '%s\n' "$sout" | grep -E 'ORA-[0-9]+' | grep -v 'ORA-01081' | head -3 | while IFS= read -r l; do warn "$s: startup: $l"; done
    sql_ok "$s" || { err "$s did not start (see $LOG_FILE)"; state_set started failed; return 1; }
    local om; om="$(sql_val "$s" "(select database_role||'/'||open_mode from v\$database)" 2>/dev/null)"
    case "$om" in
      "PRIMARY/READ WRITE"|"LOGICAL STANDBY/READ WRITE"|"PHYSICAL STANDBY/MOUNTED"|"PHYSICAL STANDBY/READ ONLY"*|"SNAPSHOT STANDBY/READ WRITE") log "$s: $om";;
      "") err "$s: cannot read the open mode after startup - not recording it as started"; state_set started failed; return 1;;
      *) err "$s is up but $om - not open read write (startup errors above / $LOG_FILE)"; state_set started failed; return 1;;
    esac
    case "$om" in PRIMARY/*|"LOGICAL STANDBY"/*) local pout; pout="$(sql_run "$s" "alter pluggable database all open;" 2>&1)"; printf '%s\n' "$pout" >>"$LOG_FILE"
      printf '%s' "$pout" | grep -qE 'ORA-[0-9]+' && warn "$s: alter pluggable database all open: $(printf '%s\n' "$pout" | grep -m1 -oE 'ORA-[0-9]+.*' | cut -c1-120)"
      local closed; closed="$(sql_val "$s" "(select count(*) from v\$pdbs where open_mode<>'READ WRITE' and name<>'PDB\$SEED')" 2>/dev/null)"
      [ -n "$closed" ] && [ "$closed" != 0 ] && warn "$s: $closed PDB(s) still not READ WRITE after 'all open'";;
    esac
  done
  state_set started ok
}

cmd_datapatch() {
  setup_env; reuse_or_init datapatch
  local oop; oop="$(state_get oop_home || true)"; [ -n "$oop" ] && HOME_DIR="$oop"
  local s rc=0; for s in $SIDS; do
    db_instances | grep -qx "$s" || { warn "$s not running - datapatch skipped"; continue; }
    sql_ok "$s" || { err "$s unreachable"; rc=1; continue; }
    [ "$(sql_val "$s" "(select database_role from v\$database)")" = "PHYSICAL STANDBY" ] && { log "$s is a physical standby - datapatch runs on the primary and ships over"; continue; }
    log "datapatch -verbose on $s (this can take 10-40 minutes; tail -f $LOG_FILE)"
    [ "$DRY_RUN" = 1 ] && continue
    ORACLE_SID="$s" ORACLE_HOME="$HOME_DIR" PATH="$HOME_DIR/bin:$HOME_DIR/OPatch:$PATH" to 7200 "$HOME_DIR/OPatch/datapatch" -verbose >>"$LOG_FILE" 2>&1 || { err "$s: datapatch returned an error"; rc=1; }
    local bad; bad="$(sql_val "$s" "(select count(*) from cdb_registry_sqlpatch where status not in ('SUCCESS','IGNORED'))" 2>/dev/null)"; [ -z "$bad" ] && bad="$(sql_val "$s" "(select count(*) from dba_registry_sqlpatch where status not in ('SUCCESS','IGNORED'))")"
    [ -z "$bad" ] && { err "$s: cannot read the sqlpatch registry after datapatch - not assuming SUCCESS (see $LOG_FILE)"; rc=1; }
    [ -n "$bad" ] && [ "$bad" != 0 ] && { err "$s: $bad datapatch entries not SUCCESS"; sql_lines "$s" "select con_id||' '||patch_id||' '||status||' '||substr(description,1,60) from cdb_registry_sqlpatch where status not in ('SUCCESS','IGNORED');" 2>/dev/null | tee -a "$LOG_FILE"; rc=1; }
    # utlrp's status used to be dropped: a recompile that never ran (no sqlplus, wrong SID, ORA-12162) left SYS objects invalid
    # with the step reported ok. Its exit status counts, and the outcome - invalid SYS/SYSTEM objects left - is printed
    log "$s: utlrp"; sql_script "$s" "$HOME_DIR/rdbms/admin" utlrp.sql || { err "$s: utlrp did not run cleanly (see $LOG_FILE)"; rc=1; }
    db_is_cdb "$s" && { sql_run "$s" "alter session set container=CDB\$ROOT;\n@?/rdbms/admin/utlrp.sql" >>"$LOG_FILE" 2>&1 || { err "$s: utlrp in CDB\$ROOT failed (see $LOG_FILE)"; rc=1; }; }
    local inv; inv="$(sql_val "$s" "(select count(*) from dba_objects where status<>'VALID' and owner in ('SYS','SYSTEM'))" 2>/dev/null)"
    if [ -z "$inv" ]; then err "$s: cannot count the invalid SYS/SYSTEM objects after utlrp"; rc=1
    elif [ "$inv" -gt 0 ]; then warn "$s: $inv invalid SYS/SYSTEM object(s) remain after utlrp - 'heal' offers utlrp again; if they stay invalid, dba_objects names them"
    else log "$s: no invalid SYS/SYSTEM objects after utlrp"; fi
  done
  state_set datapatch "$([ "$rc" = 0 ] && echo ok || echo failed)"; return "$rc"
}

cmd_verify() {
  setup_env; reuse_or_init verify
  local oop; oop="$(state_get oop_home || true)"; [ -n "$oop" ] && HOME_DIR="$oop"
  local fail=0 id; INSTALLED="$(to 180 opatch lspatches 2>/dev/null)"
  for id in $(state_get applied || true); do printf '%s\n' "$INSTALLED" | grep -q "^$id;" && log "$id in inventory" || { err "$id missing from inventory"; fail=1; }; done
  local s; for s in $SIDS; do
    db_instances | grep -qx "$s" || { err "$s not running"; fail=1; continue; }
    sql_ok "$s" || { err "$s unreachable"; fail=1; continue; }
    local role; role="$(sql_val "$s" "(select database_role from v\$database)")"
    if [ "$role" = PRIMARY ] || [ "$role" = "LOGICAL STANDBY" ]; then
      local homeru; homeru="$(printf '%s\n' "$INSTALLED" | grep -iE 'Database Release Update' | grep -viE 'OJVM|MONTHLY' | tail -1 | cut -d';' -f2 | sed 's/^ *//')"
      local miss; miss="$(sql_lines "$s" "select c.name from v\$containers c where c.open_mode='READ WRITE' and c.name<>'PDB\$SEED' and not exists (select 1 from cdb_registry_sqlpatch p where p.con_id=c.con_id and p.status='SUCCESS' and p.action='APPLY' and p.description='$homeru');" 2>/dev/null | tr '\n' ' ')"
      [ -n "$miss" ] && { err "$s: datapatch level is not '$homeru' in: $miss"; fail=1; } || log "$s: datapatch at '$homeru' in every open container"
      local bad; bad="$(sql_val "$s" "(select count(*) from cdb_registry_sqlpatch where status not in ('SUCCESS','IGNORED'))" 2>/dev/null)"
      if [ -z "$bad" ]; then err "$s: cannot read cdb_registry_sqlpatch - verify cannot pass on an unread registry"; fail=1; elif [ "$bad" != 0 ]; then err "$s: $bad failed datapatch rows"; fail=1; fi
    else log "$s: $role - checking apply"; [ "$(sql_val "$s" "(select count(*) from v\$managed_standby where process like 'MRP%')")" = 0 ] && { warn "$s: no MRP process - start redo apply (dgmgrl / alter database recover managed standby database disconnect)"; fail=1; }; fi
    local inv; inv="$(sql_val "$s" "(select count(*) from dba_objects where status<>'VALID' and owner in ('SYS','SYSTEM','PUBLIC'))")"
    if [ -z "$inv" ]; then warn "$s: could not count invalid SYS/SYSTEM objects (dba_objects)"; elif [ "$inv" -gt 0 ]; then warn "$s: $inv invalid SYS/SYSTEM objects after utlrp"; fi
    local pdbs; pdbs="$(sql_val "$s" "(select count(*) from v\$pdbs where open_mode<>'READ WRITE' and name<>'PDB\$SEED')" 2>/dev/null)"
    if [ -z "$pdbs" ]; then warn "$s: could not read the PDB open modes (v\$pdbs)"; elif [ "$pdbs" != 0 ]; then warn "$s: $pdbs PDB(s) not open"; fi
    log "$s: services $(sql_lines "$s" "select listagg(name,',') within group (order by name) from v\$active_services where name not like 'SYS%';" | head -1)"
  done
  local h lsn ok=0; listener_homes | while read -r h lsn; do [ "$h" = "$HOME_DIR" ] && echo "$lsn"; done | grep -q . || { local lst; lst="$(state_get listeners || true)"; [ -n "$lst" ] && { err "listener $lst not running"; fail=1; }; }
  state_set verify "$([ "$fail" = 0 ] && echo ok || echo failed)"; [ "$fail" = 0 ] && log "Verify OK" || err "Verify FAILED"; return "$fail"
}

cmd_rollback() {
  setup_env; reuse_or_init rollback
  local ids="${ARGS[*]}"; [ -z "$ids" ] && ids="$(state_get applied | tr ' ' '\n' | sed '1!G;h;$!d' | tr '\n' ' ')"
  [ -z "$ids" ] && die "nothing to roll back (no ids given and none recorded)"
  local oop rfail=0; oop="$(state_get oop_home || true)"   # rfail: any step below that did not do what it says
  if [ -n "$oop" ]; then
    local oldhome; oldhome="$(sed -n "s/^[^:]*:\([^:]*\):.*/\1/p" "$RUN_DIR/oratab.bak" 2>/dev/null | head -1)"
    [ -n "$oldhome" ] || die "cannot read the previous home from $RUN_DIR/oratab.bak: nothing to point the databases back at"
    log "out-of-place run: rollback = point the databases back at $oldhome"
    confirm "Restore /etc/oratab from the run dir and srvctl homes?" || die "aborted"
    # a database started from the new home after a failed oratab/srvctl restore is NOT rolled back: count every failure
    [ "$DRY_RUN" = 1 ] || { cp "$RUN_DIR/oratab.bak" /etc/oratab 2>>"$LOG_FILE" || { err "cannot write /etc/oratab (restore $RUN_DIR/oratab.bak by hand)"; rfail=1; }; local dbn; for dbn in $(srvctl_db_name); do "$GRID_HOME/bin/srvctl" modify database -d "$dbn" -oraclehome "$oldhome" >>"$LOG_FILE" 2>&1 || { err "srvctl modify database -d $dbn -oraclehome $oldhome failed (see $LOG_FILE)"; rfail=1; }; done; }
  else
    cmd_stop || { state_set rollback failed; err "rollback NOT started: the databases of $HOME_DIR did not all stop and opatch rollback needs the home idle - fix the stop, then 'rollback' again"; return 1; }
    local id; for id in $ids; do log "opatch rollback -id $id"; confirm "Roll back $id?" || die "aborted"; [ "$DRY_RUN" = 1 ] || to 3600 opatch rollback -silent -id "$id" >>"$LOG_FILE" 2>&1 || { err "opatch rollback of $id reported errors (see $LOG_FILE)"; rfail=1; }; done
  fi
  cmd_start || rfail=1
  local s; for s in $SIDS; do db_instances | grep -qx "$s" && sql_ok "$s" && { log "$s: datapatch after rollback (reverts the SQL side)"; [ "$DRY_RUN" = 1 ] || ORACLE_SID="$s" ORACLE_HOME="$HOME_DIR" to 7200 "$HOME_DIR/OPatch/datapatch" -verbose >>"$LOG_FILE" 2>&1 || { err "$s: datapatch after the rollback had errors (see $LOG_FILE)"; rfail=1; }; }; done
  local rps; rps="$(state_get restore_points || true)"
  [ -n "$rps" ] && { echo; echo "Restore points from this run: $rps"; echo "If datapatch left a database in a bad state, flashback is the clean undo (this discards everything since the restore point):"; echo "  shutdown immediate; startup mount; flashback database to restore point <RP>; alter database open resetlogs;"; echo "  (RAC: on one instance with the others down; standby: flashback the standby too or rebuild it)"; }
  if [ "$rfail" = 0 ]; then state_set rollback ok
  else state_set rollback failed; err "rollback INCOMPLETE: at least one step above failed - the home, the databases or the SQL side may still be on the patch (opatch lsinventory, datapatch -verbose, $LOG_FILE)"; return 1; fi
}

cmd_restore() {
  setup_env; reuse_or_init restore
  local tarf; tarf="$(state_get home_backup || true)"; [ -f "$tarf" ] || die "no home backup recorded in $RUN_DIR"
  confirm "Replace $HOME_DIR with $tarf? (databases must be down)" || die "aborted"
  [ -n "$(db_instances)" ] && [ "$FORCE" = 0 ] && die "databases still running; stop first (or --force)"
  [ "$DRY_RUN" = 1 ] && return 0
  mv "$HOME_DIR" "$HOME_DIR.broken.$(date +%s)" && tar -xzf "$tarf" -C "$(dirname "$HOME_DIR")" || die "restore failed; the old home is at $HOME_DIR.broken.*"
  log "restored; run 'start' then 'verify'. Remove $HOME_DIR.broken.* when happy."
}

cmd_cleanup() {
  setup_env; reuse_or_init cleanup
  # a drop whose output carried ORA- used to be logged as 'dropped' and the command exited 0 - the restore point (and the
  # flashback logs it pins in the FRA) stayed; now the output is read, the point must be gone, and the command returns 1 otherwise
  local rc=0 rp; for rp in $(state_get restore_points || true); do local s="${rp%%:*}" name="${rp#*:}"; confirm "Drop restore point $name in $s?" || continue
    [ "$DRY_RUN" = 1 ] && { log "DRY-RUN: drop restore point $name in $s"; continue; }
    local dout; dout="$(sql_run "$s" "drop restore point $name;" 2>&1)"; printf '%s\n' "$dout" >>"$LOG_FILE"
    if printf '%s' "$dout" | grep -qE 'ORA-[0-9]+'; then err "$s: drop restore point $name failed: $(printf '%s\n' "$dout" | grep -m1 -oE 'ORA-[0-9]+.*' | cut -c1-120)"; rc=1; continue; fi
    local left; left="$(sql_val "$s" "(select count(*) from v\$restore_point where name='$name')" 2>/dev/null)"
    case "$left" in 0) log "$s: dropped $name";; "") warn "$s: drop restore point $name returned no error but v\$restore_point could not be read afterwards - check it";; *) err "$s: $name is still in v\$restore_point after the drop"; rc=1;; esac
  done
  local keep="${KEEP_BACKUPS:-2}"; ls -t "$BACKUP_DIR"/oracle_home_*.tar.gz 2>/dev/null | tail -n +$((keep+1)) | while read -r f; do confirm "Delete old backup $f?" && rm -f "$f"; done
  local b; for b in "$HOME_DIR".broken.*; do [ -d "$b" ] && confirm "Delete $b?" && rm -rf "$b"; done; return "$rc"
}

cmd_heal() {
  setup_env; reuse_or_init heal; local did=0
  if opatch_locked && ! pgrep -f 'OPatch/opatch|oracle.opatch' >/dev/null; then log "removing stale OPatch lock"; confirm "rm $HOME_DIR/.patch_storage/patch_locked ?" && { [ "$DRY_RUN" = 1 ] || rm -f "$HOME_DIR/.patch_storage/patch_locked"; did=1; }; fi
  local s; for s in $SIDS; do db_instances | grep -qx "$s" && sql_ok "$s" || continue
    local bad; bad="$(sql_val "$s" "(select count(*) from dba_registry_sqlpatch where status not in ('SUCCESS','IGNORED'))")"
    [ -z "$bad" ] && warn "$s: could not read dba_registry_sqlpatch - datapatch state unknown, not clean"
    [ -n "$bad" ] && [ "$bad" != 0 ] && { warn "$s: $bad datapatch rows not SUCCESS:"; sql_lines "$s" "select patch_id||' '||status||' '||substr(description,1,60)||' log: '||logfile from dba_registry_sqlpatch where status not in ('SUCCESS','IGNORED');" ; log "  usual fix: read the logfile, fix the invalid object / missing grant it names, re-run: datapatch -verbose"; confirm "re-run datapatch -verbose on $s now?" && { cmd_datapatch; did=1; }; }
    local inv; inv="$(sql_val "$s" "(select count(*) from dba_objects where status<>'VALID' and owner in ('SYS','SYSTEM'))")"
    [ -z "$inv" ] && warn "$s: could not count invalid SYS/SYSTEM objects (dba_objects) - utlrp not offered"
    [ -n "$inv" ] && [ "$inv" -gt 0 ] && confirm "$s: $inv invalid SYS/SYSTEM objects - run utlrp?" && { if sql_script "$s" "$HOME_DIR/rdbms/admin" utlrp.sql; then did=1; local left; left="$(sql_val "$s" "(select count(*) from dba_objects where status<>'VALID' and owner in ('SYS','SYSTEM'))" 2>/dev/null)"; log "$s: utlrp done, ${left:-?} invalid SYS/SYSTEM object(s) left (was $inv)"; else err "$s: utlrp did not run cleanly (see $LOG_FILE) - the $inv objects are still invalid"; fi; }
    local closed; closed="$(sql_val "$s" "(select count(*) from v\$pdbs where open_mode<>'READ WRITE' and name<>'PDB\$SEED')" 2>/dev/null)"; [ -z "$closed" ] && warn "$s: could not read the PDB open modes (v\$pdbs)"
    [ -n "$closed" ] && [ "$closed" != 0 ] && confirm "$s: open all PDBs?" && { sql_run "$s" "alter pluggable database all open;" >>"$LOG_FILE"; did=1; }
    local home; home="$(oratab_home "$s")"; [ "$home" != "$HOME_DIR" ] && warn "$s: /etc/oratab says $home but you patched $HOME_DIR"
  done
  pgrep -f datapatch >/dev/null 2>&1 && warn "a datapatch is still running ($(pgrep -f datapatch | head -1)); do not start another"
  [ "$did" = 0 ] && log "nothing to heal"; return 0
}

cmd_run() {
  setup_env; init_run_dir run
  local dir="${ARGS[0]:-}"; [ -n "$dir" ] || die "run needs <patch-dir>"
  [ "$USE_LATEST" = 1 ] && { cmd_latest || die "latest failed"; }
  [ -n "$PATCHES" ] && { ARGS=("$dir" "${PATCHES//,/ }"); cmd_download; ARGS=("$dir"); }
  cmd_inspect; echo
  cmd_preflight || die "preflight failed - nothing changed"
  cmd_plan; confirm "Proceed with backup > stop > apply > start > datapatch > verify?" || die "aborted"
  cmd_backup || die "FAILED: backup - nothing changed, the databases are up and the home untouched. Log: $LOG_FILE"
  cmd_stop || die "FAILED: stop - a database or listener of $HOME_DIR is still running, nothing patched. Log: $LOG_FILE"
  if ! cmd_apply; then err "apply failed"
    # with nothing recorded as applied there is nothing for opatch to roll back - rollback died on that ('nothing to roll back')
    # and the databases, stopped a step earlier, stayed DOWN; they are started on the home as it is
    if [ -n "$(state_get applied || true)" ]; then err "rolling back what was applied"; cmd_rollback; cmd_verify || cmd_restore; die "FAILED: apply (rolled back). Log: $LOG_FILE"
    else log "no patch recorded as applied - starting the databases on the home as it is"; cmd_start || err "the databases did NOT start - they are DOWN (see $LOG_FILE)"; die "FAILED: apply (no patch applied, nothing to roll back). Log: $LOG_FILE"; fi
  fi
  cmd_start || { err "start failed after apply - rolling back"; cmd_rollback; die "FAILED: start (rolled back). Log: $LOG_FILE"; }
  if ! cmd_datapatch; then err "datapatch failed"; if confirm "Roll back the patches (opatch rollback + datapatch) now? [no = leave it for heal]"; then cmd_rollback; fi; die "FAILED: datapatch. Log: $LOG_FILE  (heal shows the failed rows; flashback restore points: $(state_get restore_points || echo none))"; fi
  cmd_verify || { err "verify failed"; confirm "Roll back?" && cmd_rollback; die "FAILED: verify. Log: $LOG_FILE"; }
  echo "SUCCESS: $HOME_DIR patched ($(state_get applied)), datapatch applied in: $SIDS. Restore points: $(state_get restore_points || echo none) - drop them with 'cleanup' when happy. Log: $LOG_FILE"
}

main() {
  load_config; refuse_root
  local cmd="${1:-}"; shift || true; parse_opts "$@"
  case "$cmd" in
    inspect) cmd_inspect;; latest) cmd_latest;; download) cmd_download;; plan) cmd_plan;; preflight) cmd_preflight;; backup) cmd_backup;;
    stop) cmd_stop;; apply) cmd_apply;; start) cmd_start;; datapatch) cmd_datapatch;; verify) cmd_verify;; rollback) cmd_rollback;;
    restore) cmd_restore;; cleanup) cmd_cleanup;; heal) cmd_heal;; run) cmd_run;; ""|-h|--help|help) usage;; *) die "Unknown command: $cmd";;
  esac
}
main "$@"
