#!/usr/bin/env bash
# ohs-quarter-stage.sh - sort a get-patches.ps1 download tree into the folders ohs-quarter.sh reads.
#
# get-patches.ps1 files what it downloads by patch kind (wls/ spb/ db/ ohs/ jdk/ dbclient/). ohs-quarter.sh reads
# one folder per step of its runbook (jdk wlspsu dbclient dbclientru webgate oss ohs jdbc libovd fmwthirdparty perl
# libdms2 libiau) and refuses a root that holds wls/, db/ or spb/. This script is the step between the two: it
# reads the patch NUMBER out of each Oracle file name (p<number>_<release>_<platform>.zip) and puts the file in
# the folder the runbook applies that number from. It needs no network and reads nothing but file names.
#
# The table below is the October 2026 set from the head of ohs-quarter.sh. The numbers change every quarter:
# pass the new ones with --map FILE rather than editing them into a copy of this script.
#
# Usage: ohs-quarter-stage.sh plan <download-dir> <patch-root> [options]   say where every file would go; change nothing
#        ohs-quarter-stage.sh run  <download-dir> <patch-root> [options]   the same checks, then move the files
#
#   <download-dir>  the tree get-patches.ps1 wrote (or any folder of Oracle patch zips, searched two levels deep)
#   <patch-root>    the root ohs-quarter.sh will be given; created if missing. Not <download-dir> or inside it
#
# Options
#   --map FILE        patch numbers for this quarter, one "<number> <folder>" per line (# comments). Replaces the
#                     built-in table; a folder that is not one of the runbook's is refused
#   --copy            copy instead of move (needs the space twice; the default move is a rename on one filesystem)
#   --leave-unknown   a p<number>_*.zip whose number is not in the table is left where it is and listed. Without
#                     this it is refused: a patch nobody filed is a patch the outage silently does not apply
#   -h|--help
#
# Nothing is moved until every file has a destination and every destination is clear. Refused before any change:
#   - a patch zip whose number is not in the table (unless --leave-unknown)
#   - two different files for one destination name, or more than one JDK tarball
#   - a destination folder that already holds something else (ohs-patch.sh applies every patch in its folder, so
#     last quarter's zip left there would be applied again)
# A JDK is the one *.tar.gz (java-patch.sh takes the tarball; the zip get-patches.ps1 unpacked it from is left).
#
# It ends by naming the runbook folders that are still empty and the exact --skip list ohs-quarter.sh would need
# for them. It does not decide that leaving them out is right: that is the operator's call, made by typing --skip.
#
# Exit: 0 planned or staged; 1 refused or failed (run: files already moved stay where they were put, each named)

set -uo pipefail

SETS=(jdk wlspsu dbclient dbclientru webgate oss ohs jdbc libovd fmwthirdparty perl libdms2 libiau)
# number folder - ohs-quarter.sh's own table (its header, "The set, in the order this script applies it")
MAP="39919567 wlspsu
34761383 dbclient
39425385 dbclientru
39114058 webgate
39567777 oss
40005842 ohs
39487427 jdbc
39465265 libovd
39574504 fmwthirdparty
38590502 perl
38098858 libdms2
38832179 libiau"

err() { printf 'ERROR: %s\n' "$*" >&2; }
die() { err "$*"; exit 1; }
optchk() { [ $# -ge 2 ] || die "$1 needs a value"; case "$2" in -[!0-9]*) die "$1 needs a value, got '$2'";; esac; }
usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }
is_set() { local s; for s in "${SETS[@]}"; do [ "$s" = "$1" ] && return 0; done; return 1; }
folder_of() { printf '%s\n' "$MAP" | awk -v n="$1" '$1 == n { print $2; exit }'; }

CMD=""; SRC=""; DEST=""; MAP_FILE=""; COPY=0; LEAVE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --map)           optchk "$@"; MAP_FILE="$2"; shift 2;;
    --copy)          COPY=1; shift;;
    --leave-unknown) LEAVE=1; shift;;
    -h|--help|help)  usage; exit 0;;
    -*) die "Unknown option: $1";;
    *) if [ -z "$CMD" ]; then CMD="$1"; elif [ -z "$SRC" ]; then SRC="$1"; elif [ -z "$DEST" ]; then DEST="$1"; else die "Unknown argument: $1"; fi; shift;;
  esac
done
case "$CMD" in plan|run) ;; '') usage; exit 1;; *) die "Unknown command: $CMD (plan or run)";; esac
[ -n "$SRC" ] && [ -n "$DEST" ] || die "$CMD needs <download-dir> and <patch-root>"
[ -d "$SRC" ] || die "download dir is not a directory: $SRC"
[ -r "$SRC" ] || die "download dir is not readable: $SRC"
SRC="$(cd "$SRC" && pwd -P)" || die "cannot enter $SRC"
case "$DEST" in /*) ;; *) DEST="$PWD/$DEST";; esac
DEST="${DEST%/}"
# compare REAL paths: resolve the deepest part of the root that exists (it may not be created yet) and put the
# rest back on, so a symlinked path to the download dir, or to a folder inside it, is still seen as that
anc="$DEST"; tail=""
while [ ! -d "$anc" ] && [ "$anc" != / ] && [ -n "$anc" ]; do tail="/${anc##*/}$tail"; anc="${anc%/*}"; [ -n "$anc" ] || anc=/; done
DEST_REAL="$(cd "$anc" 2>/dev/null && pwd -P)" || die "cannot resolve <patch-root> $DEST"
DEST_REAL="${DEST_REAL%/}$tail"
case "$DEST_REAL/" in "$SRC/"*) die "<patch-root> $DEST is the download dir or inside it - the kind folders (wls/ db/ spb/) would stay in the root and ohs-quarter.sh refuses that. Give a separate folder. Nothing changed.";; esac

if [ -n "$MAP_FILE" ]; then
  [ -r "$MAP_FILE" ] || die "--map file is not readable: $MAP_FILE"
  MAP="$(sed -e 's/#.*//' -e '/^[[:space:]]*$/d' "$MAP_FILE")"
  [ -n "$MAP" ] || die "--map $MAP_FILE has no '<number> <folder>' lines"
fi
# the table is checked whole, built-in or not: a bad line must not surface as "unknown patch" later
while read -r num folder rest; do
  [ -n "$num" ] || continue
  case "$num" in *[!0-9]*) die "table line '$num $folder $rest': '$num' is not a patch number. Nothing changed.";; esac
  [ -n "$folder" ] && [ -z "$rest" ] || die "table line '$num $folder $rest': expected '<number> <folder>'. Nothing changed."
  is_set "$folder" || die "table line '$num $folder': '$folder' is not a folder of the runbook (${SETS[*]}). Nothing changed."
  [ "$folder" != jdk ] || die "table line '$num $folder': jdk/ takes the JDK tarball, not a patch zip. Nothing changed."
  [ "$(printf '%s\n' "$MAP" | awk -v n="$num" '$1 == n' | wc -l | tr -d ' ')" = 1 ] || die "table names patch $num more than once. Nothing changed."
done <<EOF
$MAP
EOF

# ---- read the tree: every file gets a destination, is left on purpose, or is a reason to refuse --------------
PLAN=""        # lines: <source path>|<folder>|<file name>
UNKNOWN=""; LEFT=""; JDKS=""; problems=0
problem() { err "$*"; problems=$((problems + 1)); }
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base="${f##*/}"
  case "$base" in
    *.tar.gz) JDKS="${JDKS}${f}
"; continue;;
    p[0-9]*_*.zip)
      num="${base#p}"; num="${num%%_*}"
      case "$num" in *[!0-9]*) LEFT="${LEFT}${f}
"; continue;; esac
      folder="$(folder_of "$num")"
      if [ -n "$folder" ]; then PLAN="${PLAN}${f}|${folder}|${base}
"
      # the zip a JDK tarball came out of: java-patch.sh takes the tarball, so this is not a patch left unfiled
      elif [ "$(basename "$(dirname "$f")")" = jdk ]; then LEFT="${LEFT}${f}
"
      else UNKNOWN="${UNKNOWN}${f}
"; fi;;
    *) LEFT="${LEFT}${f}
";;
  esac
done <<EOF
$(find "$SRC" -mindepth 1 -maxdepth 2 -type f 2>/dev/null | LC_ALL=C sort)
EOF

njdk="$(printf '%s' "$JDKS" | grep -c . || true)"
if [ "$njdk" -gt 1 ]; then problem "more than one JDK tarball under $SRC - ohs-quarter.sh takes exactly one: $(printf '%s' "$JDKS" | tr '\n' ' ')"
elif [ "$njdk" = 1 ]; then j="$(printf '%s' "$JDKS" | head -1)"; PLAN="${PLAN}${j}|jdk|${j##*/}
"; fi

if [ -n "$UNKNOWN" ]; then
  if [ "$LEAVE" = 1 ]; then LEFT="${LEFT}${UNKNOWN}"
  else
    while IFS= read -r f; do [ -n "$f" ] && problem "no folder for ${f##*/} (found at $f): its patch number is not in the table. Add it with --map, or pass --leave-unknown to leave it out of this outage on purpose."; done <<EOF
$UNKNOWN
EOF
  fi
fi
[ -n "$PLAN" ] || problem "nothing under $SRC that the table files: no p<number>_*.zip it names and no JDK tarball"

# two sources for one destination name: the same bytes are one file, different bytes are a question for a person
DEDUP=""
while IFS='|' read -r f folder base; do
  [ -n "$f" ] || continue
  prev="$(printf '%s' "$DEDUP" | awk -F'|' -v k="$folder|$base" '($2 "|" $3) == k { print $1; exit }')"
  if [ -z "$prev" ]; then DEDUP="${DEDUP}${f}|${folder}|${base}
"
  elif cmp -s "$prev" "$f"; then LEFT="${LEFT}${f}
"
  else problem "$base is under $SRC twice with different contents ($prev and $f) - keep the one MOS's SHA-256 matches"; fi
done <<EOF
$PLAN
EOF
PLAN="$DEDUP"

# a destination folder holds exactly what this run puts there: anything else in it would be applied too
for s in "${SETS[@]}"; do
  d="$DEST/$s"; [ -d "$d" ] || continue
  [ -r "$d" ] || { problem "$d is not readable"; continue; }
  while IFS= read -r have; do
    [ -n "$have" ] || continue
    src="$(printf '%s' "$PLAN" | awk -F'|' -v k="$s|$have" '($2 "|" $3) == k { print $1; exit }')"
    if [ -z "$src" ]; then problem "$d already holds $have, which this run does not put there - ohs-quarter.sh would apply it too. Move it away first."
    elif ! cmp -s "$src" "$d/$have"; then problem "$d/$have exists and differs from $src - not overwriting it. Move it away first."; fi
  done <<EOF
$(ls -A "$d" 2>/dev/null)
EOF
done

# ---- say the plan -------------------------------------------------------------------------------------------
verb="move"; [ "$COPY" = 1 ] && verb="copy"
echo "ohs-quarter-stage: $SRC -> $DEST"
while IFS='|' read -r f folder base; do [ -n "$f" ] && printf '  %-14s %s   (from %s)\n' "$folder/" "$base" "${f#"$SRC"/}"; done <<EOF
$PLAN
EOF
if [ -n "$LEFT" ]; then
  echo "left where it is (not a patch this runbook applies):"
  while IFS= read -r f; do [ -n "$f" ] && echo "  ${f#"$SRC"/}"; done <<EOF
$LEFT
EOF
fi
[ "$problems" = 0 ] || die "$problems problem(s) above. Nothing changed."

missing=""
for s in "${SETS[@]}"; do
  printf '%s' "$PLAN" | awk -F'|' -v s="$s" '$2 == s { found = 1 } END { exit !found }' || missing="${missing:+$missing,}$s"
done
summary() {
  if [ -z "$missing" ]; then echo "all ${#SETS[@]} runbook folders are filled: ohs-quarter.sh $DEST"
  else
    echo "NOT IN THIS DOWNLOAD: ${missing//,/ }"
    echo "ohs-quarter.sh refuses a root with those folders missing. Download them (get-patches.ps1 -Patch <number>) and run this again,"
    echo "or leave them out on purpose:  ohs-quarter.sh $DEST --skip $missing"
  fi
}

if [ "$CMD" = plan ]; then echo "plan only - nothing changed. 'run' would $verb the files above."; summary; exit 0; fi

# ---- do it --------------------------------------------------------------------------------------------------
done_n=0
while IFS='|' read -r f folder base; do
  [ -n "$f" ] || continue
  d="$DEST/$folder"
  mkdir -p "$d" || die "cannot create $d ($done_n file(s) already staged under $DEST)"
  if [ -e "$d/$base" ]; then echo "  already there: $folder/$base"; continue; fi   # identical: checked above
  size="$(wc -c <"$f" | tr -d ' ')"
  if [ "$COPY" = 1 ]; then cp -p "$f" "$d/$base"; else mv "$f" "$d/$base"; fi || die "could not $verb $f to $d/ ($done_n file(s) already staged under $DEST)"
  # read it back: a full disk can leave a short file behind a zero exit
  [ -f "$d/$base" ] && [ "$(wc -c <"$d/$base" | tr -d ' ')" = "$size" ] || die "$d/$base is not the $size bytes of $f after the $verb ($done_n file(s) already staged under $DEST)"
  done_n=$((done_n + 1)); echo "  staged: $folder/$base"
done <<EOF
$PLAN
EOF
echo "staged $done_n file(s) under $DEST"
summary
exit 0
