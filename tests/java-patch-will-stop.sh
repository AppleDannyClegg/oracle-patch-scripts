#!/usr/bin/env bash
# java-patch --will-stop gate: an in-place preflight on a host whose JVMs still run on the old JDK is a
# refusal, unless the caller says it will stop them (--will-stop) - then it is only a WARN, because apply's
# own hard die is still the gate. Without the flag nothing changes.
#
# Usage: tests/java-patch-will-stop.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/patching/java-patch/java-patch.sh"
[ -f "$SCRIPT" ] || { echo "java-patch will-stop gate: $SCRIPT not found"; exit 2; }

T="$(cd "$(mktemp -d /tmp/jpws.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# a temp tree so the script's ../../lib resolves, with its trailing 'main "$@"' removed
mkdir -p "$T/tree/patching/java-patch"; ln -s "$ROOT/lib" "$T/tree/lib"
sed '$d' "$SCRIPT" >"$T/tree/patching/java-patch/java-patch.sh"

mkjdk() { mkdir -p "$1/bin"; printf '#!/bin/sh\necho "openjdk version \\"%s\\" 2024-07-16" >&2\n' "$2" >"$1/bin/java"; chmod +x "$1/bin/java"; }
mkjdk "$T/jdk" 1.8.0_471
mkdir -p "$T/src/jdk-1.8.0_511/bin"; mkjdk "$T/src/jdk-1.8.0_511" 1.8.0_511
printf 'JAVA_VERSION="1.8.0_511"\n' >"$T/src/jdk-1.8.0_511/release"
tar -czf "$T/jdk-1.8.0_511_linux-x64_bin.tar.gz" -C "$T/src" jdk-1.8.0_511

# a ps that reports one JVM living under $T/jdk
mkdir -p "$T/bin"; cat >"$T/bin/ps" <<EOF
#!/bin/sh
case " \$* " in
  *" -eo pid,args "*) echo "4242 $T/jdk/bin/java -Xmx1g" ;;
  *" -o args= -p 4242 "*) echo "$T/jdk/bin/java" ;;
esac
exit 0
EOF
chmod +x "$T/bin/ps"
# a ps that cannot run at all: an unreadable process list must stay fail-closed even with --will-stop
mkdir -p "$T/bin-fail" "$T/emptyproc"; printf '#!/bin/sh\nexit 1\n' >"$T/bin-fail/ps"; chmod +x "$T/bin-fail/ps"

preflight() { # <extra flag...>; prints the output, returns cmd_preflight's status
  # shellcheck disable=SC2034  # RUN_DIR/TOOL/... are read by the sourced script
  ( PATH="${PSDIR:-$T/bin}:$PATH"; export PROC_DIR="${PROC_DIR_OVERRIDE:-/proc}"
    . "$T/tree/patching/java-patch/java-patch.sh"
    RUN_DIR="$T/run"; TOOL=java-patch; DRY_RUN=0; ASSUME_YES=1; NO_CACERTS=1; WILL_STOP=0
    FORCE=0; JSON_OUT=0; VERBOSE=0; IN_PLACE=0; KEEP_OLD=0; OLD_JH="$T/jdk"
    parse_opts "$@" "$T/jdk-1.8.0_511_linux-x64_bin.tar.gz" --run-dir "$T/run"
    cmd_preflight >/dev/null 2>"$T/err"; printf 'rc=%s\n' "$?" )
}

# without --will-stop: the in-place running-JVM check refuses (exit 1)
rm -rf "$T/run"; out="$(preflight 2>&1)"
[ "${out##*rc=}" != 0 ] && ok || bad "preflight without --will-stop did not refuse a running JVM (rc=${out##*rc=})"
grep -q 'in-place: JVMs run on' "$T/err" && ok || bad "the refusal was not named"

# with --will-stop: it only warns and preflight passes
rm -rf "$T/run"; out="$(preflight --will-stop 2>&1)"
[ "${out##*rc=}" = 0 ] && ok || bad "preflight with --will-stop did not pass (rc=${out##*rc=})"
grep -q '\[WARN \] in-place: JVMs run on' "$T/err" && ok || bad "--will-stop did not WARN about the running JVM"
grep -q 'apply still refuses' "$T/err" && ok || bad "the warn does not say apply still refuses"
grep -q '^preflight=ok' "$T/run/state" 2>/dev/null && ok || bad "--will-stop did not record preflight=ok"

# an unreadable process list stays a refusal even with --will-stop (GERTY/TARS)
rm -rf "$T/run"; out="$(PSDIR="$T/bin-fail" PROC_DIR_OVERRIDE="$T/emptyproc" preflight --will-stop 2>&1)"
[ "${out##*rc=}" != 0 ] && ok || bad "an unreadable process list passed preflight with --will-stop (rc=${out##*rc=})"
grep -q 'cannot read the process list' "$T/err" && ok || bad "the unreadable process list was not named"

# apply's hard die is untouched: an in-place apply with the JVM still running dies even with --force
# shellcheck disable=SC2034  # RUN_DIR/TOOL/... are read by the sourced script
( PATH="$T/bin:$PATH"
  . "$T/tree/patching/java-patch/java-patch.sh"
  RUN_DIR="$T/run"; TOOL=java-patch; DRY_RUN=0; ASSUME_YES=1; NO_CACERTS=1; WILL_STOP=1; FORCE=1
  JSON_OUT=0; VERBOSE=0; OLD_JH="$T/jdk"
  parse_opts "$T/jdk-1.8.0_511_linux-x64_bin.tar.gz" --java-home "$T/jdk" --force --no-cacerts --run-dir "$T/run"
  cmd_apply >/dev/null 2>"$T/aerr"; printf 'rc=%s\n' "$?" ) >"$T/aout" 2>&1
grep -q 'apply still refuses\|does not waive this\|JVMs run on' "$T/aerr" && ok || bad "apply did not hard-die under a running JVM: $(cat "$T/aerr")"
grep -q '1\.8\.0_471' "$T/jdk/bin/java" && ok || bad "the old JDK java was replaced by apply under a running JVM"

# a rollback under a live JVM is refused too (Ash's root-cause P2): the in-place move is the apply hazard
mkdir -p "$T/oldjdk/bin"; printf '#!/bin/sh\ntrue\n' >"$T/oldjdk/bin/java"; chmod +x "$T/oldjdk/bin/java"
rm -rf "$T/rbrun"; mkdir -p "$T/rbrun"
printf 'in_place=1\nold_jdk=%s\nold_real=%s\nold_jh=%s\nbackup=ok\n' "$T/oldjdk" "$T/jdk" "$T/jdk" >"$T/rbrun/state"
# shellcheck disable=SC2034  # RUN_DIR/TOOL/... are read by the sourced script
( PATH="$T/bin:$PATH"
  . "$T/tree/patching/java-patch/java-patch.sh"
  RUN_DIR="$T/rbrun"; TOOL=java-patch; DRY_RUN=0; ASSUME_YES=1; NO_CACERTS=1; JSON_OUT=0; VERBOSE=0
  OLD_JH="$T/jdk"; OLD_REAL="$T/jdk"
  cmd_rollback >/dev/null 2>"$T/rberr"; printf 'rc=%s\n' "$?" ) >"$T/rbout" 2>&1
grep -q 'rc=0' "$T/rbout" && bad "rollback ran under a live JVM" || ok
grep -q 'JVMs run on' "$T/rberr" && ok || bad "the rollback refusal was not named"
[ -d "$T/oldjdk" ] && [ -d "$T/jdk" ] && ok || bad "rollback moved a JDK under a live JVM"

# a symlinked parent (/u01 -> a data mount) must not read as 'no JVM runs': running_on compares canonical /proc/pid/exe
ln -sfn "$T" "$T/sym"
rm -rf "$T/rbrun2"; mkdir -p "$T/rbrun2"
printf 'in_place=1\nold_jdk=%s\nold_real=%s\nold_jh=%s\nbackup=ok\n' "$T/oldjdk" "$T/sym/jdk" "$T/sym/jdk" >"$T/rbrun2/state"
# shellcheck disable=SC2034  # RUN_DIR/TOOL/... are read by the sourced script
( PATH="$T/bin:$PATH"
  . "$T/tree/patching/java-patch/java-patch.sh"
  RUN_DIR="$T/rbrun2"; TOOL=java-patch; DRY_RUN=0; ASSUME_YES=1; NO_CACERTS=1; JSON_OUT=0; VERBOSE=0
  OLD_JH="$T/sym/jdk"; OLD_REAL="$T/sym/jdk"
  cmd_rollback >/dev/null 2>"$T/rberr2"; printf 'rc=%s\n' "$?" ) >"$T/rbout2" 2>&1
grep -q 'rc=0' "$T/rbout2" && bad "rollback ran under a live JVM through a symlinked parent" || ok
grep -q 'JVMs run on' "$T/rberr2" && ok || bad "the symlinked-parent rollback refusal was not named"
[ -d "$T/jdk" ] && [ -d "$T/oldjdk" ] && ok || bad "rollback moved a JDK under a live JVM through a symlinked parent"

echo "java-patch will-stop gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
