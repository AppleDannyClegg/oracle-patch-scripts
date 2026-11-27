#!/usr/bin/env bash
# Directory options ending in "/" must not build the aside path inside the
# directory being moved. This gate drives apply in dry-run mode with stubs for
# the host side, then asserts the logged aside path is a SIBLING.
set -uo pipefail
# shellcheck disable=SC2016,SC2034  # literal stub text; sourced script reads these globals
cd "$(dirname "$0")/.." || exit 1
SCRIPT=patching/java-patch/java-patch.sh
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/home/bin" "$T/base" "$T/run"
printf '#!/bin/sh\ncase "$1" in -version) echo "java version \\"1.8.0_471\\"" >&2;; esac\n' >"$T/home/bin/java"
chmod +x "$T/home/bin/java"
mkdir -p "$T/tar/jdk/bin"; cp "$T/home/bin/java" "$T/tar/jdk/bin/java"; tar czf "$T/jdk.tar.gz" -C "$T/tar" jdk

# Source the script without its final `main "$@"` so the option parser and
# cmd_apply can be called with the host side stubbed.
mkdir -p "$T/tree/patching/java-patch" "$T/tree/lib"
sed '$d' "$SCRIPT" >"$T/tree/patching/java-patch/java-patch.sh"
cp lib/oracle-lib.sh lib/file-patterns "$T/tree/lib/"
probe() { # <home with or without trailing slash>
  (
    . "$T/tree/patching/java-patch/java-patch.sh" >/dev/null 2>&1 || exit 99
    cd "$T/tree/patching/java-patch" || exit 99
    export OLD_JH="$1" OLD_REAL="${1%/}" LINKED=0 IN_PLACE=1 KEEP_OLD=0
    export JAVA_BASE="$T/base" TARBALL="$T/jdk.tar.gz" DRY_RUN=1 FORCE=1
    export ARGS; ARGS=(); parse_opts --java-home "$1" --run-dir "$T/run" --dry-run --force
    discover() { :; }
    reuse_or_init() { :; }
    state_get() { case "$1" in preflight) echo ok;; backup) echo ok;; *) echo ;; esac; }
    state_set() { :; }
    jdk_version() { echo 1.8.0_471; }
    java_major_of() { echo 8; }
    cmd_backup() { :; }
    cve_tree_check() { :; }
    carry_cacerts() { :; }
    running_on() { :; }
    confirm() { :; }
    cmd_preflight || :
    cmd_apply
  ) >"$T/out" 2>&1
}

probe "$T/home/"
aside="$(grep -oE 'the old JDK is renamed to [^ ]+' "$T/out" | sed 's/.*to //' | head -1)"
[ -n "$aside" ] && ok || bad "dry-run apply with a trailing slash logged no aside path: $(tail -2 "$T/out")"
case "$aside" in
  "$T/home/.old-"*) bad "aside path is INSIDE the home: $aside" ;;
  "$T/home.old-"*) ok ;;
  *) bad "aside path is not a sibling: $aside" ;;
esac
# The preflight in the same run must refuse the shape rather than print an OK.
grep -q 'aside path\|trailing slash\|inside' "$T/out" && ok || bad "preflight did not name the bad aside path: $(tail -2 "$T/out")"

echo "java-patch dir slash gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
