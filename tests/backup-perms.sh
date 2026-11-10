#!/bin/bash
# backup-perms.sh - T195 gate: the rollback backup must not trust the host umask, and must not impose one
# on the children that touch the ORACLE HOME. Runs each script's REAL backup path on stub trees.
#   INV1 (script-controlled): run dir 0700, run.log 0600, every archive 0600 - under caller umask 022 AND 077.
#   INV2 (host-controlled): a fake tar -x restore and a fake opatch file, run through the script's own child
#        runner, keep the CALLER umask (755/644 at 022, 700/600 at 077) and the ambient umask is unchanged -
#        a script-wide `umask 077` breaks this (it makes the home private and a start fails after a rollback).
# Own mktemp dir, nothing shared touched; offline only.
set -u
cd "$(dirname "$0")/.." || exit 1
T="$(mktemp -d)"; trap 'chmod -R u+rwX "$T" 2>/dev/null; rm -rf "$T"' EXIT
pass=0; fail=0
ok()  { pass=$((pass+1)); }
bad() { fail=$((fail+1)); printf 'FAIL - %s\n' "$*"; }
mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null || echo '?'; }

# strip the trailing main "$@" so sourcing defines functions only
funcs() { mkdir -p "$(dirname "$T/f/$2")"; sed '/^main "\$@"[[:space:]]*$/d' "$1" >"$T/f/$2"; }

stub() { # <base>
  mkdir -p "$1/OH/oui" "$1/dom/domain1/config/fmwconfig" "$1/inv"
  printf x >"$1/OH/oui/comp.txt"; printf w >"$1/dom/domain1/config/fmwconfig/cwallet.sso"; printf r >"$1/inv/Inventory.xml"
}

# one script, one caller umask -> prints "rundir log archive... restored-dir restored-file opatch-file ambient"
measure() { # <relpath> <umask>
  local rel="$1" um="$2" base="$T/$(echo "$rel" | tr / _)-$2"
  funcs "$rel" "$rel.funcs"; mkdir -p "$base"; stub "$base"
  (
    umask "$um"; set +e; RUN_DIR=""
    # shellcheck disable=SC1090
    source "$T/f/$rel.funcs" >/dev/null 2>&1
    case "$rel" in
      patching/ohs-patch/ohs-patch.sh)
        OH="$base/OH"; DOMS="$base/dom/domain1"; INV="$base/inv"; BK="$base/backup"
        RUN_BASE="$base/runs"; OUTPUT_HINT="$base"; DRY_RUN=0
        STAMP=fixture; open_run >/dev/null 2>&1; backup_all >/dev/null 2>&1
        ART="$BK"; RC=do_cmd; AF="$BK/home.tgz" ;;
      patching/dbclient-upgrade/dbclient-upgrade.sh)
        OH="$base/OH"; DOMS="$base/dom/domain1"; INV="$base/inv"; BK="$base/backup"
        RUN_BASE="$base/runs"; OUTPUT_HINT="$base"; DRY_RUN=0
        STAMP=fixture; open_run >/dev/null 2>&1; backup_all >/dev/null 2>&1
        ART="$BK"; RC=do_cmd; AF="$BK/home.tgz" ;;
      patching/wls-patch/wls-patch.sh)
        setup_env() { :; }; state_set() { :; }
        ORACLE_HOME="$base/OH"; DOMAINS="$base/dom/domain1"; BACKUP_DIR="$base/backups"
        RUN_BASE="$base/runs"; RUN_DIR=""; OUTPUT_HINT="$base"; DRY_RUN=0; VERSION=gate
        cmd_backup >/dev/null 2>&1
        d="$(ls -d "$BACKUP_DIR"/*/ 2>/dev/null | tail -1)"; d="${d%/}"; ART="$d"; RC=run_cmd; AF="$d/oracle_home.tar.gz" ;;
    esac
    logf="$RUN_DIR/run.log"; [ "$rel" = patching/wls-patch/wls-patch.sh ] && logf="${LOG_FILE:-$RUN_DIR/wls-patch.log}"
    mkdir -p "$base/restore" "$base/opatch"
    $RC tar -C "$base/restore" -xzf "$AF" >/dev/null 2>&1 || true
    $RC sh -c 'mkdir -p "$1"; : >"$1/f"; : >"$1/f.conf"' _ "$base/opatch" >/dev/null 2>&1 || true
    printf '%s|%s|%s|%s|%s|%s\n' "$(mode "$RUN_DIR")" "$(mode "$logf")" \
      "$(for f in "$ART"/*.tgz "$ART"/*.tar.gz; do [ -e "$f" ] && mode "$f" || true; done | sort -u | tr '\n' ',' )" \
      "$(mode "$base/restore/OH")|$(mode "$base/restore/OH/oui/comp.txt")" "$(mode "$base/opatch/f.conf")" "$(umask)"
  )
}

check() { # <relpath> <umask>
  local rel="$1" um="$2" line rundir logf archs rdir rfile oprobe ambient want_dir want_file
  line="$(measure "$rel" "$um")"
  IFS='|' read -r rundir logf archs rdir rfile oprobe ambient <<<"$line"
  local name; name="$(basename "$rel")"
  [ "$rundir" = 700 ] || bad "$name umask $um: run dir $rundir (want 700)"
  [ "$logf" = 600 ]   || bad "$name umask $um: run log $logf (want 600)"
  [ -n "$archs" ] || bad "$name umask $um: no archives created"
  case ",$archs" in *,644,*|*,640,*|*,660,*) bad "$name umask $um: archive perms $archs (want 600)";; esac
  [ "$um" = 022 ] && { want_dir=755; want_file=644; } || { want_dir=700; want_file=600; }
  [ "$rdir" = "$want_dir" ]  || bad "$name umask $um: restored home dir $rdir (child must keep caller umask, want $want_dir)"
  [ "$rfile" = "$want_file" ] || bad "$name umask $um: restored home file $rfile (want $want_file)"
  [ "$oprobe" = "$want_file" ] || bad "$name umask $um: fake-opatch file $oprobe (want $want_file)"
  [ "$ambient" = "0$um" ] || bad "$name umask $um: umask after call is $ambient - script-wide umask leaked to children"
  [ "$rundir" = 700 ] && [ "$logf" = 600 ] && [ "$rdir" = "$want_dir" ] && [ "$rfile" = "$want_file" ] && [ "$oprobe" = "$want_file" ] && [ "$ambient" = "0$um" ] && ok
}

for s in patching/ohs-patch/ohs-patch.sh patching/dbclient-upgrade/dbclient-upgrade.sh patching/wls-patch/wls-patch.sh; do
  check "$s" 022
  check "$s" 077
done

echo "backup-perms gate: $pass passed, $fail failed"
[ "$fail" = 0 ]