#!/usr/bin/env bash
# ohs-db19c.sh - move an OHS 12.2.1.4 home onto the DB19c track in ONE outage. It composes
# dbclient-upgrade.sh (the FMW installer, 34761383) and ohs-patch.sh (the opatch bundles) - it holds no patch
# logic of its own, exactly as wls-quarter.sh holds none.
#
# The set, in the order this script applies it (advisor: FMW CPU Patch Advisor KA1182 / Doc 2806740.2, the
# "Oracle HTTP Server 12.2.1.4 (with a DB Client 19c)" page; the installer and its scope are KB585169 + the
# 34761383 README):
#   1. DB Client 19c upgrade   34761383  dbclient/     the FMW INSTALLER (12c -> 19.14) - no uninstaller
#   2. FMW DBCLIENT RU         39425385  dbclientru/   opatch (-> 19.31)
#   3. OSS 19C bundle          39567777  oss/          opatch - the advisor applies OHS + OSS + DB Client together
#   4. OAM WebGate DB19c       39114058  webgate/      opatch - needs DBCLIENT FOR FMW 19.29 or later
#   5. OHS (NATIVE) DB19c      40005842  ohs/          opatch
# A folder that is missing or empty is skipped (so a re-run after a partial hand-fix does not fail); the order
# among the opatch bundles is the one above, and WebGate is always after the DBCLIENT RU for the 19.29 prereq.
#
# ONE BACKUP, ONE RESTORE POINT. The installer's backup is the whole outage's rollback (its restore_all - the
# client upgrade cannot be uninstalled). Every opatch apply is passed the same run dir through the child's
# backup-run flag, so it uses the same restore point (the level before patch 1) instead of demanding a backup per
# patch. The shared run dir must
# carry what ohs-patch's apply reads (ohs-patch.sh:747-773): oracle_home=<home>, backup=ok, backup_dir=<dir>,
# pre_patches=<level before patch 1>, and <backup_dir>/home.tgz + <backup_dir>/oraInventory.tgz must be non-empty.
# That is the interface dbclient-upgrade.sh's `backup` has to write; it is the integration seam of this script.
#
# Flow: 1. preflight every folder that is present, the installer first - refuse before any change
#       2. one confirmation for the outage, then ONE backup
#       3. stop once, apply in the order above against that one backup, start once, verify all
#       4. on any failure after the backup: restore that ONE backup (the installer's restore_all when there is
#          one, else ohs-patch's), then start once. Exit 3 when the restore itself fails.
#
# Usage: ohs-db19c.sh [<patch-root>] [options]
#
# Options
#   --patch-root DIR   the staging root (default /u01/patches, or the positional argument)
#   --oracle-home DIR  the OHS home (passed to both children)
#   --run-dir DIR      this outage's run dir (default: $RUN_BASE/<stamp>-ohs-db19c)
#   --backup-dir DIR   where the backup goes (passed to the installer)
#   --force            passed to both children
#   --yes --dry-run    as the children
#   -h|--help
#
# Env: OHS_DB19C_DBCLIENT / OHS_DB19C_OHS_PATCH override the child script paths (used by the gate).
#      RUN_BASE overrides the parent of the default run dir.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DBCLIENT="${OHS_DB19C_DBCLIENT:-$SCRIPT_DIR/../dbclient-upgrade/dbclient-upgrade.sh}"
OHS_PATCH="${OHS_DB19C_OHS_PATCH:-$SCRIPT_DIR/../ohs-patch/ohs-patch.sh}"

ts() { date '+%Y-%m-%d %H:%M:%S'; }
log()  { printf '%s [INFO ] %s\n' "$(ts)" "$*" >&2; }
warn() { printf '%s [WARN ] %s\n' "$(ts)" "$*" >&2; }
err()  { printf '%s [ERROR] %s\n' "$(ts)" "$*" >&2; }
die()  { err "$*"; exit 1; }
optchk() { [ $# -ge 2 ] || die "$1 needs a value"; case "$2" in -[!0-9]*) die "$1 needs a value, got '$2'";; esac; }
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

PATCH_ROOT=""; ORACLE_HOME_ARG=""; RUN_DIR=""; BACKUP_DIR=""; FORCE=0; DRY=0; YES=0
while [ $# -gt 0 ]; do
  case "$1" in
    --patch-root)  optchk "$@"; PATCH_ROOT="$2"; shift 2;;
    --oracle-home) optchk "$@"; ORACLE_HOME_ARG="$2"; shift 2;;
    --run-dir)     optchk "$@"; RUN_DIR="$2"; shift 2;;
    --backup-dir)  optchk "$@"; BACKUP_DIR="$2"; shift 2;;
    --force)       FORCE=1; shift;;
    --yes)         YES=1; shift;;
    --dry-run)     DRY=1; shift;;
    -h|--help|help) usage; exit 0;;
    -*) die "Unknown option: $1";;
    *) [ -z "$PATCH_ROOT" ] || die "Unknown argument: $1"; PATCH_ROOT="$1"; shift;;
  esac
done
[ -n "$PATCH_ROOT" ] || PATCH_ROOT=/u01/patches
[ -x "$DBCLIENT" ] || die "dbclient-upgrade.sh not found or not executable: $DBCLIENT"
[ -x "$OHS_PATCH" ] || die "ohs-patch.sh not found or not executable: $OHS_PATCH"
[ -d "$PATCH_ROOT" ] || die "patch root is not a directory: $PATCH_ROOT"

# ---- what this outage has, in the order it is applied ----------------------------------------------------
# the installer first, then the four opatch bundles in this family order (WebGate after the DBCLIENT RU)
INSTALLER_DIR=""; OPATCH_DIRS=()
for fam in dbclient dbclientru oss webgate ohs; do
  d="$PATCH_ROOT/$fam"
  if [ "$fam" = dbclient ]; then
    if [ ! -d "$d" ]; then log "$fam/: missing - skipping the DB Client installer"; continue; fi
    [ -r "$d" ] || die "$d is not readable"
    if [ -z "$(ls -A "$d" 2>/dev/null)" ]; then log "$fam/: empty - skipping the DB Client installer"; continue; fi
    INSTALLER_DIR="$d"
  else
    if [ ! -d "$d" ]; then log "$fam/: missing - skipping the $fam bundle"; continue; fi
    [ -r "$d" ] || die "$d is not readable"
    if [ -z "$(ls -A "$d" 2>/dev/null)" ]; then log "$fam/: empty - skipping the $fam bundle"; continue; fi
    OPATCH_DIRS+=("$d")
  fi
done
[ -n "$INSTALLER_DIR" ] || [ "${#OPATCH_DIRS[@]}" -gt 0 ] || die "nothing to apply under $PATCH_ROOT (no dbclient/, dbclientru/, oss/, webgate/ or ohs/ with content)"
if [ -z "$INSTALLER_DIR" ] && [ "${#OPATCH_DIRS[@]}" -gt 0 ]; then
  warn "$PATCH_ROOT has the opatch bundles but no dbclient/ - the DB19C bundles need the Database Client on 19c (34761383). The children's preflight decides; nothing is applied before it does."
fi

# the ordered apply list, as owner|dir, for the preflight/apply/verify loops
APPLY=(); [ -n "$INSTALLER_DIR" ] && APPLY+=("installer|$INSTALLER_DIR")
for d in "${OPATCH_DIRS[@]}"; do APPLY+=("opatch|$d"); done

# ---- run dir + one shared backup dir ----------------------------------------------------------------------
[ -n "$RUN_DIR" ] || RUN_DIR="${RUN_BASE:-$HOME/ohs-db19c/runs}/$(date '+%Y%m%d-%H%M%S')-ohs-db19c"
SHARED="$RUN_DIR/backup"       # the ONE backup the whole outage restores from; every apply takes --backup-run
mkdir -p "$RUN_DIR" || die "Cannot create the run dir $RUN_DIR"
{
  echo "created=$(ts)"
  echo "patch_root=$PATCH_ROOT"
  echo "shared_backup=$SHARED"
  echo "installer=$([ -n "$INSTALLER_DIR" ] && echo "$INSTALLER_DIR" || echo -)"
  echo "opatch_dirs=${OPATCH_DIRS[*]:-}"
} >"$RUN_DIR/state"

# ---- child invocations -----------------------------------------------------------------------------------
DOpts=(); [ -n "$ORACLE_HOME_ARG" ] && DOpts+=(--oracle-home "$ORACLE_HOME_ARG"); [ -n "$BACKUP_DIR" ] && DOpts+=(--backup-dir "$BACKUP_DIR")
[ "$FORCE" = 1 ] && DOpts+=(--force); [ "$DRY" = 1 ] && DOpts+=(--dry-run); [ "$YES" = 1 ] && DOpts+=(--yes)
OOPTS=(); [ -n "$ORACLE_HOME_ARG" ] && OOPTS+=(--oracle-home "$ORACLE_HOME_ARG")
[ "$FORCE" = 1 ] && OOPTS+=(--force); [ "$DRY" = 1 ] && OOPTS+=(--dry-run); [ "$YES" = 1 ] && OOPTS+=(--yes)

# the installer: its own log run dir for preflight/apply/verify, and the SHARED run dir for backup/rollback
drun()    { local cmd="$1"; shift; "$DBCLIENT" "$cmd" "$@" "${DOpts[@]}" --run-dir "$RUN_DIR/dbclient"; }
dshared() { local cmd="$1"; shift; "$DBCLIENT" "$cmd" "$@" "${DOpts[@]}" --run-dir "$SHARED"; }
# an opatch bundle: one log run dir, and the SHARED run dir for backup/rollback
orun()    { local cmd="$1"; shift; "$OHS_PATCH" "$cmd" "$@" "${OOPTS[@]}" --run-dir "$RUN_DIR/opatch"; }
oshared() { local cmd="$1"; shift; "$OHS_PATCH" "$cmd" "$@" "${OOPTS[@]}" --run-dir "$SHARED"; }

# the backup is the installer's when there is one (that is the documented restore point), else ohs-patch's
backup_once() {
  if [ -n "$INSTALLER_DIR" ]; then dshared backup
  else oshared backup "${OPATCH_DIRS[0]}"; fi
}

installer_attempted=0; opatch_attempted=0
# returns 0 when the home is restored (or nothing needed restoring) and started, 1 when it is not
recover() {
  local rec=1
  log "recovering: stopping the components first"
  if ! orun stop; then
    err "Could not stop the components to recover - nothing is restored, and they are NOT started. Fix by hand."
    return 1
  fi
  if [ "$installer_attempted" = 1 ] || [ "$opatch_attempted" = 1 ]; then
    if [ -n "$INSTALLER_DIR" ]; then
      log "recovering: dbclient-upgrade rollback from $SHARED (the installer's restore_all - not opatch rollback)"
      dshared rollback || { err "the restore failed - restore this home by hand from the backup"; rec=0; }
    else
      log "recovering: ohs-patch rollback from $SHARED (there is no installer in this outage)"
      oshared rollback || { err "the restore failed - restore this home by hand from the backup"; rec=0; }
    fi
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
log "=== 1/6 preflight (nothing has changed yet)"
for entry in "${APPLY[@]}"; do
  owner="${entry%%|*}"; dir="${entry#*|}"
  if [ "$owner" = installer ]; then
    drun preflight "$dir" --will-stop || die "installer preflight failed - nothing changed"
    log "dbclient: $dir preflight OK"
  else
    orun preflight "$dir" || die "preflight failed for $dir - nothing changed"
    log "$(basename "$dir"): $dir preflight OK"
  fi
done

# one confirmation for the whole outage, so the children do not each prompt: after it they all run --yes
what=""
for entry in "${APPLY[@]}"; do what="${what:+$what + }$(basename "${entry#*|}")"; done
if [ "$DRY" = 0 ] && [ "$YES" = 0 ]; then
  [ -t 0 ] || die "Non-interactive and --yes not given: refusing to stop the components and apply ($what)"
  printf 'Preflight OK. Stop the components, apply %s in one outage, then start once? [y/N] ' "$what"
  ans=""; read -r ans || true
  case "$ans" in [Yy]*) YES=1; DOpts+=(--yes); OOPTS+=(--yes);; *) die "aborted - nothing changed";; esac
fi

# ---- 2. backup (ONCE) ------------------------------------------------------------------------------------
log "=== 2/6 backup (one backup for the whole outage)"
backup_once || die "the backup failed - nothing changed"

# ---- 3. stop (once) --------------------------------------------------------------------------------------
log "=== 3/6 stop (once for the whole outage)"
orun stop || die "Could not stop the components cleanly - nothing patched"

# ---- 4. apply, in the pinned order ----------------------------------------------------------------------
log "=== 4/6 apply"
for entry in "${APPLY[@]}"; do
  owner="${entry%%|*}"; dir="${entry#*|}"
  if [ "$owner" = installer ]; then
    installer_attempted=1
    drun apply "$dir" --backup-run "$SHARED" || fail_after "dbclient-upgrade apply failed (installer $dir)"
    log "dbclient: applied $dir"
  else
    opatch_attempted=1
    orun apply "$dir" --backup-run "$SHARED" || fail_after "ohs-patch apply failed on $dir"
    log "$(basename "$dir"): applied $dir"
  fi
done

# ---- 5. start (once) -------------------------------------------------------------------------------------
log "=== 5/6 start (once - the only restart)"
orun start || fail_after "the patched home does not start"

# ---- 6. verify -------------------------------------------------------------------------------------------
log "=== 6/6 verify"
for entry in "${APPLY[@]}"; do
  owner="${entry%%|*}"; dir="${entry#*|}"
  if [ "$owner" = installer ]; then
    drun verify || fail_after "dbclient-upgrade verify failed (sqlplus -V 19.14+ / oracle.rdbms.rsf 19.x)"
  else
    orun verify "$dir" || fail_after "ohs-patch verify failed on $dir"
  fi
done

log "OHS DB19C OK: $(printf '%s ' "$what")applied in one outage; the one backup is under $SHARED"
