#!/usr/bin/env bash
# java-patch in-place gate: a REAL-directory --java-home (not a symlink) must be replaced in place - the
# path ends up on the new build, the old one is renamed to a sibling, a SEPARATE 'verify' passes, and
# rollback puts the old build back. The dry-run env stages a symlink target, so this is the only
# mechanical cover for the in-place branch.
#
# Usage: tests/java-patch-inplace.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
S="$ROOT/patching/java-patch/java-patch.sh"
[ -f "$S" ] || { echo "java-patch in-place gate: $S not found"; exit 2; }

T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'; else sha256sum "$1" | awk '{print $1}'; fi; }

# a fake JDK whose bin/java answers -version, so jdk_version() works
jdk() { mkdir -p "$1/bin"; printf '#!/bin/sh\necho "openjdk version \\"%s\\" 2024-07-16" >&2\n' "$2" >"$1/bin/java"; chmod +x "$1/bin/java"; }
jdk "$T/java" 1.8.0_471
mkdir -p "$T/src/jdk-1.8.0_511"; jdk "$T/src/jdk-1.8.0_511" 1.8.0_511
printf 'JAVA_VERSION="1.8.0_511"\n' >"$T/src/jdk-1.8.0_511/release"
tar -czf "$T/jdk-1.8.0_511_linux-x64_bin.tar.gz" -C "$T/src" jdk-1.8.0_511
mkdir -p "$T/src/jdk-1.8.0_521"; jdk "$T/src/jdk-1.8.0_521" 1.8.0_521
printf 'JAVA_VERSION="1.8.0_521"\n' >"$T/src/jdk-1.8.0_521/release"
tar -czf "$T/jdk-1.8.0_521_linux-x64_bin.tar.gz" -C "$T/src" jdk-1.8.0_521

R="$T/run"; OUT="$T/out.log"
run() { bash "$S" "$@" --java-home "$T/java" --no-cacerts --run-dir "$R" >>"$OUT" 2>&1; }
ver() { "$T/java/bin/java" -version 2>&1 | head -1; }

# a reference file that names the target: in place the script must not read, copy or restore it
REF="$T/ref.env"; printf 'JAVA_HOME=%s/java\n' "$T" >"$REF"
export EXTRA_REF_FILES="$REF"
ref_sha() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$REF" | awk '{print $1}'; else sha256sum "$REF" | awk '{print $1}'; fi; }
REF_BEFORE="$(ref_sha)"

run preflight "$T/jdk-1.8.0_511_linux-x64_bin.tar.gz" && ok || bad "preflight failed: $(tail -2 "$OUT")"
grep -q '^preflight=ok' "$R/state" 2>/dev/null && ok || bad "preflight verdict not recorded with --run-dir (state: $(cat "$R/state" 2>/dev/null | tr '\n' ' '))"

run apply "$T/jdk-1.8.0_511_linux-x64_bin.tar.gz" --yes && ok || bad "apply failed: $(tail -2 "$OUT")"
[ "$(ver)" = 'openjdk version "1.8.0_511" 2024-07-16' ] && ok || bad "the path does not run the new build (got: $(ver))"
ls -d "$T"/java.old-* >/dev/null 2>&1 && ok || bad "the old JDK was not renamed to a sibling"
grep -q '^new_ver=1.8.0_511' "$R/state" 2>/dev/null && ok || bad "apply did not record new_ver"
# a dry-run apply must leave a real run's state BYTE-IDENTICAL (Gort: push blocker). With no --run-dir it reuses
# 'latest'; point that at this real run and give it a different tarball (1.8.0_521), so a state write is visible.
H="$T/home"; mkdir -p "$H/java-patch/runs"; ln -sfn "$R" "$H/java-patch/runs/latest"
before="$(sha "$R/state")"
HOME="$H" bash "$S" apply "$T/jdk-1.8.0_521_linux-x64_bin.tar.gz" --dry-run --yes --java-home "$T/java" --no-cacerts >>"$OUT" 2>&1
[ "$(sha "$R/state")" = "$before" ] && ok || bad "a no---run-dir dry-run apply changed a real run's state (apply=$(sed -n 's/^apply=//p' "$R/state" | tail -1), new_ver=$(sed -n 's/^new_ver=//p' "$R/state" | tail -1))"

run verify && ok || bad "a separate 'verify --run-dir' failed: $(tail -3 "$OUT")"
# after a real apply, 'verify --dry-run' is read-only but must still check for real (Baymax P3)
bash "$S" verify --dry-run --run-dir "$R" --java-home "$T/java" --no-cacerts >"$T/out-vdry.log" 2>&1 && ok || bad "'verify --dry-run' after a real apply failed: $(tail -2 "$T/out-vdry.log")"
grep -q 'dry-run: would verify' "$T/out-vdry.log" && bad "'verify --dry-run' skipped the read-only checks after a real apply" || ok

# a bare 'rollback --run-dir R' has no --java-home: it must seed OLD_JH from the recorded old_jh
bash "$S" rollback --run-dir "$R" --yes >>"$OUT" 2>&1 && ok || bad "a bare 'rollback --run-dir' failed: $(tail -3 "$OUT")"
[ "$(ver)" = 'openjdk version "1.8.0_471" 2024-07-16' ] && ok || bad "rollback did not restore the old build (got: $(ver))"
[ -e "$T/java/old-jdk" ] && bad "rollback nested the old JDK inside the path" || ok
# the abandoned new build is parked at <path>.failed-<stamp>; the output must name it
ls -d "$T"/java.failed-* >/dev/null 2>&1 && ok || bad "rollback did not park the new build at a .failed-<stamp> sibling"
grep -q 'the new build being rolled back from is at .*\.failed-' "$OUT" && ok || bad "rollback did not name the .failed-<stamp> residue"
# a dry run installed nothing: verify must not assert, and must not drive a rollback
bash "$S" run "$T/jdk-1.8.0_511_linux-x64_bin.tar.gz" --dry-run --yes --java-home "$T/java" --no-cacerts --run-dir "$T/run-dry" >"$T/out-dry.log" 2>&1 && ok || bad "run --dry-run failed: $(tail -3 "$T/out-dry.log")"
grep -q 'dry-run: would verify' "$T/out-dry.log" && ok || bad "run --dry-run did not say it would verify"
grep -q 'Verify FAILED' "$T/out-dry.log" && bad "run --dry-run reported Verify FAILED" || ok
# in place, the reference file is not copied, recorded or restored: it is the human's ask
[ "$(ref_sha)" = "$REF_BEFORE" ] && ok || bad "in place: the reference file was changed"
[ -z "$(ls -A "$R/files" 2>/dev/null)" ] && ok || bad "in place: a reference file was backed up into $R/files"
grep -q '^backed_files=' "$R/state" 2>/dev/null && bad "in place: backed_files was recorded" || ok

# cycle isolation: a bare 'preflight' (no --run-dir) must start a FRESH run dir, not reuse the previous
# cycle's dir through the 'latest' link - a reused 'backup=ok' would skip the next cycle's backup and a
# rollback would restore older files. Seed a previous cycle's dir and point 'latest' at it.
H="$T/home2"; RB="$H/java-patch/runs"; prev="$RB/20260101-000000-run"
mkdir -p "$prev"; printf 'backup=ok\nbacked_files=/u01/x/setDomainEnv.sh\n' >"$prev/state"
ln -sfn "$prev" "$RB/latest"
HOME="$H" bash "$S" preflight "$T/jdk-1.8.0_511_linux-x64_bin.tar.gz" --java-home "$T/java" --no-cacerts >>"$OUT" 2>&1 && ok || bad "no---run-dir preflight failed: $(tail -2 "$OUT")"
grep -q '^preflight=' "$prev/state" && bad "no---run-dir preflight reused the previous cycle's run dir (wrote into latest)" || ok

echo "java-patch in-place gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
