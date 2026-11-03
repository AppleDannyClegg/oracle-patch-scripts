#!/usr/bin/env bash
# oem-standby-lag.sh - import, publish, deploy and verify the OEM 13c metric extension for Data Guard
# standby lag, and roll it back.
#
# The metric itself is built once in the EM console (Enterprise > Monitoring > Metric Extensions) from
# standby-lag.sql; this script owns the CLI half around it: import the exported extension, publish the
# draft, deploy it to the standby database targets, verify that each is collecting, and roll back by
# undeploying exactly the targets a deploy recorded. It never logs in to emcli - the operator does that
# first, so no password ever reaches this script's argv or environment.
#
# Usage: oem-standby-lag.sh <command> [options]
#
# Commands
#   plan        Print the ordered steps for this extension. Read-only.
#   sql-test    Run standby-lag.sql against --sid and print the lag row. Exit 2 CRIT / 1 WARN / 0 clean.
#               A failed read or an empty read is CRIT - an unreadable lag is never a clean 0.
#   preflight   emcli logged in, every flag this script passes listed by 'emcli help', each target known. Read-only.
#   import      emcli import_metric_extension for $ME_ARCHIVE.
#   publish     emcli save_metric_extension_draft, then publish_metric_extension.
#   deploy      Apply the monitoring template ($ME_TEMPLATE, which holds the metric extension and its
#               thresholds) to --targets with emcli apply_template. deployed_targets is recorded only
#               after that exits 0; verify reads the repository and is the check that it is collecting.
#   verify      Read sysman.mgmt$metric_current over OMR_CONNECT; a missing or UNKNOWN target is CRIT.
#   rollback    Print the console undeploy steps for the targets deploy recorded. Makes no change.
#   run         preflight, import, publish, deploy, verify.
#
# Options
#   --targets <name[,name]>   EM database targets to deploy to (target type oracle_database).
#   --sid <SID>               database instance for sql-test.
#   --sql-file <FILE>         the metric SQL (default: standby-lag.sql beside this script).
#   --run-dir <DIR>           the run to record into / read from (deploy writes it, rollback reads it).
#   --timeout <SECS>          timeout for each emcli call (default 120).
#   --dry-run --yes --force --json --verbose --quiet   shared library behaviour; --dry-run reaches no changing verb.
#
# Config: oem-standby-lag.conf (600), ~/.oem-standby-lag.conf or the shared oracle.conf -
#   TRANSPORT_LAG_WARN (300), TRANSPORT_LAG_CRIT (900), APPLY_LAG_WARN (900), APPLY_LAG_CRIT (3600),
#   CONTACT_AGE_WARN (300), CONTACT_AGE_CRIT (900), ME_ARCHIVE (the exported .zip), ME_NAME
#   (default ME$STANDBY_LAG), ME_TEMPLATE (default STANDBY_LAG - the monitoring template holding the
#   extension and its thresholds), OMR_CONNECT (sysman/<pw>@<omr> - read through sqlplus on stdin, never argv).

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="oem-standby-lag"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

ME_NAME="${ME_NAME:-ME\$STANDBY_LAG}"    # the metric extension's name in EM
ME_TEMPLATE="${ME_TEMPLATE:-STANDBY_LAG}"    # the monitoring template that holds the extension and its thresholds
ME_ARCHIVE="${ME_ARCHIVE:-}"
ME_TARGETS="${ME_TARGETS:-}"
ME_SID="${ME_SID:-}"
SQL_FILE="${ME_SQL_FILE:-$SCRIPT_DIR/standby-lag.sql}"
TRANSPORT_LAG_WARN="${TRANSPORT_LAG_WARN:-300}"; TRANSPORT_LAG_CRIT="${TRANSPORT_LAG_CRIT:-900}"
APPLY_LAG_WARN="${APPLY_LAG_WARN:-900}"; APPLY_LAG_CRIT="${APPLY_LAG_CRIT:-3600}"
CONTACT_AGE_WARN="${CONTACT_AGE_WARN:-300}"; CONTACT_AGE_CRIT="${CONTACT_AGE_CRIT:-900}"
OMR_CONNECT="${OMR_CONNECT:-}"
EMCLI_TIMEOUT="${EMCLI_TIMEOUT:-120}"

usage() { usage_from_header "$0"; }
parse_opts() {
  while [ $# -gt 0 ]; do case "$1" in
    --targets) optchk "$@"; ME_TARGETS="$2"; shift 2;;
    --sid) optchk "$@"; ME_SID="$2"; shift 2;;
    --sql-file) optchk "$@"; SQL_FILE="$2"; shift 2;;
    --run-dir) optchk "$@"; RUN_DIR="$2"; shift 2;;
    --timeout) optchk "$@"; EMCLI_TIMEOUT="$2"; shift 2;;
    --force) FORCE=1; shift;;
    --dry-run) DRY_RUN=1; shift;; --yes) ASSUME_YES=1; shift;; --json) JSON_OUT=1; shift;; --verbose) VERBOSE=1; shift;; --quiet) QUIET=1; shift;;
    -h|--help) usage; exit 0;;
    *) die "Unknown option: $1 (see --help)";;
  esac; done
}

is_num() { case "${1:-}" in ''|*[!0-9]*) return 1;; esac; return 0; }
# target_list: --targets a,b -> "a b"
target_list() { printf '%s' "${ME_TARGETS:-}" | tr ',' ' '; }
# emcli_sync: a run that is not logged in must stop here, before any change
emcli_sync() {
  if ! to "$EMCLI_TIMEOUT" emcli sync >/dev/null 2>&1; then
    die "emcli is not logged in (emcli sync failed) - run 'emcli login ...' first; this script never takes a password"
  fi
}
# emcli_change <args...>: run a changing emcli verb, or print it under --dry-run. Every changing verb goes
# through here so --dry-run reaches none of them (the dry-run gate reads what the stubs saw).
emcli_change() {
  if [ "$DRY_RUN" = 1 ]; then log "dry-run: would run: emcli $*"; return 0; fi
  to "$EMCLI_TIMEOUT" emcli "$@"
}
# emcli_help_check <verb> <flag...>: every flag this script passes must be listed by 'emcli help <verb>'. A
# flag renamed in another EM release fails here, not half-way through a deploy. Under --dry-run the check is
# skipped: 'emcli help <changing verb>' reads as a changing verb to the dry-run gate, and a dry run changes nothing.
emcli_help_check() {
  [ "$DRY_RUN" = 1 ] && return 0
  local verb="$1"; shift
  local out; out="$(to "$EMCLI_TIMEOUT" emcli help "$verb" 2>&1)" || die "emcli help $verb failed - cannot confirm the flags on this EM release"
  local f
  for f in "$@"; do
    printf '%s\n' "$out" | grep -qF -- "$f" || die "emcli help $verb does not list $f - the EM release may have renamed or dropped it; refusing before any change"
  done
}
# validate_targets <list>: refuse a name that could be read as an emcli argument before any emcli call
validate_targets() {
  local t
  for t in $1; do
    case "$t" in ''|*[!A-Za-z0-9_.:-]*) die "invalid target name '$t' (allowed: A-Za-z0-9_.:-) - refusing before any emcli call";; esac
  done
}
# emcli_targets_present <list>: get_targets must list every name we are about to act on
emcli_targets_present() {
  local gt rc=0; gt="$(to "$EMCLI_TIMEOUT" emcli get_targets 2>&1)" || rc=$?
  [ "$rc" = 0 ] || die "emcli get_targets failed (status $rc) - cannot confirm the targets"
  local t
  for t in $1; do
    printf '%s\n' "$gt" | grep -qw -- "$t" || die "target $t is not known to EM (emcli get_targets did not list it)"
  done
}

# cmd_sql_test: run the metric's own SQL and turn the row into an exit code. A failed or empty read is CRIT.
cmd_sql_test() {
  local sid="${ME_SID:-}"
  [ -n "$sid" ] || die "sql-test needs --sid SID (or ME_SID)"
  [ -f "$SQL_FILE" ] || die "metric SQL not found: $SQL_FILE (set --sql-file, or run beside standby-lag.sql)"
  local stmt; stmt="$(cat "$SQL_FILE")"
  local q; q="set heading off feedback off
select database_role||'|'||open_mode||'|'||transport_lag_sec||'|'||apply_lag_sec||'|'||primary_contact_age_sec||'|'||mrp_processes||'|'||lag_status from ($stmt)"
  local rc=0 out
  out="$(sql_lines "$sid" "$q" 2>&1)" || rc=$?
  if [ "$rc" != 0 ]; then
    err "could not read the standby lag from $sid (sqlplus status $rc; see the ORA- above) - no lag is assumed"
    return 2
  fi
  local row; row="$(printf '%s\n' "$out" | grep -E '\|' | head -1)"
  if [ -z "$row" ]; then
    err "could not read the standby lag from $sid: the query returned no row"
    return 2
  fi
  local role open_mode transport apply contact mrp status
  IFS='|' read -r role open_mode transport apply contact mrp status <<<"$row"
  say "standby-lag $sid: database_role=$role open_mode=$open_mode lag_status=$status"
  [ -n "$transport" ] && say "transport lag ${transport}s"
  [ -n "$apply" ] && say "apply lag ${apply}s"
  [ -n "$contact" ] && say "primary contact age ${contact}s"
  [ -n "$mrp" ] && say "mrp processes $mrp"
  if [ "$status" = PRIMARY ]; then
    say "$sid is PRIMARY - no standby lag to measure (this metric is switchover-safe: deploy to both sides)"
    return 0
  fi
  local sev=0
  if [ "$status" = UNKNOWN ]; then err "$sid: lag_status is UNKNOWN - the lag cannot be computed (apply off, or stats not computed)"; sev=2; fi
  if is_num "$apply" && [ "$apply" -ge "$APPLY_LAG_CRIT" ]; then err "$sid: apply lag ${apply}s is at or over the critical threshold ${APPLY_LAG_CRIT}s"; sev=2
  elif is_num "$apply" && [ "$apply" -ge "$APPLY_LAG_WARN" ]; then { [ "$sev" -lt 1 ] && sev=1; }; warn "$sid: apply lag ${apply}s is at or over the warning threshold ${APPLY_LAG_WARN}s"; fi
  if is_num "$transport" && [ "$transport" -ge "$TRANSPORT_LAG_CRIT" ]; then err "$sid: transport lag ${transport}s is at or over the critical threshold ${TRANSPORT_LAG_CRIT}s"; sev=2
  elif is_num "$transport" && [ "$transport" -ge "$TRANSPORT_LAG_WARN" ]; then { [ "$sev" -lt 1 ] && sev=1; }; warn "$sid: transport lag ${transport}s is at or over the warning threshold ${TRANSPORT_LAG_WARN}s"; fi
  if is_num "$contact" && [ "$contact" -ge "$CONTACT_AGE_CRIT" ]; then err "$sid: primary contact age ${contact}s is at or over the critical threshold ${CONTACT_AGE_CRIT}s - the primary may be gone and a 0 lag reading is frozen"; sev=2
  elif is_num "$contact" && [ "$contact" -ge "$CONTACT_AGE_WARN" ]; then { [ "$sev" -lt 1 ] && sev=1; }; warn "$sid: primary contact age ${contact}s is at or over the warning threshold ${CONTACT_AGE_WARN}s"; fi
  return "$sev"
}

cmd_plan() {
  cat <<EOF
OEM standby-lag metric extension - plan
  extension : $ME_NAME   sql: $SQL_FILE
  archive   : ${ME_ARCHIVE:-<set ME_ARCHIVE to the emcli export_metric_extension .zip>}

  1. sql-test   on each standby host (okv-rotate shape):  oem-standby-lag.sh sql-test --sid <SID>
  2. preflight  from a host with emcli logged in:          oem-standby-lag.sh preflight --targets <a,b>
  3. import     the exported extension:                    oem-standby-lag.sh import --yes
  4. publish    the draft:                                 oem-standby-lag.sh publish --yes
  5. deploy     apply the template to the targets:        oem-standby-lag.sh deploy --targets <a,b> --yes
  6. verify     that each is collecting (reads the OMR):  oem-standby-lag.sh verify --targets <a,b>
  7. rollback   print the console undeploy steps:         oem-standby-lag.sh rollback --yes

Everything here is verified against stubs only (tests/oem-standby-lag.sh); the real emcli flag names on
your EM release, the SQL on a real standby, and the metric in the console are preflight/sql-test/verify
on the real estate. The console build of the extension is manual - see README.md.
EOF
}

cmd_preflight() {
  local targets; targets="$(target_list)"
  [ -n "$targets" ] || die "preflight needs --targets a,b"
  validate_targets "$targets"
  emcli_sync
  emcli_help_check import_metric_extension -file_name
  emcli_help_check save_metric_extension_draft -name -version
  emcli_help_check publish_metric_extension -name -version
  emcli_help_check apply_template -name -targets
  emcli_targets_present "$targets"
  say "preflight OK: emcli logged in, every flag listed, targets present: $targets"
  return 0
}

cmd_import() {
  local arch="${ME_ARCHIVE:-}"
  [ -n "$arch" ] || die "import needs the metric-extension archive: set ME_ARCHIVE to the .zip from emcli export_metric_extension"
  [ -f "$arch" ] || die "metric-extension archive not found: $arch (export_metric_extension writes it)"
  emcli_sync
  emcli_help_check import_metric_extension -file_name
  confirm "Import metric extension from $arch?" || die "aborted"
  if ! emcli_change import_metric_extension "-file_name=$arch"; then
    err "emcli import_metric_extension failed for $arch"; return 1
  fi
  say "imported metric extension from $arch"
  return 0
}

cmd_publish() {
  emcli_sync
  emcli_help_check save_metric_extension_draft -target_type -name -version
  emcli_help_check publish_metric_extension -target_type -name -version
  confirm "Publish metric extension $ME_NAME?" || die "aborted"
  if ! emcli_change save_metric_extension_draft "-target_type=oracle_database" "-name=$ME_NAME" "-version=1"; then
    err "emcli save_metric_extension_draft failed"; return 1
  fi
  if ! emcli_change publish_metric_extension "-target_type=oracle_database" "-name=$ME_NAME" "-version=1"; then
    err "emcli publish_metric_extension failed"; return 1
  fi
  [ "$DRY_RUN" = 1 ] || state_set published "$ME_NAME"
  say "published $ME_NAME"
  return 0
}

cmd_deploy() {
  local targets; targets="$(target_list)"
  [ -n "$targets" ] || die "deploy needs --targets a,b"
  validate_targets "$targets"
  local csv t tstr=""; csv="$(printf '%s' "$targets" | tr ' ' ',')"
  for t in $targets; do tstr="${tstr:+$tstr;}$t:oracle_database"; done
  if [ "$DRY_RUN" = 1 ]; then
    log "dry-run: would run: emcli apply_template -name=$ME_TEMPLATE -targets=$tstr"
    say "dry-run: monitoring template $ME_TEMPLATE (metric extension $ME_NAME) would be applied to $tstr"
    return 0
  fi
  emcli_sync
  emcli_help_check apply_template -name -targets
  emcli_targets_present "$targets"
  confirm "Apply monitoring template $ME_TEMPLATE (metric extension $ME_NAME) to $csv?" || die "aborted"
  if ! emcli_change apply_template "-name=$ME_TEMPLATE" "-targets=$tstr"; then
    err "emcli apply_template failed - $ME_NAME is NOT deployed on $csv"
    return 1
  fi
  # apply_template's rc is not proof the metric is collecting: 'verify' reads the repository and is that check
  state_set deployed_targets "$csv"
  say "applied monitoring template $ME_TEMPLATE (metric extension $ME_NAME) to $csv - run 'verify' to confirm it is collecting"
  return 0
}

cmd_verify() {
  local targets; targets="$(target_list)"
  [ -n "$targets" ] || die "verify needs --targets a,b"
  if [ -z "${OMR_CONNECT:-}" ]; then
    warn "OMR_CONNECT is not set - cannot read sysman.mgmt\$metric_current, so collection is NOT verified"
    return 1
  fi
  local sql; sql="set heading off feedback off
select target_name||'|'||metric_column||'|'||value||'|'||to_char(collection_timestamp,'YYYY-MM-DD HH24:MI:SS') from sysman.mgmt\$metric_current where metric_column='lag_status'"
  # the connect string is a shell variable (never exported), so sqlplus reads it on stdin and it stays out of argv
  local saved="${SQL_CONNECT:-}"
  SQL_CONNECT="$OMR_CONNECT"
  local rc=0 rows
  rows="$(sql_lines "OMR" "$sql" 2>&1)" || rc=$?
  SQL_CONNECT="$saved"
  if [ "$rc" != 0 ]; then
    err "could not read sysman.mgmt\$metric_current over OMR_CONNECT (sqlplus status $rc) - collection is NOT verified"
    return 2
  fi
  if [ -z "$rows" ]; then
    err "sysman.mgmt\$metric_current returned no lag_status rows - no target is collecting"
    return 2
  fi
  local fail=0 t line val
  for t in $targets; do
    line="$(printf '%s\n' "$rows" | awk -F'|' -v t="$t" '$1==t {print; exit}')"
    if [ -z "$line" ]; then
      err "target $t has no current lag_status row in sysman.mgmt\$metric_current - it is NOT collecting"
      fail=1; continue
    fi
    val="$(printf '%s\n' "$line" | awk -F'|' '{print $3}')"
    if [ "$val" = UNKNOWN ]; then
      err "target $t reports lag_status UNKNOWN - it is collecting, but the lag is not computable (apply off, or stats missing)"
      fail=1
    fi
  done
  [ "$fail" = 0 ] || return 2
  say "verify OK: $targets are collecting lag_status"
  return 0
}

cmd_rollback() {
  local csv; csv="$(state_get deployed_targets || true)"
  [ -n "$csv" ] || die "no deployed_targets recorded in this run dir - point --run-dir at the deploy run"
  # there is no emcli verb that undeploys a metric extension: this is a console action, and the script makes no change
  say "Rollback is a console action: Enterprise > Monitoring > Metric Extensions > $ME_NAME > Actions > Undeploy From Targets"
  say "Targets recorded by deploy: $csv"
  say "The metric extension stays deployed until you do that from the console - this script changes nothing."
  return 0
}

cmd_run() {
  cmd_preflight || return $?
  cmd_import || return $?
  cmd_publish || return $?
  cmd_deploy || return $?
  cmd_verify
}

main() {
  load_config; refuse_root
  local cmd=""
  # options may come before the command (tests/optchk-gate.sh runs 'script --opt'): take the first bare word as the command
  case "${1:-}" in
    ""|-h|--help|help) usage; exit 0;;
    --*) : ;;
    *) cmd="$1"; shift;;
  esac
  parse_opts "$@"
  case "$cmd" in
    plan) init_run_dir plan; cmd_plan;;
    sql-test) init_run_dir sql-test; cmd_sql_test;;
    preflight) init_run_dir preflight; cmd_preflight;;
    import) init_run_dir import; cmd_import;;
    publish) init_run_dir publish; cmd_publish;;
    deploy) init_run_dir deploy; cmd_deploy;;
    verify) init_run_dir verify; cmd_verify;;
    rollback) init_run_dir rollback; cmd_rollback;;
    run) init_run_dir run; cmd_run;;
    "") usage; exit 1;;
    *) die "Unknown command: $cmd";;
  esac
}
main "$@"
