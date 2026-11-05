#!/usr/bin/env bash
# java-patch cacerts gate: the CA aliases in a JDK store can contain spaces ('comodoaaaca [jdk]'), so the
# carry loop must read the old-only list a line at a time, and the vendor's own roots ('... [jdk]') must not
# be carried back. A live 8u471 -> 8u511 run word-split five aliases into ten failed imports and then died.
#
# Usage: tests/java-patch-cacerts.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/patching/java-patch/java-patch.sh"
[ -f "$SCRIPT" ] || { echo "java-patch cacerts gate: $SCRIPT not found"; exit 2; }

T="$(cd "$(mktemp -d /tmp/jpcac.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

mkdir -p "$T/tree/patching/java-patch"; ln -s "$ROOT/lib" "$T/tree/lib"
sed '$d' "$SCRIPT" >"$T/tree/patching/java-patch/java-patch.sh"

# a keytool stub: -list names the store's entries (old and new differ), -exportcert prints a fake cert,
# -importcert records the -alias it was given (so a word-split alias shows up as two lines)
stub() { # <dir> <list lines as one string> <imports log> <import rc>
  mkdir -p "$1/bin"
  cat >"$1/bin/keytool" <<EOF
#!/bin/sh
alias=""; prev=""
for x in "\$@"; do [ "\$prev" = "-alias" ] && alias="\$x"; prev="\$x"; done
case " \$* " in
  *" -list "*) printf '%s\n' "$2" ;;
  *" -exportcert "*) printf -- '-----BEGIN CERTIFICATE-----\nFAKE\n-----END CERTIFICATE-----\n' ;;
  *" -importcert "*) printf '%s\n' "\$alias" >>"$3"; exit $4 ;;
esac
exit 0
EOF
  chmod +x "$1/bin/keytool"
}

OLD="$T/old"; NEW="$T/new"; OLDSTORE="$T/oldstore"; NEWSTORE="$T/newstore"; IMPORTS="$T/imports.log"; LOG="$T/log"
stub "$OLD" "comodoaaaca [jdk], 2024-01-01, trustedCertEntry,
site root ca, 2024-01-01, trustedCertEntry,
shared ca, 2024-01-01, trustedCertEntry," "$IMPORTS" 0
stub "$NEW" "shared ca, 2024-01-01, trustedCertEntry," "$IMPORTS" 0
: >"$IMPORTS"

carry() { # <old-dir> <new-dir> <imports-log> ; prints carry_cacerts' rc
  ( . "$T/tree/patching/java-patch/java-patch.sh"
    OLD_JH="$1"; NEW_JH="$2"; RUN_DIR="$T/run"; LOG_FILE="$LOG"; STATE_FILE="$T/state"; TOOL=t
    CACERTS_PASSWORD=x; mkdir -p "$RUN_DIR"
    carry_cacerts "$1" "$2" "$OLDSTORE" "$NEWSTORE" "$T/pw"; printf 'rc=%s\n' "$?" )
}

# ---- the space alias is carried whole; the [jdk] vendor root is not carried ---------------------------
out="$(carry "$OLD" "$NEW" 2>&1)"; rc="${out##*rc=}"
[ "$rc" = 0 ] && ok || bad "carry_cacerts returned $rc (want 0): $out"
[ "$(cat "$IMPORTS")" = "site root ca" ] && ok || bad "imports were [$(tr '\n' '|' <"$IMPORTS")], want exactly [site root ca] (a space alias split into two, or the [jdk] root carried)"
grep -q "alias comodoaaaca" "$IMPORTS" && bad "the [jdk] vendor root was carried" || ok
grep -q '\[jdk\]' "$LOG" && ok || bad "the [jdk] skip is not named in the output"

# ---- an import failure is reported and non-zero -------------------------------------------------------
: >"$IMPORTS"
stub "$NEW" "shared ca, 2024-01-01, trustedCertEntry," "$IMPORTS" 1
out="$(carry "$OLD" "$NEW" 2>&1)"; rc="${out##*rc=}"
[ "$rc" != 0 ] && ok || bad "a failed import returned rc=$rc (want non-zero)"
printf '%s\n' "$out" | grep -q 'NOT carried over' && ok || bad "a failed import was not named: $out"

echo "java-patch cacerts gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
