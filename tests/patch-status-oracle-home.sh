#!/usr/bin/env bash
# patch-status-oracle-home.sh - behavioural gate for patching/patch-status/patch-status.sh.
#
# opatch resolves the inventory from $ORACLE_HOME, not from the directory its executable sits in. On a
# host where the oracle user has ORACLE_HOME set (the usual case) every home was read from that one home:
# a WebLogic home other than $ORACLE_HOME showed the exported home's PSU, and the DATAPATCH PENDING
# compare ran against the wrong home. Each opatch call must be scoped to the home it belongs to.
#
# Builds two fake WebLogic homes, each with an opatch stub that - like the real binary - answers for
# $ORACLE_HOME, exports ORACLE_HOME as the first and MW_HOME as the second, runs the real script and
# checks that each row carries its own home's PSU.
#
# Usage: tests/patch-status-oracle-home.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/patching/patch-status/patch-status.sh"
[ -f "$SCRIPT" ] || { echo "patch-status gate: $SCRIPT not found"; exit 2; }

# a short path: the table truncates the home column, and the whole home must stay readable in a row
T="$(cd "$(mktemp -d /tmp/psgate.XXXXXX)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
A="$T/fmwA"; B="$T/fmwB"
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }

# a stub that behaves like opatch: it answers for $ORACLE_HOME, whatever binary was invoked. Both homes
# get the SAME stub, so a row's PSU proves which home opatch was pointed at, not which binary ran.
mk_home() {
  mkdir -p "$1/wlserver" "$1/inventory" "$1/OPatch"
  echo '<component name="WebLogic Server" version="12.2.1.4.0"/>' >"$1/inventory/registry.xml"
  cat >"$1/OPatch/opatch" <<EOF
#!/bin/sh
case "\$1" in
  version) echo "OPatch Version: 13.9.4.2.23" ;;
  lspatches)
    case "\${ORACLE_HOME:-}" in
      $A) echo "11111;WLS PATCH SET UPDATE 12.2.1.4.240415" ;;
      $B) echo "22222;WLS PATCH SET UPDATE 12.2.1.4.250415" ;;
      *)  echo "99999;WLS PATCH SET UPDATE 12.2.1.4.000000" ;;
    esac
    echo; echo "OPatch succeeded." ;;
esac
EOF
  chmod +x "$1/OPatch/opatch"
}
mk_home "$A"
mk_home "$B"

# ORACLE_HOME names the first home; the second is discovered through MW_HOME
OUT="$T/stdout"
( cd "$T" && HOME="$T" ORACLE_HOME="$A" MW_HOME="$B" bash "$SCRIPT" --no-net --quiet ) >"$OUT" 2>"$T/stderr"
rc=$?
[ "$rc" = 0 ] && ok || bad "exit $rc on two readable homes (want 0): $(tail -2 "$T/stderr")"

ra="$(grep 'WebLogic' "$OUT" | grep -F "$A" | head -1)"
rb="$(grep 'WebLogic' "$OUT" | grep -F "$B" | head -1)"
[ -n "$ra" ] && ok || bad "no WebLogic row for $A"
[ -n "$rb" ] && ok || bad "no WebLogic row for $B"
case "$ra" in *'12.2.1.4.240415'*) ok;; *) bad "home A does not carry its own PSU (12.2.1.4.240415): [$ra]";; esac
case "$rb" in *'12.2.1.4.250415'*) ok;; *) bad "home B carries the wrong PSU, not its own (12.2.1.4.250415): [$rb]";; esac

echo "patch-status oracle-home gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
