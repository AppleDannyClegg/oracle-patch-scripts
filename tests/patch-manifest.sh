#!/usr/bin/env bash
# patch-manifest.sh - behavioural gate for patching/patch-manifest.sh.
#
# Builds a fake WebLogic home (registry.xml, an opatch stub, .globalEnv.properties) and a fake JDK, runs the
# script against them and checks the manifest lines get-patches.ps1 reads. Also checks that a failing
# `opatch lspatches` writes no manifest and exits non-zero: a half-read host must never look up to date.
# And that a database/client home's version is found even when `sqlplus -V` says nothing: the home's
# inventory, then the install path, then a warning - never a silent empty field.
#
# Usage: tests/patch-manifest.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
SCRIPT="$ROOT/patching/patch-manifest.sh"
[ -f "$SCRIPT" ] || { echo "patch-manifest gate: $SCRIPT not found"; exit 2; }

# physical path: the script resolves JDK symlinks (macOS /var -> /private/var), so compare like with like
T="$(cd "$(mktemp -d)" && pwd -P)"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $*"; }
has() { grep -qxF -- "$2" "$1" && ok || bad "manifest has no line [$2]"; }

# fake JDK 8
mkdir -p "$T/jdk/bin"
cat >"$T/jdk/bin/java" <<'EOF'
#!/bin/sh
echo 'java version "1.8.0_471"' >&2
EOF
chmod +x "$T/jdk/bin/java"

# fake WebLogic 12.2.1.4 home with Coherence
H="$T/fmw"
mkdir -p "$H/wlserver" "$H/inventory" "$H/OPatch" "$H/oui"
echo '<component name="WebLogic Server" version="12.2.1.4.0"/><component name="Oracle Coherence" version="12.2.1.4.0"/>' >"$H/inventory/registry.xml"
echo "JAVA_HOME=$T/jdk" >"$H/oui/.globalEnv.properties"
cat >"$H/OPatch/opatch" <<'EOF'
#!/bin/sh
case "$1" in
  version) echo "OPatch Version: 13.9.4.2.23"; echo; echo "OPatch succeeded." ;;
  lspatches)
    [ -f "$(dirname "$0")/fail" ] && { echo "lspatches broke" >&2; exit 1; }
    [ -f "$(dirname "$0")/none" ] && { echo "There are no Interim patches installed in this Oracle Home."; echo; echo "OPatch succeeded."; exit 0; }
    echo "38102345;WLS PATCH SET UPDATE 12.2.1.4.260514"
    echo "37984123;Coherence 12.2.1.4 Cumulative Patch 30 (12.2.1.4.30)"
    echo "36946553; FMW PLATFORM BUNDLE PATCH 12.2.1.4.240812"
    echo
    echo "OPatch succeeded." ;;
esac
EOF
chmod +x "$H/OPatch/opatch"

# an opatch stub for the non-WebLogic homes: version + one lspatches row
mk_opatch() { # $1 = home, $2 = opatch version, $3 = lspatches line
  mkdir -p "$1/OPatch"
  cat >"$1/OPatch/opatch" <<EOF
#!/bin/sh
case "\$1" in
  version) echo "OPatch Version: $2" ;;
  lspatches) echo "$3"; echo; echo "OPatch succeeded." ;;
esac
EOF
  chmod +x "$1/OPatch/opatch"
}

# a central inventory (ORAINST_LOC stands in for /etc/oraInst.loc) with:
#   C  a 19c client whose sqlplus -V works
#   A  an EM agent
#   C2 a client whose sqlplus -V prints nothing, version only in its inventory
#   C3 a client with no sqlplus at all, version only in the install path
#   C4 a db home with no version anywhere (must warn, not fail)
C="$T/client/19.0.0.0"; A="$T/agent/agent_24.1.0.0.0"
C2="$T/client2/19.0.0.0"; C3="$T/client3/19.0.0.0"; C4="$T/client4/foo"
# an EM agent home ships rdbms/ as well as sysman/: it must still be read as an agent, not a db home (WF-1)
mkdir -p "$T/oraInventory/ContentsXML" "$C/bin" "$A/sysman" "$A/rdbms" "$C2/bin" "$C2/inventory/ContentsXML" "$C3/rdbms" "$C4/rdbms"
printf 'inventory_loc=%s\ninst_group=oinstall\n' "$T/oraInventory" >"$T/oraInst.loc"
cat >"$T/oraInventory/ContentsXML/inventory.xml" <<EOF2
<HOME_LIST>
<HOME NAME="OraClient19Home1" LOC="$C" TYPE="O" IDX="1"/>
<HOME NAME="agent24c1" LOC="$A" TYPE="O" IDX="2"/>
<HOME NAME="OraClient19Home2" LOC="$C2" TYPE="O" IDX="3"/>
<HOME NAME="OraClient19Home3" LOC="$C3" TYPE="O" IDX="4"/>
<HOME NAME="OraDbHome1" LOC="$C4" TYPE="O" IDX="5"/>
</HOME_LIST>
EOF2
cat >"$C/bin/sqlplus" <<'EOF2'
#!/bin/sh
echo; echo "SQL*Plus: Release 19.0.0.0.0 - Production"; echo "Version 19.27.0.0.0"
EOF2
mk_opatch "$C" 12.2.0.1.44 "37642901;Database Release Update : 19.27.0.0.250415 (37642901)"
mk_opatch "$A" 13.9.4.2.20 "38000111;EM-AGENT Patch Set Update 24.1.0.0.250131"
# C2: sqlplus starts but prints nothing (a client home with no LD_LIBRARY_PATH); comps.xml carries the version
cat >"$C2/bin/sqlplus" <<'EOF2'
#!/bin/sh
exit 0
EOF2
echo '<COMP NAME="oracle.sqlplus" VER="19.0.0.0.0" REP_VER="19.0.0.0.0"/>' >"$C2/inventory/ContentsXML/comps.xml"
mk_opatch "$C2" 12.2.0.1.44 "37642901;Database Release Update : 19.27.0.0.250415 (37642901)"
# C3: no sqlplus, no comps.xml - only the path says 19.0.0.0
mk_opatch "$C3" 12.2.0.1.44 "37642901;Database Release Update : 19.27.0.0.250415 (37642901)"
# C4: nothing reads its version
mk_opatch "$C4" 12.2.0.1.44 "37642901;Database Release Update : 19.27.0.0.250415 (37642901)"
chmod +x "$C/bin/sqlplus" "$C2/bin/sqlplus"
export ORAINST_LOC="$T/oraInst.loc"

OUT="$T/manifest.txt"
# no config from the real host, no real Oracle homes: ORACLE_HOME points at the fake one
( cd "$T" && HOME="$T" ORACLE_HOME="$H" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$OUT" ) >"$T/run.log" 2>&1
rc=$?
[ "$rc" = 0 ] && ok || bad "exit $rc on a readable host (want 0): $(tail -3 "$T/run.log")"
if [ -f "$OUT" ]; then
  has "$OUT" "wls|$H|12.2.1.4.0|13.9.4.2.23|yes"
  has "$OUT" "patch|$H|38102345|WLS PATCH SET UPDATE 12.2.1.4.260514"
  has "$OUT" "patch|$H|37984123|Coherence 12.2.1.4 Cumulative Patch 30 (12.2.1.4.30)"
  has "$OUT" "patch|$H|36946553|FMW PLATFORM BUNDLE PATCH 12.2.1.4.240812"
  has "$OUT" "jdk|$T/jdk|1.8.0_471|8"
  grep -q '^host|' "$OUT" && ok || bad "manifest has no host line"
  has "$OUT" "home|$C|db|19.27.0.0.0|12.2.0.1.44"
  has "$OUT" "patch|$C|37642901|Database Release Update : 19.27.0.0.250415 (37642901)"
  has "$OUT" "home|$A|agent|24.1.0.0.0|13.9.4.2.20"
  has "$OUT" "patch|$A|38000111|EM-AGENT Patch Set Update 24.1.0.0.250131"
  has "$OUT" "home|$C2|db|19.0.0.0.0|12.2.0.1.44"
  has "$OUT" "home|$C3|db|19.0.0.0|12.2.0.1.44"
  has "$OUT" "home|$C4|db||12.2.0.1.44"
  grep -q "warning: could not read the version of $C4" "$T/run.log" && ok || bad "no warning for a db home with no readable version"
  grep -q "warning: could not read the version of $C2" "$T/run.log" && bad "warned although C2's version came from its inventory" || ok
  grep -q "^home|$H|" "$OUT" && bad "the WebLogic home is listed twice (wls and home lines)" || ok
  grep -q 'OPatch succeeded' "$OUT" && bad "opatch chatter leaked into the manifest" || ok
else
  bad "no manifest written to $OUT"
fi

# a real client sqlplus only runs with its own ORACLE_HOME set: C's sqlplus now refuses any other
rm -f "$OUT"; mv "$C/bin/sqlplus" "$C/bin/sqlplus.ok"
printf '#!/bin/sh\n[ "$ORACLE_HOME" = "%s" ] && exec "%s" "$@"\necho "SP2-0667: Message file sp1<lang>.msb not found" >&2; exit 1\n' "$C" "$C/bin/sqlplus.ok" >"$C/bin/sqlplus"
chmod +x "$C/bin/sqlplus"
( cd "$T" && HOME="$T" ORACLE_HOME="$H" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$OUT" ) >"$T/run4.log" 2>&1
has "$OUT" "home|$C|db|19.27.0.0.0|12.2.0.1.44"
rm -f "$C/bin/sqlplus"; mv "$C/bin/sqlplus.ok" "$C/bin/sqlplus"

# lspatches fails: no manifest, non-zero exit
rm -f "$OUT"; touch "$H/OPatch/fail"
( cd "$T" && HOME="$T" ORACLE_HOME="$H" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$OUT" ) >"$T/run2.log" 2>&1
rc=$?
[ "$rc" != 0 ] && ok || bad "exit 0 when opatch lspatches failed"
[ -f "$OUT" ] && bad "a manifest was written although opatch lspatches failed" || ok

# a home with no patches applied yet (lspatches lists nothing) still gets a manifest
rm -f "$OUT" "$H/OPatch/fail"; touch "$H/OPatch/none"
( cd "$T" && HOME="$T" ORACLE_HOME="$H" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$OUT" ) >"$T/run3.log" 2>&1
rc=$?
[ "$rc" = 0 ] && ok || bad "exit $rc for a home with no patches (want 0): $(tail -2 "$T/run3.log")"
[ -f "$OUT" ] && grep -q "^wls|$H|" "$OUT" && ok || bad "no wls line for a home with no patches"

# OPatch resolves the inventory from $ORACLE_HOME, not from the directory its executable sits in. The real
# host has ORACLE_HOME set (the header tells you to), so every home must be probed with ORACLE_HOME set to
# itself - otherwise every home reports the calling home's OPatch version and patch list (WF-2).
W="$T/wf2"; mkdir -p "$W/wls/wlserver" "$W/wls/OPatch" "$W/client/bin" "$W/client/OPatch" "$W/inv/ContentsXML"
for h in wls client; do
  cat >"$W/$h/OPatch/opatch" <<'EOF2'
#!/bin/sh
case "$1" in
  version) echo "OPatch Version: 13.9.4.2.23" ;;
  lspatches) echo "77777;PATCH-OWNER=$(basename "${ORACLE_HOME:-unset}")"; echo; echo "OPatch succeeded." ;;
esac
EOF2
  chmod +x "$W/$h/OPatch/opatch"
done
printf '#!/bin/sh\necho "Version 19.27.0.0.0"\n' >"$W/client/bin/sqlplus"; chmod +x "$W/client/bin/sqlplus"
printf 'inventory_loc=%s\ninst_group=oinstall\n' "$W/inv" >"$W/oraInst.loc"
printf '<HOME_LIST>\n<HOME NAME="client" LOC="%s" TYPE="O" IDX="1"/>\n</HOME_LIST>\n' "$W/client" >"$W/inv/ContentsXML/inventory.xml"
OUT2="$T/wf2-manifest.txt"
( cd "$T" && HOME="$T" ORAINST_LOC="$W/oraInst.loc" ORACLE_HOME="$W/wls" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$OUT2" ) >"$T/wf2.log" 2>&1
has "$OUT2" "patch|$W/wls|77777|PATCH-OWNER=wls"
has "$OUT2" "patch|$W/client|77777|PATCH-OWNER=client"

echo "patch-manifest gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
