#!/usr/bin/env bash
# java-patch.sh gate: the tarball picker accepts every JDK naming shape Oracle ships.
#
# java-patch gets its tarball from get-patches, which keeps Oracle's own name: a Java 8 download is
# 'server-jre-8u511-linux-x64.tar.gz', a JDK update is 'jdk-17.0.9_linux-x64_bin.tar.gz', a plain JRE
# is 'jre-8u511-linux-x64.tar.gz'. pick_tar used to glob only 'jdk*', so the server-jre the tool itself
# downloads was rejected with 'no jdk*.tar.gz'. This gate pins all three shapes and the die paths.
#
# Usage: tests/java-patch.sh [repo-root]
#
# The script is sourced with its trailing main call removed (a temp tree whose ../../lib resolves), so the
# gate calls the real pick_tar, not a copy of its glob.

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/patching/java-patch/java-patch.sh"
[ -f "$SCRIPT" ] || { echo "java-patch gate: $SCRIPT not found"; exit 2; }

T="$(cd "$(mktemp -d /tmp/jpgate.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# a temp tree so SCRIPT_DIR's '../../lib/oracle-lib.sh' resolves, with the script minus its 'main "$@"'
mkdir -p "$T/tree/patching/java-patch" "$T/base"
ln -s "$ROOT/lib" "$T/tree/lib"
sed '$d' "$SCRIPT" >"$T/tree/patching/java-patch/java-patch.sh"

mk_java_tar() { # <out-dir> <tar-name> <top> <version>
  local d="$1" name="$2" top="$3" ver="$4"
  local src="$T/src-$name"
  mkdir -p "$d" "$src/$top/bin" "$src/$top/lib"
  : >"$src/$top/bin/java"; chmod +x "$src/$top/bin/java"
  printf 'JAVA_VERSION="%s"\n' "$ver" >"$src/$top/release"
  # many entries after bin/java, the shape of a real JDK tarball
  local i; for i in $(seq 1 120); do : >"$src/$top/lib/f$i.jar"; done
  ( cd "$src" && tar -czf "$d/$name" "$top" )
}

# pick <dir>: prints 'TARBALL|NEW_VER' on success; returns pick_tar's status (die -> non-zero, no output)
pick() {
  # pick_tar's own return status is 1 for any major but 1.x (the trailing '[ "$NEW_MAJOR" = 1 ] && ...'
  # idiom), which the script ignores; a die exits the subshell before the printf. So success = non-empty stdout.
  # shellcheck disable=SC2034  # ARGS/JAVA_BASE are read by the sourced script
  ( . "$T/tree/patching/java-patch/java-patch.sh"; ARGS=("$1"); TARBALL=""; JAVA_BASE="$T/base"
    pick_tar >/dev/null 2>"$T/pick.err"
    printf '%s|%s\n' "$TARBALL" "$NEW_VER" )
}

# ---- the three Oracle naming shapes must all be selected -----------------------------------------------
idx=0
for spec in "server-jre-8u511-linux-x64.tar.gz|jdk1.8.0_511|1.8.0_511" \
            "jre-8u511-linux-x64.tar.gz|jdk1.8.0_511|1.8.0_511" \
            "jdk-17.0.9_linux-x64_bin.tar.gz|jdk-17.0.9|17.0.9"; do
  IFS='|' read -r name top ver <<<"$spec"
  idx=$((idx + 1)); d="$T/one-$idx"
  mk_java_tar "$d" "$name" "$top" "$ver"
  out="$(pick "$d")"
  tar_sel="${out%%|*}"; got_ver="${out#*|}"
  [ -n "$out" ] && ok || bad "pick_tar rejected $name: $(tail -1 "$T/pick.err")"
  [ "$tar_sel" = "$d/$name" ] && ok || bad "pick_tar selected '$tar_sel' for $name, want $d/$name"
  [ "$got_ver" = "$ver" ] && ok || bad "pick_tar read version '$got_ver' from $name, want $ver"
done

# ---- the JDK root is found from bin/java, not the first listing entry ---------------------------------
# A production host, 5 Nov 2026: jdk-8u511-internal-bin-b00-...-debug.tar.gz died 'has no
# jdk1.8.0_511/bin/java' because the JDK is nested (jdk1.8.0_511/jdk1.8.0_511/bin/java), so the first
# entry's root is jdk1.8.0_511 but bin/java is a level below it.
mk_java_tar "$T/nested" 'jdk-8u511-internal-nested.tar.gz' 'jdk1.8.0_511/jdk1.8.0_511' '1.8.0_511'
first="$(tar -tzf "$T/nested/jdk-8u511-internal-nested.tar.gz" | head -1)"
[ "${first%%/*}" = 'jdk1.8.0_511' ] && ok || bad "the nested fixture's first entry is not jdk1.8.0_511/ ('$first')"
out="$(pick "$T/nested")"
got_ver="${out#*|}"
[ -n "$out" ] && ok || bad "pick_tar rejected a nested JDK tarball: $(tail -1 "$T/pick.err")"
[ "$got_ver" = '1.8.0_511' ] && ok || bad "pick_tar read version '$got_ver' from a nested tarball, want 1.8.0_511"

# a tarball made with 'tar -C <dir> .' prefixes every name with './'
mkdir -p "$T/src-dot/jdk1.8.0_511/bin" "$T/src-dot/jdk1.8.0_511/lib"; : >"$T/src-dot/jdk1.8.0_511/bin/java"
printf 'JAVA_VERSION="1.8.0_511"\n' >"$T/src-dot/jdk1.8.0_511/release"
( cd "$T/src-dot" && tar -czf "$T/dot.tar.gz" . )
out="$(pick "$T/dot.tar.gz")"
got_ver="${out#*|}"
[ -n "$out" ] && ok || bad "pick_tar rejected a './'-prefixed JDK tarball: $(tail -1 "$T/pick.err")"
[ "$got_ver" = '1.8.0_511' ] && ok || bad "pick_tar read version '$got_ver' from a './'-prefixed tarball, want 1.8.0_511"

# ---- die paths ---------------------------------------------------------------------------------------
mkdir -p "$T/empty"
out="$(pick "$T/empty")"
[ -z "$out" ] && ok || bad "pick_tar accepted an empty dir (want the 'no JDK tarball' die)"
grep -qi 'no JDK tarball' "$T/pick.err" && ok || bad "an empty dir did not name the 'no JDK tarball' error"

# a jdk-named tar that is not a JDK (no <top>/bin/java) must be refused, not accepted
mkdir -p "$T/src-notjdk/notjdk" "$T/bad"; : >"$T/src-notjdk/notjdk/readme"
( cd "$T/src-notjdk" && tar -czf "$T/bad/jdk-not-a-jdk.tar.gz" notjdk )
out="$(pick "$T/bad")"
[ -z "$out" ] && ok || bad "pick_tar accepted a jdk-named tar with no bin/java"
grep -qi 'not a JDK tarball' "$T/pick.err" && ok || bad "a non-JDK jdk-named tar did not name the 'not a JDK tarball' error"

# ---- the :121 shape: the tarball listing must not be piped into a '-q' consumer -----------------------
# 'tar -tzf | grep -q' (or 'printf | grep -q') ends grep at the match, the producer takes SIGPIPE, and
# pipefail surfaces 141 - a real JDK then dies as 'not a JDK tarball'. This is platform-dependent to
# reproduce (GNU tar yes, macOS bsdtar no), so assert the shape, not the timing.
BODY="$(sed -n '/^pick_tar()/,/^}/p' "$SCRIPT")"
CODE="$(printf '%s\n' "$BODY" | grep -v '^[[:space:]]*#')"
printf '%s' "$CODE" | grep -qE 'grep[[:space:]]+-[A-Za-z]*q' && bad "pick_tar pipes a listing into a 'grep -q' (SIGPIPE/pipefail 141 hazard)" || ok
printf '%s' "$CODE" | grep -qE 'listing=' && ok || bad "pick_tar does not capture the tar listing once"

# ---- a directory holding more than one KIND of JDK tarball must die, not pick the older ----------------
mkdir -p "$T/mixed"
mk_java_tar "$T/mixed" 'jdk-8u481-linux-x64.tar.gz' 'jdk8u481' '1.8.0_481'
mk_java_tar "$T/mixed" 'server-jre-8u471-linux-x64.tar.gz' 'jdk8u471' '1.8.0_471'
out="$(pick "$T/mixed")"
[ -z "$out" ] && ok || bad "pick_tar silently picked '$out' from a mixed jdk/server-jre dir (want a die)"
grep -qi 'more than one kind' "$T/pick.err" && ok || bad "a mixed-kind dir did not name the 'more than one kind' error"

echo "java-patch gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
