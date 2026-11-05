#!/usr/bin/env bash
# wls-patch-spb.sh - behavioural gate for wls-patch.sh's Stack Patch Bundle handling.
#
# A WLS Stack Patch Bundle is applied with SPBAT (tools/spbat/generic/SPBAT/spbat.sh), not with
# 'opatch apply' one patch at a time: SPBAT runs a precheck (OPatch 13.9.4.2.13+), then an apply that also
# upgrades OPatch, and the README's rollback is 'opatch nrollback -idFile'.
#
# Runs the real script against a fake WebLogic home and an SPB tree whose spbat.sh only records its argv.
#
# Usage: tests/wls-patch-spb.sh [repo-root]
set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/patching/wls-patch/wls-patch.sh"
[ -f "$SCRIPT" ] || { echo "wls-patch spb gate: $SCRIPT not found"; exit 2; }

T="$(cd "$(mktemp -d /tmp/wlsspb.XXXXXX)" && pwd -P)"; trap '[ -n "${KEEP:-}" ] || rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

mk_home() { # <dir> <opatch version>
  local h="$1"
  mkdir -p "$h/wlserver" "$h/inventory" "$h/OPatch" "$h/oui"
  echo '<component name="WebLogic Server" version="12.2.1.4.0"/>' >"$h/inventory/registry.xml"
  echo "JAVA_HOME=$T/jdk" >"$h/oui/.globalEnv.properties"
  cat >"$h/OPatch/opatch" <<EOF
#!/bin/sh
echo "\$*" >>"$T/opatch.log"
case "\$1" in
  version) echo "OPatch Version: $2" ;;
  lspatches) echo "39372515;WLS PATCH SET UPDATE 12.2.1.4.260514" ;;
esac
exit 0
EOF
  chmod +x "$h/OPatch/opatch"
}
mkdir -p "$T/jdk/bin"
printf '#!/bin/sh\necho "java version \\"1.8.0_471\\"" >&2\nexit 0\n' >"$T/jdk/bin/java"
chmod +x "$T/jdk/bin/java"

mk_spb() { # <patch dir>
  local spb="$1/extracted/WLS_SPB_12.2.1.4.990101"
  mkdir -p "$spb/tools/spbat/generic/SPBAT" "$spb/binary_patches/p40129643/etc/config"
  printf 'x' >"$spb/binary_patches/rollback_patchlist.txt"
  # an SPB patch dir looks exactly like an ordinary patch to 'find -path */etc/config/inventory.xml'
  echo '<inventory/>' >"$spb/binary_patches/p40129643/etc/config/inventory.xml"
  cat >"$spb/tools/spbat/generic/SPBAT/spbat.sh" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$T/spbat.log"
exit 0
EOF
  chmod +x "$spb/tools/spbat/generic/SPBAT/spbat.sh"
}

run() { # each invocation gets its own log; run() is called in $( ), so a counter would not persist
  local f; f="$(printf '%s/run.%02d.log' "$T" "$(( $(find "$T" -maxdepth 1 -name 'run.*.log' | wc -l | tr -d ' ') + 1 ))")"
  HOME="$T" ORACLE_HOME="$1" JAVA_HOME="$T/jdk" bash "$SCRIPT" "${@:2}" >"$f" 2>&1; echo $?; }
lastlog() { tail -4 "$(find "$T" -maxdepth 1 -name 'run.*.log' | sort | tail -1)"; }

# ---- precheck is run when OPatch is new enough -------------------------------------------------------
OH="$T/oh-new"; mk_home "$OH" 13.9.4.2.23
PD="$T/patches-new"; mk_spb "$PD"; : >"$T/spbat.log"
rc="$(run "$OH" preflight "$PD" --oracle-home "$OH" --java-home "$T/jdk" --yes)"
[ "$rc" = 0 ] && ok || bad "preflight exit $rc on an SPB dir: $(lastlog)"
grep -q 'Stack Patch Bundle' "$(find "$T" -maxdepth 1 -name 'run.*.log' | sort | tail -1)" && ok || bad "preflight did not recognise the SPB: $(lastlog)"
grep -qx -- '-phase precheck -oracle_home '"$OH" "$T/spbat.log" && ok || bad "SPBAT precheck not run/arg-spaced: [$(cat "$T/spbat.log")]"
# the SPB's own binary patch must not be queued as an individual 'opatch apply'
grep -q '^40129643|' "$(find "$T" -maxdepth 1 -name 'run.*.log' | sort | tail -1)" && bad "the SPB's binary patch was listed as an individual patch" || ok

# ---- precheck is skipped, and said so, on an OPatch below 13.9.4.2.13 --------------------------------
OH2="$T/oh-old"; mk_home "$OH2" 12.2.0.1.40
PD2="$T/patches-old"; mk_spb "$PD2"; : >"$T/spbat.log"
rc="$(run "$OH2" preflight "$PD2" --oracle-home "$OH2" --java-home "$T/jdk" --yes)"
grep -q 'precheck skipped' "$(find "$T" -maxdepth 1 -name 'run.*.log' | sort | tail -1)" && ok || bad "no 'precheck skipped' on OPatch 12.2.0.1.40: $(lastlog)"
grep -q -- '-phase precheck' "$T/spbat.log" && bad "SPBAT precheck ran on an OPatch below the minimum" || ok

# ---- apply routes to SPBAT and records it, and rollback uses the README's nrollback ------------------
PD3="$T/patches-apply"; mk_spb "$PD3"; : >"$T/spbat.log"; : >"$T/opatch.log"
rc="$(run "$OH" apply "$PD3" --oracle-home "$OH" --java-home "$T/jdk" --yes)"
grep -qx -- '-phase apply -oracle_home '"$OH" "$T/spbat.log" && ok || bad "SPBAT apply not run/arg-spaced: [$(cat "$T/spbat.log")]"
grep -q 'opatch apply' "$T/opatch.log" && bad "opatch apply ran alongside SPBAT" || ok
rc="$(run "$OH" verify --oracle-home "$OH" --java-home "$T/jdk")"
[ "$rc" = 0 ] && ok || bad "verify after an SPB apply exited $rc: $(lastlog)"
grep -Eq 'inventory PSU .*bundle|inventory PSU is' "$(find "$T" -maxdepth 1 -name 'run.*.log' | sort | tail -1)" && ok || bad "verify did not compare the inventory PSU with the bundle: $(lastlog)"
rc="$(run "$OH" rollback --yes)"
grep -q -- 'nrollback' "$T/opatch.log" && ok || bad "rollback did not use the SPB's 'opatch nrollback': [$(cat "$T/opatch.log")]"
grep -q -- '-idFile .*rollback_patchlist.txt' "$T/opatch.log" && ok || bad "nrollback without the README's -idFile: [$(cat "$T/opatch.log")]"

# ---- two bundles in one folder is refused, not silently last-one-wins -------------------------------
PD7="$T/patches-two"; mk_spb "$PD7"
cp -R "$PD7/extracted/WLS_SPB_12.2.1.4.990101" "$PD7/extracted/WLS_SPB_12.2.1.4.990102"
: >"$T/spbat.log"
rc="$(run "$OH" preflight "$PD7" --oracle-home "$OH" --java-home "$T/jdk" --yes)"
[ "$rc" != 0 ] && ok || bad "preflight accepted two Stack Patch Bundles in one folder"
grep -q 'more than one Stack Patch Bundle' "$(find "$T" -maxdepth 1 -name 'run.*.log' | sort | tail -1)" && ok || bad "two SPBs not reported: $(lastlog)"

# ---- an unreadable oui/.globalEnv.properties is reported, not read as a pass ------------------------
OH4="$T/oh-nogj"; mk_home "$OH4" 13.9.4.2.23; rm -f "$OH4/oui/.globalEnv.properties"
PD8="$T/patches-nogj"; mk_spb "$PD8"
rc="$(run "$OH4" preflight "$PD8" --oracle-home "$OH4" --java-home "$T/jdk" --yes)"
grep -q 'could not read .*globalEnv.properties' "$(find "$T" -maxdepth 1 -name 'run.*.log' | sort | tail -1)" && ok || bad "a missing oui/.globalEnv.properties passed the JAVA_HOME check silently: $(lastlog)"

# ---- get-patches files the SPB zip under <patch-dir>/spb/, which must still be found ------------------
PD6="$T/patches-sub"; mkdir -p "$PD6/spb" "$T/zipsrc"
cp -R "$T/patches-new/extracted/WLS_SPB_12.2.1.4.990101" "$T/zipsrc/"
( cd "$T/zipsrc" && zip -qr "$PD6/spb/p40129641_122140_Generic.zip" WLS_SPB_12.2.1.4.990101 ) || bad "could not build the spb/ zip fixture"
: >"$T/spbat.log"
rc="$(run "$OH" preflight "$PD6" --oracle-home "$OH" --java-home "$T/jdk" --yes)"
grep -q 'Stack Patch Bundle' "$(find "$T" -maxdepth 1 -name 'run.*.log' | sort | tail -1)" && ok || bad "an SPB zip filed under <dir>/spb/ (get-patches' layout) was not found: $(lastlog)"
grep -qx -- '-phase precheck -oracle_home '"$OH" "$T/spbat.log" && ok || bad "precheck not reached for a spb/-filed zip: [$(cat "$T/spbat.log")]"

# ---- get-patches also files ordinary patches under <patch-dir>/wls/, which must be found too -------------
PD9="$T/patches-wls"; mkdir -p "$PD9/wls" "$T/zipwls"
mkdir -p "$T/zipwls/p39372515_122140_Generic/etc/config"
echo '<inventory/>' >"$T/zipwls/p39372515_122140_Generic/etc/config/inventory.xml"
( cd "$T/zipwls" && zip -qr "$PD9/wls/p39372515_122140_Generic.zip" p39372515_122140_Generic ) || bad "could not build the wls/ zip fixture"
rc="$(run "$OH" preflight "$PD9" --oracle-home "$OH" --java-home "$T/jdk" --yes)"
grep -q '^p39372515_122140_Generic|' "$(find "$T" -maxdepth 1 -name 'run.*.log' | sort | tail -1)" && ok || bad "a patch filed under <dir>/wls/ (get-patches' layout) was not found: $(lastlog)"

# ---- an SPBAT failure stops the apply; nothing is recorded as applied ---------------------------------
OH3="$T/oh-fail"; mk_home "$OH3" 13.9.4.2.23
PD4="$T/patches-fail"; mk_spb "$PD4"
printf '#!/bin/sh\nexit 1\n' >"$PD4/extracted/WLS_SPB_12.2.1.4.990101/tools/spbat/generic/SPBAT/spbat.sh"
rc="$(run "$OH3" apply "$PD4" --oracle-home "$OH3" --java-home "$T/jdk" --yes)"
[ "$rc" != 0 ] && ok || bad "apply exited 0 although SPBAT failed"
grep -q 'SPBAT apply failed' "$(find "$T" -maxdepth 1 -name 'run.*.log' | sort | tail -1)" && ok || bad "a failed SPBAT apply was not reported: $(lastlog)"

# ---- a dry run applies nothing and must not record the SPB as applied --------------------------------
PD5="$T/patches-dry"; mk_spb "$PD5"; : >"$T/spbat.log"
rc="$(run "$OH" apply "$PD5" --oracle-home "$OH" --java-home "$T/jdk" --yes --dry-run --run-dir "$T/dryrun")"
[ "$rc" = 0 ] && ok || bad "dry-run apply exited $rc: $(lastlog)"
grep -q -- '-phase apply' "$T/spbat.log" && bad "a dry run executed SPBAT apply" || ok
grep -rq '^spb_applied=' "$T/dryrun" 2>/dev/null && bad "a dry run recorded spb_applied in the state" || ok

echo "wls-patch spb gate: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
