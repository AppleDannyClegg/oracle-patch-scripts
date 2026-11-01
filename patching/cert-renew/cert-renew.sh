#!/usr/bin/env bash
# cert-renew.sh - every TLS certificate on an Oracle host, sorted by days left, and the renewal of one of them:
# WebLogic identity keystores (from config.xml), NodeManager, ORDS standalone, OHS and listener/database
# wallets, Java cacerts, OKV endpoint and GoldenGate Microservices certificates, plus whatever answers TLS on
# a local port. Renewal = build the keystore/wallet from your new cert + key + chain, back up the old one,
# switch the product config (WebLogic via WLST, ORDS standalone.properties, wallet swap + listener reload,
# OHS wallet + restart, cacerts import), prove it with openssl s_client, roll back when it does not.
# Runs as the Oracle software owner. Secrets come from the conf (mode 600) or a prompt, never the command line.
#
# Usage: cert-renew.sh <command> [args] [options]
#
# Commands
#   inspect [target]     Every certificate found, sorted by days left (configured store AND what the port really serves)
#                        --report writes REPORT.md (expired CRIT, <30 d WARN, <90 d INFO, demo/self-signed, SHA1, <2048 bit)
#                        --json for machines. Exit code with --report: 2 CRIT, 1 WARN, 0 clean (cron-friendly)
#   csr <name>           New private key + CSR: --cn, --san a,b (CN added), --bits; written to CERT_DIR/<name>/
#   plan <target>        What apply would do with --cert FILE --key FILE [--chain FILE]: cert/key match, chain, names, dates
#   preflight <target>   plan + tools present, credentials available, files writable, live port reachable
#   backup <target>      Copy the current keystore/wallet/config of the target into the run dir
#   apply <target>       Build the new store, back up, switch the config, restart when --restart (or RESTART_CMDS)
#   verify <target>      s_client on the target's port(s): serial = the new cert, chain verifies, hostname covered, days left
#   rollback             Put the previous store/config back (latest run or --run-dir) and restart again; refuses once the
#                        backup is past BACKUP_KEEP_HOURS (168) or cleanup has shredded it
#   cleanup              Shred this run's backup (the previous keystore/wallet and the password that opens it); every
#                        command also shreds backups older than BACKUP_KEEP_HOURS in RUN_BASE, so none is kept for ever
#   run <target>         inspect > preflight > backup > apply > restart > verify (rollback on failure)
#
# Targets
#   wls:<domain>:<server>   a WebLogic server's identity keystore (domain = directory name or path); wls:<domain> = all SSL servers
#   nm:<domain>             the NodeManager of that domain (nodemanager.properties)
#   ords                    ORDS standalone HTTPS (standalone.https.cert / .cert.key)
#   listener                the listener/database TCPS wallet (WALLET_LOCATION in listener.ora / sqlnet.ora)
#   ohs:<instance>          an Oracle HTTP Server instance's wallet (SSLWallet in ssl.conf)
#   java:<JAVA_HOME>        trust only: import the --chain CAs into that JDK's cacerts
#
# Options
#   --cert FILE  --key FILE  --chain FILE   the new certificate (PEM), its private key (PEM), the CA chain (PEM, root last)
#   --cn NAME  --san a,b  --bits N          for csr                 --alias NAME   identity alias (default server_cert)
#   --wallet DIR                            wallet dir when it cannot be read from the config
#   --trust-mode M                          WebLogic KeyStores value (CustomIdentityAndJavaStandardTrust | CustomIdentityAndCustomTrust)
#   --restart        restart the target after apply (also done when RESTART_CMDS names the target)   --no-scan  skip the live port scan
#   --report  --out DIR  --dry-run  --yes  --force  --json  --verbose  --run-dir DIR
#
# Config: cert-renew.conf (mode 600), ~/.cert-renew.conf or the shared oracle.conf: KS_PASSWORDS (comma list tried on
# existing keystores), WLS_KS_PASS (new keystore), WLS_KS_TYPE (JKS|PKCS12), WLS_ADMIN_URL + WLS_USERCONFIG/WLS_USERKEY or
# WLS_ADMIN_USER/WLS_ADMIN_PASSWORD, WALLET_PASSWORD, CACERTS_PASSWORD, KEY_PASSWORD (if the key is encrypted), CERT_DIR,
# CERT_OUT, CSR_SUBJECT_SUFFIX ("/O=Bank/C=GB"), CHECK_HOST (name the cert must cover), EXTRA_PORTS, GG_DEPLOY_DIRS,
# OKV_DIRS, RESTART_CMDS ("ords=sudo -n systemctl restart ords,wls:dom:srv=/u01/.../restart.sh,listener=lsnrctl ..."),
# WARN_DAYS (30), INFO_DAYS (90), PORT_LIMIT (100).

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="cert-renew"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

CERT=""; KEY=""; CHAIN=""; CN=""; SAN=""; BITS="${CSR_BITS:-2048}"; CERT_ALIAS="${CERT_ALIAS:-server_cert}"; WALLET_OPT=""; TRUST_MODE_OPT=""
DO_RESTART=0; NO_SCAN=0; REPORT_OUT=0
KS_PASSWORDS="${KS_PASSWORDS:-}"; WLS_KS_PASS="${WLS_KS_PASS:-}"; WLS_KS_TYPE="${WLS_KS_TYPE:-JKS}"; WALLET_PASSWORD="${WALLET_PASSWORD:-}"
CACERTS_PASSWORD="${CACERTS_PASSWORD:-changeit}"; KEY_PASSWORD="${KEY_PASSWORD:-}"; CSR_SUBJECT_SUFFIX="${CSR_SUBJECT_SUFFIX:-}"
VERIFY_WAIT="${VERIFY_WAIT:-90}"; CERT_DIR="${CERT_DIR:-$HOME/cert-renew/csr}"; CERT_OUT="${CERT_OUT:-$HOME/cert-renew}"; CHECK_HOST="${CHECK_HOST:-$(hostname -f 2>/dev/null || hostname)}"
EXTRA_PORTS="${EXTRA_PORTS:-}"; GG_DEPLOY_DIRS="${GG_DEPLOY_DIRS:-}"; OKV_DIRS="${OKV_DIRS:-}"; RESTART_CMDS="${RESTART_CMDS:-}"
WARN_DAYS="${WARN_DAYS:-30}"; INFO_DAYS="${INFO_DAYS:-90}"; PORT_LIMIT="${PORT_LIMIT:-100}"
CERTS=""        # rows: days|kind|target|where|cn|issuer|notafter|sig|bits|serial|flags
LIVE_PORTS=""   # ports already probed through a configured item
KEYTOOL=""; ORAPKI=""
T_KIND=""; T_DOMAIN=""; T_SERVER=""; T_INST=""; T_JH=""; T_PORT=""; T_ADDR=""; T_FILE=""; T_TYPE=""; T_ALIAS=""; T_MODE=""; T_TRUST=""; T_TRUSTTYPE=""; T_WALLET=""; T_PROPS=""; T_HOME=""; T_NAME=""

usage() { usage_from_header "$0"; }
parse_opts() {
  ARGS=()
  while [ $# -gt 0 ]; do case "$1" in
    --cert) optchk "$@"; CERT="$2"; shift 2;; --key) optchk "$@"; KEY="$2"; shift 2;; --chain) optchk "$@"; CHAIN="$2"; shift 2;; --cn) optchk "$@"; CN="$2"; shift 2;; --san) optchk "$@"; SAN="$2"; shift 2;; --bits) optchk "$@"; BITS="$2"; shift 2;;
    --alias) optchk "$@"; CERT_ALIAS="$2"; shift 2;; --wallet) optchk "$@"; WALLET_OPT="$2"; shift 2;; --trust-mode) optchk "$@"; TRUST_MODE_OPT="$2"; shift 2;; --out) optchk "$@"; CERT_OUT="$2"; shift 2;;
    --restart) DO_RESTART=1; shift;; --no-scan) NO_SCAN=1; shift;; --report) REPORT_OUT=1; shift;;
    --force) FORCE=1; shift;; --dry-run) DRY_RUN=1; shift;; --yes) ASSUME_YES=1; shift;; --json) JSON_OUT=1; shift;; --verbose) VERBOSE=1; shift;; --run-dir) optchk "$@"; RUN_DIR="$2"; shift 2;;
    -h|--help) usage; exit 0;; --*) die "Unknown option: $1";; *) ARGS+=("$1"); shift;; esac; done
}

# ---------------------------------------------------------------------------
# tools and certificate facts
# ---------------------------------------------------------------------------
find_tools() {
  local j; for j in "${JAVA_HOME:-}" $(java_homes); do [ -x "$j/bin/keytool" ] && { KEYTOOL="$j/bin/keytool"; break; }; done
  [ -z "$KEYTOOL" ] && have keytool && KEYTOOL="$(command -v keytool)"
  ORAPKI="${ORAPKI:-}"; [ -z "$ORAPKI" ] && for j in "${ORACLE_HOME:-}" "$(db_home_of "$(db_instances | head -1)")" $(listener_homes | awk '{print $1}') $(grid_home); do [ -x "$j/bin/orapki" ] && { ORAPKI="$j/bin/orapki"; break; }; done
  [ -z "$ORAPKI" ] && have orapki && ORAPKI="$(command -v orapki)"
  require_cmd openssl
}
# x509_facts <pem>: X_SUBJ X_CN X_ISS X_ICN X_END X_SERIAL X_SIG X_KEYALG X_BITS X_SAN X_SELF X_DAYS
x509_facts() {
  local f="$1" txt
  X_SUBJ="$(openssl x509 -in "$f" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//')"
  X_ISS="$(openssl x509 -in "$f" -noout -issuer -nameopt RFC2253 2>/dev/null | sed 's/^issuer=//')"
  X_END="$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | sed 's/notAfter=//')"
  X_SERIAL="$(openssl x509 -in "$f" -noout -serial 2>/dev/null | sed 's/serial=//')"
  txt="$(openssl x509 -in "$f" -noout -text 2>/dev/null)"
  X_SIG="$(printf '%s\n' "$txt" | grep -m1 'Signature Algorithm' | awk '{print $NF}')"
  X_KEYALG="$(printf '%s\n' "$txt" | grep -m1 'Public Key Algorithm' | awk '{print $NF}')"
  X_BITS="$(printf '%s\n' "$txt" | grep -m1 -oE 'Public-Key: \([0-9]+ bit' | grep -oE '[0-9]+')"
  X_SAN="$(printf '%s\n' "$txt" | grep -A1 'Subject Alternative Name' | tail -1 | sed 's/^ *//; s/DNS://g; s/IP Address://g; s/, */,/g')"
  X_CN="$(printf '%s' "$X_SUBJ" | sed -n 's/.*CN=\([^,]*\).*/\1/p')"; [ -z "$X_CN" ] && X_CN="$X_SUBJ"
  X_ICN="$(printf '%s' "$X_ISS" | sed -n 's/.*CN=\([^,]*\).*/\1/p')"; [ -z "$X_ICN" ] && X_ICN="$X_ISS"
  X_SELF=0; [ "$X_SUBJ" = "$X_ISS" ] && X_SELF=1
  X_DAYS="$(days_until "$X_END" 2>/dev/null)"; [ -z "$X_DAYS" ] && X_DAYS="?"
  [ -n "$X_END" ]
}
# add_cert <kind> <target> <where> <pem> [flags]: one row from a PEM certificate
add_cert() {
  local kind="$1" target="$2" where="$3" pem="$4" flags="${5:-}"
  x509_facts "$pem" || { CERTS="${CERTS}?|$kind|$target|$where|unreadable|-|-|-|-|-|unreadable"$'\n'; return 1; }
  [ "$X_SELF" = 1 ] && flags="${flags:+$flags,}self-signed"
  { printf '%s\n' "$X_CN" "$X_ICN" | grep -qiE 'demo|^localhost$|CertGenCA' || printf '%s' "$X_ISS" | grep -q 'OracleOHS'; } && flags="${flags:+$flags,}demo"
  printf '%s' "$X_SIG" | grep -qiE 'sha1|md5' && flags="${flags:+$flags,}weak-sig"
  [ "$X_KEYALG" = rsaEncryption ] && [ -n "$X_BITS" ] && [ "$X_BITS" -lt 2048 ] && flags="${flags:+$flags,}weak-key"
  CERTS="${CERTS}$X_DAYS|$kind|$target|$where|$X_CN|$X_ICN|$X_END|$X_SIG|${X_BITS:-?}|$X_SERIAL|${flags:--}"$'\n'
}
# live_pem <host:port> <out.pem>: the certificate a port serves (chain in <out>.chain); 1 when nothing answers TLS
live_pem() {
  local hp="$1" out="$2" raw; raw="$(echo | to 8 openssl s_client -connect "$hp" -servername "$CHECK_HOST" -showcerts 2>/dev/null)"
  printf '%s\n' "$raw" | awk '/BEGIN CERTIFICATE/{c++} c>=1{print} /END CERTIFICATE/{if(c>=1)exit}' >"$out"
  printf '%s\n' "$raw" | awk '/BEGIN CERTIFICATE/{p=1} p{print} /END CERTIFICATE/{p=0}' >"$out.chain"
  grep -q 'END CERTIFICATE' "$out"
}
# add_live <kind> <target> <host:port>: row for what the port really serves; sets LIVE_SERIAL
add_live() {
  local kind="$1" target="$2" hp="$3" out; out="$RUN_DIR/live_$(printf '%s' "$hp" | tr ':' '_').pem"
  LIVE_PORTS="$LIVE_PORTS ${hp##*:} "
  LIVE_SERIAL=""; if live_pem "$hp" "$out"; then add_cert "$kind" "$target" "live $hp" "$out" live; LIVE_SERIAL="$X_SERIAL"
  else CERTS="${CERTS}?|$kind|$target|live $hp|no TLS answer|-|-|-|-|-|down"$'\n'; fi
}
# kt <keystore> <pass|-> <keytool args...>: keytool with the password from a 600 file (or none: JKS lists without one)
kt() {
  local ks="$1" pw="$2"; shift 2; local pf
  if [ "$pw" = - ] || [ -z "$pw" ]; then printf '\n' | to 60 "$KEYTOOL" "$@" -keystore "$ks" 2>/dev/null
  else pf="$(tmp_secret_file "$pw")"; to 60 "$KEYTOOL" "$@" -keystore "$ks" -storepass:file "$pf" 2>>"${KT_ERR:-/dev/null}"; local rc=$?; rm -f "$pf"; return $rc; fi
}
# ks_pass <keystore> [type]: a password that opens it (KS_PASSWORDS, WLS_KS_PASS, defaults, demo) or "-"
ks_pass() {
  local ks="$1" t="${2:-}" p; for p in ${KS_PASSWORDS//,/ } "$WLS_KS_PASS" "$CACERTS_PASSWORD" DemoIdentityKeyStorePassPhrase DemoTrustKeyStorePassPhrase; do
    [ -n "$p" ] || continue; kt "$ks" "$p" -list ${t:+-storetype "$t"} >/dev/null && { printf '%s' "$p"; return 0; }; done
  [ "${t:-JKS}" = JKS ] && kt "$ks" - -list >/dev/null 2>&1 && { printf '%s' -; return 0; }
  printf '%s' -; return 1
}
ks_type_of() { case "$1" in *.p12|*.pfx|*.pkcs12) echo PKCS12;; *.jks) echo JKS;; *) echo "${2:-JKS}";; esac; }
# ks_entries <keystore> <pass> <type>: "alias|PrivateKeyEntry|trustedCertEntry" lines
ks_entries() { kt "$1" "$2" -list -storetype "$3" | grep -E ', *(PrivateKeyEntry|trustedCertEntry|SecretKeyEntry)' | sed -E 's/^([^,]*),.*(PrivateKeyEntry|trustedCertEntry|SecretKeyEntry).*/\1|\2/'; }
# add_keystore <kind> <target> <keystore> <type> [alias]: identity entries (or the one alias) of a keystore
add_keystore() {
  local kind="$1" target="$2" ks="$3" t="$4" want="${5:-}" pw e a kind2 out
  [ -f "$ks" ] || { CERTS="${CERTS}?|$kind|$target|$ks|missing file|-|-|-|-|-|missing"$'\n'; return 1; }
  pw="$(ks_pass "$ks" "$t")" || { if [ "$t" != JKS ]; then CERTS="${CERTS}?|$kind|$target|$ks|no password opens it (KS_PASSWORDS)|-|-|-|-|-|locked"$'\n'; return 1; fi; }
  local n=0; while IFS='|' read -r a kind2; do
    [ -n "$want" ] && [ "$a" != "$want" ] && continue
    [ -z "$want" ] && [ "$kind2" != PrivateKeyEntry ] && continue
    out="$RUN_DIR/ks_$(printf '%s' "$ks$a" | tr '/ ' '__').pem"; kt "$ks" "$pw" -exportcert -rfc -storetype "$t" -alias "$a" >"$out" || continue
    add_cert "$kind" "$target" "$ks alias $a" "$out" "$([ "$kind2" = PrivateKeyEntry ] && echo identity || echo trusted)"; n=$((n+1))
  done < <(ks_entries "$ks" "$pw" "$t")
  [ "$n" = 0 ] && { local why="no PrivateKeyEntry"; [ -n "$want" ] && why="alias $want not found"; CERTS="${CERTS}?|$kind|$target|$ks|$why|-|-|-|-|-|empty"$'\n'; }
  return 0
}
# wallet_certs <dir> <outdir>: user certificate(s) of an Oracle wallet as PEM files (openssl with WALLET_PASSWORD, else orapki export)
wallet_certs() {
  local d="$1" o="$2" pf; mkdir -p "$o"
  if [ -f "$d/ewallet.p12" ] && [ -n "$WALLET_PASSWORD" ]; then
    pf="$(tmp_secret_file "$WALLET_PASSWORD")"
    { openssl pkcs12 -in "$d/ewallet.p12" -nokeys -clcerts -passin "file:$pf" 2>/dev/null || openssl pkcs12 -legacy -in "$d/ewallet.p12" -nokeys -clcerts -passin "file:$pf" 2>/dev/null; } | awk -v o="$o" '/BEGIN CERTIFICATE/{n++; f=o"/user"n".pem"} f{print >f} /END CERTIFICATE/{close(f); f=""}'
    rm -f "$pf"
  elif [ -n "$ORAPKI" ] && [ -f "$d/cwallet.sso" ]; then
    local dn n=0; while IFS= read -r dn; do n=$((n+1)); to 60 "$ORAPKI" wallet export -wallet "$d" -dn "$dn" -cert "$o/user$n.pem" >/dev/null 2>&1 </dev/null; done < <(to 60 "$ORAPKI" wallet display -wallet "$d" 2>/dev/null </dev/null | awk '/User Certificates:/{u=1;next} /Trusted Certificates:/{u=0} u&&/Subject:/{sub(/^ *Subject: */,""); print}')
  fi
  ls "$o"/user*.pem >/dev/null 2>&1
}
add_wallet() { # <kind> <target> <dir>
  local kind="$1" target="$2" d="$3" o f
  [ -d "$d" ] || { CERTS="${CERTS}?|$kind|$target|$d|wallet dir missing|-|-|-|-|-|missing"$'\n'; return 1; }
  o="$RUN_DIR/wallet_$(printf '%s' "$d" | tr '/' '_')"
  if wallet_certs "$d" "$o"; then for f in "$o"/user*.pem; do add_cert "$kind" "$target" "$d (ewallet.p12)" "$f" identity; done
  else CERTS="${CERTS}?|$kind|$target|$d|not readable: set WALLET_PASSWORD$([ -z "$ORAPKI" ] && echo ' (no orapki)')|-|-|-|-|-|locked"$'\n'; fi
}

# ---------------------------------------------------------------------------
# discovery per product
# ---------------------------------------------------------------------------
# wls_ssl_servers <domain>: name|address|ssl_enabled|ssl_port|keystores|idfile|idtype|alias|trustfile|trusttype
wls_ssl_servers() {
  awk '/<server>/{b=1;s=0;n="";a="";e="";p="";k="";f="";t="";al="";tf="";tt=""} b&&/<ssl>/{s=1} b&&/<\/ssl>/{s=0}
       b&&n==""&&match($0,/<name>[^<]*<\/name>/){n=substr($0,RSTART+6,RLENGTH-13)}
       b&&a==""&&match($0,/<listen-address>[^<]*<\/listen-address>/){a=substr($0,RSTART+16,RLENGTH-33)}
       b&&s&&match($0,/<enabled>[^<]*<\/enabled>/){e=substr($0,RSTART+9,RLENGTH-19)}
       b&&s&&match($0,/<listen-port>[^<]*<\/listen-port>/){p=substr($0,RSTART+13,RLENGTH-27)}
       b&&s&&match($0,/<server-private-key-alias>[^<]*<\/server-private-key-alias>/){al=substr($0,RSTART+26,RLENGTH-53)}
       b&&match($0,/<key-stores>[^<]*<\/key-stores>/){k=substr($0,RSTART+12,RLENGTH-25)}
       b&&match($0,/<custom-identity-key-store-file-name>[^<]*<\/custom-identity-key-store-file-name>/){f=substr($0,RSTART+37,RLENGTH-75)}
       b&&match($0,/<custom-identity-key-store-type>[^<]*<\/custom-identity-key-store-type>/){t=substr($0,RSTART+32,RLENGTH-65)}
       b&&match($0,/<custom-trust-key-store-file-name>[^<]*<\/custom-trust-key-store-file-name>/){tf=substr($0,RSTART+34,RLENGTH-69)}
       b&&match($0,/<custom-trust-key-store-type>[^<]*<\/custom-trust-key-store-type>/){tt=substr($0,RSTART+29,RLENGTH-59)}
       b&&/<\/server>/{b=0; print n"|"a"|"(e==""?"false":e)"|"(p==""?"7002":p)"|"(k==""?"DemoIdentityAndDemoTrust":k)"|"f"|"t"|"al"|"tf"|"tt}' "$1/config/config.xml" 2>/dev/null
}
wls_home_of_domain() { local h; for h in $(wls_homes); do wls_domains "$h" | grep -qx "$1" && { printf '%s' "$h"; return; }; done; wls_homes | head -1; }
demo_identity() { local d="$1" h; h="$(wls_home_of_domain "$d")"; local f; for f in "$d/security/DemoIdentity.jks" "$d/security/DemoIdentity.p12" "$h/wlserver/server/lib/DemoIdentity.jks" "$h/wlserver/server/lib/DemoIdentity.p12"; do [ -f "$f" ] && { printf '%s' "$f"; return; }; done; }
abs_in() { case "$2" in /*) printf '%s' "$2";; *) printf '%s/%s' "$1" "$2";; esac; }
# inspect_wls [domain] [server]
inspect_wls() {
  local h d row n a e p k f t al tf tt ks kst target
  for h in $(wls_homes); do for d in $(wls_domains "$h"); do
    [ -n "${1:-}" ] && [ "$d" != "$1" ] && [ "$(basename "$d")" != "$1" ] && continue
    while IFS='|' read -r n a e p k f t al tf tt; do
      [ -n "${2:-}" ] && [ "$n" != "$2" ] && continue
      target="wls:$(basename "$d"):$n"
      [ "$e" = true ] || { [ -n "${2:-}" ] && CERTS="${CERTS}?|wls|$target|config.xml|SSL not enabled|-|-|-|-|-|ssl-off"$'\n'; continue; }
      X_SERIAL=""; case "$k" in Demo*) ks="$(demo_identity "$d")"; kst="$(ks_type_of "$ks")"; al="${al:-demoidentity}"; add_keystore wls "$target" "$ks" "$kst" "$al";;
        CustomIdentity*) ks="$(abs_in "$d" "$f")"; kst="${t:-$(ks_type_of "$ks")}"; add_keystore wls "$target" "$ks" "$kst" "$al";;
        *) CERTS="${CERTS}?|wls|$target|config.xml|KeyStores=$k|-|-|-|-|-|-"$'\n';; esac
      local cfgserial="$X_SERIAL"; add_live wls "$target" "${a:-127.0.0.1}:$p"
      [ -n "$LIVE_SERIAL" ] && [ -n "$cfgserial" ] && [ "$LIVE_SERIAL" != "$cfgserial" ] && finding WARN wls "$target serves serial $LIVE_SERIAL but the configured keystore holds $cfgserial: a restart or an activate is pending"
    done < <(wls_ssl_servers "$d")
    [ -n "${2:-}" ] && continue
    local nmp="$d/nodemanager/nodemanager.properties"; if [ -f "$nmp" ] && grep -q '^KeyStores=CustomIdentity' "$nmp"; then
      ks="$(abs_in "$d" "$(sed -n 's/^CustomIdentityKeyStoreFileName=//p' "$nmp" | head -1)")"; add_keystore nm "nm:$(basename "$d")" "$ks" "$(sed -n 's/^CustomIdentityKeyStoreType=//p' "$nmp" | head -1 | grep . || ks_type_of "$ks")" "$(sed -n 's/^CustomIdentityAlias=//p' "$nmp" | head -1)"
      local nmport; nmport="$(sed -n 's/^ListenPort=//p' "$nmp" | head -1)"; grep -q '^SecureListener=false' "$nmp" || add_live nm "nm:$(basename "$d")" "127.0.0.1:${nmport:-5556}"
    elif [ -f "$nmp" ] && ! grep -q '^SecureListener=false' "$nmp"; then
      ks="$(demo_identity "$d")"; [ -n "$ks" ] && add_keystore nm "nm:$(basename "$d")" "$ks" "$(ks_type_of "$ks")" demoidentity; fi
  done; done
}
# ORDS 19-21 kept the standalone settings in global/standalone/standalone.properties (key=value); 22+ keeps them in
# global/settings.xml (<entry key="standalone.https.cert">...</entry>), written with "ords config set"
ords_props() { local p="${ORDS_CONFIG:-}/global/standalone/standalone.properties"; [ -f "$p" ] || { [ -f "${ORDS_CONFIG:-}/global/settings.xml" ] && p="$ORDS_CONFIG/global/settings.xml"; }; printf '%s' "$p"; }
ords_prop() { local f; f="$(ords_props)"; case "$f" in *.xml) sed -n "s#.*<entry key=\"$1\">\(.*\)</entry>.*#\1#p" "$f" 2>/dev/null | head -1;; *) sed -n "s/^$1=//p" "$f" 2>/dev/null | head -1;; esac; }
ords_set_prop() { # <key> <value>: "ords config set" when the CLI runs here, else edit the file
  local f; f="$(ords_props)"
  case "$f" in
    *.xml) if [ -x "${ORDS_HOME:-/nonexistent}/bin/ords" ] && "$ORDS_HOME/bin/ords" --config "$ORDS_CONFIG" config set "$1" "$2" >>"$LOG_FILE" 2>&1; then return 0; fi
           sed -i "\#<entry key=\"$1\">#d" "$f" && sed -i "s#</properties>#<entry key=\"$1\">$2</entry>\n</properties>#" "$f";;
    *) { grep -vE "^$1=" "$f"; printf '%s=%s\n' "$1" "$2"; } >"$f.tmp" && cat "$f.tmp" >"$f" && rm -f "$f.tmp";;
  esac
}
inspect_ords() {
  ords_detect >/dev/null 2>&1 || return 0
  local p c k port; p="$(ords_props)"; [ -f "$p" ] || { dbg "no $p"; return 0; }
  port="$(ords_prop standalone.https.port)"; c="$(ords_prop standalone.https.cert)"; k="$(ords_prop standalone.https.cert.key)"
  [ -z "$c" ] && { c="$(ords_prop ssl.cert)"; k="$(ords_prop ssl.cert.key)"; }
  if [ -n "$c" ]; then add_cert ords ords "$p: $c" "$c" identity
  elif [ -n "$port" ]; then local s; s="$(ls "$ORDS_CONFIG"/global/standalone/*self*signed*.pem "$ORDS_CONFIG"/global/standalone/*.crt 2>/dev/null | head -1)"; [ -n "$s" ] && add_cert ords ords "$p: generated $s" "$s" "identity,demo" || CERTS="${CERTS}?|ords|ords|$p|https on $port with no standalone.https.cert: ORDS generates a self-signed one|-|-|-|-|-|demo"$'\n'
  else return 0; fi
  [ -n "$port" ] && add_live ords ords "127.0.0.1:$port"
}
# listener wallet: WALLET_LOCATION in listener.ora / sqlnet.ora of each listener home (or TNS_ADMIN)
wallet_dir_in() { tr -d ' \t\n' <"$1" 2>/dev/null | grep -oE 'WALLET_LOCATION=\(SOURCE=\(METHOD=FILE\)\(METHOD_DATA=\(DIRECTORY=[^)]*' | sed 's/.*DIRECTORY=//' | head -1; }
tcps_ports_in() { tr -d ' \t\n' <"$1" 2>/dev/null | grep -oE '\(ADDRESS=(\([A-Z_]+=[^()]*\))+\)' | grep 'PROTOCOL=TCPS' | grep -oE 'PORT=[0-9]+' | cut -d= -f2 | sort -u; }
listener_admin_dirs() { { [ -n "${TNS_ADMIN:-}" ] && echo "$TNS_ADMIN"; listener_homes | awk '{print $1"/network/admin"}'; local s; for s in $(db_instances); do echo "$(db_home_of "$s")/network/admin"; done; [ -n "$(grid_home)" ] && echo "$(grid_home)/network/admin"; } 2>/dev/null | grep . | sort -u; }
inspect_listener() {
  local ad w f ports port done=""
  for ad in $(listener_admin_dirs); do
    w="${WALLET_OPT:-}"; [ -z "$w" ] && for f in "$ad/listener.ora" "$ad/sqlnet.ora"; do [ -f "$f" ] && w="$(wallet_dir_in "$f")" && [ -n "$w" ] && break; done
    ports="$(tcps_ports_in "$ad/listener.ora")"
    [ -z "$w" ] && [ -z "$ports" ] && continue
    [ -n "$w" ] && ! printf '%s' "$done" | grep -q " $w " && { add_wallet listener listener "$w"; done="$done $w "; }
    for port in $ports; do add_live listener listener "127.0.0.1:$port"; done
  done
}
inspect_ohs() {
  local h d i conf w port inst
  for h in $(wls_homes); do for d in $(wls_domains "$h"); do for conf in "$d"/config/fmwconfig/components/OHS/instances/*/ssl.conf; do
    [ -f "$conf" ] || continue; i="$(basename "$(dirname "$conf")")"; inst="ohs:$i"
    w="$(sed -n 's/^[[:space:]]*SSLWallet[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$conf" | head -1 | sed "s#\${ORACLE_INSTANCE}#$d#g; s#\${COMPONENT_TYPE}#OHS#g; s#\${COMPONENT_NAME}#$i#g")"
    [ -n "$w" ] && add_wallet ohs "$inst" "$w"
    port="$(grep -oE '^<VirtualHost[^>]*:[0-9]+' "$conf" | grep -oE '[0-9]+$' | head -1)"; [ -n "$port" ] && add_live ohs "$inst" "127.0.0.1:$port"
  done; done; done
}
inspect_java() {
  local j c pw n exp soon out line a
  for j in $(java_homes); do
    c="$j/jre/lib/security/cacerts"; [ -f "$c" ] || c="$j/lib/security/cacerts"; [ -f "$c" ] || continue
    pw="$(ks_pass "$c" JKS)" || true
    out="$RUN_DIR/cacerts_$(printf '%s' "$j" | tr '/' '_').txt"; kt "$c" "$pw" -list -v >"$out" || { CERTS="${CERTS}?|cacerts|java:$j|$c|cannot list (CACERTS_PASSWORD?)|-|-|-|-|-|locked"$'\n'; continue; }
    n="$(grep -c '^Alias name:' "$out")"; exp=""; soon=""
    while IFS= read -r line; do a="${line%%|*}"; local dd; dd="$(days_until "${line#*|}" 2>/dev/null || echo 99999)"; if [ "$dd" -le 0 ]; then exp="$exp $a"; elif [ "$dd" -lt "$INFO_DAYS" ]; then soon="$soon $a"; fi; done < <(awk '/^Alias name:/{a=$3} /^Valid from:/{sub(/.*until: /,""); print a"|"$0}' "$out")
    CERTS="${CERTS}$([ -n "$exp" ] && echo 0 || { [ -n "$soon" ] && echo "$INFO_DAYS" || echo 9999; })|cacerts|java:$j|$c|$n trusted CAs|-|$([ -n "$exp" ] && echo "expired:$exp;")$([ -n "$soon" ] && echo "expiring:$soon")|-|-|-|$([ -n "$exp$soon" ] && echo trust-expiry || echo -)"$'\n'
  done
}
inspect_okv() {
  local d f; for d in ${OKV_DIRS//,/ } "${OKV_HOME:-}" /opt/oracle/okv* /u01/app/oracle/okv* "${WALLET_ROOT:-}"/okv /etc/ORACLE/WALLETS/*/okv /etc/ORACLE/KEYSTORES/*/okv "${ORACLE_BASE:-/u01/app/oracle}"/admin/*/wallet/okv "${ORACLE_BASE:-/u01/app/oracle}"/okv/*; do
    [ -d "$d" ] || continue; f="$(find "$d" -maxdepth 3 -path '*/ssl/cert.pem' 2>/dev/null | head -1)"; [ -n "$f" ] || continue
    add_cert okv "okv:$(dirname "$(dirname "$f")")" "$f" "$f" "endpoint,TDE"
  done
}
inspect_gg() {
  local d f; ogg_detect >/dev/null 2>&1 || [ -n "$GG_DEPLOY_DIRS" ] || return 0
  for d in ${GG_DEPLOY_DIRS//,/ } /u01/app/oracle/gg_deployments /u01/app/ogg/deployments /u01/ogg/deployments /u01/app/oracle/goldengate/deployments "${OGG_HOME:-/nonexistent}"/../deployments; do
    [ -d "$d" ] || continue
    while IFS= read -r f; do grep -q 'BEGIN CERTIFICATE' "$f" 2>/dev/null && add_cert gg "gg:$(basename "$(dirname "$(dirname "$(dirname "$f")")")")" "$f" "$f"; done < <(find "$d" -maxdepth 5 -path '*/etc/ssl/*' \( -name '*.pem' -o -name '*.crt' \) 2>/dev/null | head -40)
  done
}
apex_wallet_one() { local sid="$1" v; v="$(sql_val "$sid" "apex_instance_admin.get_parameter('WALLET_PATH')" 2>/dev/null)"; printf '%s' "$v" | grep -qE '^file:' && { v="${v#file:}"; add_wallet apex "apex:$sid${PDB_SET:+/$(printf '%s' "$PDB_SET" | sed 's/.*container=//; s/;//')}" "$v"; }; }
inspect_apex() {
  local sid p; for sid in $(db_instances); do sql_ok "$sid" || continue
    if db_is_cdb "$sid"; then for p in $(db_pdbs "$sid"); do with_pdb "$p" apex_wallet_one "$sid"; done; else apex_wallet_one "$sid"; fi; done
}
listening_ports() { # "port process" for every local TCP listener
  if have ss; then ss -Hltnp 2>/dev/null | awk '{p=$4; sub(/.*:/,"",p); pr=$NF; if (match(pr,/\("[^"]+"/)) pr=substr(pr,RSTART+2,RLENGTH-3); else pr="?"; print p, pr}'
  elif have lsof; then lsof -nP -iTCP -sTCP:LISTEN 2>/dev/null | awk 'NR>1{p=$9; sub(/.*:/,"",p); print p, $1}'
  else netstat -ltn 2>/dev/null | awk '/LISTEN/{p=$4; sub(/.*[:.]/,"",p); print p, "?"}'; fi | sort -u -k1,1n
}
inspect_ports() {
  [ "$NO_SCAN" = 1 ] && return 0
  local port proc n=0 p; for p in ${EXTRA_PORTS//,/ }; do printf '%s' "$LIVE_PORTS" | grep -q " $p " || add_live port "tcp:$p" "127.0.0.1:$p"; done
  while read -r port proc; do
    case "$port" in ''|*[!0-9]*) continue;; esac; printf '%s' "$LIVE_PORTS" | grep -q " $port " && continue; [ "$port" -lt 1024 ] && [ "$proc" != "?" ] && [ "$proc" != tnslsnr ] && continue
    n=$((n+1)); [ "$n" -gt "$PORT_LIMIT" ] && { warn "port scan stopped after $PORT_LIMIT ports (PORT_LIMIT)"; break; }
    local out; out="$RUN_DIR/live_127.0.0.1_$port.pem"; live_pem "127.0.0.1:$port" "$out" && add_cert port "tcp:$port ($proc)" "live 127.0.0.1:$port" "$out" live
  done < <(listening_ports)
}

# ---------------------------------------------------------------------------
# rows -> table, findings, json
# ---------------------------------------------------------------------------
sorted_rows() { printf '%s' "$CERTS" | grep . | awk -F'|' '{d=$1; if (d=="?") d=99998; print d"\t"$0}' | sort -n -k1,1 | cut -f2-; }
rows_findings() {
  local days kind target where cn issuer end sig bits serial flags
  while IFS='|' read -r days kind target where cn issuer end sig bits serial flags; do
    case "$flags" in *missing*|*locked*|*unreadable*) finding WARN "$kind" "$target: $where - $cn";; *down*) finding WARN "$kind" "$target: $where does not answer TLS";; esac
    [ "$days" = "?" ] && continue
    local what="$target ($cn, $where)"
    if [ "$days" -le 0 ]; then finding CRIT "$kind" "$what EXPIRED $end$([ "$kind" = okv ] && echo ' - TDE key operations with OKV will fail: re-enrol the endpoint')"
    elif [ "$days" -lt "$WARN_DAYS" ]; then finding WARN "$kind" "$what expires in $days days ($end)"
    elif [ "$days" -lt "$INFO_DAYS" ]; then finding INFO "$kind" "$what expires in $days days ($end)"; fi
    case "$flags" in *demo*) finding WARN "$kind" "$what is a demo/self-signed certificate (issuer $issuer)";; *self-signed*) [ "$kind" != cacerts ] && finding WARN "$kind" "$what is self-signed";; esac
    case "$flags" in *weak-sig*) finding WARN "$kind" "$what is signed with $sig";; esac
    case "$flags" in *weak-key*) finding WARN "$kind" "$what has a $bits-bit RSA key";; esac
    case "$flags" in *trust-expiry*) finding INFO "$kind" "$target cacerts: $end";; esac
  done < <(sorted_rows)
}
print_rows() { # [target prefix]
  printf '%-6s %-9s %-34s %-32s %-28s %-24s %-13s %s\n' DAYS KIND TARGET CN ISSUER EXPIRES KEY FLAGS
  local days kind target where cn issuer end sig bits serial flags
  while IFS='|' read -r days kind target where cn issuer end sig bits serial flags; do
    [ -n "${1:-}" ] && [ "${target#"$1"}" = "$target" ] && continue
    printf '%-6s %-9s %-34s %-32s %-28s %-24s %-13s %s\n' "$days" "$kind" "${target:0:34}" "${cn:0:32}" "${issuer:0:28}" "${end:0:24}" "${sig:0:8}/$bits" "$flags"; printf '       %s\n' "$where"
  done < <(sorted_rows)
}
rows_json() {
  printf '{"host":"%s","generated":"%s","certs":[' "$HOST" "$(ts)"; local first=1 days kind target where cn issuer end sig bits serial flags
  while IFS='|' read -r days kind target where cn issuer end sig bits serial flags; do
    printf '%s{"days":%s,"kind":"%s","target":"%s","where":"%s","cn":"%s","issuer":"%s","expires":"%s","sig":"%s","bits":"%s","serial":"%s","flags":"%s"}' "$([ $first = 1 ] || echo ,)" "$([ "$days" = "?" ] && echo null || echo "$days")" "$kind" "$(json_escape "$target")" "$(json_escape "$where")" "$(json_escape "$cn")" "$(json_escape "$issuer")" "$end" "$sig" "$bits" "$serial" "$flags"; first=0
  done < <(sorted_rows); echo ']}'
}

# ---------------------------------------------------------------------------
# targets
# ---------------------------------------------------------------------------
find_domain() { local h d; for h in $(wls_homes); do for d in $(wls_domains "$h"); do [ "$d" = "$1" ] || [ "$(basename "$d")" = "$1" ] && { printf '%s' "$d"; return 0; }; done; done; return 1; }
resolve_target() {
  local t="$1"; T_KIND="${t%%:*}"; T_NAME="$t"; T_DOMAIN=""; T_SERVER=""; T_INST=""; T_JH=""; T_PORT=""; T_ADDR=""; T_FILE=""; T_TYPE=""; T_ALIAS=""; T_MODE=""; T_TRUST=""; T_TRUSTTYPE=""; T_WALLET=""; T_PROPS=""; T_HOME=""
  case "$T_KIND" in
    wls) local rest="${t#wls:}"; T_DOMAIN="$(find_domain "${rest%%:*}")" || die "domain '${rest%%:*}' not found (wls_domains)"; T_SERVER="${rest#*:}"; [ "$T_SERVER" = "$rest" ] && T_SERVER=""
      [ -n "$T_SERVER" ] || return 0
      local row; row="$(wls_ssl_servers "$T_DOMAIN" | grep "^$T_SERVER|")" || die "server $T_SERVER not in $T_DOMAIN/config/config.xml"
      local n e; IFS='|' read -r n T_ADDR e T_PORT T_MODE T_FILE T_TYPE T_ALIAS T_TRUST T_TRUSTTYPE <<<"$row"
      [ "$e" = true ] || warn "$T_SERVER: SSL is not enabled in config.xml (the keystore will be set, the port stays off)"
      T_HOME="$(wls_home_of_domain "$T_DOMAIN")"; [ -n "$T_FILE" ] && T_FILE="$(abs_in "$T_DOMAIN" "$T_FILE")"; [ -n "$T_TRUST" ] && T_TRUST="$(abs_in "$T_DOMAIN" "$T_TRUST")";;
    nm) T_DOMAIN="$(find_domain "${t#nm:}")" || die "domain '${t#nm:}' not found"; T_PROPS="$T_DOMAIN/nodemanager/nodemanager.properties"; [ -f "$T_PROPS" ] || die "$T_PROPS not found"
      T_FILE="$(sed -n 's/^CustomIdentityKeyStoreFileName=//p' "$T_PROPS" | head -1)"; [ -n "$T_FILE" ] && T_FILE="$(abs_in "$T_DOMAIN" "$T_FILE")"; T_ALIAS="$(sed -n 's/^CustomIdentityAlias=//p' "$T_PROPS" | head -1)"; T_PORT="$(sed -n 's/^ListenPort=//p' "$T_PROPS" | head -1)"; T_PORT="${T_PORT:-5556}"; T_ADDR=127.0.0.1;;
    ords) ords_detect >/dev/null 2>&1 || die "ORDS not found here (ORDS_HOME/ORDS_CONFIG)"; T_PROPS="$(ords_props)"; [ -f "$T_PROPS" ] || die "$T_PROPS not found: ORDS is not running standalone here (in WebLogic the certificate is the managed server's: wls:<domain>:<server>)"
      T_PORT="$(ords_prop standalone.https.port)"; T_FILE="$(ords_prop standalone.https.cert)"; T_TYPE="$(ords_prop standalone.https.cert.key)"; T_ADDR=127.0.0.1;;
    listener) local ad f; T_WALLET="$WALLET_OPT"; for ad in $(listener_admin_dirs); do [ -z "$T_WALLET" ] && for f in "$ad/listener.ora" "$ad/sqlnet.ora"; do [ -f "$f" ] && T_WALLET="$(wallet_dir_in "$f")" && [ -n "$T_WALLET" ] && break; done; [ -z "$T_PORT" ] && T_PORT="$(tcps_ports_in "$ad/listener.ora" | head -1)"; [ -z "$T_HOME" ] && [ -f "$ad/listener.ora" ] && T_HOME="$(dirname "$(dirname "$ad")")"; done
      [ -n "$T_WALLET" ] || die "no WALLET_LOCATION in listener.ora/sqlnet.ora: give --wallet DIR"; T_ADDR=127.0.0.1; T_INST="$(listener_homes | awk '{print $2}' | head -1)"; T_INST="${T_INST:-LISTENER}";;
    ohs) T_INST="${t#ohs:}"; local h d conf; for h in $(wls_homes); do for d in $(wls_domains "$h"); do conf="$d/config/fmwconfig/components/OHS/instances/$T_INST/ssl.conf"; [ -f "$conf" ] && { T_DOMAIN="$d"; T_PROPS="$conf"; T_HOME="$h"; break 2; }; done; done
      [ -n "$T_PROPS" ] || die "OHS instance $T_INST not found under any domain's config/fmwconfig/components/OHS/instances"
      T_WALLET="${WALLET_OPT:-$(sed -n 's/^[[:space:]]*SSLWallet[[:space:]]*"\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$T_PROPS" | head -1 | sed "s#\${ORACLE_INSTANCE}#$T_DOMAIN#g; s#\${COMPONENT_TYPE}#OHS#g; s#\${COMPONENT_NAME}#$T_INST#g")}"
      T_PORT="$(grep -oE '^<VirtualHost[^>]*:[0-9]+' "$T_PROPS" | grep -oE '[0-9]+$' | head -1)"; T_ADDR=127.0.0.1;;
    java) T_JH="${t#java:}"; [ -x "$T_JH/bin/keytool" ] || die "$T_JH is not a JDK"; T_FILE="$T_JH/jre/lib/security/cacerts"; [ -f "$T_FILE" ] || T_FILE="$T_JH/lib/security/cacerts"; [ -f "$T_FILE" ] || die "no cacerts under $T_JH"; KEYTOOL="$T_JH/bin/keytool";;
    *) die "unknown target '$t' (wls:<domain>:<server>, nm:<domain>, ords, listener, ohs:<instance>, java:<JAVA_HOME>)";;
  esac
}
# wls_all_servers: expand wls:<domain> into one target per SSL-enabled server
expand_targets() { local t="$1"; if [ "${t%%:*}" = wls ] && [ "$(printf '%s' "$t" | tr -cd ':' | wc -c | tr -d ' ')" = 1 ]; then local d; d="$(find_domain "${t#wls:}")" || die "domain not found"; wls_ssl_servers "$d" | awk -F'|' -v d="$(basename "$d")" '$3=="true"{print "wls:"d":"$1}'; else echo "$t"; fi; }
restart_cmd_for() { printf '%s\n' "${RESTART_CMDS//,/$'\n'}" | sed -n "s/^$1=//p" | head -1; }
# lsnrctl reload and stop/start drop the dynamic service registrations: until LREG registers again (up to 60 s) every
# connect gets ORA-12514, so wait for the first dynamic service to come back before reporting the restart done
listener_services_wait() {
  local l="$1" i n s
  for i in $(seq 1 "${LSNR_REG_WAIT:-70}"); do n="$(to 20 "$l" status "$T_INST" 2>/dev/null | grep -c '^Service "' || true)"; [ "$n" -gt 0 ] && { log "listener $T_INST: $n service(s) registered after ${i}s"; return 0; }
    [ "$i" = 3 ] && for s in $(db_instances); do log "alter system register on $s (LREG otherwise re-registers within 60 s)"; sql_run "$s" "alter system register;" >>"$LOG_FILE" 2>&1 || true; done; sleep 1; done
  warn "listener $T_INST shows no registered services after ${LSNR_REG_WAIT:-70}s: connections get ORA-12514 until LREG re-registers (alter system register; on each instance hurries it)"; return 0
}
# restart_target: 0 = restarted (or dry-run), 1 = a restart was attempted and FAILED, 2 = nothing was restarted and the operator
# was told to do it (no command known, or the listener stop/start declined). Callers must not read 2 as "done": the process
# still serves the previous certificate until someone restarts it (board review, 1 Nov 2026: every warn-only path returned 0)
restart_target() {
  local cmd; cmd="$(restart_cmd_for "$T_NAME")"; [ -z "$cmd" ] && [ "$T_KIND" = wls ] && cmd="$(restart_cmd_for "wls:$(basename "$T_DOMAIN")")"
  if [ -n "$cmd" ]; then log "restart $T_NAME: $cmd"; run_sh "$cmd" || { err "restart command failed (see $LOG_FILE)"; return 1; }; return 0; fi
  case "$T_KIND" in
    ords) if [ -n "${ORDS_STOP_CMD:-}" ]; then run_sh "$ORDS_STOP_CMD" || { err "ORDS_STOP_CMD failed (see $LOG_FILE)"; return 1; }; sleep 5; run_sh "${ORDS_START_CMD:?ORDS_START_CMD needed with ORDS_STOP_CMD}" || { err "ORDS_START_CMD failed (see $LOG_FILE)"; return 1; }
      elif [ -n "${ORDS_SERVICE:-$(ords_service)}" ]; then run_sh "$SUDO systemctl restart ${ORDS_SERVICE:-$(ords_service)}" || { err "systemctl restart ${ORDS_SERVICE:-$(ords_service)} failed (see $LOG_FILE)"; return 1; }
      else warn "no ORDS service/RESTART_CMDS: restart ORDS yourself"; return 2; fi;;
    listener) local l="${T_HOME:+$T_HOME/bin/}lsnrctl"; log "lsnrctl reload $T_INST (the wallet is read at listener start: a full restart follows if the port still serves the old cert)"; run_sh "$l reload $T_INST" || warn "lsnrctl reload $T_INST failed (see $LOG_FILE): checking what the port serves"
      [ "$DRY_RUN" = 1 ] && return 0; sleep 3; listener_services_wait "$l"; local s; s="$(live_pem "127.0.0.1:$T_PORT" "$RUN_DIR/after_reload.pem" && x509_facts "$RUN_DIR/after_reload.pem" && printf '%s' "$X_SERIAL")"
      [ "$s" = "$(state_get new_serial || true)" ] && return 0
      confirm "Still the old certificate on $T_PORT. lsnrctl stop/start $T_INST (new connections fail for a few seconds)?" || { warn "listener not restarted: the old certificate stays live until it is"; return 2; }
      run_sh "$l stop $T_INST"; run_sh "$l start $T_INST" || { err "lsnrctl start $T_INST failed (see $LOG_FILE)"; return 1; }; listener_services_wait "$l";;
    ohs) if [ -x "$T_DOMAIN/bin/restartComponent.sh" ]; then log "restartComponent.sh $T_INST (NodeManager credentials from WLS_ADMIN_USER/WLS_ADMIN_PASSWORD)"; read_secret WLS_ADMIN_PASSWORD "NodeManager/WebLogic admin password"; [ "$DRY_RUN" = 1 ] || printf '%s\n%s\n' "${WLS_ADMIN_USER:-weblogic}" "$WLS_ADMIN_PASSWORD" | to 300 "$T_DOMAIN/bin/restartComponent.sh" "$T_INST" >>"$LOG_FILE" 2>&1 || { err "restartComponent.sh failed"; return 1; }; else warn "no restartComponent.sh: restart OHS $T_INST yourself (RESTART_CMDS ohs:$T_INST=...)"; return 2; fi;;
    wls) warn "no RESTART_CMDS entry for $T_NAME: if verify shows the old certificate, restart $T_SERVER (console or the domain's start scripts)"; return 2;;
    nm) warn "restart the NodeManager of $(basename "$T_DOMAIN") so it reads the new keystore (stopNodeManager.sh / startNodeManager.sh)"; return 2;;
    java) warn "JVMs read cacerts at start: restart the servers that must trust the new CA"; return 2;;
  esac
}

# ---------------------------------------------------------------------------
# certificate material
# ---------------------------------------------------------------------------
KP=(); KEYPF=""
keypass_opt() { KP=(); [ -n "$KEY_PASSWORD" ] && { KEYPF="$(tmp_secret_file "$KEY_PASSWORD")"; KP=(-passin "file:$KEYPF"); }; return 0; }
keypass_done() { [ -n "$KEYPF" ] && rm -f "$KEYPF"; KEYPF=""; KP=(); }
check_material() { # --cert/--key/--chain consistent; sets NEW_SERIAL NEW_CN NEW_END NEW_DAYS
  [ -n "$CERT" ] || { [ "$T_KIND" = java ] && [ -n "$CHAIN" ] && CERT="$CHAIN"; }; [ -n "$CERT" ] || die "--cert FILE is required$([ "$T_KIND" = java ] && echo ' (or --chain FILE with the CAs to trust)')"; [ -f "$CERT" ] || die "$CERT not found"
  [ "$T_KIND" = java ] || { [ -n "$KEY" ] || die "--key FILE is required for $T_KIND"; [ -f "$KEY" ] || die "$KEY not found"; }
  [ -n "$CHAIN" ] && { [ -f "$CHAIN" ] || die "$CHAIN not found"; }
  x509_facts "$CERT" || die "$CERT is not a PEM certificate"; NEW_SERIAL="$X_SERIAL"; NEW_CN="$X_CN"; NEW_END="$X_END"; NEW_DAYS="$X_DAYS"; NEW_SAN="$X_SAN"; NEW_ICN="$X_ICN"
  [ "$NEW_DAYS" != "?" ] && [ "$NEW_DAYS" -le 0 ] && die "$CERT expired $NEW_END"
  openssl x509 -in "$CERT" -noout -checkend 0 >/dev/null 2>&1 || die "$CERT is not valid now"
  local nb; nb="$(openssl x509 -in "$CERT" -noout -startdate 2>/dev/null | sed 's/notBefore=//')"; [ "$(days_until "$nb" 2>/dev/null || echo 0)" -gt 0 ] && warn "$CERT is not valid before $nb"
  if [ -n "$KEY" ]; then
    keypass_opt; local cpub kpub
    kpub="$(openssl pkey -in "$KEY" -pubout "${KP[@]}" 2>/dev/null | openssl md5 | awk '{print $NF}')"; keypass_done
    cpub="$(openssl x509 -in "$CERT" -noout -pubkey 2>/dev/null | openssl md5 | awk '{print $NF}')"
    [ -n "$kpub" ] || die "$KEY is not a readable private key (encrypted? set KEY_PASSWORD)"
    [ "$kpub" = "$cpub" ] || die "$KEY does not match $CERT (public keys differ)"
  fi
  if [ -n "$CHAIN" ]; then
    local vr; vr="$(openssl verify -CAfile "$CHAIN" "$CERT" 2>&1)"; printf '%s' "$vr" | grep -q ': OK' && log "chain: $CERT verifies against $CHAIN ($(grep -c 'BEGIN CERTIFICATE' "$CHAIN") certs)" || die "chain does not verify: $vr"
  else
    [ "$X_SELF" = 1 ] && warn "$CERT is self-signed" || { openssl verify "$CERT" >/dev/null 2>&1 && log "chain: issuer $NEW_ICN is in the system trust store" || warn "no --chain and the issuer '$NEW_ICN' is not in the system trust store: clients need the chain; give --chain for the keystore/wallet"; }
  fi
  printf '%s,%s' "$NEW_CN" "$NEW_SAN" | tr ',' '\n' | grep -qixF "$CHECK_HOST" && log "names: $CHECK_HOST is covered (CN=$NEW_CN SAN=$NEW_SAN)" || warn "names: neither CN ($NEW_CN) nor SAN ($NEW_SAN) is '$CHECK_HOST' (CHECK_HOST): clients that verify the hostname will complain"
  [ "$NEW_DAYS" != "?" ] && [ "$NEW_DAYS" -lt "$INFO_DAYS" ] && warn "the new certificate already expires in $NEW_DAYS days"
  return 0
}
# make_p12 <out.p12> <pass>: PKCS12 with cert+key+chain, 3DES/SHA1 so every keytool and orapki can read it
make_p12() {
  local out="$1" pf; pf="$(tmp_secret_file "$2")"; keypass_opt; local legacy=()
  openssl version | grep -qE 'OpenSSL [3-9]' && legacy=(-keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1)
  ( umask 077; openssl pkcs12 -export -in "$CERT" -inkey "$KEY" ${CHAIN:+-certfile "$CHAIN"} -name "$CERT_ALIAS" -out "$out" -passout "file:$pf" "${KP[@]}" "${legacy[@]}" 2>>"$LOG_FILE" ); local rc=$?
  rm -f "$pf"; keypass_done; [ "$rc" = 0 ] || die "openssl pkcs12 -export failed (see $LOG_FILE)"
}
# chain_cas <outdir>: each certificate of --chain as a separate PEM, named by CN
chain_cas() { local o="$1"; mkdir -p "$o"; [ -n "$CHAIN" ] || return 0; awk -v o="$o" '/BEGIN CERTIFICATE/{n++; f=o"/ca"n".pem"} f{print >f} /END CERTIFICATE/{close(f); f=""}' "$CHAIN"; ls "$o"/ca*.pem 2>/dev/null; }
# import_cas <keystore> <pass> <type>: trusted entries for every chain CA not yet present (by SHA-256)
import_cas() {
  local ks="$1" pw="$2" t="$3" f fp present n=0; present="$(kt "$ks" "$pw" -list -storetype "$t" | grep -oE '[0-9A-F]{2}(:[0-9A-F]{2}){31}' | tr -d ':' | tr 'A-F' 'a-f')"
  for f in $(chain_cas "$RUN_DIR/chain"); do
    fp="$(openssl x509 -in "$f" -noout -fingerprint -sha256 2>/dev/null | sed 's/.*=//' | tr -d ':' | tr 'A-F' 'a-f')"; printf '%s\n' "$present" | grep -q "$fp" && { dbg "CA $(openssl x509 -in "$f" -noout -subject | cut -c1-80) already trusted"; continue; }
    x509_facts "$f"; local alias; alias="cert-renew-$(printf '%s' "$X_CN" | tr -c 'A-Za-z0-9' '_' | cut -c1-40 | tr 'A-Z' 'a-z')"
    log "importing CA '$X_CN' as $alias into $ks"; [ "$DRY_RUN" = 1 ] || KT_ERR="$LOG_FILE" kt "$ks" "$pw" -importcert -noprompt -trustcacerts -storetype "$t" -alias "$alias" -file "$f" >/dev/null || { err "import of $X_CN into $ks failed: $(grep -iE 'exception|error|denied|read-only' "$LOG_FILE" | tail -1)"; return 1; }; n=$((n+1))
  done; log "$n CA certificate(s) added to $ks"
}
# build_wallet <dir> <p12> <p12pass>: Oracle auto-login wallet from the PKCS12 (orapki import_pkcs12 + trusted certs)
build_wallet() {
  local d="$1" p12="$2" p12pw="$3" f
  [ -n "$ORAPKI" ] || die "orapki not found: an Oracle wallet needs it (set ORAPKI=/path/to/orapki or ORACLE_HOME)"
  [ -n "$WALLET_PASSWORD" ] || { read_secret WALLET_PASSWORD "password for the new wallet $d"; }
  [ "$DRY_RUN" = 1 ] && { log "orapki wallet create/import_pkcs12/add -trusted_cert in $d"; return 0; }
  rm -rf "$d"; mkdir -p "$d"
  printf '%s\n%s\n' "$WALLET_PASSWORD" "$WALLET_PASSWORD" | to 120 "$ORAPKI" wallet create -wallet "$d" -auto_login >>"$LOG_FILE" 2>&1 || die "orapki wallet create failed (see $LOG_FILE)"
  # both passwords go to orapki on stdin: without -pwd/-pkcs12pwd it prompts 'Enter wallet password:' then 'Enter PKCS#12 file password:'
  # (verified on PKI 23 in the container, board review 1 Nov 2026), as 'wallet create' above - no password word on any orapki command line
  printf '%s\n%s\n' "$WALLET_PASSWORD" "$p12pw" | to 120 "$ORAPKI" wallet import_pkcs12 -wallet "$d" -pkcs12file "$p12" >>"$LOG_FILE" 2>&1 || die "orapki wallet import_pkcs12 failed (needs 18c+ orapki; on older releases create the CSR inside the wallet: orapki wallet add -dn ... -keysize, then add -user_cert)"
  for f in $(chain_cas "$RUN_DIR/chain"); do printf '%s\n' "$WALLET_PASSWORD" | to 60 "$ORAPKI" wallet add -wallet "$d" -trusted_cert -cert "$f" >>"$LOG_FILE" 2>&1 || dbg "trusted cert $f already in the wallet or rejected"; done
  [ -f "$d/cwallet.sso" ] || die "$d/cwallet.sso was not created"
}
new_ks_pass() { [ -n "$WLS_KS_PASS" ] || { if [ "$ASSUME_YES" = 1 ] && [ ! -t 0 ]; then die "WLS_KS_PASS not set"; fi; read_secret WLS_KS_PASS "password for the new identity keystore"; }; [ "${#WLS_KS_PASS}" -ge 6 ] || die "keystore password must be at least 6 characters"; }

# ---------------------------------------------------------------------------
cmd_inspect() {
  init_run_dir inspect; find_tools
  local t="${ARGS[0]:-}"; [ "$REPORT_OUT" = 1 ] && report_init "$CERT_OUT/${HOST}_certs_$(date '+%Y%m%d_%H%M%S')"
  [ -z "$KEYTOOL" ] && warn "no keytool found: keystores cannot be read (JAVA_HOME)"
  case "${t%%:*}" in
    "") inspect_wls; inspect_ords; inspect_listener; inspect_ohs; inspect_java; inspect_okv; inspect_gg; inspect_apex; inspect_ports;;
    wls) local rest="${t#wls:}"; inspect_wls "${rest%%:*}" "$([ "${rest#*:}" != "$rest" ] && echo "${rest#*:}")";;
    nm) inspect_wls "${t#nm:}";; ords) inspect_ords;; listener) inspect_listener;; ohs) inspect_ohs;; java) JAVA_HOME="${t#java:}" inspect_java;; okv) inspect_okv;; gg) inspect_gg;; apex) inspect_apex;; ports) inspect_ports;;
    *) die "unknown target $t";;
  esac
  rows_findings
  pgrep -f 'emagent|oracle.sysman.gcagent' >/dev/null 2>&1 && finding INFO oem "EM agent present: its certificate is managed by the OMS (emctl secure agent / emctl status agent -secure); not inspected here"
  if [ "$JSON_OUT" = 1 ]; then rows_json; return 0; fi
  print_rows; echo; print_findings 'CRIT|WARN|INFO'
  if [ "$REPORT_OUT" = 1 ]; then
    h1 "Certificates on $HOST"; para "Sorted by days left. Each configured store is read and the port it serves is probed; a serial mismatch between the two means a restart is pending."
    table_head DAYS KIND TARGET WHERE CN ISSUER EXPIRES SIG BITS SERIAL FLAGS
    local days kind target where cn issuer end sig bits serial flags; while IFS='|' read -r days kind target where cn issuer end sig bits serial flags; do table_row "$days" "$kind" "$target" "$where" "$cn" "$issuer" "$end" "$sig" "$bits" "$serial" "$flags"; done < <(sorted_rows)
    h2 "Thresholds"; kv "expired" CRIT; kv "< $WARN_DAYS days" WARN; kv "< $INFO_DAYS days" INFO; kv "demo/self-signed, SHA-1/MD5, RSA < 2048" WARN
    report_finish "cert-renew inspect: $HOST" 0 >/dev/null; findings_rc; return $?
  fi
  return 0
}

cmd_csr() {
  local name="${ARGS[0]:-}"; [ -n "$name" ] || die "csr <name> --cn NAME [--san a,b] [--bits N]"; [ -n "$CN" ] || die "--cn is required"
  init_run_dir csr; find_tools
  local d="$CERT_DIR/$name"; [ -f "$d/$name.key" ] && [ "$FORCE" != 1 ] && die "$d/$name.key exists (--force to replace it)"
  local sans="DNS:$CN"; local s; for s in ${SAN//,/ }; do [ "$s" = "$CN" ] && continue; printf '%s' "$s" | grep -qE '^[0-9.]+$' && sans="$sans,IP:$s" || sans="$sans,DNS:$s"; done
  log "key: RSA $BITS -> $d/$name.key (0600); CSR subject /CN=$CN$CSR_SUBJECT_SUFFIX; SAN $sans"
  [ "$DRY_RUN" = 1 ] && return 0
  ( umask 077; mkdir -p "$d" ) || die "cannot create $d"
  printf '[req]\ndistinguished_name=dn\nreq_extensions=v3_req\nprompt=no\n[dn]\nCN=%s\n%s[v3_req]\nsubjectAltName=%s\nkeyUsage=digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n' "$CN" "$(printf '%s' "$CSR_SUBJECT_SUFFIX" | tr '/' '\n' | grep . | sed 's/^/ /' | awk '{print $1}')" "$sans" >"$d/$name.cnf"
  ( umask 077; openssl req -new -newkey "rsa:$BITS" -nodes -keyout "$d/$name.key" -out "$d/$name.csr" -config "$d/$name.cnf" >>"$LOG_FILE" 2>&1 ) || die "openssl req failed (see $LOG_FILE)"
  openssl req -in "$d/$name.csr" -noout -subject -nameopt RFC2253; openssl req -in "$d/$name.csr" -noout -text | grep -A1 'Subject Alternative Name' | tail -1
  echo; cat "$d/$name.csr"; echo
  echo "CSR: $d/$name.csr   key: $d/$name.key (keep it here; it is what apply needs with --key)"
  echo "When the CA returns the certificate: cert-renew.sh plan <target> --cert <issued.pem> --key $d/$name.key --chain <ca-chain.pem>"
}

cmd_plan() {
  local t="${ARGS[0]:-}"; [ -n "$t" ] || die "plan <target> --cert --key [--chain]"; [ -n "$RUN_DIR" ] || init_run_dir plan; find_tools
  local one; for one in $(expand_targets "$t"); do
    resolve_target "$one"; check_material
    echo "Target   : $one"; echo "New cert : CN=$NEW_CN issuer=$NEW_ICN serial=$NEW_SERIAL expires $NEW_END ($NEW_DAYS days) SAN=$NEW_SAN"
    case "$T_KIND" in
      wls) local mode="${TRUST_MODE_OPT:-}"; [ -z "$mode" ] && case "$T_MODE" in CustomIdentityAnd*) mode="$T_MODE";; *) mode=CustomIdentityAndJavaStandardTrust;; esac
        echo "Now      : KeyStores=$T_MODE identity=${T_FILE:-demo} alias=${T_ALIAS:-demoidentity} ssl port=$T_PORT addr=${T_ADDR:-any}"
        echo "Will     : keystore $T_DOMAIN/security/identity_${T_SERVER}_$(date +%Y%m%d).$([ "$WLS_KS_TYPE" = PKCS12 ] && echo p12 || echo jks) ($WLS_KS_TYPE, alias $CERT_ALIAS, chain $([ -n "$CHAIN" ] && grep -c 'BEGIN CERTIFICATE' "$CHAIN" || echo 0) certs inside)"
        echo "           WLST on ${WLS_ADMIN_URL:-t3://localhost:7001}: Servers/$T_SERVER KeyStores=$mode, CustomIdentityKeyStore{FileName,Type,PassPhrase}, SSL/$T_SERVER ServerPrivateKey{Alias,PassPhrase}; activate"
        [ "$mode" != "$T_MODE" ] && echo "           trust changes from $T_MODE to $mode$([ "$mode" = CustomIdentityAndJavaStandardTrust ] && echo " (the JDK cacerts; --trust-mode CustomIdentityAndCustomTrust --wallet <trust.jks> to keep a custom trust store)")"
        [ "$mode" = CustomIdentityAndCustomTrust ] && echo "           trust store ${WALLET_OPT:-$T_TRUST}: chain CAs imported when missing"
        [ -n "${WLS_USERCONFIG:-}${WLS_ADMIN_USER:-}" ] || echo "           NO WebLogic credentials (WLS_USERCONFIG/WLS_USERKEY or WLS_ADMIN_USER): apply will build the keystore and print the console steps"
        echo "Restart  : $(restart_cmd_for "$one" | grep . || echo "none configured: WebLogic reloads the identity keystore on activate in 12.2.1.3+; verify checks the port, restart $T_SERVER if it still serves the old serial")";;
      nm) echo "Now      : $T_PROPS KeyStores=$(sed -n 's/^KeyStores=//p' "$T_PROPS" | head -1 | grep . || echo DemoIdentityAndDemoTrust) file=${T_FILE:-demo} alias=${T_ALIAS:-demoidentity} port=$T_PORT"
        echo "Will     : keystore $T_DOMAIN/security/identity_nm_$(date +%Y%m%d).jks; set KeyStores=CustomIdentityAndJavaStandardTrust, CustomIdentityKeyStoreFileName/Type/PassPhrase, CustomIdentityAlias, CustomIdentityPrivateKeyPassPhrase (NodeManager encrypts them at its next start)"
        echo "Restart  : NodeManager (stopNodeManager.sh / startNodeManager.sh) - $(restart_cmd_for "$one" | grep . || echo 'not configured, done by you')";;
      ords) echo "Now      : $T_PROPS https port=${T_PORT:-off} cert=${T_FILE:-none (self-signed generated)} key=${T_TYPE:-none}"
        echo "Will     : $ORDS_CONFIG/global/standalone/certs/${NEW_CN//[^A-Za-z0-9.-]/_}_$(date +%Y%m%d).pem (cert + chain) and .der (PKCS#8 DER key, as ORDS standalone requires); standalone.https.cert / standalone.https.cert.key set$([ -z "$T_PORT" ] && echo "; standalone.https.port=8443 added (ORDS_HTTPS_PORT)")"
        echo "Restart  : $(restart_cmd_for ords | grep . || echo "${ORDS_SERVICE:-$(ords_service)}" | grep . || echo 'none: restart ORDS yourself') (needed: ORDS reads the certificate at start)";;
      listener) echo "Now      : wallet $T_WALLET (listener $T_INST, TCPS port ${T_PORT:-?}, home ${T_HOME:-?})"
        echo "Will     : new wallet built in the run dir (orapki ${ORAPKI:-MISSING}: create -auto_login, import_pkcs12, add -trusted_cert x$([ -n "$CHAIN" ] && grep -c 'BEGIN CERTIFICATE' "$CHAIN" || echo 0)); old cwallet.sso/ewallet.p12 backed up; new files copied into $T_WALLET (same path: no listener.ora/sqlnet.ora change)"
        echo "Restart  : lsnrctl reload, then stop/start $T_INST if the port still serves the old serial (asked); database server processes pick the wallet up per new connection";;
      ohs) echo "Now      : OHS $T_INST wallet $T_WALLET port ${T_PORT:-?} ($T_PROPS)"; echo "Will     : wallet rebuilt as for listener, copied into $T_WALLET"; echo "Restart  : $(restart_cmd_for "$one" | grep . || echo "$T_DOMAIN/bin/restartComponent.sh $T_INST")";;
      java) echo "Now      : $T_FILE ($(kt "$T_FILE" "$(ks_pass "$T_FILE" JKS)" -list | grep -c trustedCertEntry) trusted CAs)"; echo "Will     : import every certificate of --chain${CHAIN:+ ($(grep -c 'BEGIN CERTIFICATE' "$CHAIN") certs)}${CHAIN:- and --cert} not already present, as cert-renew-<cn>; JVMs need a restart to see it";;
    esac; echo
  done
}

cmd_preflight() {
  local t="${ARGS[0]:-}"; [ -n "$t" ] || die "preflight <target> --cert --key [--chain]"; [ -n "$RUN_DIR" ] || init_run_dir preflight; find_tools
  local fail=0 one; for one in $(expand_targets "$t"); do
    resolve_target "$one"; check_material
    case "$T_KIND" in
      wls|nm|java) [ -n "$KEYTOOL" ] && log "keytool: $KEYTOOL" || { err "no keytool"; fail=1; }; [ "$T_KIND" = java ] && [ -L "$T_FILE" ] && warn "$T_FILE is a symlink to $(readlink -f "$T_FILE"): an OS-managed trust store (update-ca-trust rebuilds it) - put the CA under /etc/pki/ca-trust/source/anchors and run update-ca-trust instead of importing here"; [ "$T_KIND" = java ] && { [ -w "$T_FILE" ] && log "$T_FILE writable" || { err "$T_FILE not writable"; fail=1; }; }
        [ "$T_KIND" = wls ] && { [ -w "$T_DOMAIN/security" ] && log "$T_DOMAIN/security writable" || { err "$T_DOMAIN/security not writable"; fail=1; }; [ -x "$T_HOME/oracle_common/common/bin/wlst.sh" ] && log "wlst.sh present" || { err "no wlst.sh in $T_HOME"; fail=1; }
          [ -n "${WLS_USERCONFIG:-}${WLS_ADMIN_USER:-}" ] && log "WebLogic credentials configured" || warn "no WebLogic credentials: the config change will be left to you (console)"
          [ "$DRY_RUN" = 0 ] && { port_open "$(printf '%s' "${WLS_ADMIN_URL:-t3://localhost:7001}" | sed 's#.*:##')" "$(printf '%s' "${WLS_ADMIN_URL:-t3://localhost:7001}" | sed 's#.*//##; s#:.*##')" && log "admin server port answers" || { warn "admin server ${WLS_ADMIN_URL:-t3://localhost:7001} not reachable: WLST will fail"; }; }
          [ -n "$T_FILE" ] && [ -f "$T_FILE" ] && { ks_pass "$T_FILE" "${T_TYPE:-JKS}" >/dev/null && log "current keystore opens (password known: rollback possible)" || warn "current keystore password unknown (KS_PASSWORDS): rollback will prompt for it"; }
          new_ks_pass; }
        [ "$T_KIND" = nm ] && { [ -w "$T_PROPS" ] && log "$T_PROPS writable" || { err "$T_PROPS not writable"; fail=1; }; new_ks_pass; };;
      ords) [ -w "$T_PROPS" ] && log "$T_PROPS writable" || { err "$T_PROPS not writable"; fail=1; }; [ -n "$T_PORT" ] || warn "no standalone.https.port: ORDS_HTTPS_PORT (${ORDS_HTTPS_PORT:-8443}) will be added";;
      listener|ohs) [ -n "$ORAPKI" ] && log "orapki: $ORAPKI" || { err "orapki not found (ORAPKI=...)"; fail=1; }; [ -d "$T_WALLET" ] && [ -w "$T_WALLET" ] && log "$T_WALLET writable" || { err "$T_WALLET missing or not writable"; fail=1; }
        [ -n "$WALLET_PASSWORD" ] || { [ -t 0 ] && log "WALLET_PASSWORD will be prompted" || { err "WALLET_PASSWORD not set and not interactive"; fail=1; }; };;
    esac
    [ -n "$T_PORT" ] && [ "$T_KIND" != java ] && { port_open "$T_PORT" "${T_ADDR:-127.0.0.1}" && log "port $T_PORT open now (verify can compare before/after)" || warn "port $T_PORT not open now: verify will only pass after a start"; }
    [ "$DRY_RUN" = 1 ] || { df -Pk "$RUN_DIR" | awk 'NR==2{if ($4 < 51200) exit 1}' || { err "less than 50 MB free under $RUN_DIR"; fail=1; }; }
  done
  [ "$fail" = 0 ] && log "preflight OK" || err "preflight FAILED"; return "$fail"
}

cmd_backup() {
  local t="${ARGS[0]:-}"; [ -n "$t" ] || die "backup <target>"; [ -n "$RUN_DIR" ] || init_run_dir backup; find_tools
  local one b; for one in $(expand_targets "$t"); do resolve_target "$one"; b="$RUN_DIR/backup/$(printf '%s' "$one" | tr ':/' '__')"; mkdir -p "$b"
    case "$T_KIND" in
      wls) cp -p "$T_DOMAIN/config/config.xml" "$b/"; [ -n "$T_FILE" ] && [ -f "$T_FILE" ] && cp -p "$T_FILE" "$b/"; [ -n "$T_TRUST" ] && [ -f "$T_TRUST" ] && cp -p "$T_TRUST" "$b/"
        state_set "old_${T_SERVER}" "$T_MODE|$T_FILE|${T_TYPE:-}|${T_ALIAS:-}|${T_TRUST:-}|${T_TRUSTTYPE:-}"; local op; op="$(ks_pass "${T_FILE:-/nonexistent}" "${T_TYPE:-JKS}" 2>/dev/null || true)"; [ -n "$op" ] && [ "$op" != - ] && ( umask 077; printf '%s' "$op" >"$b/.old_ks_pass" );;
      nm) cp -p "$T_PROPS" "$b/"; [ -n "$T_FILE" ] && [ -f "$T_FILE" ] && cp -p "$T_FILE" "$b/";;
      ords) cp -p "$T_PROPS" "$b/"; [ -n "$T_FILE" ] && [ -f "$T_FILE" ] && cp -p "$T_FILE" "$b/"; [ -n "$T_TYPE" ] && [ -f "$T_TYPE" ] && ( umask 077; cp -p "$T_TYPE" "$b/" );;
      listener|ohs) ( umask 077; cp -p "$T_WALLET"/cwallet.sso "$T_WALLET"/ewallet.p12 "$b/" 2>/dev/null ); state_set wallet_dir "$T_WALLET";;
      java) cp -p "$T_FILE" "$b/";;
    esac
    state_set backup_dir "$b"; state_set target "$one"; log "backup of $one in $b: $(find "$b" -type f | wc -l | tr -d ' ') file(s)"
  done
  # the marker's mtime is the backup time: the sweep in main shreds the whole backup dir once it is BACKUP_KEEP_HOURS old
  # (a keystore or wallet plus .old_ks_pass is a usable private key, not something a run dir should keep for ever)
  touch "$RUN_DIR/backup/.kept"; log "the backup is kept ${BACKUP_KEEP_HOURS}h for rollback, then shredded ('cleanup' does it sooner)"
}

# expire_backups: every command but help sweeps RUN_BASE and shreds the backup dir of any run older than BACKUP_KEEP_HOURS
# (default 168 = a week: a renewal is verified within days, the old key should not outlive that in a run dir that gets
# rsynced to a jump box). shred_path, file_age, file_older_than, expire_run_material are the lib's; rollback refuses past the limit
expire_backups() { expire_run_material "$BACKUP_KEEP_HOURS" backup/.kept backup_removed backup; }
cmd_cleanup() {
  last_change_run || die "no run under $RUN_BASE has applied anything (--run-dir DIR to point at one)"; reuse_or_init cleanup
  local removed; removed="$(state_get backup_removed || true)"; [ -n "$removed" ] && { log "nothing to do: the backup of $RUN_DIR was shredded at $removed"; return 0; }
  [ -d "$RUN_DIR/backup" ] || { log "no backup kept in $RUN_DIR"; state_set backup_removed "$(ts)"; return 0; }
  echo "Kept for rollback in $RUN_DIR/backup ($(file_age "$RUN_DIR/backup/.kept" 2>/dev/null || echo '?') old):"; find "$RUN_DIR/backup" -type f | sed 's/^/  /'
  confirm "Shred the backup of $(state_get target || echo '?')? rollback will refuse afterwards" || die "aborted"
  [ "$DRY_RUN" = 1 ] && { log "DRY-RUN: would shred $RUN_DIR/backup"; return 0; }
  shred_path "$RUN_DIR/backup"; state_set backup_removed "$(ts)"; log "cleaned up: the previous keystore/wallet and its password are gone; rollback is no longer possible for this run"
}

wls_apply_one() {
  local ks p12 ext; ext=jks; [ "$WLS_KS_TYPE" = PKCS12 ] && ext=p12; ks="$T_DOMAIN/security/identity_${T_SERVER}_$(date +%Y%m%d).$ext"; p12="$RUN_DIR/${T_SERVER}.p12"
  new_ks_pass; make_p12 "$p12" "$WLS_KS_PASS"
  if [ "$WLS_KS_TYPE" = PKCS12 ]; then [ "$DRY_RUN" = 1 ] || { ( umask 077; cp "$p12" "$ks" ); }
  else [ "$DRY_RUN" = 1 ] || { rm -f "$ks"; ( umask 077; local pf; pf="$(tmp_secret_file "$WLS_KS_PASS")"; to 120 "$KEYTOOL" -importkeystore -noprompt -srckeystore "$p12" -srcstoretype PKCS12 -srcstorepass:file "$pf" -destkeystore "$ks" -deststoretype JKS -deststorepass:file "$pf" -srcalias "$CERT_ALIAS" -destalias "$CERT_ALIAS" -destkeypass:file "$pf" >>"$LOG_FILE" 2>&1; local rc=$?; rm -f "$pf"; exit $rc ); } || die "keytool -importkeystore failed (see $LOG_FILE)"; fi
  log "identity keystore: $ks ($WLS_KS_TYPE, alias $CERT_ALIAS)"; state_set "new_ks_$T_SERVER" "$ks"
  local mode="${TRUST_MODE_OPT:-}"; [ -z "$mode" ] && case "$T_MODE" in CustomIdentityAnd*) mode="$T_MODE";; *) mode=CustomIdentityAndJavaStandardTrust;; esac
  local trust="${WALLET_OPT:-$T_TRUST}" trusttype="${T_TRUSTTYPE:-JKS}"
  if [ "$mode" = CustomIdentityAndCustomTrust ]; then [ -n "$trust" ] || die "--trust-mode CustomIdentityAndCustomTrust needs a trust store (--wallet <file> or the server's current one)"; [ -n "$CHAIN" ] && { local tp; tp="$(ks_pass "$trust" "$trusttype")" || die "trust store $trust: password unknown (KS_PASSWORDS)"; import_cas "$trust" "$tp" "$trusttype"; }
  elif [ -n "$CHAIN" ]; then local jh c; jh="$(wls_java_home "$T_HOME")"; c="$jh/jre/lib/security/cacerts"; [ -f "$c" ] || c="$jh/lib/security/cacerts"; [ -f "$c" ] && { local f miss=0; for f in $(chain_cas "$RUN_DIR/chain"); do x509_facts "$f"; kt "$c" "$(ks_pass "$c" JKS)" -list -v | grep -qF "$(openssl x509 -in "$f" -noout -fingerprint -sha256 | sed 's/.*=//')" || { miss=1; warn "CA '$X_CN' is not in $c (JavaStandardTrust): servers that call this one over t3s/https will not trust it - cert-renew.sh apply java:$jh --chain $CHAIN"; }; done; [ "$miss" = 0 ] && log "chain CAs present in $c"; }; fi
  local py; py="edit()
startEdit()
cd('/Servers/$T_SERVER')
cmo.setKeyStores('$mode')
cmo.setCustomIdentityKeyStoreFileName('$ks')
cmo.setCustomIdentityKeyStoreType('$WLS_KS_TYPE')
cmo.setCustomIdentityKeyStorePassPhrase('$WLS_KS_PASS')
$([ "$mode" = CustomIdentityAndCustomTrust ] && printf "cmo.setCustomTrustKeyStoreFileName('%s')\ncmo.setCustomTrustKeyStoreType('%s')\n" "$trust" "$trusttype")
cd('/Servers/$T_SERVER/SSL/$T_SERVER')
cmo.setServerPrivateKeyAlias('$CERT_ALIAS')
cmo.setServerPrivateKeyPassPhrase('$WLS_KS_PASS')
save()
activate(block='true')
print 'CERT_RENEW_OK'"
  if wlst_run "$py"; then log "WebLogic $T_SERVER: keystore switched via WLST (activated)"; state_set "wlst_$T_SERVER" ok
  else warn "WLST did not run: set it in the console - Servers > $T_SERVER > Keystores: $mode, identity $ks ($WLS_KS_TYPE); SSL: alias $CERT_ALIAS; then activate and restart"; state_set "wlst_$T_SERVER" manual; return 1; fi
}
wlst_run() { # <script>: connected WLST with stored or prompted credentials; the script lands in a 600 file and is deleted
  local script="$1" h="$T_HOME"; [ -x "$h/oracle_common/common/bin/wlst.sh" ] || { warn "wlst.sh not found in $h"; return 1; }
  local conn; if [ -n "${WLS_USERCONFIG:-}" ] && [ -n "${WLS_USERKEY:-}" ]; then conn="connect(userConfigFile='$WLS_USERCONFIG', userKeyFile='$WLS_USERKEY', url='${WLS_ADMIN_URL:-t3://localhost:7001}')"
  elif [ -n "${WLS_ADMIN_USER:-}" ]; then read_secret WLS_ADMIN_PASSWORD "WebLogic admin password for $WLS_ADMIN_USER"; conn="connect('$WLS_ADMIN_USER', '$WLS_ADMIN_PASSWORD', '${WLS_ADMIN_URL:-t3://localhost:7001}')"
  else warn "no WebLogic credentials (WLS_USERCONFIG+WLS_USERKEY or WLS_ADMIN_USER)"; return 1; fi
  local f; f="$(tmp_secret_file "$conn
$script
disconnect()
exit()")"; cp "$f" "$RUN_DIR/last_wlst.py.redacted" 2>/dev/null; sed -i.bak -E "s/(PassPhrase\(|connect\()'[^']*'/\1'***'/; s/connect\('([^']*)', *'[^']*'/connect('\1', '***'/" "$RUN_DIR/last_wlst.py.redacted" 2>/dev/null; rm -f "$RUN_DIR/last_wlst.py.redacted.bak"
  [ "$DRY_RUN" = 1 ] && { log "WLST (dry-run): $(printf '%s' "$script" | grep -c .) lines"; rm -f "$f"; return 0; }
  WLST_PROPERTIES="-Dwlst.offline.log=/dev/null" to 600 "$h/oracle_common/common/bin/wlst.sh" -skipWLSModuleScanning "$f" 2>&1 | redact >>"$LOG_FILE"; local rc="${PIPESTATUS[0]}"; rm -f "$f"
  [ "$rc" = 0 ] && grep -q CERT_RENEW_OK "$LOG_FILE"
}
nm_apply() {
  local ks p12; ks="$T_DOMAIN/security/identity_nm_$(date +%Y%m%d).jks"; p12="$RUN_DIR/nm.p12"; new_ks_pass; make_p12 "$p12" "$WLS_KS_PASS"
  [ "$DRY_RUN" = 1 ] || { rm -f "$ks"; ( umask 077; local pf; pf="$(tmp_secret_file "$WLS_KS_PASS")"; to 120 "$KEYTOOL" -importkeystore -noprompt -srckeystore "$p12" -srcstoretype PKCS12 -srcstorepass:file "$pf" -destkeystore "$ks" -deststoretype JKS -deststorepass:file "$pf" -srcalias "$CERT_ALIAS" -destalias "$CERT_ALIAS" -destkeypass:file "$pf" >>"$LOG_FILE" 2>&1; local rc=$?; rm -f "$pf"; exit $rc ) || die "keytool -importkeystore failed"; }
  log "NodeManager keystore: $ks; editing $T_PROPS"; [ "$DRY_RUN" = 1 ] && return 0
  { grep -vE '^(KeyStores|CustomIdentityKeyStoreFileName|CustomIdentityKeyStoreType|CustomIdentityKeyStorePassPhrase|CustomIdentityAlias|CustomIdentityPrivateKeyPassPhrase)=' "$T_PROPS"
    printf 'KeyStores=CustomIdentityAndJavaStandardTrust\nCustomIdentityKeyStoreFileName=%s\nCustomIdentityKeyStoreType=JKS\nCustomIdentityKeyStorePassPhrase=%s\nCustomIdentityAlias=%s\nCustomIdentityPrivateKeyPassPhrase=%s\n' "$ks" "$WLS_KS_PASS" "$CERT_ALIAS" "$WLS_KS_PASS"; } >"$T_PROPS.cert-renew" && ( umask 077; cat "$T_PROPS.cert-renew" >"$T_PROPS" ) && rm -f "$T_PROPS.cert-renew"
  state_set new_ks_nm "$ks"; warn "$T_PROPS now holds the pass phrases in clear until the NodeManager restarts and encrypts them"
}
ords_apply() {
  local d="$ORDS_CONFIG/global/standalone/certs" base; base="${NEW_CN//[^A-Za-z0-9.-]/_}_$(date +%Y%m%d)"; mkdir -p "$d"
  log "ORDS: $d/$base.pem (cert + chain), $d/$base.der (PKCS#8 DER key), standalone.https.cert/.cert.key${T_PORT:+ (port $T_PORT)}"
  [ "$DRY_RUN" = 1 ] && return 0
  { cat "$CERT"; [ -n "$CHAIN" ] && cat "$CHAIN"; } >"$d/$base.pem"
  keypass_opt
  ( umask 077; openssl pkcs8 -topk8 -inform PEM -outform DER -nocrypt -in "$KEY" -out "$d/$base.der" "${KP[@]}" 2>>"$LOG_FILE" ) || die "openssl pkcs8 (key to DER) failed"; keypass_done
  ords_set_prop standalone.https.cert "$d/$base.pem"; ords_set_prop standalone.https.cert.key "$d/$base.der"; [ -z "$T_PORT" ] && ords_set_prop standalone.https.port "${ORDS_HTTPS_PORT:-8443}"; true
  [ -z "$T_PORT" ] && T_PORT="${ORDS_HTTPS_PORT:-8443}"; state_set ords_files "$d/$base.pem $d/$base.der"
}
wallet_apply() {
  local new="$RUN_DIR/wallet_new" p12="$RUN_DIR/wallet.p12" p12pw; p12pw="$(openssl rand -base64 18)"
  make_p12 "$p12" "$p12pw"; build_wallet "$new" "$p12" "$p12pw"; rm -f "$p12"
  log "swapping wallet files into $T_WALLET (same path, config unchanged)"; [ "$DRY_RUN" = 1 ] && return 0
  cp -p "$new/cwallet.sso" "$new/ewallet.p12" "$T_WALLET/" || die "copy into $T_WALLET failed"; return 0
}
java_apply() { local pw; pw="$(ks_pass "$T_FILE" JKS)" || die "cacerts password unknown (CACERTS_PASSWORD)"; [ -n "$CHAIN" ] || CHAIN="$CERT"; import_cas "$T_FILE" "$pw" JKS; }

cmd_apply() {
  local t="${ARGS[0]:-}"; [ -n "$t" ] || die "apply <target> --cert --key [--chain]"; [ -n "$RUN_DIR" ] || init_run_dir apply; find_tools
  local one rc=0 arc; for one in $(expand_targets "$t"); do   # arc: this target's own apply; rc: the command's (DeepSeek 21:32: one rc made apply_<t2>=partial after t1's restart failed)
    resolve_target "$one"; check_material
    [ -d "$RUN_DIR/backup/$(printf '%s' "$one" | tr ':/' '__')" ] || { ARGS=("$one"); cmd_backup; ARGS=("$t"); }
    confirm "Switch $one to CN=$NEW_CN (serial $NEW_SERIAL, expires $NEW_END)?" || die "aborted"
    state_set new_serial "$NEW_SERIAL"; state_set target "$one"
    arc=0; case "$T_KIND" in wls) wls_apply_one;; nm) nm_apply;; ords) ords_apply;; listener|ohs) wallet_apply;; java) java_apply;; esac || { arc=1; rc=1; }
    state_set "apply_$one" "$([ "$arc" = 0 ] && echo ok || echo partial)"
    if [ "$DO_RESTART" = 1 ] || [ "$T_KIND" = listener ] || [ -n "$(restart_cmd_for "$T_NAME")" ]; then restart_target; case $? in 0) ;; 2) state_set "restart_$one" pending;; *) rc=1; state_set "restart_$one" failed; [ "$T_KIND" = listener ] || err "$one: the config now names the new certificate but the running process still serves the old one until it restarts - fix the restart and run 'verify $one', or 'rollback --yes'";; esac; fi
  done; return "$rc"
}

# last_change_run: the newest run dir that applied something (inspect runs also move RUN_BASE/latest)
# (the latest symlink is skipped: it sorts after the dated dirs and picking it would make init_run_dir point latest at itself)
last_change_run() { [ -n "$RUN_DIR" ] && return 0; local d; while IFS= read -r d; do [ -L "${d%/}" ] && continue; grep -q '^apply_' "$d/state" 2>/dev/null && { RUN_DIR="${d%/}"; return 0; }; done < <(printf '%s\n' "$RUN_BASE"/*/ | sort -r); return 1; }
cmd_verify() {
  local t="${ARGS[0]:-}"; [ -n "$RUN_DIR" ] || { last_change_run; reuse_or_init verify; }; find_tools
  [ -n "$t" ] || { ARGS=(); cmd_inspect; return $?; }
  local want; want="$(state_get new_serial || true)"; [ -n "$CERT" ] && { x509_facts "$CERT" && want="$X_SERIAL"; }
  local fail=0 one; for one in $(expand_targets "$t"); do
    resolve_target "$one"
    if [ "$T_KIND" = java ]; then local f; for f in $(chain_cas "$RUN_DIR/chain"); do x509_facts "$f"; kt "$T_FILE" "$(ks_pass "$T_FILE" JKS)" -list -v | grep -qF "$(openssl x509 -in "$f" -noout -fingerprint -sha256 | sed 's/.*=//')" && log "$T_FILE trusts '$X_CN'" || { err "$T_FILE does not hold '$X_CN'"; fail=1; }; done; continue; fi
    [ -n "$T_PORT" ] || { warn "$one: no port known to probe"; continue; }
    local hp="${T_ADDR:-127.0.0.1}:$T_PORT" out; out="$RUN_DIR/verify_$(printf '%s' "$one" | tr ':/' '__').pem"
    [ "$DRY_RUN" = 1 ] && { log "would probe $hp"; continue; }
    local waited=0; while :; do
      if live_pem "$hp" "$out" && x509_facts "$out" && { [ -z "$want" ] || [ "$X_SERIAL" = "$want" ]; }; then break; fi
      [ -n "$want" ] && [ "$waited" -lt "$VERIFY_WAIT" ] || break
      [ "$waited" = 0 ] && log "$one: waiting up to ${VERIFY_WAIT}s for $hp to serve serial $want (restart in progress?)"; sleep 5; waited=$((waited + 5))
    done
    if ! live_pem "$hp" "$out"; then err "$one: $hp does not answer TLS (not started yet, or SSL disabled)"; fail=1; continue; fi
    x509_facts "$out"
    if [ -n "$want" ]; then [ "$X_SERIAL" = "$want" ] && log "$one: $hp serves the new certificate (serial $want)" || { err "$one: $hp serves serial $X_SERIAL, expected $want - restart pending?"; fail=1; }; else log "$one: $hp serves CN=$X_CN serial $X_SERIAL"; fi
    log "$one: expires $X_END ($X_DAYS days), CN=$X_CN SAN=$X_SAN, $X_SIG/${X_BITS:-?} bits"; [ "$X_DAYS" != "?" ] && [ "$X_DAYS" -lt "$WARN_DAYS" ] && { err "$one: expires in $X_DAYS days"; fail=1; }
    printf '%s,%s' "$X_CN" "$X_SAN" | tr ',' '\n' | grep -qixF "$CHECK_HOST" || warn "$one: $CHECK_HOST not in CN/SAN"
    local n; n="$(grep -c 'BEGIN CERTIFICATE' "$out.chain")"; local vr; if [ -n "$CHAIN" ]; then vr="$(openssl verify -CAfile "$CHAIN" -untrusted "$out.chain" "$out" 2>&1)"; else vr="$(openssl verify -untrusted "$out.chain" "$out" 2>&1)"; fi
    printf '%s' "$vr" | grep -q ': OK' && log "$one: chain verifies ($n cert(s) sent by the server$([ -n "$CHAIN" ] && echo ", against $CHAIN" || echo ', system trust'))" || { [ "$n" -le 1 ] && warn "$one: the server sends only the leaf (no chain): $vr" || warn "$one: chain does not verify: $(printf '%s' "$vr" | tail -1)"; }
  done
  state_set verify "$([ "$fail" = 0 ] && echo ok || echo failed)"; [ "$fail" = 0 ] && log "Verify OK" || err "Verify FAILED"; return "$fail"
}

cmd_rollback() {
  last_change_run || die "no run under $RUN_BASE has applied anything (--run-dir DIR to point at one)"; reuse_or_init rollback; find_tools
  local t; t="$(state_get target || true)"; [ -n "$t" ] || die "no target recorded in $RUN_DIR (nothing to roll back)"
  local removed; removed="$(state_get backup_removed || true)"; [ -n "$removed" ] && die "the backup of this run was shredded at $removed (cleanup, or past BACKUP_KEEP_HOURS): nothing to roll back to"
  local b; b="$RUN_DIR/backup/$(printf '%s' "$t" | tr ':/' '__')"; [ -d "$b" ] || die "no backup dir $b"
  [ -f "$RUN_DIR/backup/.kept" ] && { ! file_older_than "$RUN_DIR/backup/.kept" "$BACKUP_KEEP_HOURS" || die "the backup is $(file_age "$RUN_DIR/backup/.kept") old, past BACKUP_KEEP_HOURS=$BACKUP_KEEP_HOURS h: $t has served the new certificate for that long - renew again from your own records instead"; }
  resolve_target "$t"; confirm "Roll $t back to the files in $b ($(file_age "$RUN_DIR/backup/.kept" 2>/dev/null || echo '?') old)?" || die "aborted"
  case "$T_KIND" in
    wls) local old mode file type alias trust trusttype; old="$(state_get "old_$T_SERVER" || true)"; IFS='|' read -r mode file type alias trust trusttype <<<"$old"
      local op=""; [ -f "$b/.old_ks_pass" ] && op="$(cat "$b/.old_ks_pass")"
      if [ "$(state_get "wlst_$T_SERVER" || true)" = ok ]; then
        case "$mode" in Demo*) wlst_run "edit()
startEdit()
cd('/Servers/$T_SERVER')
cmo.setKeyStores('$mode')
save()
activate(block='true')
print 'CERT_RENEW_OK'";;
          *) [ -n "$op" ] || { [ -t 0 ] || die "old keystore password unknown: rerun interactively (or KS_PASSWORDS=...)"; read_secret OLD_KS_PASS "password of the previous keystore $file"; op="$OLD_KS_PASS"; }
             wlst_run "edit()
startEdit()
cd('/Servers/$T_SERVER')
cmo.setKeyStores('$mode')
cmo.setCustomIdentityKeyStoreFileName('$file')
cmo.setCustomIdentityKeyStoreType('${type:-JKS}')
cmo.setCustomIdentityKeyStorePassPhrase('$op')
cd('/Servers/$T_SERVER/SSL/$T_SERVER')
cmo.setServerPrivateKeyAlias('$alias')
cmo.setServerPrivateKeyPassPhrase('$op')
save()
activate(block='true')
print 'CERT_RENEW_OK'";; esac && log "WebLogic $T_SERVER: previous keystore settings restored (KeyStores=$mode)" || err "WLST rollback failed: restore in the console from $b/config.xml"
      else log "WLST was not used in this run (config was left for the console): nothing to undo in WebLogic"; fi
      [ -f "$b/$(basename "${trust:-/nonexistent}")" ] && { log "restoring trust store $trust"; [ "$DRY_RUN" = 1 ] || cp -p "$b/$(basename "$trust")" "$trust"; }
      log "new keystore $(state_get "new_ks_$T_SERVER" || echo '?') left in place (unused)";;
    nm) log "restoring $T_PROPS"; [ "$DRY_RUN" = 1 ] || cp -p "$b/nodemanager.properties" "$T_PROPS";;
    ords) log "restoring $T_PROPS"; [ "$DRY_RUN" = 1 ] || cp -p "$b/$(basename "$T_PROPS")" "$T_PROPS";;
    listener|ohs) log "restoring cwallet.sso/ewallet.p12 into $T_WALLET"; [ "$DRY_RUN" = 1 ] || cp -p "$b"/cwallet.sso "$b"/ewallet.p12 "$T_WALLET/" 2>/dev/null || die "restore into $T_WALLET failed";;
    java) log "restoring $T_FILE"; [ "$DRY_RUN" = 1 ] || cp -p "$b/cacerts" "$T_FILE";;
  esac
  state_set new_serial ""
  # the previous files are back; the rollback is "ok" only once the target has been restarted onto them. restart_target: 0 restarted,
  # 2 nothing restarted and the operator told, 1 failed - the state says which, "ok" is never written for 1 or 2
  restart_target; local rrc=$?
  case "$rrc" in
    0) state_set rollback ok; log "rollback done";;
    2) state_set rollback restart-pending; err "rollback NOT complete: the previous files are back in place but $T_NAME was not restarted by this script (see the line above for how) - it serves the new certificate until you restart it; then run 'verify $t'. Exit 2."; return 2;;
    *) state_set rollback failed; err "rollback incomplete: the previous files are back in place but the restart of $T_NAME FAILED - it may still serve the new certificate or be down (see $LOG_FILE)"; return 1;;
  esac
}

cmd_run() {
  local t="${ARGS[0]:-}"; [ -n "$t" ] || die "run <target> --cert --key [--chain]"; init_run_dir run; find_tools
  ARGS=("$t"); cmd_inspect >/dev/null 2>&1 || true; print_rows "$t"; echo
  cmd_plan; cmd_preflight || die "preflight failed - nothing changed"
  confirm "Proceed with backup > apply > $([ "$DO_RESTART" = 1 ] || [ -n "$(restart_cmd_for "$t")" ] && echo 'restart > ')verify for $t?" || die "aborted"
  cmd_backup
  cmd_apply || { err "apply did not complete"; confirm "Roll back?" && cmd_rollback; die "FAILED: apply. Log: $LOG_FILE"; }
  if ! cmd_verify; then err "verify failed"; confirm "Roll back to the previous certificate?" && cmd_rollback; die "FAILED: verify. Log: $LOG_FILE"; fi
  echo "SUCCESS: $t now serves CN=$NEW_CN (serial $NEW_SERIAL) until $NEW_END. Backup: $RUN_DIR/backup (kept ${BACKUP_KEEP_HOURS}h, 'cleanup' shreds it sooner). Log: $LOG_FILE"
}

main() {
  load_config; refuse_root
  local cmd="${1:-}"; shift || true; parse_opts "$@"
  BACKUP_KEEP_HOURS="${BACKUP_KEEP_HOURS:-168}"; [[ "$BACKUP_KEEP_HOURS" =~ ^[0-9]+$ ]] || die "BACKUP_KEEP_HOURS must be a whole number of hours: '$BACKUP_KEEP_HOURS'"
  case "$cmd" in ""|-h|--help|help) ;; *) if [ "$DRY_RUN" = 1 ]; then log "DRY-RUN: backups older than ${BACKUP_KEEP_HOURS}h under $RUN_BASE are left alone"; else expire_backups; fi;; esac
  case "$cmd" in
    inspect) cmd_inspect;; cleanup) cmd_cleanup;; csr) cmd_csr;; plan) cmd_plan;; preflight) cmd_preflight;; backup) cmd_backup;; apply) cmd_apply;; verify) cmd_verify;; rollback) cmd_rollback;; run) cmd_run;;
    ""|-h|--help|help) usage;; *) die "Unknown command: $cmd";;
  esac
}
main "$@"
