#!/usr/bin/env bash
# exascale-space.sh - "the vault is full": where the space on Exadata Exascale went and how to get some back.
# Storage pools (raw, used, provisionable, free vs the rebalance reserve), every vault (used vs provisioned per
# media type, days to full from its own history), what is inside each vault (by file type, by database, by
# top-level path, snapshots and thin clones, files still being deleted, files no database claims), block
# volumes and volume snapshots, and the database side (V$EXA_VAULT, V$EXA_FILE, FRA on the vault and what RMAN
# could delete, PDB snapshot clones). Then the fixes: grow a vault's provisioning (chvault, with rollback),
# purge archivelogs RMAN has already backed up, delete named files (rmfile, typed confirmation). escli with the
# oracle user's wallet; works database-side only when escli is not on the host. No network needed.
#
# Usage: exascale-space.sh <command> [args] [options]
#
# Commands
#   inspect              Everything above into REPORT.md with FINDINGS (exit 2 CRIT, 1 WARN, 0 clean); prints findings + path
#   plan [--vault V]     Read-only: what could be freed or grown, with the exact escli/RMAN commands and sizes
#   grow <vault> --hc SIZE|--ef SIZE|--xt SIZE [--pool NAME]   chvault to a new provisioned space (absolute: 10T, or +2T on top of
#                        the current value); preflight checks the pool has it; verify re-reads the vault; rollback puts the old value back
#   purge-archivelogs [--sid SID] [--days N] [--obsolete]   RMAN delete archivelog ... completed before sysdate-N backed up
#                        EXA_ARCH_BACKED_UP times to device type EXA_ARCH_DEVICE; --obsolete adds delete obsolete
#   release <@vault/file ...> | --list FILE   rmfile the files named (never a heuristic; plan lists candidates); typed confirmation
#   rollback             Undo the last grow (chvault to the saved value)
#   verify               Re-read the vault(s) touched by the last grow
#   heal | run           inspect, then purge-archivelogs for every vault over EXA_WARN_PCT (asks; --yes runs); grow/release never automatic
#
# Options
#   --vault NAME   one vault        --sid SID   one database (default: every running instance)
#   --days N       archivelog age for purge (default EXA_ARCH_DAYS=1)   --top N   rows in the biggest-files tables (25)
#   --no-files     skip the per-file listing (big vaults)   --no-db   skip the database side   --no-escli   database side only
#   --out DIR  --dry-run  --yes  --force  --verbose  --quiet  --no-tar
#
# Config: exascale-space.conf or the shared oracle.conf: ESCLI (binary), EXA_WALLET (default: escli's own search path
# $OSSCONF/eswallet, $ORACLE_BASE/admin/eswallet, /etc/oracle/cell/network-config/eswallet), EXA_CTRL (ERS host:port),
# EXA_TIMEOUT (120 s per escli call), EXA_WARN_PCT (85), EXA_CRIT_PCT (95), EXA_POOL_FREE_PCT (12, the rebalance reserve),
# EXA_WARN_DAYS (30) / EXA_CRIT_DAYS (7) days-to-full, EXA_ORPHAN_DAYS (7), EXA_ARCH_DAYS (1), EXA_ARCH_BACKED_UP (1),
# EXA_ARCH_DEVICE (sbt), EXA_OUT, EXA_HISTORY, SQL_CONNECT, RMAN_CMD, RMAN_CATALOG_CONNECT, RUN_BASE.
# Output: EXA_OUT/<host>_<ts>/REPORT.md (FINDINGS first) + raw/*.txt + raw/*.csv; change-making commands log under RUN_BASE.

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="exascale-space"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

ESCLI="${ESCLI:-}"; EXA_WALLET="${EXA_WALLET:-}"; EXA_CTRL="${EXA_CTRL:-}"; EXA_TIMEOUT="${EXA_TIMEOUT:-120}"
EXA_WARN_PCT="${EXA_WARN_PCT:-85}"; EXA_CRIT_PCT="${EXA_CRIT_PCT:-95}"; EXA_POOL_FREE_PCT="${EXA_POOL_FREE_PCT:-12}"
EXA_WARN_DAYS="${EXA_WARN_DAYS:-30}"; EXA_CRIT_DAYS="${EXA_CRIT_DAYS:-7}"; EXA_ORPHAN_DAYS="${EXA_ORPHAN_DAYS:-7}"
EXA_ARCH_DAYS="${EXA_ARCH_DAYS:-1}"; EXA_ARCH_BACKED_UP="${EXA_ARCH_BACKED_UP:-1}"; EXA_ARCH_DEVICE="${EXA_ARCH_DEVICE:-sbt}"
EXA_OUT="${EXA_OUT:-$HOME/exascale-space}"; EXA_HISTORY="${EXA_HISTORY:-$HOME/exascale-space/history}"; EXA_WINDOW="${EXA_WINDOW:-30}"
RMAN_TIMEOUT="${RMAN_TIMEOUT:-1800}"; RMAN_CATALOG_CONNECT="${RMAN_CATALOG_CONNECT:-}"
ONLY_VAULT=""; ONLY_SID=""; ARCH_DAYS=""; TOP=25; NO_FILES=0; NO_DB=0; NO_ESCLI=0; MAKE_TAR=1; DO_OBSOLETE=0; LIST_FILE=""
GROW_HC=""; GROW_EF=""; GROW_XT=""; GROW_POOL=""
TODAY="$(date +%Y-%m-%d)"
ES_VERSION=""; ES_MULTIPOOL=0
POOLS=""   # name|mediaType|raw|used|provisionable|provisioned|dataStatus|recoStatus
VAULTS=""  # name|usedHC|provHC|usedEF|provEF|usedXT|provXT
FILES=""   # vault|path|fileType|size|spaceUsed|usedBy|createTime|flags|snap|mediaType
VOLS=""    # id|name|vault|size|spaceUsed|state|acfs|numSnapshots
ARGS=()

usage() { usage_from_header "$0"; }
parse_opts() {
  ARGS=()
  while [ $# -gt 0 ]; do case "$1" in
    --vault) optchk "$@"; ONLY_VAULT="${2#@}"; shift 2;; --sid) optchk "$@"; ONLY_SID="$2"; shift 2;; --days) optchk "$@"; ARCH_DAYS="$2"; shift 2;; --top) optchk "$@"; TOP="$2"; shift 2;;
    --hc) optchk "$@"; GROW_HC="$2"; shift 2;; --ef) optchk "$@"; GROW_EF="$2"; shift 2;; --xt) optchk "$@"; GROW_XT="$2"; shift 2;; --pool) optchk "$@"; GROW_POOL="$2"; shift 2;;
    --obsolete) DO_OBSOLETE=1; shift;; --list) optchk "$@"; LIST_FILE="$2"; shift 2;;
    --no-files) NO_FILES=1; shift;; --no-db) NO_DB=1; shift;; --no-escli) NO_ESCLI=1; shift;; --no-tar) MAKE_TAR=0; shift;;
    --out) optchk "$@"; EXA_OUT="$2"; shift 2;; --dry-run) DRY_RUN=1; shift;; --yes) ASSUME_YES=1; shift;; --force) FORCE=1; shift;;
    --verbose) VERBOSE=1; shift;; --quiet) QUIET=1; shift;; --run-dir) optchk "$@"; RUN_DIR="$2"; shift 2;;
    -h|--help) usage; exit 0;; --*) die "Unknown option: $1";; *) ARGS+=("$1"); shift;; esac; done
}

# ---------------------------------------------------------------------------
# escli: one call per command, wallet from EXA_WALLET or escli's own search path, every value humanised by escli
# ---------------------------------------------------------------------------
escli_find() {
  [ -n "$ESCLI" ] && { [ -x "$ESCLI" ] || have "$ESCLI" || die "ESCLI=$ESCLI is not executable"; return 0; }
  local c; for c in escli /opt/oracle/cell/cellsrv/bin/escli /opt/oracle/dbserver/dbms/bin/escli /usr/sbin/escli /usr/bin/escli; do
    { [ -x "$c" ] || have "$c"; } && { ESCLI="$c"; return 0; }; done
  return 1
}
es() { # <escli args...>: stdout only, exit code kept
  local w=() c=()
  [ -n "$EXA_WALLET" ] && w=(--wallet "$EXA_WALLET"); [ -n "$EXA_CTRL" ] && c=(--ctrl "$EXA_CTRL")
  dbg "escli $*"; to "$EXA_TIMEOUT" "$ESCLI" "${w[@]}" "${c[@]}" "$@" 2>&1 </dev/null
}
ES_ERR=""
es_ok() { # the control services answer and the wallet logs in: lscluster --detail must come back with attributes
  local out; out="$(es lscluster --detail 2>&1)" || { ES_ERR="$out"; return 1; }
  printf '%s\n' "$out" | grep -qE '^[[:space:]]*(name|id|guid|version|softwareVersion|releaseVersion)[[:space:]]' || { ES_ERR="$out"; return 1; }
  ES_VERSION="$(printf '%s\n' "$out" | awk '$1 ~ /^(version|softwareVersion|releaseVersion)$/ {print $2; exit}')"
  printf '%s' "$ES_VERSION" | grep -qE '^(2[6-9]|[3-9][0-9])\.' && ES_MULTIPOOL=1
  return 0
}
# escli prints sizes like 10.0000G, 19.5k, 24k, 1.0000T, "unlimited", or plain bytes
to_bytes() {
  local v="${1:-0}"; v="${v%,}"
  case "$v" in unlimited|UNLIMITED) echo unlimited; return;; ""|-|null) echo 0; return;; esac
  awk -v v="$v" 'BEGIN{ n=v; u=""; if (v ~ /[A-Za-z]+$/) { match(v,/[A-Za-z]+$/); u=toupper(substr(v,RSTART)); n=substr(v,1,RSTART-1) }
    m=1; if (u ~ /^K/) m=1024; else if (u ~ /^M/) m=1048576; else if (u ~ /^G/) m=1073741824; else if (u ~ /^T/) m=1099511627776; else if (u ~ /^P/) m=1125899906842624;
    printf "%.0f", n*m }'
}
human() { awk -v b="${1:-0}" 'BEGIN{ if (b=="unlimited") {print b; exit} if (b>=1099511627776) printf "%.2f TB", b/1099511627776; else if (b>=1073741824) printf "%.1f GB", b/1073741824; else if (b>=1048576) printf "%.0f MB", b/1048576; else printf "%d B", b }'; }
pct() { awk -v a="$1" -v b="$2" 'BEGIN{ if (b=="unlimited" || b+0==0) print "-"; else printf "%d", a*100/b }'; }
# records <file>: turn "--detail" output (attr<spaces>value, one object after another, blank line or repeated
# first attribute between objects) into one line per object: attr=value<TAB>attr=value...
records() {
  awk '
    function flush() { if (n) { print rec } rec=""; n=0; delete seen }
    /^[[:space:]]*$/ { flush(); next }
    /^[[:space:]]*(\$|@)/ { next }
    { k=$1; v=$0; sub(/^[[:space:]]*[^[:space:]]+[[:space:]]*/, "", v)
      if (k in seen) flush()
      seen[k]=1; rec=rec (n?"\t":"") k "=" v; n++ }
    END { flush() }' "${1:--}"
}
attr() { printf '%s\n' "$1" | tr '\t' '\n' | sed -n "s/^$2=//p" | head -1; }
es_raw() { # <name> <escli args...>: full output to raw/<name>.txt, returns escli's code
  local name="$1"; shift; local f="$RAW/$name.txt" rc
  { printf '$ escli %s\n' "$*"; es "$@"; rc=$?; printf '\n[exit %s]\n' "$rc"; } >"$f"; return "$rc"
}
es_section() { # <name> <title> <escli args...>: fenced block in the report, full in raw/
  local name="$1" title="$2"; shift 2; es_raw "$name" "$@"
  h3 "$title"; local n; n="$(wc -l <"$RAW/$name.txt" | tr -d ' ')"
  fence_start; if [ "$n" -gt "$DIAG_LINES" ]; then head -n "$DIAG_LINES" "$RAW/$name.txt" >>"$REPORT"; printf '... (%s lines, full in raw/%s.txt)\n' "$n" "$name" >>"$REPORT"; else cat "$RAW/$name.txt" >>"$REPORT"; fi; fence_end
}

# ---------------------------------------------------------------------------
# history + days-to-full (same idea as space-forecast: least squares over EXA_WINDOW days)
# ---------------------------------------------------------------------------
hist_file() { mkdir -p "$EXA_HISTORY/$HOST"; printf '%s/%s/%s.csv' "$EXA_HISTORY" "$HOST" "$1"; }
hist_append() { # <kind> <name> <used_bytes> <max_bytes>
  local f; f="$(hist_file "$1")"; [ -f "$f" ] || echo "date,name,used_bytes,max_bytes" >"$f"
  grep -q "^$TODAY,$2," "$f" 2>/dev/null && { grep -v "^$TODAY,$2," "$f" >"$f.tmp"; mv "$f.tmp" "$f"; }
  printf '%s,%s,%s,%s\n' "$TODAY" "$2" "$3" "$4" >>"$f"
}
fit() { # <kind> <name>: "bytes_per_day points"
  local f; f="$(hist_file "$1")"; [ -f "$f" ] || { echo "0 0"; return; }
  local since; since="$(days_ago "$EXA_WINDOW")"
  awk -F, -v n="$2" -v since="$since" '
    function jdn(y,m,d) { a=int((14-m)/12); y2=y+4800-a; m2=m+12*a-3; return d+int((153*m2+2)/5)+365*y2+int(y2/4)-int(y2/100)+int(y2/400)-32045 }
    $2==n && $1>=since { split($1,d,"-"); t=jdn(d[1]+0,d[2]+0,d[3]+0); k++; sx+=t; sy+=$3; sxx+=t*t; sxy+=t*$3 }
    END { if (k<2) { print "0", k; exit } den=k*sxx-sx*sx; slope=(den==0)?0:(k*sxy-sx*sy)/den; printf "%.0f %d\n", slope, k }' "$f"
}
days_to_full() { awk -v u="$1" -v m="$2" -v s="$3" 'BEGIN{ if (m=="unlimited" || m+0<=0) {print "-"; exit} if (s<=0) {print "never"; exit} d=(m-u)/s; if (d<0) print 0; else printf "%d", d }'; }
track() { # <kind> <label> <used> <max> [nopct]: history + findings on % now (unless nopct) and days to full
  local kind="$1" lbl="$2" used="$3" max="$4" nopct="${5:-}"
  hist_append "$kind" "$lbl" "$used" "$max"
  local slope pts p d; read -r slope pts <<<"$(fit "$kind" "$lbl")"; p="$(pct "$used" "$max")"; d="$(days_to_full "$used" "$max" "$slope")"
  TRACK="${TRACK}$kind|$lbl|$used|$max|$p|$slope|$d|$pts"$'\n'
  if [ "$p" != "-" ] && [ -z "$nopct" ]; then
    [ "$p" -ge "$EXA_CRIT_PCT" ] && finding CRIT "$kind" "$lbl: ${p}% of provisioned space used ($(human "$used") of $(human "$max"))"
    [ "$p" -ge "$EXA_WARN_PCT" ] && [ "$p" -lt "$EXA_CRIT_PCT" ] && finding WARN "$kind" "$lbl: ${p}% used ($(human "$used") of $(human "$max"))"
  fi
  case "$d" in never|-) ;; *) [ "$d" -le "$EXA_CRIT_DAYS" ] && finding CRIT "$kind" "$lbl: full in ~$d days at +$(human "$slope")/day"
    [ "$d" -gt "$EXA_CRIT_DAYS" ] && [ "$d" -le "$EXA_WARN_DAYS" ] && finding WARN "$kind" "$lbl: full in ~$d days at +$(human "$slope")/day";; esac
  return 0
}
TRACK=""

# ---------------------------------------------------------------------------
# collectors
# ---------------------------------------------------------------------------
collect_pools() {
  say "storage pools"; h1 "Storage pools"
  es_raw pools lsstoragepool --detail || { para "_lsstoragepool failed: see raw/pools.txt_"; finding WARN escli "lsstoragepool failed: $(head -2 "$RAW/pools.txt" | tail -1)"; return 0; }
  para "Free = spaceRaw - spaceUsed. Oracle's rule for surviving a disk loss on a three-cell pool: keep ${EXA_POOL_FREE_PCT}% free (12% for 12-disk HC/XT cells, 20% for 6-disk HC cells; \`EXA_POOL_FREE_PCT\`). Provisioned above raw means the vaults together promise more than the pool holds."
  table_head "pool" "media" "raw" "used" "free %" "provisionable" "provisioned" "data ring" "reco ring"
  local r; while IFS= read -r r; do
    [ -n "$r" ] || continue
    local n m raw used prov able ds rs; n="$(attr "$r" name)"; m="$(attr "$r" mediaType)"; raw="$(to_bytes "$(attr "$r" spaceRaw)")"; used="$(to_bytes "$(attr "$r" spaceUsed)")"
    able="$(to_bytes "$(attr "$r" spaceProvisionable)")"; prov="$(to_bytes "$(attr "$r" spaceProvisioned)")"
    ds="$(attr "$r" highDataStatus)"; [ -z "$ds" ] && ds="$(attr "$r" normalDataStatus)"; rs="$(attr "$r" highRecoStatus)"; [ -z "$rs" ] && rs="$(attr "$r" normalRecoStatus)"
    [ -n "$n" ] || continue
    local freep; freep="$(awk -v r="$raw" -v u="$used" 'BEGIN{ if (r+0==0) print "-"; else printf "%d", (r-u)*100/r }')"
    POOLS="${POOLS}$n|$m|$raw|$used|$able|$prov|$ds|$rs"$'\n'
    table_row "$n" "$m" "$(human "$raw")" "$(human "$used")" "$freep" "$(human "$able")" "$(human "$prov")" "${ds:-?}" "${rs:-?}"
    track pool "$n ($m)" "$used" "$raw" nopct
    if [ "$freep" != "-" ]; then
      [ "$freep" -lt 5 ] && finding CRIT pool "$n ($m): only ${freep}% free of $(human "$raw") - new allocations in every vault on this pool will fail soon"
      [ "$freep" -ge 5 ] && [ "$freep" -lt "$EXA_POOL_FREE_PCT" ] && finding WARN pool "$n ($m): ${freep}% free, below the ${EXA_POOL_FREE_PCT}% needed to rebalance after a disk failure"
    fi
    [ "$raw" -gt 0 ] && [ "$prov" -gt "$raw" ] 2>/dev/null && finding WARN pool "$n ($m): vaults are provisioned $(human "$prov") on a pool of $(human "$raw") (over-provisioned: a vault that looks fine can still hit a full pool)"
    printf '%s\n' "$ds $rs" | grep -qiE 'degraded|offline|rebalanc|resync|error' && finding WARN pool "$n: data/reco ring status $ds / $rs"
  done < <(records "$RAW/pools.txt")
  kv_end
  es_section pooldisks "Pool disks (status only)" lspooldisk -l
  grep -qiE 'status[[:space:]]+(offline|failed|predictive|error|warning)' "$RAW/pooldisks.txt" && finding CRIT pool "pool disk(s) not normal: $(grep -iE 'offline|failed|predictive|error' "$RAW/pooldisks.txt" | head -3 | tr '\n' ';')"
  es_raw poolops lsstoragepooloperation --detail && grep -qiE 'state[[:space:]]+(running|in.?progress|queued)' "$RAW/poolops.txt" && finding INFO pool "a storage pool operation (rebalance/resize) is running - free space moves while it does (raw/poolops.txt)"
  return 0
}

collect_vaults() {
  say "vaults"; h1 "Vaults"
  es_raw vaults lsvault --detail || { para "_lsvault failed: see raw/vaults.txt_"; finding WARN escli "lsvault failed: $(head -2 "$RAW/vaults.txt" | tail -1)"; return 0; }
  para "Used vs provisioned per media type (HC = disk, EF = flash, XT = extended). \`unlimited\` means the vault is bounded only by the pool, so look at the pool row. Days to full come from this script's own daily history (\`$EXA_HISTORY\`); run it from cron for a real slope."
  table_head "vault" "media" "used" "provisioned" "%" "bytes/day" "days to full" "points" "flags"
  local r; while IFS= read -r r; do
    [ -n "$r" ] || continue
    local n fl; n="$(attr "$r" name)"; [ -n "$n" ] || continue; [ -n "$ONLY_VAULT" ] && [ "$n" != "$ONLY_VAULT" ] && continue
    fl="$(attr "$r" flags)"
    local uhc phc uef pef uxt pxt; uhc="$(to_bytes "$(attr "$r" spaceUsedHC)")"; phc="$(to_bytes "$(attr "$r" spaceProvHC)")"; uef="$(to_bytes "$(attr "$r" spaceUsedEF)")"; pef="$(to_bytes "$(attr "$r" spaceProvEF)")"; uxt="$(to_bytes "$(attr "$r" spaceUsedXT)")"; pxt="$(to_bytes "$(attr "$r" spaceProvXT)")"
    VAULTS="${VAULTS}$n|$uhc|$phc|$uef|$pef|$uxt|$pxt"$'\n'
    local m; for m in HC EF XT; do
      local u p; case $m in HC) u=$uhc; p=$phc;; EF) u=$uef; p=$pef;; XT) u=$uxt; p=$pxt;; esac
      [ "$u" = 0 ] && [ "$p" = 0 ] && continue
      [ "$u" = 0 ] && [ "$p" = unlimited ] && continue
      track vault "@$n/$m" "$u" "$p"
      local t; t="$(printf '%s' "$TRACK" | grep "^vault|@$n/$m|" | tail -1)"
      table_row "@$n" "$m" "$(human "$u")" "$(human "$p")" "$(echo "$t" | cut -d'|' -f5)" "$(human "$(echo "$t" | cut -d'|' -f6)")" "$(echo "$t" | cut -d'|' -f7)" "$(echo "$t" | cut -d'|' -f8)" "${fl:-}"
    done
    [ -n "$fl" ] && printf '%s' "$fl" | grep -qi being_deleted && finding INFO vault "@$n is being deleted: its space comes back when the deletion finishes"
  done < <(records "$RAW/vaults.txt")
  kv_end
  # 26.1+: provisioning per pool (a vault can draw from several pools of the same media type)
  if [ "$ES_MULTIPOOL" = 1 ]; then
    h2 "Provisioning per storage pool (lsvault --provision)"
    local v; for v in $(vault_names); do es_raw "vault_${v}_provision" lsvault "@$v" --provision || continue; fence_start; cat "$RAW/vault_${v}_provision.txt" >>"$REPORT"; fence_end
      [ "$(records_tab "$RAW/vault_${v}_provision.txt" | wc -l | tr -d ' ')" -gt 1 ] && while IFS='|' read -r pool sp su rest; do   # no pipe: finding() must run in this shell
        [ -n "$pool" ] && [ "$sp" != unlimited ] && [ "$(pct "$(to_bytes "$su")" "$(to_bytes "$sp")")" != "-" ] && [ "$(pct "$(to_bytes "$su")" "$(to_bytes "$sp")")" -ge "$EXA_WARN_PCT" ] && finding WARN vault "@$v on pool $pool: $su of $sp used"; done < <(records_tab "$RAW/vault_${v}_provision.txt")
    done
  fi
  return 0
}
vault_names() { printf '%s' "$VAULTS" | cut -d'|' -f1 | grep .; }
# tabular (-l / --provision) output -> id|col2|col3... using the header line for width-independent splitting
records_tab() { awk 'NR==1 && $1=="$" {next} /^[[:space:]]*$/ {next} $1=="id" || $1=="name" || $1=="createTime" {next} /\[exit/ {next} { out=$1; for (i=2;i<=NF;i++) out=out "|" $i; print out }' "$1"; }

# files in a vault: three ways to ask escli, the first that returns rows wins
list_files() { # <vault> -> raw/files_<vault>.txt (--detail records)
  local v="$1"; local f="$RAW/files_$v.txt"
  es_raw "files_$v" lsfile "@$v/*" --detail --include-being-deleted && grep -qE '^[[:space:]]*name[[:space:]]' "$f" && return 0
  es_raw "files_$v" lsfile --detail --include-being-deleted --filter "vault.name=$v" && grep -qE '^[[:space:]]*name[[:space:]]' "$f" && return 0
  es_raw "files_$v" ls "@$v/" -l; return 1
}
collect_files() {
  [ "$NO_FILES" = 1 ] && { para "_per-file listing skipped (--no-files)_"; return 0; }
  local v; for v in $(vault_names); do
    say "files in @$v"; h2 "@$v: what is in it"
    if ! list_files "$v"; then para "_escli did not return per-file attributes for @$v (raw/files_$v.txt has the plain listing); the database side (V\$EXA_FILE) below is the breakdown_"; continue; fi
    local r now; now="$(date +%s)"
    while IFS= read -r r; do
      [ -n "$r" ] || continue
      local p ft sz su ub ct fl sn mt; p="$(attr "$r" name)"; [ -n "$p" ] || continue
      ft="$(attr "$r" fileType)"; sz="$(to_bytes "$(attr "$r" size)")"; su="$(to_bytes "$(attr "$r" spaceUsed)")"; ub="$(attr "$r" usedBy)"; ct="$(attr "$r" createTime)"; fl="$(attr "$r" flags)"; sn="$(attr "$r" snapLockStatus)"; mt="$(attr "$r" mediaType)"
      [ -z "$sn" ] && [ -n "$(attr "$r" snapLockExpiryTime)" ] && sn=locked
      FILES="${FILES}$v|$p|${ft:-?}|$sz|$su|${ub:-}|${ct:-}|${fl:-}|${sn:-}|${mt:-}"$'\n'
    done < <(records "$RAW/files_$v.txt")
    local rows; rows="$(printf '%s' "$FILES" | grep -c "^$v|")"
    [ "$rows" = 0 ] && { para "_no files_"; continue; }
    { echo "vault,path,fileType,size_bytes,spaceUsed_bytes,usedBy,createTime,flags,snapLock,mediaType"; printf '%s' "$FILES" | grep "^$v|" | tr '|' ','; } >"$RAW/files_$v.csv"
    h3 "@$v by file type"; table_head "fileType" "files" "size" "space used"
    printf '%s' "$FILES" | grep "^$v|" | awk -F'|' '{ n[$3]++; s[$3]+=$4; u[$3]+=$5 } END { for (k in n) printf "%s|%d|%d|%d\n", k, n[k], s[k], u[k] }' | sort -t'|' -k4,4nr | while IFS='|' read -r k n s u; do table_row "$k" "$n" "$(human "$s")" "$(human "$u")"; done; kv_end
    h3 "@$v by database (usedBy)"; table_head "usedBy" "files" "size" "space used"
    printf '%s' "$FILES" | grep "^$v|" | awk -F'|' '{ k=($6==""?"(none)":$6); n[k]++; s[k]+=$4; u[k]+=$5 } END { for (k in n) printf "%s|%d|%d|%d\n", k, n[k], s[k], u[k] }' | sort -t'|' -k4,4nr | while IFS='|' read -r k n s u; do table_row "$k" "$n" "$(human "$s")" "$(human "$u")"; done; kv_end
    h3 "@$v by top-level path"; table_head "path" "files" "space used"
    printf '%s' "$FILES" | grep "^$v|" | awk -F'|' '{ p=$2; sub(/^@[^\/]*\//,"",p); split(p,a,"/"); k=(length(a)>1?a[1]:"(root)"); n[k]++; u[k]+=$5 } END { for (k in n) printf "%s|%d|%d\n", k, n[k], u[k] }' | sort -t'|' -k3,3nr | head -40 | while IFS='|' read -r k n u; do table_row "$k" "$n" "$(human "$u")"; done; kv_end
    h3 "@$v biggest files"; table_head "space used" "size" "type" "usedBy" "created" "path"
    printf '%s' "$FILES" | grep "^$v|" | sort -t'|' -k5,5nr | head -"$TOP" | while IFS='|' read -r _ p ft sz su ub ct _; do table_row "$(human "$su")" "$(human "$sz")" "$ft" "${ub:-}" "${ct:-}" "\`$p\`"; done; kv_end
    # findings
    local bd bdsz; bd="$(printf '%s' "$FILES" | grep "^$v|" | awk -F'|' 'tolower($8) ~ /delet/ {n++; s+=$5} END{print n+0, s+0}')"; read -r bd bdsz <<<"$bd"
    [ "$bd" -gt 0 ] && finding INFO files "@$v: $bd file(s) still being deleted hold $(human "$bdsz") - that space comes back by itself; do not re-delete"
    local sn snsz; sn="$(printf '%s' "$FILES" | grep "^$v|" | awk -F'|' '$9!="" {n++; s+=$5} END{print n+0, s+0}')"; read -r sn snsz <<<"$sn"
    [ "$sn" -gt 0 ] && finding INFO files "@$v: $sn snapshot file(s) with a lock hold $(human "$snsz") (lssnapshots shows their sources; a locked snapshot cannot be removed before snapLockExpiryTime)"
    local cutoff; cutoff="$(days_ago "$EXA_ORPHAN_DAYS")"
    local orph orphsz; orph="$(printf '%s' "$FILES" | grep "^$v|" | awk -F'|' -v c="$cutoff" '$6=="" && $9=="" && tolower($8) !~ /delet/ && substr($7,1,10)<c {n++; s+=$5} END{print n+0, s+0}')"; read -r orph orphsz <<<"$orph"
    [ "$orph" -gt 0 ] && [ "$orphsz" -gt 1073741824 ] && finding WARN files "@$v: $orph file(s) older than $EXA_ORPHAN_DAYS days that no database claims (usedBy empty) hold $(human "$orphsz") - \`plan\` lists them; check them against every database (a closed database still owns its files) before \`release\`"
    local arch archsz; arch="$(printf '%s' "$FILES" | grep "^$v|" | awk -F'|' -v c="$(days_ago "${ARCH_DAYS:-$EXA_ARCH_DAYS}")" 'toupper($3)=="ARCHIVELOG" && substr($7,1,10)<c {n++; s+=$5} END{print n+0, s+0}')"; read -r arch archsz <<<"$arch"
    [ "$arch" -gt 0 ] && [ "$archsz" -gt 10737418240 ] && finding WARN files "@$v: $arch archivelog(s) older than ${ARCH_DAYS:-$EXA_ARCH_DAYS} day(s) hold $(human "$archsz") - once backed up they can go: \`purge-archivelogs\`"
    local bk bksz; bk="$(printf '%s' "$FILES" | grep "^$v|" | awk -F'|' 'toupper($3) ~ /BACKUP|FLASHBACK|DUMP/ {n++; s+=$5} END{print n+0, s+0}')"; read -r bk bksz <<<"$bk"
    [ "$bk" -gt 0 ] && finding INFO files "@$v: $bk backup/flashback/dump file(s) hold $(human "$bksz") (RMAN report obsolete / flashback retention decide what can go)"
  done
  return 0
}

collect_volumes() {
  say "volumes"; h1 "Block volumes (EDV / ACFS) and volume snapshots"
  es_raw volumes lsvolume --detail || { para "_lsvolume: $(sed -n 2p "$RAW/volumes.txt")_"; return 0; }
  table_head "volume" "name" "vault" "size" "space used" "state" "acfs" "snapshots"
  local r; while IFS= read -r r; do
    [ -n "$r" ] || continue
    local id n v sz su st fs ns; id="$(attr "$r" id)"; n="$(attr "$r" name)"; v="$(attr "$r" vault)"; sz="$(to_bytes "$(attr "$r" size)")"; su="$(to_bytes "$(attr "$r" spaceUsed)")"; st="$(attr "$r" state)"; fs="$(attr "$r" acfsFileSystem)"; ns="$(attr "$r" numSnapshots)"
    [ -n "$id$n" ] || continue
    VOLS="${VOLS}$id|$n|$v|$sz|$su|$st|$fs|${ns:-0}"$'\n'
    table_row "${id:-?}" "${n:-}" "@${v:-?}" "$(human "$sz")" "$(human "$su")" "${st:-}" "${fs:-}" "${ns:-0}"
    [ "${ns:-0}" -gt 10 ] 2>/dev/null && finding INFO volume "volume ${n:-$id} has $ns snapshots - each keeps the blocks it froze (lsvolumesnapshot --detail)"
    printf '%s' "$st" | grep -qi deleting && finding INFO volume "volume ${n:-$id} is DELETING: space returns when it finishes"
  done < <(records "$RAW/volumes.txt")
  kv_end
  es_raw volsnaps lsvolumesnapshot --detail && { local vs vssz; vs="$(records "$RAW/volsnaps.txt" | awk -F'\t' '{ for(i=1;i<=NF;i++) if ($i ~ /^spaceUsed=/) { split($i,a,"="); s+=a[2]+0 } n++ } END{print n+0}')"
    [ "$vs" -gt 0 ] && { h3 "Volume snapshots"; fence_start; head -n "$DIAG_LINES" "$RAW/volsnaps.txt" >>"$REPORT"; fence_end; finding INFO volume "$vs volume snapshot(s) exist (raw/volsnaps.txt); volume snapshots keep every block the volume has overwritten since"; }; }
  es_raw acfs lsacfsfilesystem --detail && grep -qE '^[[:space:]]*(name|mountPoint)' "$RAW/acfs.txt" && { h3 "ACFS file systems on Exascale volumes"; fence_start; head -n "$DIAG_LINES" "$RAW/acfs.txt" >>"$REPORT"; fence_end; }
  return 0
}

collect_alerts() {
  es_raw alerts lsclusteralert -l || return 0
  h2 "Cluster alerts (lsclusteralert)"; fence_start; tail -n 60 "$RAW/alerts.txt" >>"$REPORT"; fence_end
  grep -qiE 'space|full|capacity|quota' "$RAW/alerts.txt" && finding WARN escli "cluster alert(s) mention space/capacity: $(grep -iE 'space|full|capacity|quota' "$RAW/alerts.txt" | tail -2 | cut -c1-160 | tr '\n' ';')"
  return 0
}

# database side: what each running instance sees of the vault, FRA on the vault, PDB thin clones
collect_db() {
  local sid="$1"; say "database $sid"; h2 "Database $sid"
  sql_ok "$sid" || { finding WARN db "$sid: cannot connect as sysdba (SQL_CONNECT?)"; para "_cannot connect_"; return 0; }
  local onexa; onexa="$(sql_val "$sid" "(select count(*) from v\$parameter where name in ('db_create_file_dest','db_recovery_file_dest','db_create_online_log_dest_1','db_create_online_log_dest_2') and value like '@%')" 2>/dev/null)"
  local nfiles; nfiles="$(sql_val "$sid" "(select count(*) from v\$datafile where name like '@%')" 2>/dev/null)"
  # unreadable is not 'not on Exascale': both counts empty used to skip the database side in silence
  if [ -z "$onexa" ] || [ -z "$nfiles" ]; then finding WARN db "$sid: could not read v\$parameter / v\$datafile - cannot tell whether this database is on Exascale (its vault use is not in this report)"; para "_$sid: v\$parameter / v\$datafile unreadable - database side skipped_"; return 0; fi
  if [ "$onexa" = 0 ] && [ "$nfiles" = 0 ]; then para "_$sid: no file destination or datafile starts with @vault - not on Exascale (or V\$EXA_* not available in this release)_"; return 0; fi
  sqlsec "$sid" params "$sid: file destinations" "select name, value from v\$parameter where name in ('db_create_file_dest','db_recovery_file_dest','db_recovery_file_dest_size','db_create_online_log_dest_1','db_create_online_log_dest_2','log_archive_dest_1','db_unique_name','compatible') order by 1;"
  sqlsec "$sid" vault "$sid: V\$EXA_VAULT (what the database sees of its vaults)" "select vault_name, round(hc_space_used/1073741824) hc_used_gb, decode(hc_space_prov,null,'unlimited',round(hc_space_prov/1073741824)) hc_prov_gb, round(ef_space_used/1073741824) ef_used_gb, decode(ef_space_prov,null,'unlimited',round(ef_space_prov/1073741824)) ef_prov_gb, round(xt_space_used/1073741824) xt_used_gb, round(flash_cache_prov/1073741824) fc_prov_gb from v\$exa_vault;"
  sqlsec "$sid" files "$sid: V\$EXA_FILE by vault, container and file type" "select vault_name, con_id, file_type, media_type, count(*) files, round(sum(size_in_bytes)/1073741824,1) size_gb, round(sum(space_used)/1073741824,1) space_used_gb from v\$exa_file group by vault_name, con_id, file_type, media_type order by 7 desc;
select vault_name, used_by, round(sum(space_used)/1073741824,1) space_used_gb, count(*) files from v\$exa_file group by vault_name, used_by order by 3 desc;
select * from (select full_path, file_type, round(size_in_bytes/1073741824,1) size_gb, round(space_used/1073741824,1) used_gb, create_time from v\$exa_file order by space_used desc) where rownum<=$TOP;"
  sqlsec "$sid" fra "$sid: recovery area on the vault (reclaimable = RMAN can delete it when the vault is full)" "select name dest, round(space_limit/1073741824) limit_gb, round(space_used/1073741824) used_gb, round(space_reclaimable/1073741824) reclaimable_gb, round((space_used-space_reclaimable)*100/nullif(space_limit,0)) pct_not_reclaimable, number_of_files from v\$recovery_file_dest;
select file_type, percent_space_used, percent_space_reclaimable, number_of_files from v\$recovery_area_usage where number_of_files>0 order by 2 desc;
select 'archivelogs on disk not yet backed up: '||count(*)||' ('||round(nvl(sum(blocks*block_size),0)/1073741824,1)||' GB), oldest '||to_char(min(first_time),'YYYY-MM-DD HH24:MI') from v\$archived_log a where a.dest_id=1 and a.deleted='NO' and a.standby_dest='NO' and a.backup_count=0;
select 'archivelogs on disk already backed up '||$EXA_ARCH_BACKED_UP||'+ times: '||count(*)||' ('||round(nvl(sum(blocks*block_size),0)/1073741824,1)||' GB), oldest '||to_char(min(first_time),'YYYY-MM-DD HH24:MI') from v\$archived_log a where a.dest_id=1 and a.deleted='NO' and a.standby_dest='NO' and a.backup_count>=$EXA_ARCH_BACKED_UP;
select 'flashback: '||(select flashback_on from v\$database)||', retention '||(select value from v\$parameter where name='db_flashback_retention_target')||' min, oldest flashback '||(select to_char(min(oldest_flashback_time),'YYYY-MM-DD HH24:MI') from v\$flashback_database_log)||', flashback size '||(select round(sum(flashback_size)/1073741824,1) from v\$flashback_database_log)||' GB' from dual;
select 'guaranteed restore points: '||listagg(name||' '||to_char(time,'YYYY-MM-DD')||' '||round(storage_size/1073741824)||'GB', ', ') within group (order by time) from v\$restore_point where guarantee_flashback_database='YES';"
  sqlsec "$sid" clones "$sid: PDB snapshot copies (thin clones: each diverging block is new vault space)" "select p.con_id, p.name, p.open_mode, p.snapshot_parent_con_id parent_con, (select name from v\$pdbs x where x.con_id=p.snapshot_parent_con_id) parent, round(p.total_size/1073741824) total_gb, p.creation_time from v\$pdbs p where p.snapshot_parent_con_id is not null order by 1;
select 'pdb snapshots (dba_pdb_snapshots): '||count(*) from dba_pdb_snapshots;"
  sql_checks "$sid" "$sid" "select 'CHECK|WARN|recovery area '||round((space_used-space_reclaimable)*100/nullif(space_limit,0))||'% used and not reclaimable of '||round(space_limit/1073741824)||' GB (db_recovery_file_dest_size)' from v\$recovery_file_dest where (space_used-space_reclaimable)*100/nullif(space_limit,0)>=$EXA_WARN_PCT;
select 'CHECK|INFO|recovery area holds '||round(space_reclaimable/1073741824)||' GB RMAN may delete (reclaimable) - it does so only when the recovery area itself is full, not when the vault is' from v\$recovery_file_dest where space_reclaimable>10737418240;
select 'CHECK|WARN|'||count(*)||' archivelog(s) on disk not backed up ('||round(sum(blocks*block_size)/1073741824)||' GB) - run the archivelog backup before purging anything' from v\$archived_log where dest_id=1 and deleted='NO' and standby_dest='NO' and backup_count=0 and first_time<sysdate-1 having count(*)>0;
select 'CHECK|INFO|'||count(*)||' archivelog(s) backed up '||$EXA_ARCH_BACKED_UP||'+ times still on the vault ('||round(sum(blocks*block_size)/1073741824)||' GB): purge-archivelogs frees them' from v\$archived_log where dest_id=1 and deleted='NO' and standby_dest='NO' and backup_count>=$EXA_ARCH_BACKED_UP having sum(blocks*block_size)>10737418240;
select 'CHECK|WARN|guaranteed restore point '||name||' from '||to_char(time,'YYYY-MM-DD')||' holds '||round(storage_size/1073741824)||' GB of flashback logs that can never be reclaimed while it exists' from v\$restore_point where guarantee_flashback_database='YES' and time<sysdate-7;
select 'CHECK|INFO|'||count(*)||' PDB snapshot copies (thin clones) exist - Oracle sizes 20-25% of the parent per updateable clone' from v\$pdbs where snapshot_parent_con_id is not null having count(*)>0;
select 'CHECK|WARN|'||count(*)||' datafile(s) at their autoextend maximum' from dba_data_files where autoextensible='YES' and maxbytes>0 and bytes>=maxbytes*0.99 having count(*)>0;
select 'CHECK|WARN|'||count(*)||' datafile(s) with autoextend OFF in '||listagg(distinct tablespace_name, ',') within group (order by tablespace_name) from dba_data_files where autoextensible='NO' having count(*)>0;"
  return 0
}

write_summary() {
  h1 "Summary table (history: $EXA_HISTORY/$HOST)"
  table_head "kind" "object" "used" "max" "%" "bytes/day" "days to full" "points"
  printf '%s' "$TRACK" | while IFS='|' read -r k l u m p s d n; do [ -n "$k" ] && table_row "$k" "$l" "$(human "$u")" "$(human "$m")" "$p" "$(human "$s")" "$d" "$n"; done; kv_end
  { echo "kind,object,used_bytes,max_bytes,pct,bytes_per_day,days_to_full,points"; printf '%s' "$TRACK" | tr '|' ','; } >"$RAW/summary.csv"
  [ -n "$POOLS" ] && { echo "pool,mediaType,raw,used,provisionable,provisioned,dataStatus,recoStatus"; printf '%s' "$POOLS" | tr '|' ','; } >"$RAW/pools.csv"
  [ -n "$VAULTS" ] && { echo "vault,usedHC,provHC,usedEF,provEF,usedXT,provXT"; printf '%s' "$VAULTS" | tr '|' ','; } >"$RAW/vaults.csv"
}

escli_setup() { # sets ESCLI or explains why not; returns 1 when the database side is all we have
  [ "$NO_ESCLI" = 1 ] && return 1
  escli_find || { finding INFO escli "escli not found on this host (ESCLI= in the conf to point at it); database side only"; return 1; }
  es_ok || { finding WARN escli "escli cannot reach Exascale: $(printf '%s' "$ES_ERR" | head -1 | cut -c1-160) (EXA_WALLET / EXA_CTRL in the conf; wallet search: \$OSSCONF/eswallet, \$ORACLE_BASE/admin/eswallet, /etc/oracle/cell/network-config/eswallet)"; return 1; }
  return 0
}
# the database list: lib db_instances returns 1 when the process list cannot be read (b728ff6) - that is 'unknown', never 'none
# running'. inspect and plan say so as a CRIT (exit 2), purge-archivelogs/heal refuse; --sid names the target and needs no list.
ps_unreadable_msg() { printf '%s' "cannot read the process list (ps failed, $PROC_DIR unreadable) - no database was found or checked; pass --sid to name one"; }
db_sids() { # sets SIDS; status 1 = the process list could not be read and no --sid names a database
  SIDS=""; [ -n "$ONLY_SID" ] && { SIDS="$ONLY_SID"; return 0; }
  local l; l="$(db_instances)" || return 1
  SIDS="$(printf '%s\n' "$l" | grep -vE '^\+ASM|^-MGMTDB|^\+APX')" || true
}

cmd_inspect() {
  report_init "$EXA_OUT/${HOST}_$(date '+%Y%m%d_%H%M%S')"
  say "exascale-space $VERSION -> $OUT"
  h1 "Environment"; kv host "$HOST"; kv user "$(id -un)"
  if escli_setup; then
    kv escli "$ESCLI"; kv "Exascale software" "${ES_VERSION:-?}"; kv wallet "${EXA_WALLET:-escli default search path}"; kv "multi-pool provisioning (26.1+)" "$ES_MULTIPOOL"; kv_end
    es_section cluster "Cluster" lscluster --detail
    collect_pools; collect_vaults; collect_files; collect_volumes; collect_alerts
  else
    kv escli "not available (database side only)"; kv_end
  fi
  if [ "$NO_DB" = 0 ]; then
    h1 "Database side"
    local s; if db_sids; then
      [ -n "$SIDS" ] || para "_no running database instance on this host_"
      for s in $SIDS; do collect_db "$s"; done
    else finding CRIT db "$(ps_unreadable_msg)"; para "_$(ps_unreadable_msg)_"; fi
  fi
  findings_sync; write_summary
  h1 "What to do when a vault is full (the short version)"
  para "1. \`$TOOL.sh plan\` shows, with sizes, what can go: archivelogs already backed up (\`purge-archivelogs\`), reclaimable recovery-area files, obsolete backups, files no database claims, snapshots past their lock, thin clones that have diverged.
2. If the pool still has provisionable space, grow the vault: \`$TOOL.sh grow <vault> --hc +2T\` (chvault; rollback puts the old value back).
3. If the pool itself is full, nothing in escli helps: delete data, add cells, or move a database to another pool. Keep ${EXA_POOL_FREE_PCT}% of the pool free or a disk failure cannot rebalance.
4. Files being deleted release their space in the background; wait before deleting more. Deleting a snapshot source does not free space while snapshots or clones still reference its blocks (\`lssnapshots <file> --tree\`)."
  report_finish "exascale-space: $HOST $TODAY" "$MAKE_TAR" >/dev/null
  print_findings; printf '\n%s\n' "$OUT/REPORT.md"
  findings_rc
}

# ---------------------------------------------------------------------------
# plan: what could be freed or grown, read-only
# ---------------------------------------------------------------------------
cmd_plan() {
  QUIET=1; local saved_tar="$MAKE_TAR"; MAKE_TAR=0
  report_init "$EXA_OUT/${HOST}_plan_$(date '+%Y%m%d_%H%M%S')"
  local have_es=0; escli_setup && have_es=1
  if [ "$have_es" = 1 ]; then collect_pools >/dev/null; collect_vaults >/dev/null; collect_files >/dev/null; fi
  echo; echo "exascale-space plan  ($HOST, $(date '+%Y-%m-%d %H:%M'))"; echo
  local v; for v in $(vault_names); do
    echo "== @$v"
    local row; row="$(printf '%s' "$VAULTS" | grep "^$v|")"
    local uhc phc; uhc="$(echo "$row" | cut -d'|' -f2)"; phc="$(echo "$row" | cut -d'|' -f3)"
    echo "   HC used $(human "$uhc") of $(human "$phc") ($(pct "$uhc" "$phc")%)"
    # grow
    local m; for m in HC EF XT; do
      local pool prow able; pool="$(printf '%s' "$POOLS" | awk -F'|' -v m="$m" '$2==m {print $1; exit}')"; [ -n "$pool" ] || continue
      prow="$(printf '%s' "$POOLS" | grep "^$pool|")"; able="$(echo "$prow" | cut -d'|' -f5)"
      local used prov; case $m in HC) used="$(echo "$row" | cut -d'|' -f2)"; prov="$(echo "$row" | cut -d'|' -f3)";; EF) used="$(echo "$row" | cut -d'|' -f4)"; prov="$(echo "$row" | cut -d'|' -f5)";; XT) used="$(echo "$row" | cut -d'|' -f6)"; prov="$(echo "$row" | cut -d'|' -f7)";; esac
      [ "$used" = 0 ] && [ "$prov" = 0 ] && continue
      if [ "$prov" = unlimited ]; then echo "   $m: provisioning is unlimited - the limit is pool $pool ($(human "$(echo "$prow" | cut -d'|' -f4)") used of $(human "$(echo "$prow" | cut -d'|' -f3)") raw)"
      elif [ "${able:-0}" -gt 0 ] 2>/dev/null; then
        local want; want="$(awk -v p="$prov" 'BEGIN{ printf "%.0f", p*1.25 }')"; [ "$want" -gt "$((prov+able))" ] && want="$((prov+able))"
        echo "   $m: pool $pool has $(human "$able") provisionable -> grow:  $TOOL.sh grow $v --${m,,} $(awk -v w="$want" 'BEGIN{ if (w>=1099511627776) printf "%.1fT", w/1099511627776; else printf "%.0fG", w/1073741824 }') $([ "$ES_MULTIPOOL" = 1 ] && echo "--pool $pool")"
      else echo "   $m: pool $pool has nothing left to provision ($(human "$(echo "$prow" | cut -d'|' -f6)") provisioned of $(human "$(echo "$prow" | cut -d'|' -f3)") raw) - free space or add storage"; fi
    done
    # what could go
    if printf '%s' "$FILES" | grep -q "^$v|"; then
      local c; c="$(days_ago "${ARCH_DAYS:-$EXA_ARCH_DAYS}")"
      printf '%s' "$FILES" | grep "^$v|" | awk -F'|' -v c="$c" 'toupper($3)=="ARCHIVELOG" && substr($7,1,10)<c {n++; s+=$5} END{ if (n) printf "   archivelogs older than %s: %d files, %.1f GB  ->  %s purge-archivelogs   (RMAN deletes only what it has backed up)\n", c, n, s/1073741824, "'"$TOOL.sh"'" }'
      printf '%s' "$FILES" | grep "^$v|" | awk -F'|' 'toupper($3) ~ /BACKUP|FLASHBACK/ {n++; s+=$5} END{ if (n) printf "   backup/flashback files: %d, %.1f GB  ->  rman: report obsolete; delete obsolete  (or shorten flashback retention / drop old guaranteed restore points)\n", n, s/1073741824 }'
      printf '%s' "$FILES" | grep "^$v|" | awk -F'|' 'tolower($8) ~ /delet/ {n++; s+=$5} END{ if (n) printf "   being deleted: %d files, %.1f GB  ->  wait; this comes back on its own\n", n, s/1073741824 }'
      printf '%s' "$FILES" | grep "^$v|" | awk -F'|' '$9!="" {n++; s+=$5} END{ if (n) printf "   locked snapshots: %d, %.1f GB  ->  escli lssnapshots <file> --tree; unlock with chfile <snap> --attributes snapLockExpiryTime=null when not immutable, then rmfile\n", n, s/1073741824 }'
      local oc; oc="$(days_ago "$EXA_ORPHAN_DAYS")"
      local orph; orph="$(printf '%s' "$FILES" | grep "^$v|" | awk -F'|' -v c="$oc" '$6=="" && $9=="" && tolower($8) !~ /delet/ && substr($7,1,10)<c')"
      if [ -n "$orph" ]; then
        echo "   files no database claims (usedBy empty, older than $EXA_ORPHAN_DAYS days): $(printf '%s\n' "$orph" | wc -l | tr -d ' ') files, $(human "$(printf '%s\n' "$orph" | awk -F'|' '{s+=$5} END{print s+0}')")"
        echo "   CHECK EACH ONE against every database first (select name from v\$datafile/v\$logfile/v\$controlfile/v\$tempfile, rman list backup) - a closed database still owns its files. Then:"
        printf '%s\n' "$orph" | sort -t'|' -k5,5nr | head -"$TOP" | while IFS='|' read -r _ p ft sz su _ ct _; do printf '      %-10s %-12s %s   %s\n' "$(human "$su")" "$ft" "$ct" "$p"; done
        printf '%s\n' "$orph" | awk -F'|' '{print $2}' >"$OUT/orphan-candidates.txt"
        echo "   list saved to $OUT/orphan-candidates.txt  ->  review, delete lines, then: $TOOL.sh release --list $OUT/orphan-candidates.txt"
      fi
    fi
    echo
  done
  [ "$have_es" = 0 ] && echo "escli not usable here ($(print_findings 'CRIT|WARN|INFO' | grep escli | head -1)); database-side plan only" && echo
  local dbrc=0
  if [ "$NO_DB" = 0 ]; then
    local s; if db_sids; then for s in $SIDS; do
      sql_ok "$s" || continue
      [ "$(sql_val "$s" "(select count(*) from v\$datafile where name like '@%')" 2>/dev/null)" = 0 ] && continue
      echo "== database $s"
      sql_lines "$s" "select 'recovery area: '||round(space_used/1073741824)||' GB used, '||round(space_reclaimable/1073741824)||' GB reclaimable of '||round(space_limit/1073741824)||' GB' from v\$recovery_file_dest;
select 'archivelogs backed up $EXA_ARCH_BACKED_UP+ times still on disk: '||count(*)||' ('||round(nvl(sum(blocks*block_size),0)/1073741824,1)||' GB)' from v\$archived_log where dest_id=1 and deleted='NO' and standby_dest='NO' and backup_count>=$EXA_ARCH_BACKED_UP;
select 'archivelogs NOT backed up: '||count(*)||' ('||round(nvl(sum(blocks*block_size),0)/1073741824,1)||' GB) - back them up first' from v\$archived_log where dest_id=1 and deleted='NO' and standby_dest='NO' and backup_count=0;
select 'guaranteed restore point '||name||' ('||to_char(time,'YYYY-MM-DD')||'): '||round(storage_size/1073741824)||' GB  ->  drop restore point '||name||';' from v\$restore_point where guarantee_flashback_database='YES';
select 'thin clone PDB '||name||' from con_id '||snapshot_parent_con_id||' ('||round(total_size/1073741824)||' GB)  ->  drop it or materialise it when the test is over' from v\$pdbs where snapshot_parent_con_id is not null;" 2>/dev/null | sed 's/^/   /'
      echo "   -> $TOOL.sh purge-archivelogs --sid $s --days ${ARCH_DAYS:-$EXA_ARCH_DAYS}$([ "$DO_OBSOLETE" = 1 ] && echo ' --obsolete')     (RMAN: delete noprompt archivelog all completed before 'sysdate-${ARCH_DAYS:-$EXA_ARCH_DAYS}' backed up $EXA_ARCH_BACKED_UP times to device type $EXA_ARCH_DEVICE)"
      echo
    done
    else echo "== databases: $(ps_unreadable_msg) - nothing is planned for the database side"; echo; finding CRIT db "$(ps_unreadable_msg)"; dbrc=2; fi
  fi
  MAKE_TAR="$saved_tar"; report_finish "exascale-space plan: $HOST $TODAY" 0 >/dev/null
  echo "details: $OUT/REPORT.md"; return "$dbrc"
}

# ---------------------------------------------------------------------------
# grow: chvault with the old value saved for rollback
# ---------------------------------------------------------------------------
vault_attr() { local r; r="$(es lsvault "@$1" --detail 2>/dev/null | records -)"; attr "$r" "$2"; }
# rman_run comes from lib/oracle-lib.sh (same wrapper as rman-ops)
size_arg() { # <current bytes|unlimited> <spec: 10T | +2T | 2000G> -> bytes
  local cur="$1" spec="$2"
  case "$spec" in +*) [ "$cur" = unlimited ] && die "the vault is unlimited: give an absolute size, not +$spec"; echo $((cur + $(to_bytes "${spec#+}")));; unlimited) echo unlimited;; *) to_bytes "$spec";; esac
}
cmd_grow() {
  local v="${ARGS[0]:-}"; v="${v#@}"; [ -n "$v" ] || die "grow <vault> --hc SIZE | --ef SIZE | --xt SIZE [--pool NAME]"
  [ -n "$GROW_HC$GROW_EF$GROW_XT" ] || die "give --hc, --ef or --xt with a size (10T, 2000G, +2T, unlimited)"
  init_run_dir "grow-$v"; escli_setup || die "escli is needed for grow"
  RAW="$RUN_DIR/raw"; REPORT="$RUN_DIR/preflight.md"; FINDINGS_FILE="$RUN_DIR/findings.txt"; mkdir -p "$RAW"
  es lsvault "@$v" --attributes name 2>/dev/null | grep -q . || die "vault @$v not found (escli lsvault)"
  collect_pools >/dev/null 2>&1 || true
  # 26.1+: the vault draws from named pools; current value and target come from lsvault --provision
  local provrows=""; [ "$ES_MULTIPOOL" = 1 ] && es_raw grow_provision lsvault "@$v" --provision >/dev/null 2>&1 && provrows="$(records_tab "$RAW/grow_provision.txt")"
  local m spec; for m in HC EF XT; do
    case $m in HC) spec="$GROW_HC";; EF) spec="$GROW_EF";; XT) spec="$GROW_XT";; esac; [ -n "$spec" ] || continue
    local a="spaceProv$m" cur new pool mode=attributes
    pool="$GROW_POOL"
    if [ -n "$provrows" ]; then
      [ -n "$pool" ] || pool="$(printf '%s\n' "$provrows" | awk -F'|' -v m="$m" '$7==m {print $1; exit}')"
      local prow0; prow0="$(printf '%s\n' "$provrows" | awk -F'|' -v p="$pool" '$1==p' | head -1)"
      [ -n "$prow0" ] && { mode=provision; cur="$(to_bytes "$(echo "$prow0" | cut -d'|' -f2)")"; }
    fi
    if [ "$mode" = attributes ]; then local curtxt; curtxt="$(vault_attr "$v" "$a")"; [ -n "$curtxt" ] || die "cannot read $a of @$v from escli: refusing to compute a new size from 0 (a '+2T' request would become 2T)"; cur="$(to_bytes "$curtxt")"; fi
    [ -n "$pool" ] || pool="$(printf '%s' "$POOLS" | awk -F'|' -v m="$m" '$2==m {print $1; exit}')"
    new="$(size_arg "$cur" "$spec")"
    # preflight: the pool must have the delta
    local prow able; prow="$(printf '%s' "$POOLS" | grep "^$pool|" || true)"; able="$(echo "$prow" | cut -d'|' -f5)"
    [ -n "$prow" ] || warn "pool '$pool' not in lsstoragepool output: cannot check provisionable space"
    if [ "$new" != unlimited ] && [ "$cur" != unlimited ] && [ -n "$able" ] && [ "$new" -gt "$cur" ] && [ $((new - cur)) -gt "$able" ]; then
      [ "$FORCE" = 1 ] || die "pool $pool has $(human "$able") provisionable, $m growth asks for $(human $((new - cur))) (--force to send it anyway; escli will refuse what the pool does not have)"
    fi
    log "grow @$v $m: $(human "$cur") -> $(human "$new")  (pool ${pool:-?}, provisionable $(human "${able:-0}"), via chvault --$mode)"
    state_set "vault" "$v"; state_set "old_$a" "$cur"; state_set "new_$a" "$new"; state_set "pool_$m" "$pool"; state_set "mode_$m" "$mode"
    confirm "chvault @$v $m provisioning $(human "$cur") -> $(human "$new")?" || { log "skipped $m"; continue; }
    chvault_set "$v" "$m" "$new" || die "chvault failed: see $LOG_FILE"
    state_set "applied_$a" 1
  done
  cmd_verify
}
# chvault_set <vault> <media> <bytes|unlimited>: --provision on 26.1+ (pool saved in the state), --attributes before
chvault_set() {
  local v="$1" m="$2" val="$3" pool mode; pool="$(state_get "pool_$m" || true)"; mode="$(state_get "mode_$m" || echo attributes)"
  if [ "$mode" = provision ]; then run_cmd es chvault "@$v" --provision "storagePool=$pool,spaceProv=$val"; else run_cmd es chvault "@$v" --attributes "spaceProv$m=$val"; fi
}
prov_now() { # <vault> <media>: current provisioned bytes the way the grow read it
  local v="$1" m="$2" pool; pool="$(state_get "pool_$m" || true)"
  if [ "$(state_get "mode_$m" || true)" = provision ]; then es lsvault "@$v" --provision 2>/dev/null >"$RUN_DIR/verify_provision.txt"; to_bytes "$(records_tab "$RUN_DIR/verify_provision.txt" | awk -F'|' -v p="$pool" '$1==p {print $2; exit}')"
  else to_bytes "$(vault_attr "$v" "spaceProv$m")"; fi
}
# the newest run dir that recorded a grow (a refused grow leaves an empty run dir behind)
grow_run_dir() { [ -n "$RUN_DIR" ] && [ -f "$RUN_DIR/state" ] && grep -q '^vault=' "$RUN_DIR/state" && { init_run_dir "$1"; return 0; }
  local d; for d in $(find "$RUN_BASE" -maxdepth 1 -type d -name '*-grow-*' 2>/dev/null | sort -r); do grep -q '^vault=' "$d/state" 2>/dev/null && { RUN_DIR="$d"; init_run_dir "$1"; return 0; }; done
  RUN_DIR=""; init_run_dir "$1"; }
cmd_verify() { # [grow|rollback]: what the re-read proves; the SUCCESS line and the state key say which
  local what="${1:-grow}"
  grow_run_dir verify; escli_setup || die "escli is needed for verify"
  local v; v="$(state_get vault || true)"; [ -n "$v" ] || die "no grow recorded in $RUN_DIR"
  [ "$DRY_RUN" = 1 ] && { log "SUCCESS (dry-run) grow @$v: nothing changed, nothing to verify"; return 0; }
  local m ok=1; for m in HC EF XT; do
    local a="spaceProv$m" want now; want="$(state_get "new_$a" || true)"; [ -n "$want" ] || continue; [ "$(state_get "applied_$a" || true)" = 1 ] || continue
    now="$(prov_now "$v" "$m")"
    if [ "$now" = "$want" ]; then log "verify @$v $a = $(human "$now")  OK"; else err "verify @$v $a is $(human "$now"), expected $(human "$want")"; ok=0; fi
  done
  es lsvault "@$v" --detail | grep -E 'spaceProv|spaceUsed' | sed 's/^/  /' >&2
  local summary=""; for m in HC EF XT; do local want2; want2="$(state_get "new_spaceProv$m" || true)"; [ -n "$want2" ] && summary="$summary$m=$(human "$want2") "; done
  [ "$ok" = 1 ] && { state_set "$what" ok; log "SUCCESS $what @$v: $summary"; return 0; }
  state_set "$what" failed; err "verify failed: @$v does not read back what $what set (see $RUN_DIR)"; return 1
}
cmd_rollback() {
  grow_run_dir rollback; escli_setup || die "escli is needed for rollback"
  local v; v="$(state_get vault || true)"; [ -n "$v" ] || die "no grow recorded in $RUN_DIR"
  local m; for m in HC EF XT; do
    local a="spaceProv$m" old; old="$(state_get "old_$a" || true)"; [ -n "$old" ] || continue; [ "$(state_get "applied_$a" || true)" = 1 ] || continue
    confirm "chvault @$v $a back to $(human "$old")?" || continue
    chvault_set "$v" "$m" "$old" || die "rollback chvault failed"
    state_set "new_$a" "$old"
  done
  cmd_verify rollback   # re-reads the vault against the restored value; rollback=ok|failed and the SUCCESS line come from it
}

# ---------------------------------------------------------------------------
# purge-archivelogs: RMAN deletes only what it has backed up; --obsolete adds delete obsolete
# ---------------------------------------------------------------------------
cmd_purge() {
  local s; db_sids || die "$(ps_unreadable_msg) - purge refused: nothing is known about which databases run"
  [ -n "$SIDS" ] || die "no running database (use --sid)"
  init_run_dir purge-archivelogs
  local fail=0
  for s in $SIDS; do
    sql_ok "$s" || { warn "$s: cannot connect"; fail=1; continue; }
    local n; n="$(sql_val "$s" "(select count(*)||' files '||round(nvl(sum(blocks*block_size),0)/1073741824,1)||' GB' from v\$archived_log where dest_id=1 and deleted='NO' and standby_dest='NO' and backup_count>=$EXA_ARCH_BACKED_UP and completion_time<sysdate-${ARCH_DAYS:-$EXA_ARCH_DAYS})" 2>/dev/null)"
    local nb; nb="$(sql_val "$s" "(select count(*) from v\$archived_log where dest_id=1 and deleted='NO' and standby_dest='NO' and backup_count=0 and completion_time<sysdate-${ARCH_DAYS:-$EXA_ARCH_DAYS})" 2>/dev/null)"
    log "$s: archivelogs backed up $EXA_ARCH_BACKED_UP+ times and older than ${ARCH_DAYS:-$EXA_ARCH_DAYS} day(s): ${n:-?}; not backed up at all: ${nb:-?} (those stay)"
    local q="crosscheck archivelog all;\ndelete noprompt expired archivelog all;\ndelete noprompt archivelog all completed before 'sysdate-${ARCH_DAYS:-$EXA_ARCH_DAYS}' backed up $EXA_ARCH_BACKED_UP times to device type $EXA_ARCH_DEVICE;"
    [ "$DO_OBSOLETE" = 1 ] && q="$q\nreport obsolete;\ndelete noprompt obsolete;"
    confirm "$s: RMAN  $(printf '%b' "$q" | tr '\n' ' ')" || continue
    if [ "$DRY_RUN" = 1 ]; then log "dry-run: would run RMAN on $s"; continue; fi
    log "RMAN on $s (output: $RUN_DIR/rman_$s.txt)"
    rman_run "$s" "$RMAN_TIMEOUT" "$q" >"$RUN_DIR/rman_$s.txt" 2>&1; local rc=$?
    grep -E 'RMAN-|ORA-' "$RUN_DIR/rman_$s.txt" | grep -vE 'RMAN-08120|RMAN-06157' | head -5 | while read -r l; do warn "$s: $l"; done
    if [ "$rc" = 0 ]; then
      local deleted; deleted="$(grep -c 'deleted archived log' "$RUN_DIR/rman_$s.txt")"
      # the outcome, not the exit code: RMAN exits 0 when the 'backed up N times to device type D' clause matches nothing
      # (backups go to SBT_TAPE, EXA_ARCH_DEVICE says DISK) - the database counted eligible logs, RMAN deleted none, and that used to be SUCCESS
      if [ "$deleted" = 0 ] && [ "${n%% *}" != "${n%% *//[0-9]/}" ] && [ "${n%% *}" -gt 0 ] 2>/dev/null; then
        warn "$s: RMAN deleted nothing although the database counts ${n%% *} archivelog(s) backed up $EXA_ARCH_BACKED_UP+ times and old enough - the clause 'backed up $EXA_ARCH_BACKED_UP times to device type $EXA_ARCH_DEVICE' matched none: check where the backups go (EXA_ARCH_DEVICE) and $RUN_DIR/rman_$s.txt"
      else log "SUCCESS purge-archivelogs $s: $deleted archivelog(s) deleted (database counted ${n:-?} eligible before)"; fi
    else err "$s: rman exit $rc (see $RUN_DIR/rman_$s.txt)"; fail=1; fi
  done
  [ -n "$ESCLI" ] || escli_find || true; [ -n "$ESCLI" ] && es_ok 2>/dev/null && es lsvault -l 2>/dev/null | sed 's/^/  /' >&2
  return "$fail"
}

# ---------------------------------------------------------------------------
# release: rmfile for files named on the command line or in a list; typed confirmation; never --force
# ---------------------------------------------------------------------------
cmd_release() {
  local files=(); [ -n "$LIST_FILE" ] && { [ -r "$LIST_FILE" ] || die "cannot read $LIST_FILE"; while read -r l; do [ -n "$l" ] && [ "${l:0:1}" != "#" ] && files+=("$l"); done <"$LIST_FILE"; }
  files+=("${ARGS[@]}"); [ "${#files[@]}" -gt 0 ] || die "release <@vault/file ...> or --list FILE"
  init_run_dir release; escli_setup || die "escli is needed for release"
  local total=0 f; echo "files to delete:"
  for f in "${files[@]}"; do
    [ "${f:0:1}" = "@" ] || die "$f: paths must start with @vault/"
    # escli's exit status and error text are checked first: es() merges stderr, so a wallet/ctrl error used to be
    # parsed as "a record with no usedBy" and the ownership guard below let the delete through
    local o r; o="$(es lsfile "$f" --detail)" || die "$f: escli lsfile failed: $(printf '%s' "$o" | head -2 | tr '\n' ' ')"
    printf '%s' "$o" | grep -qiE 'ESCLI-|error|not found' && die "$f: escli lsfile: $(printf '%s' "$o" | grep -iE 'ESCLI-|error|not found' | head -1)"
    r="$(printf '%s\n' "$o" | records /dev/stdin)"; [ -n "$r" ] || die "$f: escli does not list it"
    local su ub ft; su="$(to_bytes "$(attr "$r" spaceUsed)")"; ub="$(attr "$r" usedBy)"; ft="$(attr "$r" fileType)"; total=$((total + su))
    printf '  %-10s %-12s usedBy=%-20s %s\n' "$(human "$su")" "${ft:-?}" "${ub:-(none)}" "$f"
    [ -n "$ub" ] && die "$f is claimed by database '$ub' - refusing: drop it from the database first (alter tablespace/database ... drop) and release it afterwards; --force does not override this"
  done
  echo "  total $(human "$total") in ${#files[@]} file(s)"; log "release: ${#files[@]} files, $(human "$total")"
  [ "$DRY_RUN" = 1 ] && { log "dry-run: nothing deleted"; return 0; }
  confirm_typed "delete ${#files[@]} file(s), $(human "$total"), with rmfile (no undo)" "delete" || die "not confirmed"
  local n=0; for f in "${files[@]}"; do
    if run_cmd es rmfile "$f" --nowait; then n=$((n+1)); state_append deleted "$f"; else err "rmfile $f failed"; fi
  done
  # a release whose rmfile failed used to end 'SUCCESS release: 0 of 1 file(s) submitted' and exit 0 (false-success gate, 1 Nov 2026)
  if [ "$n" = "${#files[@]}" ]; then log "SUCCESS release: $n file(s) submitted for deletion ($(human "$total")); space returns in the background (lsfile --include-being-deleted shows the progress)"
  else err "release INCOMPLETE: $n of ${#files[@]} file(s) submitted for deletion - the rest are still in the vault (see $LOG_FILE)"; return 1; fi
}

cmd_heal() {
  cmd_inspect || true
  # an inspect that could not read the vaults knows nothing about their fill: that is a refusal, not 'nothing to do'
  [ -n "${ESCLI:-}" ] || die "heal needs the vault view and escli is not available on this host (inspect ran database-side only): nothing is known about vault fill - run it where escli is, or purge-archivelogs --sid SID by hand"
  printf '%s' "$FINDINGS" | grep -qE '\[escli\] (escli cannot reach|lsvault failed|lsstoragepool failed)' && die "inspect could not read the vaults: $(printf '%s' "$FINDINGS" | grep -E '\[escli\]' | head -1 | cut -c1-200) - nothing is known about vault fill, so nothing is purged"
  local hot; hot="$(printf '%s' "$FINDINGS" | grep -E '^\- \*\*(CRIT|WARN)\*\* \[(vault|pool)\]' | wc -l | tr -d ' ')"
  [ "$hot" = 0 ] && { log "no vault or pool over ${EXA_WARN_PCT}%: nothing to do"; return 0; }
  log "$hot space finding(s): purging archivelogs RMAN has already backed up (the only automatic step)"
  local prc=0; cmd_purge || prc=$?
  [ "$prc" = 0 ] || err "purge-archivelogs did not complete on every database (see above): the vault is still as full as inspect found it"
  log "next: $TOOL.sh plan  (grow / release are never automatic)"
  return "$prc"   # heal's one automatic step failed: heal failed (it used to exit 0 after the error above)
}

main() {
  load_config; refuse_root
  local cmd="${1:-}"; shift || true; parse_opts "$@"
  case "$cmd" in
    inspect|"") cmd_inspect;; plan) cmd_plan;; grow) cmd_grow;; verify) cmd_verify;; rollback) cmd_rollback;;
    purge-archivelogs) cmd_purge;; release) cmd_release;; heal|run) cmd_heal;; -h|--help|help) usage;; *) die "Unknown command: $cmd";;
  esac
}
main "$@"
