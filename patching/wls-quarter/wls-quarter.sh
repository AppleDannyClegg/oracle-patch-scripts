#!/usr/bin/env bash
# wls-quarter.sh - apply a whole patch quarter in ONE outage: the JDK, the WebLogic Stack Patch Bundle and the
# WebLogic single patches. It composes java-patch.sh and wls-patch.sh - it holds no patch logic of its own.
#
# Flow on a get-patches staging root (/u01/patches: jdk/*.tar.gz, spb/, wls/):
#   1. preflight every folder that is present (java-patch, then wls-patch spb and wls) - refuse before any change
#   2. backup: wls-patch once (home + domains) and java-patch
#   3. stop: wls-patch once
#   4. apply in order JDK -> SPB -> single patches (java-patch apply, wls-patch apply spb, wls-patch apply wls)
#   5. start: wls-patch once (the only restart for the outage; RESTART_CMDS/ORDS live in the wls-patch config)
#   6. verify each: java-patch, wls-patch
#   7. on any failure: wls-patch restore (never the cumulative nrollback) and java-patch rollback, in reverse
#      order; the servers are started only when BOTH recovered
#
# The JDK goes first because OPatch and SPBAT are Java tools - they run on the JDK named in
# ORACLE_HOME/oui/.globalEnv.properties, and java-patch's in-place swap keeps that path, so the whole WLS stack
# runs on the target JDK. It goes after the stop (an in-place swap refuses while a JVM runs on the old JDK), which
# is why java-patch preflight is called with --will-stop.
#
# Usage: wls-quarter.sh [<patch-root>] [options]
#
# Options
#   --patch-root DIR   the staging root (default /u01/patches, or the positional argument)
#   --java-home DIR    the JDK to replace (passed to both children)
#   --oracle-home DIR  the WebLogic home (passed to wls-patch)
#   --run-dir DIR      the quarter's run dir (default: $RUN_BASE/<stamp>-wls-quarter)
#   --no-cacerts       do not carry CA aliases (java-patch)
#   --force            passed to both children (it does NOT waive the in-place JVM stop)
#   --yes --dry-run    as the children
#   -h|--help
#
# Env: WLS_QUARTER_JAVA_PATCH / WLS_QUARTER_WLS_PATCH override the child script paths (used by the gate).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JAVA_PATCH="${WLS_QUARTER_JAVA_PATCH:-$SCRIPT_DIR/../java-patch/java-patch.sh}"
WLS_PATCH="${WLS_QUARTER_WLS_PATCH:-$SCRIPT_DIR/../wls-patch/wls-patch.sh}"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s [INFO ] %s\n' "$(ts)" "$*" >&2; }
warn() { printf '%s [WARN ] %s\n' "$(ts)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

PATCH_ROOT=""; JAVA_HOME_ARG=""; ORACLE_HOME_ARG=""; RUN_DIR=""; NO_CACERTS=0; FORCE=0; DRY=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --patch-root) [ $# -ge 2 ] || die "--patch-root needs a dir"; PATCH_ROOT="$2"; shift 2;;
    --java-home)  [ $# -ge 2 ] || die "--java-home needs a dir"; JAVA_HOME_ARG="$2"; shift 2;;
    --oracle-home) [ $# -ge 2 ] || die "--oracle-home needs a dir"; ORACLE_HOME_ARG="$2"; shift 2;;
    --run-dir)    [ $# -ge 2 ] || die "--run-dir needs a dir"; RUN_DIR="$2"; shift 2;;
    --no-cacerts) NO_CACERTS=1; shift;;
    --force)      FORCE=1; shift;;
    --yes)        YES=1; shift;;
    --dry-run)    DRY=1; shift;;
    -h|--help|help) usage; exit 0;;
    -*) die "Unknown option: $1";;
    *) [ -z "$PATCH_ROOT" ] || die "Unknown argument: $1"; PATCH_ROOT="$1"; shift;;
  esac
done
[ -n "$PATCH_ROOT" ] || PATCH_ROOT=/u01/patches
[ -x "$JAVA_PATCH" ] || die "java-patch.sh not found or not executable: $JAVA_PATCH"
[ -x "$WLS_PATCH" ] || die "wls-patch.sh not found or not executable: $WLS_PATCH"
[ -d "$PATCH_ROOT" ] || die "patch root is not a directory: $PATCH_ROOT"

# ---- what this quarter has ------------------------------------------------------------------------------
JDK_TAR=""; SPB_DIR=""; WLS_DIR=""; have_jdk=0; have_spb=0; have_wls=0
JDK_DIR="$PATCH_ROOT/jdk"
if [ -d "$JDK_DIR" ]; then
  tars=("$JDK_DIR"/*.tar.gz)
  if [ ! -e "${tars[0]:-}" ]; then log "jdk/: present but no *.tar.gz - skipping the JDK"
  elif [ "${#tars[@]}" -gt 1 ]; then die "more than one JDK tarball in $JDK_DIR: $(printf '%s ' "${tars[@]##*/}") - keep one"
  else JDK_TAR="${tars[0]}"; have_jdk=1; fi
else log "jdk/: missing - skipping the JDK"; fi
check_dir() { # <dir> <name>: sets the have_ flag via echo; empty is a skip, unreadable is fatal
  local d="$1" name="$2"
  if [ ! -d "$d" ]; then log "$name/: missing - skipping $name"; return 1; fi
  if [ ! -r "$d" ]; then die "$d is not readable"; fi
  if [ -z "$(ls -A "$d" 2>/dev/null)" ]; then log "$name/: empty - skipping $name"; return 1; fi
  return 0
}
check_dir "$PATCH_ROOT/spb" spb && { SPB_DIR="$PATCH_ROOT/spb"; have_spb=1; }
check_dir "$PATCH_ROOT/wls" wls && { WLS_DIR="$PATCH_ROOT/wls"; have_wls=1; }
[ "$have_jdk" = 1 ] || [ "$have_spb" = 1 ] || [ "$have_wls" = 1 ] || die "nothing to apply under $PATCH_ROOT (no jdk/, spb/ or wls/ with content)"

# ---- run dir + state -------------------------------------------------------------------------------------
[ -n "$RUN_DIR" ] || RUN_DIR="${RUN_BASE:-$HOME/wls-quarter/runs}/$(date '+%Y%m%d-%H%M%S')-wls-quarter"
JAVA_RUN="$RUN_DIR/java"; WLS_RUN="$RUN_DIR/wls"
mkdir -p "$JAVA_RUN" "$WLS_RUN" || die "Cannot create the run dir $RUN_DIR"
{
  echo "created=$(ts)"
  echo "patch_root=$PATCH_ROOT"
  echo "java_run=$JAVA_RUN"
  echo "wls_run=$WLS_RUN"
  echo "have_jdk=$have_jdk have_spb=$have_spb have_wls=$have_wls"
} >"$RUN_DIR/state"

# ---- child invocations -----------------------------------------------------------------------------------
JOPTS=(); [ -n "$JAVA_HOME_ARG" ] && JOPTS+=(--java-home "$JAVA_HOME_ARG"); [ "$NO_CACERTS" = 1 ] && JOPTS+=(--no-cacerts)
[ "$FORCE" = 1 ] && JOPTS+=(--force); [ "$DRY" = 1 ] && JOPTS+=(--dry-run); [ "$YES" = 1 ] && JOPTS+=(--yes)
WOPTS=(); [ -n "$ORACLE_HOME_ARG" ] && WOPTS+=(--oracle-home "$ORACLE_HOME_ARG"); [ -n "$JAVA_HOME_ARG" ] && WOPTS+=(--java-home "$JAVA_HOME_ARG")
[ "$FORCE" = 1 ] && WOPTS+=(--force); [ "$DRY" = 1 ] && WOPTS+=(--dry-run); [ "$YES" = 1 ] && WOPTS+=(--yes)

jrun() { # <java-patch command and args...>
  local cmd="$1"; shift
  "$JAVA_PATCH" "$cmd" "$@" "${JOPTS[@]}" --run-dir "$JAVA_RUN"
}
wrun() {
  local cmd="$1"; shift
  "$WLS_PATCH" "$cmd" "$@" "${WOPTS[@]}" --run-dir "$WLS_RUN"
}

# a change is only undone when one was recorded: a java apply that died before the rename leaves no state
java_changed() { grep -qE '^(apply=ok|old_jdk=)' "$JAVA_RUN/state" 2>/dev/null; }

java_attempted=0; wls_attempted=0
recover() {
  local rec=1
  # stop before undoing anything: an in-place java-patch rollback renames the JDK under live JVMs (apply refuses
  # exactly that) and an SPB restore overwrites the home under them; both need the JVMs down first
  log "recovering: stopping the servers first"
  if ! wrun stop; then
    err "Could not stop the servers to recover - nothing is restored or rolled back, and the servers are NOT started. Fix by hand."
    return 0
  fi
  if [ "$wls_attempted" = 1 ]; then
    # this quarter's own backup only: a bare 'restore' falls back to BACKUP_DIR/latest, which can be an older
    # backup of the same home (Gort 15:18:19)
    local bd; bd="$(sed -n 's/^backup_dir=//p' "$WLS_RUN/state" 2>/dev/null | tail -1)"
    if [ -z "$bd" ]; then
      err "no wls-patch backup recorded in $WLS_RUN - not restoring anything automatically"; rec=0
    else
      log "recovering: wls-patch restore $bd (an SPB's nrollback is cumulative - restore is the only complete rollback)"
      wrun restore "$bd" || { err "wls-patch restore failed - restore this home by hand"; rec=0; }
    fi
  fi
  if [ "$java_attempted" = 1 ] && java_changed; then
    log "recovering: java-patch rollback"
    jrun rollback || { err "java-patch rollback failed - restore the JDK by hand"; rec=0; }
  fi
  if [ "$rec" = 1 ]; then
    wrun start || err "Servers did not start after recovery - manual attention needed"
  else
    err "Recovery incomplete - servers NOT started: the home may be part-patched. Fix by hand."
  fi
  return 0
}
fail_after() { err "$1"; recover; exit 1; }

# ---- 1. preflight everything before any change -----------------------------------------------------------
log "=== 1/6 preflight (nothing has changed yet)"
if [ "$have_jdk" = 1 ]; then
  jrun preflight "$JDK_TAR" --will-stop || die "JDK preflight failed - nothing changed"
  log "jdk: $JDK_TAR preflight OK"
fi
if [ "$have_spb" = 1 ]; then
  wrun preflight "$SPB_DIR" || die "SPB preflight failed - nothing changed"
  log "spb: $SPB_DIR preflight OK"
fi
if [ "$have_wls" = 1 ]; then
  wrun preflight "$WLS_DIR" || die "single-patch preflight failed - nothing changed"
  log "wls: $WLS_DIR preflight OK"
fi

# ---- 2. backup -------------------------------------------------------------------------------------------
log "=== 2/6 backup"
if [ "$have_spb" = 1 ] || [ "$have_wls" = 1 ]; then wrun backup || die "wls-patch backup failed - nothing changed"; fi
if [ "$have_jdk" = 1 ]; then jrun backup || die "java-patch backup failed - nothing changed"; fi

# ---- 3. stop (once) --------------------------------------------------------------------------------------
log "=== 3/6 stop (once for the whole quarter)"
wrun stop || die "Could not stop WebLogic cleanly - nothing patched"

# ---- 4. apply: JDK -> SPB -> single patches --------------------------------------------------------------
log "=== 4/6 apply"
if [ "$have_jdk" = 1 ]; then
  java_attempted=1
  jrun apply "$JDK_TAR" || fail_after "java-patch apply failed"
  log "jdk: applied $JDK_TAR"
fi
if [ "$have_spb" = 1 ]; then
  wls_attempted=1
  wrun apply "$SPB_DIR" || fail_after "wls-patch apply failed on the Stack Patch Bundle"
  log "spb: applied $SPB_DIR"
fi
if [ "$have_wls" = 1 ]; then
  wls_attempted=1
  wrun apply "$WLS_DIR" || fail_after "wls-patch apply failed on the single patches"
  log "wls: applied $WLS_DIR"
fi

# ---- 5. start (once) -------------------------------------------------------------------------------------
log "=== 5/6 start (once - the only restart)"
wrun start || fail_after "wls-patch start failed after patching"

# ---- 6. verify -------------------------------------------------------------------------------------------
log "=== 6/6 verify"
if [ "$have_jdk" = 1 ]; then jrun verify || fail_after "java-patch verify failed"; fi
if [ "$have_spb" = 1 ] || [ "$have_wls" = 1 ]; then wrun verify || fail_after "wls-patch verify failed"; fi

log "QUARTER OK: JDK $([ "$have_jdk" = 1 ] && echo "$JDK_TAR" || echo '-'), SPB $([ "$have_spb" = 1 ] && echo "$SPB_DIR" || echo '-'), single patches $([ "$have_wls" = 1 ] && echo "$WLS_DIR" || echo '-')"
