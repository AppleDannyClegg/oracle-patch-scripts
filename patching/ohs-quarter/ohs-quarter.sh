#!/usr/bin/env bash
# ohs-quarter.sh - bring a whole Oracle HTTP Server 12.2.1.4 home CPU-current in ONE outage: the JDK, the WLS
# PSU, the Database Client 19c upgrade and every DB19c/quarterly opatch row. It composes java-patch.sh,
# wls-patch.sh, dbclient-upgrade.sh and ohs-patch.sh - it holds no patch logic of its own, exactly as
# wls-quarter.sh holds none.
#
# The set, in the order this script applies it. A/H are the advisor's standalone "Oracle HTTP Server 12.2.1.4
# (with a DB Client 19c)" page (FMW CPU Patch Advisor KA1182 / Doc 2806740.2); the installer and its scope are
# KB585169 + the 34761383 README:
#   jdk/            Java SE 8u503+ (18143322)         java-patch.sh   the JDK at /u01/app/oracle/java
#   wlspsu/         WLS PSU 39919567 12.2.1.4.260823   wls-patch.sh    for the home's wlserver
#   dbclient/       DB Client 19c 34761383             dbclient-upgrade.sh  the FMW INSTALLER (12c -> 19.14),
#                                                                     plus the opt-in removal of the 12c patches
#   dbclientru/     FMW DBCLIENT RU 39425385           ohs-patch.sh    opatch (-> 19.31)
#   webgate/        OAM WebGate DB19c 39114058         ohs-patch.sh    needs DBCLIENT FOR FMW 19.29 or later
#   oss/            OSS 19C bundle 39567777            ohs-patch.sh    advisor applies OHS + OSS + DB Client together
#   ohs/            OHS (NATIVE) DB19c 40005842        ohs-patch.sh
#   jdbc/           JDBC 19.31 39487427                ohs-patch.sh
#   libovd/         LibOVD 39465265                    ohs-patch.sh
#   fmwthirdparty/  FMW third-party 39574504           ohs-patch.sh
#   perl/  libdms2/  libiau/   PERL 38590502, LIBDMS2 38098858, LIBIAU 38832179   ohs-patch.sh
# The order among the opatch bundles is the one above, WebGate after the DBCLIENT RU for the 19.29 prereq.
#
# EVERY FOLDER ABOVE MUST BE THERE, OR BE NAMED IN --skip. A folder that is missing or empty is not applied, and
# this script will not decide that for you: it stops before anything changes and prints the --skip list to add.
# That is what keeps "OHS QUARTER OK" from being printed over an outage that applied two of thirteen sets.
# These folder names are this runbook's, one per step, and they carry the order. get-patches.ps1 files its
# downloads by patch kind (wls/ db/ spb/ ohs/ jdk/), which is a different layout: a root holding wls/, db/ or
# spb/ is refused, and the patches have to be sorted into the folders above first:
#   ohs-quarter-stage.sh plan <download-dir> <patch-root>, then run - it files each zip by its patch number.
#
# ALL PATCH LOGIC LIVES IN THE CHILDREN. The extra opatch rows go through ohs-patch.sh because it already applies
# an arbitrary opatch patch to this home; wls-patch.sh carries only the WLS PSU, because it drags in WebLogic
# domain/server semantics the OHS home does not need.
#
# ONE BACKUP PHASE, ONE STOP, ONE START. Preflight of every present child runs before any change. The backup
# phase is each child's own (the JDK, the WLS home+domains, and one shared home+inventory backup the installer
# and every opatch apply restores from). Every opatch apply is passed the shared run dir through the child's
# backup-run flag, so the restore point is the level before the first change, not before the last patch. The
# shared run dir must carry what ohs-patch's apply reads (ohs-patch.sh:747-773): oracle_home=<home>, backup=ok,
# backup_dir=<dir>, pre_patches=<level before patch 1>, and <backup_dir>/home.tgz + oraInventory.tgz non-empty.
#
# Flow: 1. preflight every present child; 2. one confirmation; 3. one backup phase; 4. stop once; 5. apply in the
# order above; 6. start once; 7. verify all. On any failure after the backup: stop, restore every child that was
# attempted in reverse order, start once. Exit 3 when the restore itself fails.
#
# Usage: ohs-quarter.sh [<patch-root>] [options]
#
# Options
#   --patch-root DIR   the staging root (default OUTPUT_DIR if set, else /u01/patches; or the positional argument)
#   --oracle-home DIR  the OHS home (passed to every child)
#   --java-home DIR    the JDK to replace (passed to java-patch and wls-patch)
#   --run-dir DIR      this outage's run dir (default: $RUN_BASE/<stamp>-ohs-quarter)
#   --backup-dir DIR   where the backups go (passed to wls-patch and the installer)
#   --remove-12c IDS   pass the opt-in 12c-patch removal to the installer (comma list; default: do not remove)
#   --skip LIST        folders this outage deliberately leaves out (comma list, e.g. --skip wlspsu,jdbc). Required
#                      for every folder above that is missing or empty; naming a folder that has content is refused
#   --no-cacerts       do not carry CA aliases across (java-patch)
#   --force            passed to every child
#   --yes --dry-run    as the children
#   -h|--help
#
# Env: OHS_QUARTER_JAVA_PATCH / OHS_QUARTER_WLS_PATCH / OHS_QUARTER_DBCLIENT / OHS_QUARTER_OHS_PATCH override the
#      child script paths (used by the gate). RUN_BASE overrides the parent of the default run dir.

set -uo pipefail
# >>> output-location (the same block in lib/oracle-lib.sh and every script that does not source it; tests/output-dir.sh compares them)
# Where a script puts what it creates. ORACLE_OUTPUT_DIR in the environment wins, then OUTPUT_DIR from oracle.conf or ~/.oracle.conf.
# With neither set, a host that already has $HOME/<tool> keeps it, so an upgrade strands no run state, backup or history; a fresh
# host uses /u01/oracle-patch-scripts (macOS: $HOME/oracle-patch-scripts when /u01 cannot be written). The first write creates it.
OUTPUT_SERVER_BASE="${OUTPUT_SERVER_BASE:-/u01/oracle-patch-scripts}"
# shellcheck disable=SC2034
OUTPUT_HINT="set OUTPUT_DIR in oracle.conf, or ORACLE_OUTPUT_DIR, to choose where this goes"
output_configured() {
  [ -n "${ORACLE_OUTPUT_DIR:-}" ] && { printf '%s' "$ORACLE_OUTPUT_DIR"; return 0; }
  local f v="" d; d="${SCRIPT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)}"
  for f in "$d/../../oracle.conf" "$d/../oracle.conf" "$HOME/.oracle.conf"; do
    [ -f "$f" ] && grep -qE '^[[:space:]]*(export[[:space:]]+)?OUTPUT_DIR=' "$f" || continue
    # shellcheck disable=SC1090
    v="$(unset OUTPUT_DIR; . "$f" >/dev/null 2>&1; printf '%s' "${OUTPUT_DIR:-}")"
  done
  printf '%s' "$v"
}
output_writable() { local d="$1"; while [ ! -e "$d" ] && [ "$d" != / ]; do d="$(dirname "$d")"; done; [ -d "$d" ] && [ -w "$d" ]; }
output_default_base() {
  case "${OSTYPE:-$(uname -s | tr 'A-Z' 'a-z')}" in
    darwin*) if output_writable "$OUTPUT_SERVER_BASE"; then printf '%s' "$OUTPUT_SERVER_BASE"; else printf '%s' "$HOME/oracle-patch-scripts"; fi;;
    msys*|cygwin*|win*) printf '%s' "$HOME/oracle-patch-scripts";;
    *) printf '%s' "$OUTPUT_SERVER_BASE";;
  esac
}
OUTPUT_CONFIGURED="$(output_configured)"
case "$OUTPUT_CONFIGURED" in ''|/*) ;; *) printf 'ERROR: OUTPUT_DIR must be an absolute path, got: %s\n' "$OUTPUT_CONFIGURED" >&2; exit 1;; esac
output_path() { # <tool>: the folder for that tool. Prints it, creates nothing.
  if [ -n "$OUTPUT_CONFIGURED" ]; then printf '%s/%s' "${OUTPUT_CONFIGURED%/}" "$1"
  elif [ -d "$HOME/$1" ]; then printf '%s/%s' "$HOME" "$1"
  else printf '%s/%s' "$(output_default_base)" "$1"; fi
}
# <<< output-location

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAVA_PATCH="${OHS_QUARTER_JAVA_PATCH:-$SCRIPT_DIR/../java-patch/java-patch.sh}"
WLS_PATCH="${OHS_QUARTER_WLS_PATCH:-$SCRIPT_DIR/../wls-patch/wls-patch.sh}"
DBCLIENT="${OHS_QUARTER_DBCLIENT:-$SCRIPT_DIR/../dbclient-upgrade/dbclient-upgrade.sh}"
OHS_PATCH="${OHS_QUARTER_OHS_PATCH:-$SCRIPT_DIR/../ohs-patch/ohs-patch.sh}"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s [INFO ] %s\n' "$(ts)" "$*" >&2; }
warn() { printf '%s [WARN ] %s\n' "$(ts)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }
optchk() { [ $# -ge 2 ] || die "$1 needs a value"; case "$2" in -[!0-9]*) die "$1 needs a value, got '$2'";; esac; }
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

PATCH_ROOT=""; ORACLE_HOME_ARG=""; JAVA_HOME_ARG=""; RUN_DIR=""; BACKUP_DIR=""; REMOVE_12C=""; SKIP=""; NO_CACERTS=0; FORCE=0; DRY=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --patch-root)  optchk "$@"; PATCH_ROOT="$2"; shift 2;;
    --oracle-home) optchk "$@"; ORACLE_HOME_ARG="$2"; shift 2;;
    --java-home)   optchk "$@"; JAVA_HOME_ARG="$2"; shift 2;;
    --run-dir)     optchk "$@"; RUN_DIR="$2"; shift 2;;
    --backup-dir)  optchk "$@"; BACKUP_DIR="$2"; shift 2;;
    --remove-12c)  optchk "$@"; REMOVE_12C="$2"; shift 2;;
    --skip)        optchk "$@"; SKIP="$2"; shift 2;;
    --no-cacerts)  NO_CACERTS=1; shift;;
    --force)       FORCE=1; shift;;
    --yes)         YES=1; shift;;
    --dry-run)     DRY=1; shift;;
    -h|--help|help) usage; exit 0;;
    -*) die "Unknown option: $1";;
    *) [ -z "$PATCH_ROOT" ] || die "Unknown argument: $1"; PATCH_ROOT="$1"; shift;;
  esac
done
[ -n "$PATCH_ROOT" ] || PATCH_ROOT="${OUTPUT_CONFIGURED:-/u01/patches}"
[ -x "$JAVA_PATCH" ] || die "java-patch.sh not found or not executable: $JAVA_PATCH"
[ -x "$WLS_PATCH" ]  || die "wls-patch.sh not found or not executable: $WLS_PATCH"
[ -x "$DBCLIENT" ]   || die "dbclient-upgrade.sh not found or not executable: $DBCLIENT"
[ -x "$OHS_PATCH" ]  || die "ohs-patch.sh not found or not executable: $OHS_PATCH"
[ -d "$PATCH_ROOT" ] || die "patch root is not a directory: $PATCH_ROOT"

# ---- the folders are the contract: every one is applied, or left out by name --------------------------------
SETS=(jdk wlspsu dbclient dbclientru webgate oss ohs jdbc libovd fmwthirdparty perl libdms2 libiau)
is_set() { local s; for s in "${SETS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }
skipped() { case ",$SKIP," in *",$1,"*) return 0;; esac; return 1; }
IFS=',' read -r -a skip_names <<<"$SKIP"
for s in "${skip_names[@]}"; do
  [ -n "$s" ] || continue
  is_set "$s" || die "--skip names '$s', which is not a folder of this runbook (${SETS[*]})"
done
# get-patches.ps1 names its folders by patch kind. wls/, db/ and spb/ are never this runbook's, so a root holding
# one is a download tree that has not been sorted: stop, or this would apply the two names that happen to match
foreign=""
for k in wls db spb; do [ -d "$PATCH_ROOT/$k" ] && foreign="$foreign $k/"; done
[ -z "$foreign" ] || die "$PATCH_ROOT holds$foreign - that is a get-patches.ps1 download tree, filed by patch kind. This runbook reads one folder per step (${SETS[*]}): sort the patches into those folders first ($SCRIPT_DIR/ohs-quarter-stage.sh plan <that tree> <a new root> does it). Nothing changed."

# ---- what this outage has, in the order it is applied ----------------------------------------------------
JDK_TAR=""; WLSPSU_DIR=""; INSTALLER_DIR=""; OPATCH_DIRS=()
# the JDK is a tarball, not a patch dir (wls-quarter's rule: exactly one *.tar.gz in jdk/)
JDK_DIR="$PATCH_ROOT/jdk"
if [ -d "$JDK_DIR" ]; then
  tars=("$JDK_DIR"/*.tar.gz)
  if [ ! -e "${tars[0]:-}" ]; then log "jdk/: present but no *.tar.gz - skipping the JDK"
  elif [ "${#tars[@]}" -gt 1 ]; then die "more than one JDK tarball in $JDK_DIR: $(printf '%s ' "${tars[@]##*/}") - keep one"
  else JDK_TAR="${tars[0]}"; fi
else log "jdk/: missing - skipping the JDK"; fi

# a patch dir is used when present, readable and non-empty; a missing/empty one is a skip, an unreadable one is fatal
# families: folder|owner  (owner: wls = wls-patch, dc = dbclient-upgrade, ohs = ohs-patch)
dirs_ok() { # <dir> <name>: 0 when usable; logs the skip otherwise
  local d="$1" name="$2"
  if [ ! -d "$d" ]; then log "$name/: missing - skipping"; return 1; fi
  [ -r "$d" ] || die "$d is not readable"
  if [ -z "$(ls -A "$d" 2>/dev/null)" ]; then log "$name/: empty - skipping"; return 1; fi
  return 0
}
dirs_ok "$PATCH_ROOT/wlspsu" wlspsu && WLSPSU_DIR="$PATCH_ROOT/wlspsu"
dirs_ok "$PATCH_ROOT/dbclient" dbclient && INSTALLER_DIR="$PATCH_ROOT/dbclient"
for fam in dbclientru webgate oss ohs jdbc libovd fmwthirdparty perl libdms2 libiau; do
  dirs_ok "$PATCH_ROOT/$fam" "$fam" && OPATCH_DIRS+=("$PATCH_ROOT/$fam")
done
[ -n "$JDK_TAR$WLSPSU_DIR$INSTALLER_DIR" ] || [ "${#OPATCH_DIRS[@]}" -gt 0 ] || die "nothing to apply under $PATCH_ROOT (no jdk/, wlspsu/, dbclient/ or opatch dir with content)"

# what was found, set against what the operator said to leave out. Both directions are refused before any change:
# a folder that is not there and was not named, and a folder that was named but is there.
present=" "
[ -n "$JDK_TAR" ] && present="${present}jdk "
[ -n "$WLSPSU_DIR" ] && present="${present}wlspsu "
[ -n "$INSTALLER_DIR" ] && present="${present}dbclient "
for d in "${OPATCH_DIRS[@]}"; do present="${present}$(basename "$d") "; done
unasked=""; contradicted=""; LEFT_OUT=""
for s in "${SETS[@]}"; do
  case "$present" in
    *" $s "*) skipped "$s" && contradicted="$contradicted $s";;
    *) if skipped "$s"; then LEFT_OUT="${LEFT_OUT:+$LEFT_OUT }$s"; else unasked="${unasked:+$unasked,}$s"; fi;;
  esac
done
[ -z "$contradicted" ] || die "--skip names$contradicted, but $PATCH_ROOT has content for it. Remove it from --skip to apply it, or move the folder away. Nothing changed."
[ -z "$unasked" ] || die "Not applying a partial runbook without being told to. Missing or empty under $PATCH_ROOT: ${unasked//,/ }. Stage them, or add  --skip $unasked${SKIP:+,$SKIP}  to leave them out on purpose. Nothing changed."
APPLIED_N=$(( ${#SETS[@]} - $(printf '%s' "$LEFT_OUT" | wc -w | tr -d ' ') ))

# the ordered apply list, as owner|arg, for the preflight/apply/verify loops
APPLY=()
[ -n "$JDK_TAR" ] && APPLY+=("java|$JDK_TAR")
[ -n "$WLSPSU_DIR" ] && APPLY+=("wls|$WLSPSU_DIR")
[ -n "$INSTALLER_DIR" ] && APPLY+=("dc|$INSTALLER_DIR")
for d in "${OPATCH_DIRS[@]}"; do APPLY+=("ohs|$d"); done

# ---- run dir + one shared backup dir ----------------------------------------------------------------------
[ -n "$RUN_DIR" ] || RUN_DIR="${RUN_BASE:-$(output_path ohs-quarter)/runs}/$(date '+%Y%m%d-%H%M%S')-ohs-quarter"
SHARED="$RUN_DIR/backup"       # the ONE shared home+inventory backup; the installer and every opatch apply use it
mkdir -p "$RUN_DIR" || die "Cannot create the run dir $RUN_DIR: $OUTPUT_HINT"
{
  echo "created=$(ts)"
  echo "patch_root=$PATCH_ROOT"
  echo "shared_backup=$SHARED"
  echo "jdk=${JDK_TAR:--}"
  echo "wlspsu=${WLSPSU_DIR:--}"
  echo "installer=${INSTALLER_DIR:--}"
  echo "opatch=${OPATCH_DIRS[*]:-}"
  echo "left_out=${LEFT_OUT:--}"
} >"$RUN_DIR/state"

# ---- child invocations -----------------------------------------------------------------------------------
JOPTS=(); [ -n "$JAVA_HOME_ARG" ] && JOPTS+=(--java-home "$JAVA_HOME_ARG"); [ "$NO_CACERTS" = 1 ] && JOPTS+=(--no-cacerts)
[ "$FORCE" = 1 ] && JOPTS+=(--force); [ "$DRY" = 1 ] && JOPTS+=(--dry-run); [ "$YES" = 1 ] && JOPTS+=(--yes)
WOPTS=(); [ -n "$ORACLE_HOME_ARG" ] && WOPTS+=(--oracle-home "$ORACLE_HOME_ARG"); [ -n "$JAVA_HOME_ARG" ] && WOPTS+=(--java-home "$JAVA_HOME_ARG")
[ -n "$BACKUP_DIR" ] && WOPTS+=(--backup-dir "$BACKUP_DIR"); [ "$FORCE" = 1 ] && WOPTS+=(--force); [ "$DRY" = 1 ] && WOPTS+=(--dry-run); [ "$YES" = 1 ] && WOPTS+=(--yes)
DOpts=(); [ -n "$ORACLE_HOME_ARG" ] && DOpts+=(--oracle-home "$ORACLE_HOME_ARG"); [ -n "$BACKUP_DIR" ] && DOpts+=(--backup-dir "$BACKUP_DIR")
[ -n "$REMOVE_12C" ] && DOpts+=(--remove-12c "$REMOVE_12C")
[ "$FORCE" = 1 ] && DOpts+=(--force); [ "$DRY" = 1 ] && DOpts+=(--dry-run); [ "$YES" = 1 ] && DOpts+=(--yes)
OOPTS=(); [ -n "$ORACLE_HOME_ARG" ] && OOPTS+=(--oracle-home "$ORACLE_HOME_ARG")
[ "$FORCE" = 1 ] && OOPTS+=(--force); [ "$DRY" = 1 ] && OOPTS+=(--dry-run); [ "$YES" = 1 ] && OOPTS+=(--yes)

jrun()    { local cmd="$1"; shift; "$JAVA_PATCH" "$cmd" "$@" "${JOPTS[@]}" --run-dir "$RUN_DIR/java"; }
wrun()    { local cmd="$1"; shift; "$WLS_PATCH" "$cmd" "$@" "${WOPTS[@]}" --run-dir "$RUN_DIR/wls"; }
drun()    { local cmd="$1"; shift; "$DBCLIENT" "$cmd" "$@" "${DOpts[@]}" --run-dir "$RUN_DIR/dbclient"; }
dshared() { local cmd="$1"; shift; "$DBCLIENT" "$cmd" "$@" "${DOpts[@]}" --run-dir "$SHARED"; }
orun()    { local cmd="$1"; shift; "$OHS_PATCH" "$cmd" "$@" "${OOPTS[@]}" --run-dir "$RUN_DIR/opatch"; }
oshared() { local cmd="$1"; shift; "$OHS_PATCH" "$cmd" "$@" "${OOPTS[@]}" --run-dir "$SHARED"; }

# one backup phase: the JDK, the WLS home+domains, and the shared home+inventory (the installer's, else ohs-patch's)
backup_once() {
  [ -n "$JDK_TAR" ] && { jrun backup || return 1; }
  if [ -n "$WLSPSU_DIR" ]; then wrun backup || return 1; fi
  if [ -n "$INSTALLER_DIR" ]; then dshared backup || return 1
  elif [ "${#OPATCH_DIRS[@]}" -gt 0 ]; then oshared backup "${OPATCH_DIRS[0]}" || return 1; fi
  return 0
}

java_attempted=0; wls_attempted=0; dc_attempted=0; ohs_attempted=0
# returns 0 when everything attempted is restored and the components are started, 1 otherwise
recover() {
  local rec=1
  log "recovering: stopping the components first"
  if ! orun stop; then
    err "Could not stop the components to recover - nothing is restored, and they are NOT started. Fix by hand."
    return 1
  fi
  # reverse of the apply order: opatch/installer share the one backup, then the WLS home, then the JDK
  if [ "$ohs_attempted" = 1 ] || [ "$dc_attempted" = 1 ]; then
    if [ -n "$INSTALLER_DIR" ]; then
      log "recovering: dbclient-upgrade rollback from $SHARED (the installer's restore_all - not opatch rollback)"
      dshared rollback || { err "the restore failed - restore this home by hand from the backup"; rec=0; }
    else
      log "recovering: ohs-patch rollback from $SHARED"
      oshared rollback || { err "the restore failed - restore this home by hand from the backup"; rec=0; }
    fi
  fi
  if [ "$wls_attempted" = 1 ]; then
    log "recovering: wls-patch restore (its own home+domains backup)"
    local bd; bd="$(sed -n 's/^backup_dir=//p' "$RUN_DIR/wls/state" 2>/dev/null | tail -1)"
    if [ -n "$bd" ]; then wrun restore "$bd" || { err "wls-patch restore failed - restore this home by hand"; rec=0; }
    else wrun restore || { err "wls-patch restore failed - restore this home by hand"; rec=0; }; fi
  fi
  if [ "$java_attempted" = 1 ]; then
    log "recovering: java-patch rollback"
    jrun rollback || { err "java-patch rollback failed - restore the JDK by hand"; rec=0; }
  fi
  if [ "$rec" = 1 ]; then
    orun start || { err "the components did not start after recovery - manual attention needed"; rec=0; }
  else
    err "Recovery incomplete - components NOT started: the home may be part-patched. Fix by hand."
  fi
  [ "$rec" = 1 ]
}
fail_after() { err "$1"; if recover; then exit 1; else exit 3; fi; }

# ---- 1. preflight everything before any change -----------------------------------------------------------
log "=== 1/7 preflight (nothing has changed yet)"
for entry in "${APPLY[@]}"; do
  owner="${entry%%|*}"; arg="${entry#*|}"
  case "$owner" in
    java) jrun preflight "$arg" --will-stop || die "java-patch preflight failed - nothing changed"; log "jdk: $arg preflight OK";;
    wls)  wrun preflight "$arg" || die "wls-patch preflight failed - nothing changed"; log "wlspsu: $arg preflight OK";;
    dc)   drun preflight "$arg" --will-stop || die "dbclient-upgrade preflight failed - nothing changed"; log "dbclient: $arg preflight OK";;
    ohs)  orun preflight "$arg" || die "ohs-patch preflight failed for $arg - nothing changed"; log "$(basename "$arg"): $arg preflight OK";;
  esac
done

# one confirmation for the whole outage, so the children do not each prompt: after it they all run --yes
what=""; for entry in "${APPLY[@]}"; do what="${what:+$what + }$(basename "${entry#*|}")"; done
if [ "$DRY" = 0 ] && [ "$YES" = 0 ]; then
  [ -t 0 ] || die "Non-interactive and --yes not given: refusing to stop the components and apply ($what)"
  printf 'Preflight OK. Stop the components, apply %s in one outage (%s of %s sets%s), then start once? [y/N] ' "$what" "$APPLIED_N" "${#SETS[@]}" "${LEFT_OUT:+; left out: $LEFT_OUT}"
  ans=""; read -r ans || true
  case "$ans" in [Yy]*) YES=1; JOPTS+=(--yes); WOPTS+=(--yes); DOpts+=(--yes); OOPTS+=(--yes);; *) die "aborted - nothing changed";; esac
fi

# ---- 2. backup (one phase) -------------------------------------------------------------------------------
log "=== 2/7 backup (one phase; each child backs up what it owns, the home+inventory one is shared)"
backup_once || die "a backup failed - nothing changed"

# ---- 3. stop (once) --------------------------------------------------------------------------------------
log "=== 3/7 stop (once for the whole outage)"
orun stop || die "Could not stop the components cleanly - nothing patched"

# ---- 4. apply, in the pinned order ----------------------------------------------------------------------
log "=== 4/7 apply"
for entry in "${APPLY[@]}"; do
  owner="${entry%%|*}"; arg="${entry#*|}"
  case "$owner" in
    java) java_attempted=1; jrun apply "$arg" || fail_after "java-patch apply failed"; log "jdk: applied $arg";;
    wls)  wls_attempted=1;  wrun apply "$arg" || fail_after "wls-patch apply failed"; log "wlspsu: applied $arg";;
    dc)   dc_attempted=1;   drun apply "$arg" --backup-run "$SHARED" || fail_after "dbclient-upgrade apply failed"; log "dbclient: applied $arg";;
    ohs)  ohs_attempted=1;  orun apply "$arg" --backup-run "$SHARED" || fail_after "ohs-patch apply failed on $arg"; log "$(basename "$arg"): applied $arg";;
  esac
done

# ---- 5. start (once) -------------------------------------------------------------------------------------
log "=== 5/7 start (once - the only restart)"
orun start || fail_after "the patched home does not start"

# ---- 6. verify -------------------------------------------------------------------------------------------
# The health check is ohs-patch verify (every component's ports answer). wls-patch verify is NOT it: on an OHS
# home it only proves the patch ids are in the inventory and checks no port (Cerebro 23:03:28 item 3). wls-patch's
# PSU level is also always empty on a home whose lspatches returns bare ids (item 2), so never read it here.
log "=== 6/7 verify"
for entry in "${APPLY[@]}"; do
  owner="${entry%%|*}"; arg="${entry#*|}"
  case "$owner" in
    java) jrun verify || fail_after "java-patch verify failed";;
    wls)  wrun verify || fail_after "wls-patch verify failed";;
    dc)   drun verify || fail_after "dbclient-upgrade verify failed (sqlplus -V 19.14+ / oracle.rdbms.rsf 19.x)";;
    ohs)  orun verify "$arg" || fail_after "ohs-patch verify failed on $arg";;
  esac
done

if [ -n "$LEFT_OUT" ]; then
  log "=== 7/7 OHS QUARTER OK, PARTIAL BY REQUEST: $APPLIED_N of ${#SETS[@]} sets applied in one outage ($what). LEFT OUT (--skip): $LEFT_OUT. The shared backup is under $SHARED"
else
  log "=== 7/7 OHS QUARTER OK: all ${#SETS[@]} sets applied in one outage ($what); the shared backup is under $SHARED"
fi
