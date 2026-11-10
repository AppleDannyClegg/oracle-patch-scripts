#!/usr/bin/env bash
# ohs-quarter-stage gate: a get-patches.ps1 download tree (folders by patch kind) is sorted into the folders
# ohs-quarter.sh reads, by the patch number in each file name - and everything it cannot place is refused before
# a single file moves. No Oracle software, no network: the "patches" are small files with Oracle's names.
#
# Usage: tests/ohs-quarter-stage.sh
set -u
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
S="$REPO/patching/ohs-quarter/ohs-quarter-stage.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/ohs-quarter-stage.XXXXXX")"; trap 'rm -rf "$T"' EXIT
pass=0; fail=0
ok() { if [ "$1" = 0 ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $2"; fi; }
has() { grep -qF -- "$2" "$1"; }
snapshot() { (cd "$1" && find . | LC_ALL=C sort); }

# the October 2026 set, as get-patches.ps1 would file it: by kind, not by runbook step
tree() { # <dir>: a full download
  local d="$1"; mkdir -p "$d/wls" "$d/ohs" "$d/jdk" "$d/dbclient" "$d/db"
  local n
  for n in 39919567 39425385 39114058 39567777 39487427 39465265 39574504 38590502 38098858 38832179; do echo "zip $n" >"$d/wls/p${n}_122140_Generic.zip"; done
  echo "zip 40005842" >"$d/ohs/p40005842_122140_Linux-x86-64.zip"
  echo "zip 34761383" >"$d/dbclient/p34761383_122140_Linux-x86-64.zip"
  echo "tar" >"$d/jdk/jdk-8u511-linux-x64.tar.gz"; echo "jdkzip" >"$d/jdk/p18143322_180511_Linux-x86-64.zip"
  echo "note" >"$d/README.txt"
}

# ---- plan changes nothing and names every destination ----
tree "$T/dl"; before="$(snapshot "$T/dl")"
"$S" plan "$T/dl" "$T/root" >"$T/plan.out" 2>&1; ok $? "plan on a full tree exits 0"
r=0; [ "$(snapshot "$T/dl")" = "$before" ] && [ ! -e "$T/root" ] || r=1; ok $r "plan moves nothing and creates no root"
has "$T/plan.out" "wlspsu/" && has "$T/plan.out" "p39919567_122140_Generic.zip"; ok $? "plan names the WLS PSU's folder"
has "$T/plan.out" "all 13 runbook folders are filled"; ok $? "plan says all 13 folders are filled"
has "$T/plan.out" "jdk/p18143322_180511_Linux-x86-64.zip"; ok $? "plan lists the JDK zip as left, not as an unknown patch"

# ---- run: every file in its runbook folder, the kind folders no longer carry patches ----
"$S" run "$T/dl" "$T/root" >"$T/run.out" 2>&1; ok $? "run on a full tree exits 0"
want="dbclient/p34761383_122140_Linux-x86-64.zip dbclientru/p39425385_122140_Generic.zip fmwthirdparty/p39574504_122140_Generic.zip jdbc/p39487427_122140_Generic.zip jdk/jdk-8u511-linux-x64.tar.gz libdms2/p38098858_122140_Generic.zip libiau/p38832179_122140_Generic.zip libovd/p39465265_122140_Generic.zip ohs/p40005842_122140_Linux-x86-64.zip oss/p39567777_122140_Generic.zip perl/p38590502_122140_Generic.zip webgate/p39114058_122140_Generic.zip wlspsu/p39919567_122140_Generic.zip"
got="$(cd "$T/root" && find . -type f | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ' | sed 's/ $//')"
r=0; [ "$got" = "$want" ] || r=1; ok $r "run files the 13 sets exactly: [$got]"
r=0; [ "$(cat "$T/root/webgate/p39114058_122140_Generic.zip")" = "zip 39114058" ] || r=1; ok $r "a staged file is the file that was downloaded"
r=0; [ -z "$(find "$T/dl/wls" "$T/dl/ohs" "$T/dl/dbclient" -type f)" ] || r=1; ok $r "run moved the patches out of the kind folders"
for k in wls db spb; do r=0; [ ! -e "$T/root/$k" ] || r=1; ok $r "the staged root has no $k/ (ohs-quarter.sh refuses one)"; done
has "$T/run.out" "staged 13 file(s)"; ok $? "run counts what it staged"

# ---- the staged root is one ohs-quarter.sh accepts, and the download tree is one it refuses ----
mk() { printf '#!/bin/sh\nexit 0\n' >"$1"; chmod +x "$1"; }
mk "$T/child"; tree "$T/dl-raw"
q() { OHS_QUARTER_JAVA_PATCH="$T/child" OHS_QUARTER_WLS_PATCH="$T/child" OHS_QUARTER_DBCLIENT="$T/child" OHS_QUARTER_OHS_PATCH="$T/child" \
      RUN_BASE="$T/runs" "$REPO/patching/ohs-quarter/ohs-quarter.sh" "$1" --dry-run --yes; }
q "$T/dl-raw" >"$T/q-raw.out" 2>&1; rc=$?
[ "$rc" != 0 ] && has "$T/q-raw.out" "get-patches.ps1 download tree"; ok $? "control: ohs-quarter.sh refuses the unsorted download tree (rc=$rc)"
q "$T/root" >"$T/q-root.out" 2>&1
! has "$T/q-root.out" "get-patches.ps1 download tree" && ! has "$T/q-root.out" "partial runbook"; ok $? "ohs-quarter.sh does not refuse the staged root as foreign or partial: $(tail -1 "$T/q-root.out")"

# ---- a partial download: staged, and the missing folders are named with the --skip list ----
mkdir -p "$T/part/ohs" "$T/part/dbclient"; echo a >"$T/part/ohs/p40005842_122140_Linux-x86-64.zip"; echo b >"$T/part/dbclient/p34761383_122140_Linux-x86-64.zip"
"$S" run "$T/part" "$T/root-part" >"$T/part.out" 2>&1; ok $? "a partial download is staged (exit 0)"
has "$T/part.out" "NOT IN THIS DOWNLOAD: jdk wlspsu dbclientru webgate oss jdbc libovd fmwthirdparty perl libdms2 libiau"; ok $? "the folders the download lacks are named"
has "$T/part.out" "--skip jdk,wlspsu,dbclientru,webgate,oss,jdbc,libovd,fmwthirdparty,perl,libdms2,libiau"; ok $? "the --skip list ohs-quarter.sh would need is printed, not applied"

# ---- refusals: all before any change ----
refuses() { # <what> <expected text> <src> <dest> [args...]
  local what="$1" text="$2" src="$3" dest="$4"; shift 4
  local b; b="$(snapshot "$src")"
  "$S" run "$src" "$dest" "$@" >"$T/r.out" 2>&1; local rc=$?
  [ "$rc" = 1 ] && has "$T/r.out" "$text" && has "$T/r.out" "Nothing changed" && [ "$(snapshot "$src")" = "$b" ]
  ok $? "$what: rc=$rc, said '$text', source untouched: $(grep ERROR "$T/r.out" | head -1)"
}
tree "$T/u"; echo x >"$T/u/wls/p28186730_139400_Generic.zip"
refuses "an unknown patch number" "no folder for p28186730_139400_Generic.zip" "$T/u" "$T/root-u"
r=0; [ ! -e "$T/root-u" ] || r=1; ok $r "a refused run creates no root"
"$S" run "$T/u" "$T/root-u" --leave-unknown >"$T/lu.out" 2>&1; ok $? "--leave-unknown stages the rest"
[ -f "$T/u/wls/p28186730_139400_Generic.zip" ] && has "$T/lu.out" "wls/p28186730_139400_Generic.zip"; ok $? "...and the unknown zip stays put and is listed"

tree "$T/j"; echo t2 >"$T/j/jdk/jdk-8u503-linux-x64.tar.gz"
refuses "two JDK tarballs" "more than one JDK tarball" "$T/j" "$T/root-j"

tree "$T/d"; echo different >"$T/d/ohs/p39919567_122140_Generic.zip"
refuses "one patch twice with different bytes" "twice with different contents" "$T/d" "$T/root-d"

tree "$T/s"; mkdir -p "$T/root-s/ohs"; echo old >"$T/root-s/ohs/p39611663_122140_Linux-x86-64.zip"
refuses "last quarter's zip in a destination folder" "already holds p39611663_122140_Linux-x86-64.zip" "$T/s" "$T/root-s"

tree "$T/o"; mkdir -p "$T/root-o/ohs"; echo other >"$T/root-o/ohs/p40005842_122140_Linux-x86-64.zip"
refuses "a different file already at the destination" "exists and differs" "$T/o" "$T/root-o"
r=0; [ "$(cat "$T/root-o/ohs/p40005842_122140_Linux-x86-64.zip")" = other ] || r=1; ok $r "the existing destination file is not overwritten"

tree "$T/i"
refuses "a root inside the download dir" "is the download dir or inside it" "$T/i" "$T/i/staged"
refuses "the download dir as the root" "is the download dir or inside it" "$T/i" "$T/i"

mkdir -p "$T/e/wls"; echo n >"$T/e/wls/notes.txt"
refuses "a tree with nothing the table files" "nothing under" "$T/e" "$T/root-e"

# ---- --map replaces the table; a bad table is refused whole ----
mkdir -p "$T/m/ohs"; echo n >"$T/m/ohs/p41111111_122140_Linux-x86-64.zip"
printf '# next quarter\n41111111 ohs\n' >"$T/map"
"$S" run "$T/m" "$T/root-m" --map "$T/map" >"$T/m.out" 2>&1; ok $? "--map files a number the built-in table does not know"
r=0; [ -f "$T/root-m/ohs/p41111111_122140_Linux-x86-64.zip" ] || r=1; ok $r "...into the folder the map names"
printf '41111111 wls\n' >"$T/badmap"
refuses "a map naming a kind folder" "'wls' is not a folder of the runbook" "$T/m" "$T/root-m2" --map "$T/badmap"
printf '41111111 ohs\n41111111 jdbc\n' >"$T/dupmap"
"$S" plan "$T/m" "$T/root-m3" --map "$T/dupmap" >"$T/dm.out" 2>&1; [ $? = 1 ] && has "$T/dm.out" "more than once"; ok $? "a map naming one patch twice is refused"

# ---- --copy leaves the download whole; a second run of the same files is a no-op, not a refusal ----
tree "$T/c"; b="$(snapshot "$T/c")"
"$S" run "$T/c" "$T/root-c" --copy >"$T/c.out" 2>&1; ok $? "--copy exits 0"
r=0; [ "$(snapshot "$T/c")" = "$b" ] && [ -f "$T/root-c/ohs/p40005842_122140_Linux-x86-64.zip" ] || r=1; ok $r "--copy leaves the download tree whole and fills the root"
"$S" run "$T/c" "$T/root-c" --copy >"$T/c2.out" 2>&1; ok $? "staging the same files again is accepted"
has "$T/c2.out" "already there: ohs/p40005842_122140_Linux-x86-64.zip" && has "$T/c2.out" "staged 0 file(s)"; ok $? "...and says each is already there"

# ---- arguments ----
"$S" run "$T/c" >"$T/a.out" 2>&1; [ $? = 1 ] && has "$T/a.out" "needs <download-dir> and <patch-root>"; ok $? "a missing root is refused"
"$S" stage "$T/c" "$T/x" >"$T/a.out" 2>&1; [ $? = 1 ] && has "$T/a.out" "Unknown command"; ok $? "an unknown command is refused"
"$S" run "$T/c" "$T/x" --map >"$T/a.out" 2>&1; [ $? = 1 ] && has "$T/a.out" "--map needs a value"; ok $? "--map without a value is refused"
"$S" run "$T/nope" "$T/x" >"$T/a.out" 2>&1; [ $? = 1 ] && has "$T/a.out" "not a directory"; ok $? "a download dir that is not there is refused"

echo "ohs-quarter-stage gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
