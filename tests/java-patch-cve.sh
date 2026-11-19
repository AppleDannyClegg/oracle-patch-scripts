#!/usr/bin/env bash
# java-patch CVE gate: a JDK that does not fix CVE-2026-91403 / CVE-2026-114820 (the eMudhra CA distrust) is never
# switched in. The proof is in the files the JVM reads, not a version number (Oracle's first fix had the blocklist
# and still shipped the roots):
#   - its own blacklisted.certs (8) / blocked.certs (11+) holds all 16 compromised intermediates as UPPERCASE keys;
#   - its cacerts holds none of the four distrusted roots, nor the 16, BY FINGERPRINT, under any alias.
# preflight checks the tarball, apply checks the staged tree it is about to switch in, verify checks the result;
# --no-cve-check passes with a warning; an unreadable cacerts or a missing list is refused; the CA carry-over never
# imports a distrusted certificate back, by alias name or by fingerprint.
#
# Usage: tests/java-patch-cve.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/patching/java-patch/java-patch.sh"
BL="$ROOT/patching/java-patch/blocklist"
[ -f "$SCRIPT" ] && [ -f "$BL/emudhra-16.sha256" ] && [ -f "$BL/emudhra-roots.sha256" ] || { echo "java-patch-cve gate: script or lists not found under $ROOT"; exit 2; }

T="$(cd "$(mktemp -d /tmp/jpcve.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

mkdir -p "$T/tree/patching/java-patch" "$T/base" "$T/run"; ln -s "$ROOT/lib" "$T/tree/lib"
ln -s "$BL" "$T/tree/patching/java-patch/blocklist"
sed '$d' "$SCRIPT" >"$T/tree/patching/java-patch/java-patch.sh"
FPS="$(grep -E '^[0-9A-F]{64}$' "$BL/emudhra-16.sha256")"
AAA="$(grep -E '^[0-9A-F]{64}$' "$BL/emudhra-roots.sha256" | sed -n 2p)"   # AAA Certificate Services
OK1=1111111111111111111111111111111111111111111111111111111111111111; OK2=2222222222222222222222222222222222222222222222222222222222222222

# A fake keytool. A "keystore" is lines 'alias|SHA256'. -list [-v] lists it (exit 1 if the file is 'UNREADABLE');
# -exportcert -alias A writes A's SHA256 as the "certificate"; -printcert -file F prints F's SHA256 colon-separated;
# -importcert -alias A records A in $IMPORTS.
mkdir -p "$T/kt/bin"
cat >"$T/kt/bin/keytool" <<'EOF'
#!/bin/sh
ks=""; al=""; file=""; prev=""; mode=""
for x in "$@"; do
  case "$prev" in -keystore) ks="$x";; -alias) al="$x";; -file) file="$x";; esac
  case "$x" in -list|-exportcert|-printcert|-importcert) mode="$x";; esac
  prev="$x"
done
colon() { printf '%s' "$1" | sed 's/\(..\)/\1:/g; s/:$//'; }
case "$mode" in
  -list) [ "$(head -1 "$ks")" = EMPTY ] && exit 0
         [ "$(head -1 "$ks")" = UNREADABLE ] && { echo "keytool error: Keystore was tampered with, or password was incorrect" >&2; exit 1; }
         case " $* " in *" -v "*) while IFS='|' read -r a f; do printf 'Alias name: %s\nEntry type: trustedCertEntry\nCertificate fingerprints:\n\t SHA1: 00\n\t SHA256: %s\n' "$a" "$(colon "$f")"; done <"$ks";;
                        *) while IFS='|' read -r a f; do printf '%s, 2024-01-01, trustedCertEntry,\n' "$a"; done <"$ks";; esac;;
  -exportcert) grep "^$al|" "$ks" | head -1 | grep -q '|EXPORTFAIL$' && { echo '-----BEGIN CERTIFICATE-----'; exit 9; }
               grep "^$al|" "$ks" | head -1 | cut -d'|' -f2;;
  -printcert) [ "$(head -1 "$file")" = NOPRINT ] && { echo "keytool error: java.lang.Exception: Failed to parse input" >&2; exit 1; }
              printf 'Owner: CN=x\nCertificate fingerprints:\n\t SHA256: %s\n' "$(colon "$(head -1 "$file")")";;
  -importcert) printf '%s\n' "$al" >>"$IMPORTS";;
esac
exit 0
EOF
chmod +x "$T/kt/bin/keytool"; : >"$T/kt/bin/java"; chmod +x "$T/kt/bin/java"
export IMPORTS="$T/imports"

# mk <name> <top> <blocklist path or ''> <blocklist body> <cacerts lines or ''> [dot]: a fake JDK tarball
mk() {
  local src="$T/src-$1"; rm -rf "$src"; mkdir -p "$src/$2/bin" "$src/$2/lib/security"
  : >"$src/$2/bin/java"; chmod +x "$src/$2/bin/java"; printf 'JAVA_VERSION="17.0.21.1"\n' >"$src/$2/release"
  [ -n "$3" ] && { mkdir -p "$(dirname "$src/$2/$3")"; printf 'Algorithm=SHA-256\n%s\n' "$4" >"$src/$2/$3"; }
  local cdir="lib/security"; case "$3" in jre/*) cdir="jre/lib/security"; mkdir -p "$src/$2/$cdir";; esac
  [ -n "$5" ] && printf '%s\n' "$5" >"$src/$2/$cdir/cacerts"
  if [ "${6:-}" = dot ]; then ( cd "$src" && tar -czf "$T/$1.tar.gz" ./"$2" ); else ( cd "$src" && tar -czf "$T/$1.tar.gz" "$2" ); fi
}
# in_script <cmds>: run inside the sourced script with quiet stubs and the fake keytool as the old JDK's
in_script() {
  # shellcheck disable=SC2034  # read by the sourced script
  ( . "$T/tree/patching/java-patch/java-patch.sh"
    state_set() { :; }; log() { echo "LOG $*"; }; warn() { echo "WARN $*"; }; err() { echo "ERR $*"; }
    OLD_JH="$T/kt"; RUN_DIR="$T/run"; LOG_FILE="$T/log"; JAVA_BASE="$T/base"; NO_CVE_CHECK="${NOCVE:-0}"; CACERTS_PASSWORD=x
    eval "$1" ) >"$T/out" 2>&1
}
check() { in_script "ARGS=('$1'); TARBALL=''; pick_tar >/dev/null 2>&1; cve_check_tar"; }
CLEAN="$(printf 'corp-ca|%s\nother|%s' "$OK1" "$OK2")"
FIRSTFIX="$(printf 'corp-ca|%s\nrenamed-root|%s' "$OK1" "$AAA")"

# ---- the tarball (preflight) -----------------------------------------------------------------------------
mk j17 jdk-17.0.21.1 lib/security/blocked.certs "$FPS" "$CLEAN"
check "$T/j17.tar.gz"; [ $? = 0 ] && grep -q 'carries the fix' "$T/out" && ok || bad "Java 17, fixed: refused: $(cat "$T/out")"
mk j8 jdk1.8.0_513 jre/lib/security/blacklisted.certs "$FPS" "$CLEAN"
check "$T/j8.tar.gz"; [ $? = 0 ] && ok || bad "Java 8, fixed: refused: $(cat "$T/out")"
mk dot jdk-17.0.22 lib/security/blocked.certs "$FPS" "$CLEAN" dot
check "$T/dot.tar.gz"; [ $? = 0 ] && ok || bad "a ./-prefixed fixed tarball refused: $(cat "$T/out")"

mk first jdk-17.0.21.0.2 lib/security/blocked.certs "$FPS" "$FIRSTFIX"
check "$T/first.tar.gz"; [ $? = 1 ] && grep -q 'still trusts 1 ' "$T/out" && ok || bad "the first fix (16 blocked, AAA root kept under another alias) not refused: $(cat "$T/out")"
mk short jdk-17.0.21.0.1 lib/security/blocked.certs "$(printf '%s\n' "$FPS" | sed 1d)" "$CLEAN"
check "$T/short.tar.gz"; [ $? = 1 ] && grep -q 'blocks 15 of the 16' "$T/out" && ok || bad "15 of 16 not refused: $(cat "$T/out")"
mk lower jdk-17.0.21.0.9 lib/security/blocked.certs "$(printf '%s\n' "$FPS" | tr 'A-F' 'a-f')" "$CLEAN"
check "$T/lower.tar.gz"; [ $? = 1 ] && grep -q 'blocks 0 of the 16' "$T/out" && ok || bad "a lowercase blocklist not refused: $(cat "$T/out")"
mk none jdk-17.0.19 '' '' "$CLEAN"
check "$T/none.tar.gz"; [ $? = 1 ] && grep -q 'no blacklisted.certs' "$T/out" && ok || bad "no blocklist not refused: $(cat "$T/out")"
mk unread jdk-17.0.21.5 lib/security/blocked.certs "$FPS" "UNREADABLE"
check "$T/unread.tar.gz"; [ $? = 1 ] && grep -q 'NOT known' "$T/out" && ok || bad "an unreadable cacerts passed: $(cat "$T/out")"
mk empty jdk-17.0.21.7 lib/security/blocked.certs "$FPS" "EMPTY"
check "$T/empty.tar.gz"; [ $? = 1 ] && grep -q 'listed no certificate fingerprints' "$T/out" && ok || bad "a cacerts that lists no fingerprints passed as clean: $(cat "$T/out")"
mk nocacerts jdk-17.0.21.6 lib/security/blocked.certs "$FPS" ''
check "$T/nocacerts.tar.gz"; [ $? = 1 ] && grep -q 'no cacerts' "$T/out" && ok || bad "a JDK with no cacerts passed: $(cat "$T/out")"

NOCVE=1 check "$T/first.tar.gz"; [ $? = 0 ] && grep -q '^WARN .*does NOT carry' "$T/out" && ok || bad "--no-cve-check did not pass the first fix with a warning: $(cat "$T/out")"

# ---- the staged tree (apply) and the installed tree (verify) ----------------------------------------------
st="$T/staged/jdk-17.0.21.0.2"; mkdir -p "$st/lib/security"; printf 'Algorithm=SHA-256\n%s\n' "$FPS" >"$st/lib/security/blocked.certs"
printf '%s\n' "$FIRSTFIX" >"$st/lib/security/cacerts"
in_script "cve_tree_check '$st' '$T/kt/bin/keytool'"; [ $? = 1 ] && ok || bad "a staged first-fix tree passed cve_tree_check: $(cat "$T/out")"
printf '%s\n' "$CLEAN" >"$st/lib/security/cacerts"
in_script "cve_tree_check '$st' '$T/kt/bin/keytool'"; [ $? = 0 ] && ok || bad "a staged fixed tree refused: $(cat "$T/out")"

# ---- the CA carry-over: a distrusted certificate is never imported back, by name or by fingerprint -------
printf 'corp-ca|%s\nrenamed-root|%s\ncomodoaaaca|%s\nemsignrootcag1 [jdk]|%s\n' "$OK1" "$AAA" "$AAA" "$OK2" >"$T/old.ks"
printf 'other|%s\n' "$OK2" >"$T/new.ks"; : >"$IMPORTS"
in_script "carry_cacerts '$T/kt' '$T/kt' '$T/old.ks' '$T/new.ks' '$T/pw'"; rc=$?
[ $rc = 0 ] && [ "$(sort "$IMPORTS")" = "corp-ca" ] && ok || bad "carry-over imported [$(tr '\n' '|' <"$IMPORTS")] rc=$rc, want only corp-ca: $(cat "$T/out")"
grep -q 'renamed-root not carried - its certificate is distrusted' "$T/out" && ok || bad "the fingerprint skip is not named: $(cat "$T/out")"

# a certificate whose fingerprint cannot be read is NOT imported (fail closed), and the carry reports it
printf 'corp-ca|%s\nodd-ca|NOPRINT\n' "$OK1" >"$T/old.ks"; printf 'other|%s\n' "$OK2" >"$T/new.ks"; : >"$IMPORTS"
in_script "carry_cacerts '$T/kt' '$T/kt' '$T/old.ks' '$T/new.ks' '$T/pw'"; rc=$?
[ $rc != 0 ] && ! grep -qx 'odd-ca' "$IMPORTS" && grep -q 'odd-ca NOT carried over - its fingerprint could not be read' "$T/out" && ok || bad "an unreadable fingerprint was imported or not reported: rc=$rc imports [$(tr '\n' '|' <"$IMPORTS")]: $(cat "$T/out")"

# an export that fails but leaves bytes is NOT imported; the carry reports it
printf 'corp-ca|%s\nhalf-ca|EXPORTFAIL\n' "$OK1" >"$T/old.ks"; printf 'other|%s\n' "$OK2" >"$T/new.ks"; : >"$IMPORTS"
in_script "carry_cacerts '$T/kt' '$T/kt' '$T/old.ks' '$T/new.ks' '$T/pw'"; rc=$?
[ $rc != 0 ] && ! grep -qx 'half-ca' "$IMPORTS" && grep -q 'half-ca NOT carried over - keytool could not export' "$T/out" && ok || bad "a failed export was imported or not reported: rc=$rc imports [$(tr '\n' '|' <"$IMPORTS")]: $(cat "$T/out")"

# the four alias spellings, and only those
got="$( . "$T/tree/patching/java-patch/java-patch.sh" 2>/dev/null; printf '%s\n' 'emsigneccrootcag3' 'EmSignRootCAG1' 'emsignrootcag2 [jdk]' 'comodoaaaca' 'corp-root-ca' 'comodoaaaca-old' 'myemsignrootcag1' | cve_distrusted_aliases | tr '\n' ',')"
[ "$got" = "emsigneccrootcag3,EmSignRootCAG1,emsignrootcag2 [jdk],comodoaaaca," ] && ok || bad "distrusted aliases matched '$got'"

# a missing list (a single script copied) is refused, not read as zero-of-zero
rm "$T/tree/patching/java-patch/blocklist"
check "$T/j17.tar.gz"; [ $? = 1 ] && grep -q 'is missing' "$T/out" && ok || bad "a missing fingerprint list not refused: $(cat "$T/out")"

# ---- wired in: preflight fails on it, apply dies on it before the switch, verify fails on it ---------------
body() { sed -n "/^$1() *{/,/^}/p" "$SCRIPT"; }
body cmd_preflight | grep -q 'cve_check_tar || fail=1' && ok || bad "cmd_preflight does not fail on cve_check_tar"
a="$(body cmd_apply)"; ln_c="$(printf '%s\n' "$a" | grep -n 'cve_tree_check' | head -1 | cut -d: -f1)"; ln_s="$(printf '%s\n' "$a" | grep -n 'carry_cacerts\|mv "\$OLD_JH"\|ln -sfn' | head -1 | cut -d: -f1)"
[ -n "$ln_c" ] && [ -n "$ln_s" ] && [ "$ln_c" -lt "$ln_s" ] && printf '%s\n' "$a" | grep -q 'cve_tree_check .*|| die' && ok || bad "cmd_apply does not die on cve_tree_check before the carry-over/switch (check line ${ln_c:-none}, switch ${ln_s:-none})"
# apply re-checks the FINAL tree after the last write to cacerts (the carry-over), before the switch
lc="$(printf '%s\n' "$a" | grep -n 'carry_cacerts' | head -1 | cut -d: -f1)"; lf="$(printf '%s\n' "$a" | grep -n 'cve_tree_check' | sed -n 2p | cut -d: -f1)"; lsw="$(printf '%s\n' "$a" | grep -n 'mv "\$OLD_JH"\|ln -sfn\|swap\|switch_' | grep -v '^ *#' | head -1 | cut -d: -f1)"
[ -n "$lc" ] && [ -n "$lf" ] && [ "$lf" -gt "$lc" ] && { [ -z "$lsw" ] || [ "$lf" -lt "$lsw" ]; } && ok || bad "cmd_apply does not re-check the final tree after carry_cacerts and before the switch (carry ${lc:-none}, check ${lf:-none}, switch ${lsw:-none})"
body cmd_verify | grep -q 'cve_tree_check .*|| fail=1' && ok || bad "cmd_verify does not fail on cve_tree_check"

echo "java-patch-cve: $pass passed, $fail failed"
[ "$fail" = 0 ]
