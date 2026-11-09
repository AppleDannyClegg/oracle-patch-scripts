#!/usr/bin/env bash
# output-dir.sh - every script that creates, downloads or reports puts its files in the one configurable location.
#
# Checks that nothing writes under a bare $HOME/<tool> any more, that each script gets its defaults from the
# resolver, that the copies of the resolver in the scripts that do not source the lib match the lib's, and, by
# running each script's real default line, that ORACLE_OUTPUT_DIR reaches it. Offline, no Oracle needed.
#
# Usage: tests/output-dir.sh
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
pass=0; fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

block() { sed -n '/^# >>> output-location/,/^# <<< output-location/p' "$1"; }
want="$(block lib/oracle-lib.sh)"
[ -n "$want" ] && ok || bad "no output-location block in the lib"

# the scripts that do not source the lib carry the same block
for f in get.sh patching/patch-manifest.sh patching/ohs-patch/ohs-patch.sh patching/dbclient-upgrade/dbclient-upgrade.sh \
         patching/ohs-quarter/ohs-quarter.sh patching/wls-quarter/wls-quarter.sh patching/wls-patch/wls-patch.sh \
         patching/apex-patch/apex-patch.sh patching/ords-patch/ords-patch.sh reports/oracle-diag/oracle-diag.sh; do
  [ "$(block "$f")" = "$want" ] && ok || bad "$f: output-location block differs from the lib's"
done

# no script keeps a default under a bare $HOME/<tool> (config files, credentials and product discovery are not outputs)
left="$(git grep -nE '\$HOME/[a-z-]+' -- 'patching/*.sh' 'operations/*.sh' 'reports/*.sh' get.sh lib \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#|\.oracle\.conf|\.mos-token|/ords"|oraInventory|oraInst|\.[a-z-]+\.conf|oracle-patch-scripts|\$HOME/\$1' || true)"
[ -z "$left" ] && ok || bad "default still under \$HOME: $left"

# every script either uses the resolver or goes through the lib's RUN_BASE
while IFS= read -r f; do
  case "$f" in *file-patterns*) continue;; esac
  if grep -qE 'output_path|OUTPUT_CONFIGURED' "$f"; then ok
  elif grep -qE '\. .*oracle-lib\.sh' "$f" && grep -qE 'init_run_dir|reuse_or_init|report_init' "$f"; then ok
  else bad "$f: not wired to the output location"; fi
done < <(git ls-files 'patching/*.sh' 'operations/*.sh' 'reports/*.sh' get.sh | grep -v '/lib/')

# run each default line for real, against an isolated HOME
T="$(cd "$(mktemp -d)" && pwd -P)"
while IFS=: read -r f var sub; do
  got="$(env -u "$var" -u RUN_BASE -u DRY_RUN HOME="$T/h-$var" ORACLE_OUTPUT_DIR="$T/o" bash -c '
    f="$1"; var="$2"; SCRIPT_DIR="$(dirname "$f")"; TOOL="$(basename "$f" .sh)"
    . lib/oracle-lib.sh >/dev/null 2>&1
    eval "$(grep -E "^[[:space:]]*(.*; *)?$var=\"\\\$\{$var:-\\\$\(output_path" "$f" | head -1 | grep -oE "$var=\"\\\$\{$var:-[^}]*\}\"")"
    printf %s "${!var}"' _ "$f" "$var")"
  [ "$got" = "$T/o/$sub" ] && ok || bad "$f $var: [$got], wanted [$T/o/$sub]"
done <<'TABLE'
reports/perf-snapshot/perf-snapshot.sh:PERF_OUT:perf-snapshot
reports/db-health-daily/db-health-daily.sh:HEALTH_OUT:db-health-daily
reports/obic-diag/obic-diag.sh:OBIC_OUT:obic-diag
reports/okv-diag/okv-diag.sh:OKV_OUT:okv-diag
reports/security-posture/security-posture.sh:SEC_OUT:security-posture
reports/space-forecast/space-forecast.sh:SPACE_OUT:space-forecast
reports/space-forecast/space-forecast.sh:SPACE_HISTORY:space-forecast/history
operations/rman-ops/rman-ops.sh:RMAN_OUT:rman-ops
operations/incident-pack/incident-pack.sh:PACK_OUT:incident-pack
operations/exascale-space/exascale-space.sh:EXA_OUT:exascale-space
operations/exascale-space/exascale-space.sh:EXA_HISTORY:exascale-space/history
operations/apex-export/apex-export.sh:APEX_OUT:apex-export
operations/apex-export/apex-export.sh:APEX_REPO:apex-export/repo
operations/gg-ops/gg-ops.sh:GG_OUT:gg-ops
patching/patch-status/patch-status.sh:PATCH_OUT:patch-status
patching/cert-renew/cert-renew.sh:CERT_OUT:cert-renew
patching/cert-renew/cert-renew.sh:CERT_DIR:cert-renew/csr
patching/db-patch/db-patch.sh:BACKUP_DIR:db-patch/backups
TABLE

# RUN_BASE and PATCH_BASE in the lib, and an explicit RUN_BASE still winning
r="$(env -u RUN_BASE HOME="$T/h" TOOL=x ORACLE_OUTPUT_DIR="$T/o" bash -c '. lib/oracle-lib.sh; printf "%s %s" "$RUN_BASE" "$PATCH_BASE"' 2>/dev/null)"
[ "$r" = "$T/o/x/runs $T/o" ] && ok || bad "lib RUN_BASE/PATCH_BASE: [$r]"
r="$(HOME="$T/h" TOOL=x RUN_BASE=/kept ORACLE_OUTPUT_DIR="$T/o" bash -c '. lib/oracle-lib.sh; printf %s "$RUN_BASE"' 2>/dev/null)"
[ "$r" = /kept ] && ok || bad "explicit RUN_BASE lost: [$r]"
printf 'PATCH_BASE=/from-conf\n' >"$T/x.conf"
r="$(HOME="$T/h" TOOL=x ORACLE_OUTPUT_DIR="$T/o" SCRIPT_DIR="$T" bash -c '. lib/oracle-lib.sh; load_config "$0" 2>/dev/null; printf %s "$PATCH_BASE"' "$T/x.conf" 2>/dev/null)"
[ "$r" = "$T/o" ] && ok || bad "load_config let PATCH_BASE override OUTPUT_DIR: [$r]"

# the self-contained tools take the setting at runtime
for s in "patching/ohs-quarter/ohs-quarter.sh" "patching/wls-quarter/wls-quarter.sh"; do
  grep -q '\$(output_path [a-z-]*-quarter)/runs' "$s" && ok || bad "$s run dir default"
  grep -q 'PATCH_ROOT="${OUTPUT_CONFIGURED:-/u01/patches}"' "$s" && ok || bad "$s patch root default"
done
r="$(env -u PATCH_BASE HOME="$T/h" ORACLE_OUTPUT_DIR="$T/o" bash -c 'source <(sed -n "/^# >>> output-location/,/^PATCH_BASE=/p" get.sh); printf %s "$PATCH_BASE"' 2>/dev/null)"
[ "$r" = "$T/o" ] && ok || bad "get.sh PATCH_BASE: [$r]"
r="$(env -u PATCH_BASE HOME="$T/h" ORACLE_OUTPUT_DIR="" bash -c 'source <(sed -n "/^# >>> output-location/,/^PATCH_BASE=/p" get.sh); printf %s "$PATCH_BASE"' 2>/dev/null)"
[ "$r" = /u01/patches ] && ok || bad "get.sh default PATCH_BASE: [$r]"

# documented where an operator will look
grep -q '^#OUTPUT_DIR=' oracle.conf.example && ok || bad "oracle.conf.example has no OUTPUT_DIR"
grep -q 'ORACLE_OUTPUT_DIR' README.md && ok || bad "README.md does not document ORACLE_OUTPUT_DIR"

echo "output-dir gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
