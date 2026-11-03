# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# oem-standby-lag: the emcli world. emcli is not in the gates' stub list, so this file adds one: it logs like the
# others, honours FAIL_RE (false-success gate), and answers sync / help / get_targets so the wrapper's preflight and
# its change commands reach emcli instead of ending NOT-EXERCISED. The wrapper's metric SQL and its verify repository
# read are answered by the gates' sqlplus stub from $ANSWERS. The metric-extension archive and the run dir a rollback
# reads are seeded under $T/env (recreated per command), so import/rollback have the file and state they need.
ME="$T/env/oem"; mkdir -p "$ME"
: >"$ME/oem-standby-lag.zip"
r="$T/env/run-rollback"; mkdir -p "$r"; printf 'deployed_targets=STBYA,STBYB\n' >"$r/state"
# the wrapper reads the archive from ME_ARCHIVE (the gate asserts -file_name=$T/me.zip in its own stub world)
export ME_ARCHIVE="$ME/oem-standby-lag.zip"
export SQL_CMD="$STUB/sqlplus -S" SQL_CONNECT="/ as sysdba" ORACLE_HOME="$T/oh"
mkdir -p "$T/oh/bin"
# the metric SQL (one row, 7 columns) and the verify repository read, matched on this call's stdin only
cat >"$ANSWERS" <<A
v\\\$dataguard_stats|PHYSICAL STANDBY|READ ONLY WITH APPLY|0|5|3|1|OK
mgmt\\\$metric_current|STBYA|lag_status|OK|2026-11-03 12:00:00
A
cat >"$STUB/emcli" <<'E'
#!/bin/sh
q=""; [ -t 0 ] || q="$(cat)"
{ echo "TOOL emcli $*"; [ -n "$q" ] && printf '%s\n' "$q" | sed 's/^/  > /'; } >>"$DRY_LOG"
line="emcli $* | $(printf '%s' "$q" | tr '\n' ';')"
if [ -n "${FAIL_RE:-}" ] && printf '%s' "$line" | grep -qiE -- "$FAIL_RE"; then
  echo "FAILED emcli $*" >>"$DRY_LOG"; echo "emcli: failed (false-success gate)" >&2; exit 1
fi
verb="$1"; shift
case "$verb" in
  sync) exit "${EMCLI_SYNC_RC:-0}";;
  help) for f in -file_name -target_type -name -version -target_names -targets; do echo "    [$f=\"value\"]"; done; exit 0;;
  get_targets) for t in ${EMCLI_TARGETS:-STBYA STBYB}; do echo "1  Up  oracle_database  $t"; done; exit 0;;
esac
echo "$verb ok"
exit 0
E
chmod +x "$STUB/emcli"
export EMCLI_TARGETS="STBYA STBYB"
# emcli's metric-extension verbs are not in the gates' CHANGE_RE, so fail the extension calls explicitly: the
# false-success gate then drives the command for real and checks the wrapper records no success after emcli failed.
# anchored '^emcli <verb>': preflight calls 'emcli help <verb>', so an unanchored regex fails the help call and the
# false-success gate never reaches the actual change. Fail the change itself.
# deploy matches either the current deploy_metric_extension or the redesign's apply_template (Cortex 12:10:32,
# still unverified per Legion/Vision 12:10:53), so PKG 4 survives whichever verb lands without another edit. rollback's
# undeploy is kept for the current script; under the redesign rollback makes no emcli call and is NOT-EXERCISED, correct.
FAIL_import='^emcli import_metric_extension'; FAIL_publish='^emcli (save_metric_extension_draft|publish_metric_extension)'; FAIL_deploy='^emcli (deploy_metric_extension|apply_template)'; FAIL_rollback='^emcli undeploy_metric_extension'; FAIL_run='^emcli (import|save|publish|deploy)_metric_extension|^emcli apply_template'
# a change claim in state: any <step>=ok, plus the extension-specific records the wrapper writes only after success
OK_import='^([a-z_]+=ok|imported=)'; OK_publish='^([a-z_]+=ok|published=)'; OK_deploy='^([a-z_]+=ok|deployed_targets=)'; OK_rollback='^([a-z_]+=ok|undeployed_targets=)'; OK_run='^([a-z_]+=ok|deployed_targets=)'
export ME_TEMPLATE="STANDBY_LAG"
ARGS="--sid STBY"; ARGS_sql_test="--sid STBY"; ARGS_import="--targets STBYA"; ARGS_publish="--targets STBYA"; ARGS_deploy="--targets STBYA,STBYB --run-dir $T/env/run-deploy"; ARGS_rollback="--run-dir $r"; ARGS_run="--targets STBYA,STBYB"
