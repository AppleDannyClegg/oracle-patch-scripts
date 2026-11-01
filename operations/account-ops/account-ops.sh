#!/usr/bin/env bash
# account-ops.sh - the service accounts that take the stack down when they expire or lock:
# APEX_PUBLIC_USER, ORDS_PUBLIC_USER, ORDS_METADATA, APEX_LISTENER, APEX_REST_PUBLIC_USER, DBSNMP, SYSMAN,
# GGADMIN, the RMAN catalog owner, and any --user. Shows status, expiry and where each password is
# stored; unlocks; resets the password everywhere at once (database + ORDS pools + WebLogic data sources
# + GoldenGate credential store), with a verified rollback of the old password hash. Runs as oracle.
#
# Usage: account-ops.sh <command> [options]
#
# Commands
#   inspect                 Every known service account in every open container: status, expiry, profile, last logon,
#                           failed logins (24 h), and where its password lives (ORDS pool.xml, WebLogic JDBC modules,
#                           GoldenGate credential store, wallets, OEM note)
#   expiring [--days N]     Accounts (service or not) expiring within N days (default 14) or already EXPIRED/LOCKED
#   unlock                  account unlock (and, for EXPIRED(GRACE), warn that the password must still be reset)
#   reset                   New password (prompt, or --generate shown once) in the database AND propagated to every
#                           store that holds it: ords config secret db.password + restart, WebLogic data source via
#                           WLST (credentials needed), GoldenGate credential store (ggsci alter credentialstore),
#                           OEM: emcli command printed. Old hash saved for rollback.
#   profile                 Put the service accounts on a profile without expiry (SERVICE_ACCOUNTS profile, created
#                           if missing: PASSWORD_LIFE_TIME UNLIMITED, FAILED_LOGIN_ATTEMPTS per conf); --no-expiry
#                           alone only sets the profile, nothing else
#   verify                  sqlplus login test with the stored/new password where possible, ORDS URL 200, WebLogic
#                           JDBC testPool, ggsci dblogin useridalias
#   rollback                Restore the previous password hash ('identified by values') and the backed-up config files
#   heal                    ORDS answers 503 / "pool not available"? find the locked or expired account behind it, fix it,
#                           restart ORDS, check again
#   run                     = heal
#
# Options
#   --user NAME[,NAME]   act on these accounts (default: the known service accounts found)      --sid SID     one database
#   --pdb NAME           one container (default: every open PDB + root for common users)         --days N      for expiring
#   --generate           make a 20-character password and show it once (otherwise prompted)       --no-expiry   profile only
#   --no-propagate       database only (do not touch ORDS/WebLogic/GoldenGate)                   --no-restart  do not restart ORDS
#   --dry-run  --yes  --force  --json  --verbose  --run-dir DIR
#
# Config: account-ops.conf (600), ~/.account-ops.conf or the shared oracle.conf: SQL_CONNECT, SERVICE_ACCOUNTS (extra names),
# ORDS_HOME, ORDS_CONFIG, ORDS_URL, ORDS_SERVICE/ORDS_STOP_CMD/ORDS_START_CMD, WLS_ADMIN_URL + WLS_USERCONFIG/WLS_USERKEY
# (or WLS_ADMIN_USER/WLS_ADMIN_PASSWORD), OGG_HOME, GG_ALIAS_MAP (user=alias,...), SA_PROFILE (SERVICE_ACCOUNTS),
# SA_FAILED_LOGINS (10), NEW_PASSWORD (not recommended; prompt or --generate instead).

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="account-ops"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

KNOWN="APEX_PUBLIC_USER ORDS_PUBLIC_USER ORDS_METADATA APEX_LISTENER APEX_REST_PUBLIC_USER DBSNMP SYSMAN GGADMIN C##GGADMIN RMAN RCAT RCOWNER"
USERS="${SERVICE_ACCOUNTS:-}"; ONLY_SID=""; ONLY_PDB=""; DAYS=14; GENERATE=0; NO_EXPIRY=0; NO_PROPAGATE=0; NO_RESTART=0
SA_PROFILE="${SA_PROFILE:-SERVICE_ACCOUNTS}"; SA_FAILED_LOGINS="${SA_FAILED_LOGINS:-10}"; GG_ALIAS_MAP="${GG_ALIAS_MAP:-}"
NEW_PASSWORD="${NEW_PASSWORD:-}"

usage() { usage_from_header "$0"; }
parse_opts() {
  while [ $# -gt 0 ]; do case "$1" in
    --user) optchk "$@"; USERS="$2"; shift 2;; --sid) optchk "$@"; ONLY_SID="$2"; shift 2;; --pdb) optchk "$@"; ONLY_PDB="$2"; shift 2;; --days) optchk "$@"; DAYS="$2"; shift 2;;
    --generate) GENERATE=1; shift;; --no-expiry) NO_EXPIRY=1; shift;; --no-propagate) NO_PROPAGATE=1; shift;; --no-restart) NO_RESTART=1; shift;;
    --dry-run) DRY_RUN=1; shift;; --yes) ASSUME_YES=1; shift;; --force) FORCE=1; shift;; --json) JSON_OUT=1; shift;; --verbose) VERBOSE=1; shift;; --run-dir) optchk "$@"; RUN_DIR="$2"; shift 2;;
    -h|--help) usage; exit 0;; *) die "Unknown option: $1";; esac; done
  USERS="$(printf '%s' "${USERS//,/ }" | tr '[:lower:]' '[:upper:]')"
}

# ---------------------------------------------------------------------------
# where accounts live: "sid|container|user" rows
# ---------------------------------------------------------------------------
sids() { if [ -n "$ONLY_SID" ]; then echo "$ONLY_SID"; else db_instances | grep -vE '^\+ASM|^-MGMTDB|^\+APX'; fi; }
containers() { # <sid>: "-" for root/non-CDB, then open PDBs
  if [ -n "$ONLY_PDB" ]; then echo "$ONLY_PDB"; return; fi
  echo "-"; db_is_cdb "$1" && db_pdbs "$1"; return 0
}
wp() { local c="$1"; shift; [ "$c" = - ] && c=""; with_pdb "$c" "$@"; }   # with_pdb that understands the "-" root marker
cs() { [ "$1" = - ] || [ -z "$1" ] || printf '/%s' "$1"; }                # container suffix for messages
user_list_sql() { # IN-list of the accounts we care about
  local all="$KNOWN $USERS" u s=""; for u in $all; do s="${s:+$s,}'$u'"; done; printf '%s' "$s"
}
# account_rows <sid> <pdb>: USER|STATUS|EXPIRY|PROFILE|LAST_LOGIN|LOCK_DATE|FAILED24H|COMMON
account_rows() {
  local sid="$1" pdb="$2"
  wp "$pdb" sql_lines "$sid" "select u.username||'|'||u.account_status||'|'||nvl(to_char(u.expiry_date,'YYYY-MM-DD'),'-')||'|'||u.profile||'|'||nvl(to_char(u.last_login,'YYYY-MM-DD HH24:MI'),'-')||'|'||nvl(to_char(u.lock_date,'YYYY-MM-DD HH24:MI'),'-')||'|'||nvl((select count(*) from dba_audit_trail a where a.username=u.username and a.returncode in (1017,28000) and a.timestamp>sysdate-1),0)||'|'||u.common from dba_users u where u.username in ($(user_list_sql)) order by 1;" 2>/dev/null \
  || wp "$pdb" sql_lines "$sid" "select u.username||'|'||u.account_status||'|'||nvl(to_char(u.expiry_date,'YYYY-MM-DD'),'-')||'|'||u.profile||'|'||nvl(to_char(u.last_login,'YYYY-MM-DD HH24:MI'),'-')||'|'||nvl(to_char(u.lock_date,'YYYY-MM-DD HH24:MI'),'-')||'|?|'||u.common from dba_users u where u.username in ($(user_list_sql)) order by 1;" 2>/dev/null
}
failed_unified() { wp "$2" sql_val "$1" "(select count(*) from unified_audit_trail where dbusername='$3' and return_code in (1017,28000) and event_timestamp>systimestamp-1)" 2>/dev/null; }
# stores: where is the password of <user> kept on this host?
ords_pools_for() { # <user>: pool names whose db.username matches
  ords_detect >/dev/null 2>&1 || return 0; local p; for p in $ORDS_POOLS; do [ "$(ords_pool_user "$p" | tr '[:lower:]' '[:upper:]')" = "$1" ] && echo "$p"; done
}
wls_ds_for() { # <user>: "domain|file|jndi" for JDBC modules using it
  local h d f; for h in $(wls_homes); do for d in $(wls_domains "$h"); do for f in "$d"/config/jdbc/*.xml; do [ -f "$f" ] || continue
    tr -d '\n' <"$f" | grep -qiE "<name>[[:space:]]*user[[:space:]]*</name>[[:space:]]*<value>[[:space:]]*$1[[:space:]]*</value>" && printf '%s|%s|%s\n' "$d" "$f" "$(grep -oE '<jndi-name>[^<]*' "$f" | head -1 | sed 's/<[^>]*>//')"; done; done; done
}
gg_alias_for() { # <user>: credential store aliases whose userid is this user
  ogg_detect >/dev/null 2>&1 || return 0; local m; for m in ${GG_ALIAS_MAP//,/ }; do [ "$(printf '%s' "${m%%=*}" | tr '[:lower:]' '[:upper:]')" = "$1" ] && { echo "${m#*=}"; return; }; done
  [ -x "${OGG_HOME:-/nonexistent}/ggsci" ] && ggsci "info credentialstore" 2>/dev/null | awk -v u="$1" 'BEGIN{IGNORECASE=1} /Alias:/{a=$2} /Userid:/{split($2,x,"@"); if (toupper(x[1])==u) print a}'
}
wallet_hits() { # <user>: wallets (mkstore) that hold a credential for this user, best effort
  local w mk; mk="$(db_home_of "$(sids | head -1)")/bin/mkstore"; [ -x "$mk" ] || return 0
  for w in /u01/app/oracle/*/wallet* "$HOME"/wallet* /etc/ORACLE/WALLETS/*/; do [ -f "$w/cwallet.sso" ] || continue; to 10 "$mk" -wrl "$w" -listCredential </dev/null 2>/dev/null | grep -qi " $1\$" && echo "$w"; done; return 0
}
stores_of() { # <user>: one line
  local u="$1" s=""; local p; for p in $(ords_pools_for "$u"); do s="$s ords:$p"; done
  local l; while IFS='|' read -r d f j; do [ -n "$f" ] && s="$s wls:$(basename "$d")/$(basename "$f")${j:+($j)}"; done < <(wls_ds_for "$u")
  for l in $(gg_alias_for "$u"); do s="$s gg:$l"; done
  for l in $(wallet_hits "$u"); do s="$s wallet:$l"; done
  case "$u" in DBSNMP) s="$s oem:monitoring-credentials(emcli)";; SYSMAN) s="$s oem:repository(emctl config oms -change_repos_pwd)";; esac
  printf '%s' "${s# }"
}

cmd_inspect() {
  local sid pdb rows u first=1
  [ "$JSON_OUT" = 1 ] && printf '['
  for sid in $(sids); do sql_ok "$sid" || { warn "$sid: cannot connect"; continue; }
    for pdb in $(containers "$sid"); do
      rows="$(account_rows "$sid" "$pdb")"; [ -z "$rows" ] && continue
      [ "$JSON_OUT" = 1 ] || { echo; echo "== $sid$(cs "$pdb") =="; printf '  %-24s %-18s %-11s %-18s %-17s %-7s %s\n' USER STATUS EXPIRES PROFILE LAST_LOGIN FAILED24 STORED_IN; }
      while IFS='|' read -r u st ex pr ll ld f24 cm; do [ -z "$u" ] && continue
        [ "$f24" = '?' ] && f24="$(failed_unified "$sid" "$pdb" "$u")"; local where; where="$(stores_of "$u")"
        if [ "$JSON_OUT" = 1 ]; then printf '%s{"sid":"%s","container":"%s","user":"%s","status":"%s","expires":"%s","profile":"%s","last_login":"%s","failed_24h":"%s","stored_in":"%s"}' "$([ $first = 1 ] || echo ,)" "$sid" "$([ "$pdb" = - ] && echo ROOT || echo "$pdb")" "$u" "$st" "$ex" "$pr" "$ll" "${f24:-?}" "$(json_escape "$where")"; first=0
        else printf '  %-24s %-18s %-11s %-18s %-17s %-7s %s\n' "$u" "$st" "$ex" "$pr" "$ll" "${f24:-?}" "${where:-?}"; fi
      done <<<"$rows"
    done
  done
  [ "$JSON_OUT" = 1 ] && echo ']'
  [ "$JSON_OUT" = 1 ] || { echo; ords_detect >/dev/null 2>&1 && echo "ORDS: ${ORDS_HOME:-?} config ${ORDS_CONFIG:-?} pools [${ORDS_POOLS:-none}] url ${ORDS_URL:-?} -> HTTP $(url_code "${ORDS_URL:-http://localhost:8080/ords/}" 10)"; ogg_detect >/dev/null 2>&1 && echo "GoldenGate: ${OGG_HOME:-MA} $(ggsci 'info credentialstore' 2>/dev/null | grep -c Alias) credential alias(es)"; }
  return 0
}

cmd_expiring() {
  local sid pdb; for sid in $(sids); do sql_ok "$sid" || continue
    for pdb in $(containers "$sid"); do
      local rows; rows="$(wp "$pdb" sql_lines "$sid" "select username||'|'||account_status||'|'||nvl(to_char(expiry_date,'YYYY-MM-DD'),'-')||'|'||profile||'|'||nvl(to_char(last_login,'YYYY-MM-DD'),'-') from dba_users where (oracle_maintained='N' or username in ($(user_list_sql))) and (account_status like '%EXPIRED%' or account_status like '%LOCKED%' or (expiry_date is not null and expiry_date<sysdate+$DAYS)) order by expiry_date nulls last, 1;" 2>/dev/null)"
      [ -z "$rows" ] && continue
      echo; echo "== $sid$(cs "$pdb"): expiring within $DAYS days, expired or locked =="; printf '%s\n' "$rows" | awk -F'|' '{printf "  %-28s %-18s expires %-11s profile %-18s last login %s\n", $1, $2, $3, $4, $5}'
    done
  done
  echo; echo "Profiles with a password lifetime:"; for sid in $(sids); do sql_lines "$sid" "select '  $sid '||profile||' PASSWORD_LIFE_TIME='||limit from dba_profiles where resource_name='PASSWORD_LIFE_TIME' and limit not in ('UNLIMITED') order by 1;" 2>/dev/null; done
  return 0
}

# ---------------------------------------------------------------------------
# change: unlock, reset, profile
# ---------------------------------------------------------------------------
targets() { # "sid|pdb|user|status|common" for the requested users (or every known one found)
  local want="${USERS:-$KNOWN}" sid pdb; for sid in $(sids); do sql_ok "$sid" || continue
    for pdb in $(containers "$sid"); do
      local inl="" u; for u in $want; do inl="${inl:+$inl,}'$u'"; done
      wp "$pdb" sql_lines "$sid" "select '$sid|$pdb|'||username||'|'||account_status||'|'||common from dba_users where username in ($inl) order by 1;" 2>/dev/null
    done
  done
}
# usql <sid> <pdb> <description> <sql>
usql() { local sid="$1" pdb="$2" desc="$3" q="$4" out; log "SQL $sid$(cs "$pdb"): $desc"; [ "$DRY_RUN" = 1 ] && return 0; out="$(wp "$pdb" sql_run "$sid" "whenever sqlerror exit 1\n$q")"; printf '%s\n' "$out" | redact >>"$LOG_FILE"; printf '%s' "$out" | grep -qE 'ORA-' && { err "  $(printf '%s' "$out" | grep -E 'ORA-' | head -1)"; return 1; }; return 0; }

cmd_unlock() {
  init_run_dir unlock; local n=0
  while IFS='|' read -r sid pdb u st cm; do [ -z "$u" ] && continue
    case "$st" in *LOCKED*) ;; *) log "$sid$(cs "$pdb") $u is $st - nothing to unlock"; continue;; esac
    confirm "Unlock $u in $sid$(cs "$pdb") ($st)?" || continue
    usql "$sid" "$pdb" "unlock $u" "alter user \"$u\" account unlock;" && n=$((n+1))
    case "$st" in *EXPIRED*) warn "$u was also EXPIRED: unlock does not fix that - run 'reset' (the password is needed everywhere it is stored) or 'profile' first";; esac
  done < <(targets)
  log "unlocked $n account(s)"
}

gen_password() { LC_ALL=C tr -dc 'A-Za-z0-9#_' </dev/urandom | head -c 18; printf '%s' "$(LC_ALL=C tr -dc 'A-Za-z' </dev/urandom | head -c 1)1"; }
ords_set_secret() { # <pool> <password>
  local pool="$1" pw="$2"
  [ -x "${ORDS_HOME:-}/bin/ords" ] || { warn "ords binary not found (ORDS_HOME); set db.password for pool $pool by hand: ords --config $ORDS_CONFIG config --db-pool $pool secret db.password"; return 1; }
  log "ORDS: ords --config $ORDS_CONFIG config --db-pool $pool secret --password-stdin db.password"; [ "$DRY_RUN" = 1 ] && return 0
  cp -p "$ORDS_CONFIG/databases/$pool/pool.xml" "$RUN_DIR/pool.xml.$pool.bak" 2>/dev/null; cp -p "$ORDS_CONFIG/databases/$pool/wallet/cwallet.sso" "$RUN_DIR/cwallet.sso.$pool.bak" 2>/dev/null
  printf '%s\n' "$pw" | to 120 "$ORDS_HOME/bin/ords" --config "$ORDS_CONFIG" config --db-pool "$pool" secret --password-stdin db.password >>"$LOG_FILE" 2>&1 || { err "ords config secret failed for pool $pool (see $LOG_FILE)"; return 1; }
  state_append ords_pools_changed "$pool"
}
ords_restart() {
  [ "$NO_RESTART" = 1 ] && { warn "ORDS not restarted (--no-restart): it keeps using the old password until restarted"; return 0; }
  if [ -n "${ORDS_STOP_CMD:-}" ]; then
    # both commands checked before anything is stopped: ':?' on the start command used to abort with ORDS already down
    [ -n "${ORDS_START_CMD:-}" ] || { err "ORDS_START_CMD is not set (needed with ORDS_STOP_CMD): ORDS NOT restarted, it keeps the old password until you restart it"; return 1; }
    run_sh "$ORDS_STOP_CMD" || warn "ORDS stop command returned non-zero"; sleep 5; run_sh "$ORDS_START_CMD" || { err "ORDS start command failed: see $LOG_FILE"; return 1; }
  elif [ -n "${ORDS_SERVICE:-$(ords_service)}" ]; then run_sh "$SUDO systemctl restart ${ORDS_SERVICE:-$(ords_service)}"
  elif [ -n "${ORDS_PID:-}" ]; then warn "ORDS runs as pid $ORDS_PID without a service; restart it yourself (or set ORDS_STOP_CMD/ORDS_START_CMD)"; return 0
  else warn "ORDS not running here or deployed in WebLogic: restart the ords application / managed server"; return 0; fi
  [ "$DRY_RUN" = 1 ] && return 0; wait_for_url "${ORDS_URL:-http://localhost:8080/ords/}" 180 && log "ORDS answers again" || warn "ORDS did not answer within 180 s"
}
wlst_run() { # <domain> <script>: run WLST offline-connected script with stored creds
  local dom="$1" script="$2" h; h="$(wls_homes | head -1)"; [ -x "$h/oracle_common/common/bin/wlst.sh" ] || { warn "wlst.sh not found"; return 1; }
  local conn; if [ -n "${WLS_USERCONFIG:-}" ] && [ -n "${WLS_USERKEY:-}" ]; then conn="connect(userConfigFile='$WLS_USERCONFIG', userKeyFile='$WLS_USERKEY', url='${WLS_ADMIN_URL:-t3://localhost:7001}')"
  elif [ -n "${WLS_ADMIN_USER:-}" ]; then read_secret WLS_ADMIN_PASSWORD "WebLogic admin password for $WLS_ADMIN_USER"; conn="connect('$WLS_ADMIN_USER', '$WLS_ADMIN_PASSWORD', '${WLS_ADMIN_URL:-t3://localhost:7001}')"
  else warn "no WebLogic credentials (WLS_USERCONFIG+WLS_USERKEY or WLS_ADMIN_USER): data sources in $dom must be updated in the console"; return 1; fi
  local f; f="$(tmp_secret_file "$conn
$script
disconnect()
exit()")"
  [ "$DRY_RUN" = 1 ] && { log "WLST: $(printf '%s' "$script" | head -3 | tr '\n' ' ')"; rm -f "$f"; return 0; }
  WLST_PROPERTIES="-Dwlst.offline.log=/dev/null" to 300 "$h/oracle_common/common/bin/wlst.sh" -skipWLSModuleScanning "$f" 2>&1 | redact >>"$LOG_FILE"; local rc="${PIPESTATUS[0]}"; rm -f "$f"; return "$rc"
}
wls_set_ds_password() { # <domain> <jdbc file> <jndi> <password>
  local dom="$1" f="$2" jndi="$3" pw="$4" ds; ds="$(grep -oE '<name>[^<]*</name>' "$f" | head -1 | sed 's/<[^>]*>//g')"
  cp -p "$f" "$RUN_DIR/$(basename "$dom")_$(basename "$f").bak" 2>/dev/null
  log "WebLogic $(basename "$dom"): data source '$ds' ($jndi) password via WLST (edit session, activate)"
  wlst_run "$dom" "edit()
startEdit()
cd('/JDBCSystemResources/$ds/JDBCResource/$ds/JDBCDriverParams/$ds')
cmo.setPassword('$(printf '%s' "$pw" | sed "s/'/\\\\'/g")')
activate()" && state_append wls_ds_changed "$dom:$ds" || { err "WLST update of $ds failed (see $LOG_FILE); the console path: Services > Data Sources > $ds > Connection Pool > Password"; return 1; }
}
gg_set_alias() { # <alias> <user> <password>
  log "GoldenGate: alter credentialstore replace user $2 alias $1 (password on stdin)"; [ "$DRY_RUN" = 1 ] && return 0
  cp -rp "$OGG_HOME/dircrd" "$RUN_DIR/dircrd.bak" 2>/dev/null
  local out; out="$(ggsci "alter credentialstore replace user $2 password $3 alias $1")"; printf '%s\n' "$out" | redact >>"$LOG_FILE"
  printf '%s' "$out" | grep -qiE 'successfully|Credential store altered' && state_append gg_alias_changed "$1" || { err "ggsci alter credentialstore failed: $(printf '%s' "$out" | tail -1)"; return 1; }
}

cmd_reset() {
  init_run_dir reset
  local tg; tg="$(targets)"; [ -n "$tg" ] || die "no matching account (--user NAME, --sid, --pdb)"
  echo "Accounts to reset:"; printf '%s\n' "$tg" | awk -F'|' '{printf "  %s%s %s (%s)\n", $1, ($2==""?"":"/"$2), $3, $4}'
  local pw="$NEW_PASSWORD"
  if [ -z "$pw" ]; then if [ "$GENERATE" = 1 ]; then pw="$(gen_password)"; echo; echo "  NEW PASSWORD (shown once, store it in your vault now): $pw"; echo; else read_secret NEW_PASSWORD "new password for the account(s) above"; pw="$NEW_PASSWORD"; local again; read -r -s -p "again: " again; echo; [ "$again" = "$pw" ] || die "passwords differ"; fi; fi
  [ -n "$pw" ] || die "empty password"
  case "$pw" in *\"*|*$'\n'*) die "the password may not contain a double quote or a newline (it goes inside identified by \"...\")";; esac
  [ "${#pw}" -ge 12 ] || warn "password shorter than 12 characters; profiles with a verify function may reject it"
  confirm "Reset the password of the account(s) above in the database$([ "$NO_PROPAGATE" = 1 ] || echo ' and propagate to ORDS / WebLogic / GoldenGate')?" || die "aborted"
  local fail=0
  while IFS='|' read -r sid pdb u st cm; do [ -z "$u" ] && continue
    # save the old hash for rollback
    # sys.user$.spare4 holds the verifiers ("S:...;T:..."); dbms_metadata's CLOB is cut at "set long" and wrapped at linesize
    local hash; hash="$(wp "$pdb" sql_lines "$sid" "set linesize 4000\nselect 'VALUES '''||spare4||'''' from sys.user\$ where name='$u' and spare4 is not null;" 2>/dev/null | head -1)"
    [ -n "$hash" ] && { printf '%s|%s|%s|%s\n' "$sid" "$pdb" "$u" "$hash" >>"$RUN_DIR/old_hashes.txt"; chmod 600 "$RUN_DIR/old_hashes.txt"; } || warn "$u: could not read the old password hash (rollback will not be able to restore it)"
    # a common user is reset once, in the root with container=all; the same row inside a PDB would raise ORA-65066
    [ "$cm" = YES ] && [ "$pdb" != - ] && { log "$pdb/$u: common user, reset in the root"; continue; }
    local cont=""; [ "$cm" = YES ] && [ "$pdb" = - ] && cont=" container=all"
    usql "$sid" "$pdb" "alter user $u identified by *** account unlock$cont" "alter user \"$u\" identified by \"$pw\" account unlock$cont;" || { fail=1; continue; }
    state_append reset_done "$sid:$pdb:$u"
    [ "$NO_PROPAGATE" = 1 ] && continue
    local p; for p in $(ords_pools_for "$u"); do ords_set_secret "$p" "$pw" || fail=1; done
    while IFS='|' read -r dom f jndi; do [ -n "$f" ] && { wls_set_ds_password "$dom" "$f" "$jndi" "$pw" || fail=1; }; done < <(wls_ds_for "$u")
    local a; for a in $(gg_alias_for "$u"); do gg_set_alias "$a" "$u" "$pw" || fail=1; done
    case "$u" in DBSNMP) echo "  OEM: update the monitoring credentials:  emcli modify_target -name=<target> -type=oracle_database -credentials=\"UserName:dbsnmp;password:<new>;Role:Normal\"  (or Setup > Security > Monitoring Credentials)";;
                SYSMAN) echo "  OEM: SYSMAN is the repository owner - change it ONLY with: emctl config oms -change_repos_pwd  (not alter user); this script changed the database side, do the OMS side now or the OMS will not start";; esac
  done <<<"$tg"
  [ "$NO_PROPAGATE" = 0 ] && [ -n "$(state_get ords_pools_changed || true)" ] && ords_restart
  unset NEW_PASSWORD
  [ "$fail" = 0 ] && { log "reset done. Run 'verify'. Rollback: 'rollback' restores the old hashes and config files from $RUN_DIR"; state_set reset ok; } || { err "reset finished with errors - see $LOG_FILE; 'rollback' puts the old passwords back"; state_set reset failed; return 1; }
}

cmd_profile() {
  init_run_dir profile
  local sid pdb; for sid in $(sids); do sql_ok "$sid" || continue
    for pdb in $(containers "$sid"); do
      local have; have="$(wp "$pdb" sql_val "$sid" "(select count(*) from dba_profiles where profile='$SA_PROFILE')")"
      if [ "${have:-0}" = 0 ]; then
        confirm "Create profile $SA_PROFILE in $sid$(cs "$pdb") (PASSWORD_LIFE_TIME UNLIMITED, FAILED_LOGIN_ATTEMPTS $SA_FAILED_LOGINS, PASSWORD_GRACE_TIME UNLIMITED)?" || continue
        usql "$sid" "$pdb" "create profile $SA_PROFILE" "create profile \"$SA_PROFILE\" limit password_life_time unlimited failed_login_attempts $SA_FAILED_LOGINS password_grace_time unlimited password_lock_time 1/24 password_reuse_time unlimited password_reuse_max unlimited$([ "$pdb" = - ] && db_is_cdb "$sid" && echo ' container=all');" || continue
      fi
      local u; for u in $(printf '%s\n' "$(targets)" | awk -F'|' -v s="$sid" -v p="$pdb" '$1==s && $2==p {print $3}'); do
        local cur; cur="$(wp "$pdb" sql_val "$sid" "(select profile from dba_users where username='$u')")"; [ "$cur" = "$SA_PROFILE" ] && continue
        confirm "$sid$(cs "$pdb"): move $u from profile $cur to $SA_PROFILE?" && usql "$sid" "$pdb" "profile $u" "alter user \"$u\" profile \"$SA_PROFILE\";"
      done
    done
  done
  log "note: a profile change does not un-expire an already EXPIRED account; that needs a password reset"
}

cmd_verify() {
  reuse_or_init verify; local fail=0
  while IFS='|' read -r sid pdb u st cm; do [ -z "$u" ] && continue
    case "$st" in OPEN) log "$sid$(cs "$pdb") $u: OPEN";; *) err "$sid$(cs "$pdb") $u: $st"; fail=1;; esac
  done < <(targets)
  if ords_detect >/dev/null 2>&1; then local code; code="$(url_code "${ORDS_URL:-http://localhost:8080/ords/}" 15)"; local p; for p in $ORDS_POOLS; do local pc; pc="$(url_code "${ORDS_URL%/}/$([ "$p" = default ] && echo '' || echo "$p/")" 15)"; log "ORDS pool $p (user $(ords_pool_user "$p")): HTTP ${pc:-none}"; [[ "$pc" =~ ^(200|30[0-9]|404)$ ]] || { [ "$pc" = 503 ] && { err "ORDS pool $p: 503 - pool cannot connect (locked/expired/wrong password)"; fail=1; }; }; done; log "ORDS root: HTTP ${code:-none}"; [ "$code" = 400 ] && url_sni_rejected "${ORDS_URL:-http://localhost:8080/ords/}" && warn "400 is Jetty's 'Invalid SNI': the host in ORDS_URL is not in the ORDS certificate - use the certificate's hostname"
    [ -x "${ORDS_HOME:-}/bin/ords" ] && for p in $ORDS_POOLS; do to 90 "$ORDS_HOME/bin/ords" --config "$ORDS_CONFIG" config --db-pool "$p" verify >>"$LOG_FILE" 2>&1 && log "ords config verify $p: ok" || warn "ords config verify $p: not ok / unsupported (see log)"; done; fi
  local dom f jndi; while IFS='|' read -r dom f jndi; do [ -n "$f" ] || continue; local ds; ds="$(grep -oE '<name>[^<]*</name>' "$f" | head -1 | sed 's/<[^>]*>//g')"
    if wlst_run "$dom" "domainRuntime()
for s in cmo.getServerRuntimes():
    r = s.getJDBCServiceRuntime().lookupJDBCDataSourceRuntime('$ds')
    if r is not None:
        res = r.testPool()
        print 'TESTPOOL', s.getName(), '$ds', (res is None and 'OK' or res)" 2>/dev/null; then grep -E '^TESTPOOL' "$LOG_FILE" | tail -3 | sed 's/^/  /' >&2; grep -E "^TESTPOOL .* $ds OK" "$LOG_FILE" >/dev/null && log "WebLogic $ds: testPool OK" || { warn "WebLogic $ds: testPool did not report OK"; }; fi
  done < <(for u in $(printf '%s\n' "$(targets)" | cut -d'|' -f3 | sort -u); do wls_ds_for "$u"; done)
  if ogg_detect >/dev/null 2>&1 && [ -x "${OGG_HOME:-/nonexistent}/ggsci" ]; then local a; for a in $(for u in $(printf '%s\n' "$(targets)" | cut -d'|' -f3 | sort -u); do gg_alias_for "$u"; done); do ggsci "dblogin useridalias $a" | grep -q 'Successfully logged into database' && log "GoldenGate alias $a: dblogin ok" || { err "GoldenGate alias $a: dblogin failed"; fail=1; }; done; fi
  state_set verify "$([ "$fail" = 0 ] && echo ok || echo failed)"; [ "$fail" = 0 ] && log "Verify OK" || err "Verify FAILED"; return "$fail"
}

cmd_rollback() {
  reuse_or_init rollback
  [ -f "$RUN_DIR/old_hashes.txt" ] || die "no old_hashes.txt in $RUN_DIR (nothing from a reset to roll back)"
  confirm "Restore the previous password hashes of $(wc -l <"$RUN_DIR/old_hashes.txt" | tr -d ' ') account(s) and the backed-up ORDS/WebLogic/GoldenGate files?" || die "aborted"
  local nfail=0 nok=0
  while IFS='|' read -r sid pdb u hash; do if usql "$sid" "$pdb" "restore old password of $u" "alter user \"$u\" identified by $hash;"; then nok=$((nok+1)); else nfail=$((nfail+1)); fi; done <"$RUN_DIR/old_hashes.txt"
  local p; for p in $(state_get ords_pools_changed || true); do [ -f "$RUN_DIR/pool.xml.$p.bak" ] && { log "ORDS pool $p: restoring pool.xml and wallet"; [ "$DRY_RUN" = 1 ] || { cp -p "$RUN_DIR/pool.xml.$p.bak" "$ORDS_CONFIG/databases/$p/pool.xml"; [ -f "$RUN_DIR/cwallet.sso.$p.bak" ] && cp -p "$RUN_DIR/cwallet.sso.$p.bak" "$ORDS_CONFIG/databases/$p/wallet/cwallet.sso"; }; }; done
  [ -n "$(state_get ords_pools_changed || true)" ] && ords_restart
  local b; for b in "$RUN_DIR"/*_config_jdbc_*.bak "$RUN_DIR"/*.xml.bak; do [ -f "$b" ] || continue; warn "WebLogic: $b is the previous JDBC module - the password inside is encrypted for that domain; copy it back over config/jdbc/ with the servers down, or set the old password in the console"; done
  [ -d "$RUN_DIR/dircrd.bak" ] && { log "GoldenGate: restoring dircrd"; [ "$DRY_RUN" = 1 ] || cp -rp "$RUN_DIR/dircrd.bak/." "$OGG_HOME/dircrd/"; }
  # a rollback that could not restore a hash is not "ok": say so, leave the state failed, exit non-zero
  [ "$nfail" = 0 ] || { state_set rollback failed; err "rollback incomplete: $nfail of $((nok+nfail)) password hash(es) NOT restored (see $LOG_FILE); the config files above were restored"; exit 1; }
  state_set rollback ok; log "rolled back ($nok hash(es) restored); run verify"
}

cmd_heal() {
  init_run_dir heal
  ords_detect >/dev/null 2>&1 || { log "no ORDS on this host; checking accounts only"; }
  local code; code="$(url_code "${ORDS_URL:-http://localhost:8080/ords/}" 15)"; log "ORDS ${ORDS_URL:-?}: HTTP ${code:-none}"
  local bad=""; while IFS='|' read -r sid pdb u st cm; do [ -z "$u" ] && continue; case "$st" in OPEN) ;; *) bad="$bad $sid|$pdb|$u|$st";; esac; done < <(targets)
  if [ -z "$bad" ]; then
    log "every service account is OPEN"
    [ "$code" = 503 ] && { warn "ORDS still 503 with open accounts: wrong password in the pool, or the database/listener is down. Pool users: $(for p in $ORDS_POOLS; do printf '%s=%s ' "$p" "$(ords_pool_user "$p")"; done). Try: ords --config $ORDS_CONFIG config --db-pool default verify ; tail $ORDS_CONFIG/../logs or journalctl -u ords"; grep -hE 'ORA-01017|ORA-28000|ORA-28001|ORA-28002|ORA-12514|ORA-12541' "${ORDS_HOME:-/nonexistent}"/logs/*.log /var/log/ords/*.log 2>/dev/null | tail -5 | sed 's/^/  log: /' >&2; }
    return 0
  fi
  local t; for t in $bad; do IFS='|' read -r sid pdb u st <<<"$t"
    case "$st" in
      LOCKED*) warn "$sid$(cs "$pdb") $u is $st (lock date $(wp "$pdb" sql_val "$sid" "(select to_char(lock_date,'YYYY-MM-DD HH24:MI') from dba_users where username='$u')"); failed logins come from something using an OLD password - find it before unlocking or it locks again): $(stores_of "$u")"
        confirm "unlock $u now?" && usql "$sid" "$pdb" "unlock $u" "alter user \"$u\" account unlock;";;
      EXPIRED*GRACE*) warn "$sid$(cs "$pdb") $u is in its grace period: logins still work but will stop. Fix for good: 'profile' (no expiry) + 'reset' (new password everywhere)"
        confirm "move $u to profile $SA_PROFILE now (stops the clock, does not un-expire)?" && { USERS="$u" ONLY_SID="$sid" ONLY_PDB="$([ "$pdb" = - ] || echo "$pdb")" cmd_profile; };;
      EXPIRED*) err "$sid$(cs "$pdb") $u is EXPIRED: every login fails (ORA-28001) until the password is reset. Stored in: $(stores_of "$u")"
        if confirm "reset $u now with a generated password and propagate it?"; then USERS="$u" ONLY_SID="$sid" ONLY_PDB="$([ "$pdb" = - ] || echo "$pdb")" GENERATE=1 cmd_reset; else log "then do: account-ops.sh reset --user $u --sid $sid$([ "$pdb" = - ] || echo " --pdb $pdb") --generate"; fi;;
      *) warn "$sid$(cs "$pdb") $u: $st";;
    esac
  done
  if [ -n "${ORDS_HOME:-}" ]; then
    case "${code:-000}" in
      503) confirm "restart ORDS now?" && ords_restart;;
      000) if [ -n "${ORDS_STOP_CMD:-}" ] || [ -n "${ORDS_SERVICE:-$(ords_service)}" ]; then warn "ORDS does not answer at all (no HTTP) - the process is down, not just the pool"; confirm "start ORDS now?" && ords_restart
           else warn "ORDS does not answer at all (no HTTP): start it (ORDS_SERVICE or ORDS_STOP_CMD/ORDS_START_CMD let this script do it)"; fi;;
    esac
  fi
  code="$(url_code "${ORDS_URL:-http://localhost:8080/ords/}" 15)"; log "ORDS after healing: HTTP ${code:-none}"; cmd_verify
}

main() {
  load_config; refuse_root
  local cmd="${1:-}"; shift || true; parse_opts "$@"
  case "$cmd" in
    inspect) cmd_inspect;; expiring) cmd_expiring;; unlock) cmd_unlock;; reset) cmd_reset;; profile) cmd_profile;; verify) cmd_verify;;
    rollback) cmd_rollback;; heal|run) cmd_heal;; ""|-h|--help|help) usage;; *) die "Unknown command: $cmd";;
  esac
}
main "$@"
