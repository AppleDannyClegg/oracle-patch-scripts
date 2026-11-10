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
    [ -f "$(dirname "$0")/fail" ] && { echo "opatch failed: PRKC-1044 cannot reach the inventory" >&2; exit 28; }
    [ -f "$(dirname "$0")/none" ] && { echo "There are no Interim patches installed in this Oracle Home."; echo; echo "OPatch succeeded."; exit 0; }
    echo "38102345;WLS PATCH SET UPDATE 12.2.1.4.260514"
    echo "37984123;Coherence 12.2.1.4 Cumulative Patch 30 (12.2.1.4.30)"
    echo "36946553; FMW PLATFORM BUNDLE PATCH 12.2.1.4.240812"
    echo "39426213;WLS STACK PATCH BUNDLE 12.2.1.4.260522 (Patch 39426129)"
    echo "38887908;RDA release 26.2-2026421 for OFM 12.2.1.4 SPB"
    echo "38000001;ADF BUNDLE PATCH 12.2.1.4.260514"
    echo "38000006;ADF BUNDLE PATCH 12.2.1.4.0.270101"
    echo "38000005;JDBC19.30 BUNDLE PATCH 12.2.1.4.260216"
    echo "38000008;JDBC19.31 BUNDLE PATCH 12.2.1.4.270101"
    echo "39024181;OSS 19C BUNDLE PATCH 12.2.1.4.260228"
    echo "39024182;OSS 19D BUNDLE PATCH 12.2.1.4.261101"
    echo "38000002;OPSS BUNDLE PATCH 12.2.1.4.260514"
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
# O: a standalone Oracle HTTP Server home - ohs/ and oracle_common/, no wlserver/; its release is in registry.xml
O="$T/ohs/fmw"
mkdir -p "$O/ohs/bin" "$O/oracle_common" "$O/inventory"
echo '<distribution status="installed" name="Oracle HTTP Server (Standalone)" version="12.2.1.4.0"/>' >"$O/inventory/registry.xml"
# its Database Client is 12c (oracle.rdbms.rsf in comps.xml, the KB585169 check), as on Gen's home
mkdir -p "$O/inventory/ContentsXML"
printf '<PRD_LIST>\n<COMP NAME="oracle.ohs2" VER="12.2.1.4.0"/>\n<COMP NAME="oracle.rdbms.rsf" VER="12.1.0.2.0" BUILD_NUMBER="0"/>\n</PRD_LIST>\n' >"$O/inventory/ContentsXML/comps.xml"
# the collocated shape: OHS installed into the WebLogic home itself
mkdir -p "$H/ohs/bin"
echo '<component name="WebLogic Server" version="12.2.1.4.0"/><component name="Oracle Coherence" version="12.2.1.4.0"/><distribution status="installed" name="Oracle HTTP Server (Collocated)" version="12.2.1.4.0"/>' >"$H/inventory/registry.xml"
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
<HOME NAME="OraOhsHome1" LOC="$O" TYPE="O" IDX="6"/>
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
mk_opatch "$O" 13.9.4.2.23 "38000222;OHS (NATIVE) BUNDLE PATCH 12.2.1.4.260501"
chmod +x "$C/bin/sqlplus" "$C2/bin/sqlplus"
export ORAINST_LOC="$T/oraInst.loc"

OUT="$T/manifest.txt"
# no config from the real host, no real Oracle homes: ORACLE_HOME points at the fake one
# env -u PATCH_BASE: the default patch_base| check below must not read the tester's own exported PATCH_BASE
( cd "$T" && env -u PATCH_BASE HOME="$T" ORACLE_HOME="$H" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$OUT" ) >"$T/run.log" 2>&1
rc=$?
[ "$rc" = 0 ] && ok || bad "exit $rc on a readable host (want 0): $(tail -3 "$T/run.log")"
if [ -f "$OUT" ]; then
  has "$OUT" "wls|$H|12.2.1.4.0|13.9.4.2.23|yes"
  has "$OUT" "patch|$H|38102345|WLS PATCH SET UPDATE 12.2.1.4.260514"
  has "$OUT" "patch|$H|37984123|Coherence 12.2.1.4 Cumulative Patch 30 (12.2.1.4.30)"
  has "$OUT" "patch|$H|36946553|FMW PLATFORM BUNDLE PATCH 12.2.1.4.240812"
  has "$OUT" "jdk|$T/jdk|1.8.0_471|8"
  # FMW product bundles: family derived from the real lspatches description, not a hard-coded list
  has "$OUT" "fmw|$H|ADF|12.2.1.4.0.270101|38000006"
  has "$OUT" "fmw|$H|OPSS|12.2.1.4.260514|38000002"
  grep -q "^fmw|$H|OWSM|" "$OUT" && bad "FMW: emitted a family that is not installed (OWSM)" || ok
  grep -q "^fmw|$H|FMW PLATFORM|" "$OUT" && bad "FMW: emitted FMW PLATFORM, which Get-WlsPlan already plans" || ok
  # a bundle-shaped line that does not fit '<FAMILY> BUNDLE PATCH' must surface as OTHER, not vanish
  grep -q "^fmw|$H|OTHER|WLS STACK PATCH BUNDLE 12.2.1.4.260522" "$OUT" && ok || bad "FMW: the WLS STACK PATCH BUNDLE was dropped silently"
  grep -q "^fmw|$H|OTHER|RDA release 26.2-2026421 for OFM 12.2.1.4 SPB|" "$OUT" && ok || bad "FMW: the RDA SPB line was dropped silently"
  # a versioned family token is emitted as-is; the consumer normalises it (a850512). Two JDBC versions are one family (P3c)
  has "$OUT" "fmw|$H|JDBC19.31|12.2.1.4.270101|38000008"
  [ "$(grep -c "^fmw|$H|JDBC" "$OUT")" = 1 ] && ok || bad "FMW: two JDBC versions gave more than one fmw| line"
  # a letter-suffixed version collapses too ('OSS 19C'/'OSS 19D' -> one 'OSS' family, newest) (GERTY P3)
  [ "$(grep -c "^fmw|$H|OSS" "$OUT")" = 1 ] && ok || bad "FMW: two letter-suffixed OSS versions gave more than one fmw| line"
  has "$OUT" "fmw|$H|OSS 19D|12.2.1.4.261101|39024182"
  # two patches of the same family: one line, the newest by yymmdd, across 4-part and 5-part shapes (P3b)
  [ "$(grep -c "^fmw|$H|ADF|" "$OUT")" = 1 ] && ok || bad "FMW: two ADF patches gave more than one fmw| line"
  grep -q "^fmw|$H|ADF|12.2.1.4.260514" "$OUT" && bad "FMW: kept the older ADF line instead of the newer 5-part one" || ok
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
  # OHS: a standalone home is kind ohs with its release, never 'other'; a collocated one gets an ohs| line
  # ...with its Database Client level as a 6th field (back-compatible: readers check a minimum count)
  has "$OUT" "home|$O|ohs|12.2.1.4.0|13.9.4.2.23|12.1.0.2.0"
  has "$OUT" "patch|$O|38000222|OHS (NATIVE) BUNDLE PATCH 12.2.1.4.260501"
  # the collocated home has no comps.xml: the client field is empty and the run says so
  has "$OUT" "ohs|$H|12.2.1.4.0|"
  grep -q "warning: could not read the Database Client level (oracle.rdbms.rsf) of $H" "$T/run.log" && ok || bad "no warning for an OHS home whose client level is unreadable"
  grep -q "warning: could not read the Database Client level.* of $O" "$T/run.log" && bad "warned although $O's client level was read" || ok
  # db/agent/other homes keep five fields: the client field is OHS-only
  grep -E "^home\|[^|]*\|(db|agent|other)\|[^|]*\|[^|]*\|" "$OUT" && bad "a non-OHS home| line grew a 6th field" || ok
  grep -q "^ohs|$O|" "$OUT" && bad "OHS: the standalone home also got an ohs| line (it is a home|..|ohs line)" || ok
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

# EM-2 / ROY-1: the die on a failed lspatches must carry opatch's own reason, not just 'it failed'
grep -q 'PRKC-1044' "$T/run2.log" && ok || bad "EM-2: the die dropped opatch's stderr (no PRKC-1044 in run2.log)"

# P3 (Baymax): the die path must not leak the stderr temp file. Private TMPDIR so the count is not
# raced by another seat's run (GERTY/Ash/Roy) - the fix must leave ITS OWN tmpdir empty.
P3TMP="$T/p3tmp"; mkdir -p "$P3TMP"
touch "$H/OPatch/fail"
( cd "$T" && HOME="$T" TMPDIR="$P3TMP" ORACLE_HOME="$H" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$T/p3.txt" ) >"$T/p3.log" 2>&1
rm -f "$H/OPatch/fail"
P3LEFT="$(find "$P3TMP" -maxdepth 1 -name 'patch-manifest.*' 2>/dev/null | wc -l | tr -d ' ')"
[ "$P3LEFT" = 0 ] && ok || bad "P3: the die path leaked a patch-manifest.* temp file into its own TMPDIR ($P3LEFT)"

# ---- EM-4: an existing oraInst.loc that yields no readable inventory must stop the run, not silently
#      drop every inventory home and write a WLS-only manifest with exit 0 (Gort's live P2) -------------
E4="$T/em4"; mkdir -p "$E4"; printf 'inventory_loc=%s/missing\n' "$E4" >"$E4/oraInst.loc"
OUT4="$T/em4.txt"
( cd "$T" && HOME="$T" ORAINST_LOC="$E4/oraInst.loc" ORACLE_HOME="$H" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$OUT4" ) >"$T/em4.log" 2>&1
rc=$?
[ "$rc" != 0 ] && ok || bad "EM-4: exit 0 although an existing oraInst.loc has no readable inventory"
[ -f "$OUT4" ] && bad "EM-4: a manifest was written with every inventory home silently dropped" || ok

# ---- PM-8: a REMOVED="T" inventory entry must be skipped, not kill the manifest when its home has OPatch
P8="$T/pm8"; mkdir -p "$P8/live/OPatch" "$P8/dead/OPatch" "$P8/inv/ContentsXML"
mk_opatch "$P8/live" 12.2.0.1.44 "11111;Database Release Update : 19.27.0.0.250415 (11111)"
cat >"$P8/dead/OPatch/opatch" <<'EOF2'
#!/bin/sh
echo "opatch: the inventory is locked (rc 73)" >&2; exit 73
EOF2
chmod +x "$P8/dead/OPatch/opatch"
printf 'inventory_loc=%s\n' "$P8/inv" >"$P8/oraInst.loc"
printf '<HOME_LIST>\n<HOME NAME="dead" LOC="%s" TYPE="O" IDX="1" REMOVED="T"/>\n<HOME NAME="live" LOC="%s" TYPE="O" IDX="2"/>\n</HOME_LIST>\n' "$P8/dead" "$P8/live" >"$P8/inv/ContentsXML/inventory.xml"
OUT8="$T/pm8.txt"
( cd "$T" && HOME="$T" ORAINST_LOC="$P8/oraInst.loc" ORACLE_HOME="$H" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$OUT8" ) >"$T/pm8.log" 2>&1
rc=$?
[ "$rc" = 0 ] && ok || bad "PM-8: exit $rc - a REMOVED home with OPatch killed the manifest"
grep -q "^home|$P8/live|" "$OUT8" && ok || bad "PM-8: the live home was not read"
grep -q "^home|$P8/dead|" "$OUT8" && bad "PM-8: the REMOVED home was still probed" || ok

# ---- PM-7: JAVA_TOOL_OPTIONS makes the JVM print 'Picked up...' first; the jdk line must survive -------
P7="$T/pm7"; mkdir -p "$P7/jdk/bin"
cat >"$P7/jdk/bin/java" <<'EOF2'
#!/bin/sh
[ -n "${JAVA_TOOL_OPTIONS:-}" ] && echo "Picked up JAVA_TOOL_OPTIONS: $JAVA_TOOL_OPTIONS" >&2
echo 'java version "1.8.0_471"' >&2
EOF2
chmod +x "$P7/jdk/bin/java"
OUT7="$T/pm7.txt"
( cd "$T" && HOME="$T" ORAINST_LOC="$T/oraInst.loc" ORACLE_HOME="$H" JAVA_HOME="$P7/jdk" JAVA_TOOL_OPTIONS=-Dfile.encoding=UTF-8 bash "$SCRIPT" --out "$OUT7" ) >"$T/pm7.log" 2>&1
has "$OUT7" "jdk|$P7/jdk|1.8.0_471|8"

# ---- EM-1: a JDK whose java cannot report a version must warn, not vanish silently -------------------
E1="$T/em1"; mkdir -p "$E1/bin"
printf '#!/bin/sh\necho "not a java" >&2\nexit 1\n' >"$E1/bin/java"; chmod +x "$E1/bin/java"
OUTE1="$T/em1.txt"
( cd "$T" && HOME="$T" ORAINST_LOC="$T/oraInst.loc" ORACLE_HOME="$H" JAVA_HOME="$E1" bash "$SCRIPT" --out "$OUTE1" ) >"$T/em1.log" 2>&1
grep -q "warning: could not read the version of $E1" "$T/em1.log" && ok || bad "EM-1: a JDK whose java fails was dropped without a warning"

# ---- A-M1 / ROY-2 / EM-3: an empty release or OPatch read must warn, not emit 'wls|home|||no' silently
AM="$T/am1"; mkdir -p "$AM/wlserver" "$AM/OPatch"
cat >"$AM/OPatch/opatch" <<'EOF2'
#!/bin/sh
case "$1" in version) exit 0;; lspatches) echo "OPatch succeeded.";; esac
EOF2
chmod +x "$AM/OPatch/opatch"
OUTAM="$T/am1.txt"
( cd "$T" && HOME="$T" ORAINST_LOC="$T/oraInst.loc" ORACLE_HOME="$AM" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$OUTAM" ) >"$T/am1.log" 2>&1
grep -q 'warning: could not read the WebLogic release' "$T/am1.log" && ok || bad "A-M1: no warning for an empty WebLogic release read"
grep -q 'warning: could not read the OPatch version' "$T/am1.log" && ok || bad "A-M1: no warning for an empty OPatch version read"

# ---- EM-6: comp_version must read a later matching line and the real VER, not quit early / read REP_VER
echo '<COMP NAME="oracle.rdbms" REP_VER="19.0.0.0.0"/>' >"$T/em6a.xml"
printf '<COMP NAME="oracle.rdbms" REP_VER="19.0.0.0.0"/>\n<COMP NAME="oracle.rdbms" VER="19.27.0.0.0" REP_VER="19.0.0.0.0"/>\n' >"$T/em6.xml"
E6H="$T/em6home/dbhome"; mkdir -p "$E6H/rdbms" "$E6H/OPatch" "$E6H/inventory/ContentsXML"
cp "$T/em6.xml" "$E6H/inventory/ContentsXML/comps.xml"
mk_opatch "$E6H" 12.2.0.1.44 "22222;Database Release Update : 19.27.0.0.250415 (22222)"
E6INV="$T/em6inv"; mkdir -p "$E6INV/ContentsXML"
printf 'inventory_loc=%s\n' "$E6INV" >"$T/em6-oraInst.loc"
printf '<HOME_LIST>\n<HOME NAME="em6" LOC="%s" TYPE="O" IDX="1"/>\n</HOME_LIST>\n' "$E6H" >"$E6INV/ContentsXML/inventory.xml"
OUTE6="$T/em6.txt"
( cd "$T" && HOME="$T" ORAINST_LOC="$T/em6-oraInst.loc" ORACLE_HOME="$H" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$OUTE6" ) >"$T/em6.log" 2>&1
has "$OUTE6" "home|$E6H|db|19.27.0.0.0|12.2.0.1.44"

# ---- GM-3: a failing ps must warn, not silently drop the JDKs of running JVMs ----------------------
GP="$T/gm3/bin"; mkdir -p "$GP"; printf '#!/bin/sh\nexit 1\n' >"$GP/ps"; chmod +x "$GP/ps"
OUTG3="$T/gm3.txt"
( cd "$T" && HOME="$T" PATH="$GP:$PATH" ORAINST_LOC="$T/oraInst.loc" ORACLE_HOME="$H" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$OUTG3" ) >"$T/gm3.log" 2>&1
grep -q 'cannot read the process list' "$T/gm3.log" && ok || bad "GM-3: a failing ps dropped the running JVMs' JDKs without a warning"

# ---- header: plat| and patch_base| for get-patches.ps1, created| with its timezone ----------------
# its own run: earlier cases rewrite $OUT, and env -u keeps the tester's exported PATCH_BASE out of the default
OUTH="$T/header.txt"
( cd "$T" && env -u PATCH_BASE HOME="$T" ORACLE_HOME="$H" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$OUTH" ) >"$T/header.log" 2>&1
grep -qE "^plat\|$(uname -s | tr '[:upper:]' '[:lower:]')\|$(uname -m | tr '[:upper:]' '[:lower:]')$" "$OUTH" && ok || bad "header: no plat|<os>|<arch> line from uname"
has "$OUTH" "patch_base|/u01/patches"
grep -qE '^created\|[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [+-][0-9]{4}$' "$OUTH" && ok || bad "header: created| has no timezone"

# a moved PATCH_BASE is what the manifest names
OUTPB="$T/pb.txt"
( cd "$T" && HOME="$T" PATCH_BASE="$T/pb" ORACLE_HOME="$H" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$OUTPB" ) >"$T/pb.log" 2>&1
has "$OUTPB" "patch_base|$T/pb"
# a trailing slash goes out as given: stripping it is the reader's job, one place
OUTPS="$T/ps.txt"
( cd "$T" && HOME="$T" PATCH_BASE="$T/pb/" ORACLE_HOME="$H" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$OUTPS" ) >"$T/ps.log" 2>&1
has "$OUTPS" "patch_base|$T/pb/"

# a PATCH_BASE that is relative, or carries a '|' that would shift every field, writes no manifest
for pb in "rel/patches" "$T/a|b"; do
  OUTBAD="$T/pbbad.txt"; rm -f "$OUTBAD"
  ( cd "$T" && HOME="$T" PATCH_BASE="$pb" ORACLE_HOME="$H" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$OUTBAD" ) >"$T/pbbad.log" 2>&1
  rc=$?
  [ "$rc" != 0 ] && [ ! -f "$OUTBAD" ] && grep -q 'PATCH_BASE' "$T/pbbad.log" && ok || bad "PATCH_BASE [$pb]: rc $rc, manifest written or no message naming PATCH_BASE"
done

# a failing uname writes no manifest: get-patches must not guess the platform
UP="$T/uname/bin"; mkdir -p "$UP"; printf '#!/bin/sh\nexit 1\n' >"$UP/uname"; chmod +x "$UP/uname"
OUTU="$T/uname.txt"
( cd "$T" && HOME="$T" PATH="$UP:$PATH" ORACLE_HOME="$H" JAVA_HOME="$T/jdk" bash "$SCRIPT" --out "$OUTU" ) >"$T/uname.log" 2>&1
rc=$?
[ "$rc" != 0 ] && [ ! -f "$OUTU" ] && grep -q 'cannot read the platform' "$T/uname.log" && ok || bad "uname failing: rc $rc, manifest written or no 'cannot read the platform'"

echo "patch-manifest gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
