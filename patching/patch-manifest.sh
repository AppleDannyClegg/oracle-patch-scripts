#!/usr/bin/env bash
# patch-manifest.sh - what is installed on this host, for a server with no internet. Read-only.
# Writes a small text file. Copy it to a Windows machine that has internet and run get-patches.ps1 there:
# it looks up the newest WebLogic PSU, Coherence patch, FMW Platform Bundle, OPatch and JDK on My Oracle
# Support and downloads the ones this host is behind on.
#
# One file, nothing else needed: copy it to the server and run it as the oracle user.
#
# Usage: patch-manifest.sh [--out FILE]
#   --out FILE   where to write it (default ./patch-manifest-<host>.txt)
#
# WebLogic homes are found from the Oracle inventory, the usual paths, running servers and ORACLE_HOME /
# MW_HOME; every other home with OPatch (database client, EM agent, ...) from the inventory. JDKs from those
# homes, running java processes, JAVA_HOME and the usual paths. ORAINST_LOC points at another oraInst.loc.
#
# Lines (| separated):
#   host|<name>   created|<date>
#   wls|<home>|<release>|<OPatch version>|<coherence installed: yes/no>
#   home|<home>|<kind: db (database or client) / agent (EM agent) / other>|<version, may be empty>|<OPatch version>
#   patch|<home>|<patch number>|<description from opatch lspatches>   (for every home above)
#   jdk|<java home>|<version>|<major>
#
# Exit: 0 written; 1 when any Oracle home's patches could not be read (opatch lspatches failed). Then no
# file is written, so a half-read host never looks up to date.

set -uo pipefail

die() { echo "patch-manifest: $*" >&2; exit 1; }

# ---- discovery ------------------------------------------------------------------------------------------
# every home in the central Oracle inventory, one per line
inventory_homes() {
  local inv d
  for inv in ${ORAINST_LOC:-/etc/oraInst.loc /var/opt/oracle/oraInst.loc}; do
    [ -f "$inv" ] || continue
    d="$(sed -n 's/^inventory_loc=//p' "$inv")"
    sed -n 's/.*<HOME NAME="[^"]*" LOC="\([^"]*\)".*/\1/p' "$d/ContentsXML/inventory.xml" 2>/dev/null
  done
}

# every FMW home on the host, one per line
wls_homes() {
  {
    inventory_homes
    ls -d /u01/app/oracle/product/*/fmw* /u01/app/oracle/middleware* /u01/oracle/* /opt/oracle/* /opt/oracle/product/* "$HOME"/Oracle/Middleware*
    [ -n "${ORACLE_HOME:-}" ] && echo "$ORACLE_HOME"
    [ -n "${MW_HOME:-}" ] && echo "$MW_HOME"
    ps -eo args | grep -oE '[^ ]*/wlserve[r]/' | sed 's#/wlserver/##'
  } 2>/dev/null | while read -r h; do [ -d "$h/wlserver" ] && echo "$h"; done | sort -u
}

wls_version() {
  local v
  v="$(sed -n 's/.*name="WebLogic Server"[^>]*version="\([0-9.]*\)".*/\1/p' "$1/inventory/registry.xml" 2>/dev/null | head -1)"
  [ -n "$v" ] || v="$(sed -n 's/^WLS_PRODUCT_VERSION=//p' "$1/wlserver/.product.properties" 2>/dev/null)"
  printf '%s' "$v"
}

wls_java_home() {
  local j
  j="$(sed -n 's/^JAVA_HOME=//p' "$1/oui/.globalEnv.properties" 2>/dev/null | head -1)"
  [ -x "$j/bin/java" ] || j="$(grep -E '^\s*JAVA_HOME=' "$1/oracle_common/common/bin/commEnv.sh" 2>/dev/null | head -1 | sed 's/.*JAVA_HOME=//; s/"//g')"
  [ -x "$j/bin/java" ] && printf '%s' "$j"
}

# every JDK referenced by something on the host, one per line, symlinks resolved
java_homes() {
  {
    local h c
    for h in $(wls_homes); do wls_java_home "$h"; echo; done
    ps -eo args | awk '$1 ~ /\/bin\/java$/ {print $1}' | sed 's#/bin/java$##'
    [ -n "${JAVA_HOME:-}" ] && echo "$JAVA_HOME"
    ls -d /usr/java/jdk* /usr/java/latest /usr/lib/jvm/* /opt/java/* /u01/app/oracle/jdk* /u01/jdk*
    c="$(command -v java)"
    [ -n "$c" ] && dirname "$(dirname "$(readlink -f "$c")")"
  } 2>/dev/null | while read -r j; do [ -x "$j/bin/java" ] && (readlink -f "$j" 2>/dev/null || echo "$j"); done | sort -u
}

java_version_of() { "$1/bin/java" -version 2>&1 | head -1 | sed -n 's/.*version "\([^"]*\)".*/\1/p'; }

# 1.8.0_471 -> 8, 17.0.13 -> 17
java_major_of() {
  local v j
  v="$(java_version_of "$1")"
  j="${v%%.*}"
  if [ "$j" = 1 ]; then j="${v#1.}"; j="${j%%.*}"; fi
  printf '%s' "$j"
}

# run with a time limit when timeout(1) is there (opatch can hang on a locked inventory)
with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout -k 5 "$secs" "$@"; else "$@"; fi
}

# what a non-WebLogic home is and its version
home_kind() {
  # an EM agent home ships an rdbms/ directory too, so its own marks are tested before the db arm: read as
  # a db home it is planned as a database and its version column comes out empty (the wl2 agent line)
  if [ -d "$1/sysman" ] || [[ "$1" == */agent/agent_* ]]; then echo agent
  elif [ -x "$1/bin/sqlplus" ] || [ -d "$1/rdbms" ]; then echo db
  else echo other; fi
}
# version of an installed component from a home's own inventory; the last resort when nothing else reads it
comp_version() {
  local h="$1" name
  for name in oracle.rdbms oracle.sqlplus oracle.client; do
    sed -n "/NAME=\"$name\"/{s/.*VER=\"\([0-9][0-9.]*\)\".*/\1/p;q;}" "$h/inventory/ContentsXML/comps.xml" 2>/dev/null
  done | head -1
}

# a version-looking path component: .../product/19.0.0.0 or .../product/19.0.0/dbhome_1
version_in_path() {
  local p
  for p in "$(basename "$1")" "$(basename "$(dirname "$1")")"; do
    printf '%s' "$p" | grep -qE '^[0-9]+(\.[0-9]+)+$' && { printf '%s' "$p"; return; }
  done
}

home_version() {
  local h="$1" kind="$2" v
  case "$kind" in
    db)
      # sqlplus -V needs the home's lib on the loader path, and prints nothing at all when it cannot
      # start (a client home is often read this way): try it plain, then with LD_LIBRARY_PATH, then
      # read the version out of the home's inventory, then off the install path
      v="$(with_timeout 30 "$h/bin/sqlplus" -V 2>/dev/null | sed -n 's/^Version \([0-9.]*\).*/\1/p' | head -1)"
      [ -n "$v" ] || v="$(ORACLE_HOME="$h" LD_LIBRARY_PATH="$h/lib:${LD_LIBRARY_PATH:-}" with_timeout 30 "$h/bin/sqlplus" -V 2>/dev/null | sed -n 's/^Version \([0-9.]*\).*/\1/p' | head -1)"
      [ -n "$v" ] || v="$(comp_version "$h")"
      [ -n "$v" ] || v="$(version_in_path "$h")"
      printf '%s' "$v" ;;
    agent) basename "$h" | grep -oE '[0-9]+(\.[0-9]+)+' | head -1 ;;
  esac
}

# patch lines for one home from its lspatches output
patch_lines() {
  local h="$1" lsp="$2" id desc
  # a home with no patches applied lists none: grep finding nothing is not a failure
  printf '%s\n' "$lsp" | tr -d '\r' | { grep -E '^[0-9]+;' || true; } | while IFS=';' read -r id desc; do
    desc="${desc#"${desc%%[! ]*}"}"   # opatch can leave a space after the ;
    printf 'patch|%s|%s|%s\n' "$h" "$id" "$desc"
  done
}

# ---- manifest -------------------------------------------------------------------------------------------
# one wls line and its patch lines per WebLogic home
wls_lines() {
  local h release opatch lsp coherence
  for h in $(wls_homes); do
    [ -x "$h/OPatch/opatch" ] || continue
    release="$(wls_version "$h")"
    # opatch acts on $ORACLE_HOME, not on the directory its executable sits in: scope it to this home or
    # every home reports the calling home's OPatch and patches
    opatch="$(ORACLE_HOME="$h" "$h/OPatch/opatch" version 2>/dev/null | sed -n 's/^OPatch Version: *//p')"
    lsp="$(ORACLE_HOME="$h" with_timeout 180 "$h/OPatch/opatch" lspatches 2>/dev/null)" || die "opatch lspatches failed in $h - run it by hand. No manifest written."
    coherence=no
    grep -qi 'coherence' "$h/inventory/registry.xml" 2>/dev/null && coherence=yes
    printf 'wls|%s|%s|%s|%s\n' "$h" "$release" "$opatch" "$coherence"
    patch_lines "$h" "$lsp"
  done
}

# a home line and its patch lines for every other inventory home that has OPatch
other_lines() {
  local h kind opatch lsp wls version
  wls="$(wls_homes)"
  for h in $(inventory_homes | sort -u); do
    [ -x "$h/OPatch/opatch" ] || continue
    printf '%s\n' "$wls" | grep -qxF "$h" && continue
    kind="$(home_kind "$h")"
    opatch="$(ORACLE_HOME="$h" "$h/OPatch/opatch" version 2>/dev/null | sed -n 's/^OPatch Version: *//p')"
    lsp="$(ORACLE_HOME="$h" with_timeout 180 "$h/OPatch/opatch" lspatches 2>/dev/null)" || die "opatch lspatches failed in $h - run it by hand. No manifest written."
    version="$(home_version "$h" "$kind")"
    # get-patches.ps1 needs the version to pick the right Release Update: say so here, do not leave it silent
    [ -n "$version" ] || [ "$kind" != db ] || echo "patch-manifest: warning: could not read the version of $h - get-patches.ps1 will skip its Release Update" >&2
    printf 'home|%s|%s|%s|%s\n' "$h" "$kind" "$version" "$opatch"
    patch_lines "$h" "$lsp"
  done
}

jdk_lines() {
  local j version
  for j in $(java_homes); do
    version="$(java_version_of "$j")"
    [ -n "$version" ] || continue   # a java that will not say its version is no use for picking a download
    printf 'jdk|%s|%s|%s\n' "$j" "$version" "$(java_major_of "$j")"
  done
}

main() {
  local out_file="" host body others
  while [ $# -gt 0 ]; do
    case "$1" in
      --out) [ $# -ge 2 ] || die "--out needs a file"; out_file="$2"; shift 2;;
      -h|--help|help) sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; exit 0;;
      *) die "Unknown option: $1";;
    esac
  done
  host="$(hostname -s 2>/dev/null || hostname)"
  [ -n "$out_file" ] || out_file="./patch-manifest-$host.txt"

  body="$(wls_lines)" || exit 1
  others="$(other_lines)" || exit 1
  body="$body"$'\n'"$others"$'\n'"$(jdk_lines)"
  printf '%s' "$body" | grep -q . || die "No WebLogic home or JDK found. Set ORACLE_HOME (or JAVA_HOME) and run again."

  {
    echo "# patch-manifest v1 - copy to the Windows machine and run: .\\get-patches.ps1 -Manifest <this file>"
    echo "host|$host"
    echo "created|$(date '+%Y-%m-%d %H:%M')"
    printf '%s\n' "$body" | grep .
  } >"$out_file" || die "Cannot write $out_file"
  echo "wrote $out_file" >&2
  cat "$out_file"
}
main "$@"
