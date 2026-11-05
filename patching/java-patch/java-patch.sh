#!/usr/bin/env bash
# java-patch.sh - move WebLogic, ORDS and friends to a new JDK build: find every JDK on the host and who
# uses it, check the new tarball against each product's support matrix, unpack it next to the old one,
# carry the customer CA certificates across, switch the references (symlink flip when possible, else the
# config files), restart what is configured, verify the JVMs really run on the new JDK, roll back if not.
# Runs as the Oracle software owner. The EM agent and GoldenGate Microservices are reported, not touched.
#
# Usage: java-patch.sh <command> [args] [options]
#
# Commands
#   inspect              Every JDK (version, vendor, path, symlink?), who references it (WebLogic .globalEnv/commEnv/
#                        setDomainEnv/nodemanager, ORDS unit/profile/env, /usr/java links, alternatives), running JVMs
#   latest               Ask My Oracle Support for the newest JDK of the same major (8/11/17/21) as --java-home
#   download <dir>       Fetch it from MOS into <dir> (or put the tar.gz there yourself: no internet needed)
#   plan <tar|dir>       What run would do
#   preflight <tar|dir>  Tarball is a JDK, major matches (--force to change major), product matrix, disk, running JVMs
#   backup               Copy of every file that will be edited (the old JDK directory is never removed)
#   apply <tar|dir>      Unpack to JAVA_BASE, import extra cacerts aliases from the old store, flip symlink or edit files
#   restart              Run RESTART_CMDS (or ORDS service) so the JVMs pick up the new JDK
#   verify               New java -version, references point at it, no running JVM on the old JDK, URLs answer
#   rollback             Restore the references/symlink and the edited files from this run, restart again
#   run <tar|dir>        inspect > preflight > backup > apply > restart > verify (rollback on failure)
#
# Options
#   --java-home DIR    the JDK to replace (default: the one WebLogic/ORDS use, if there is only one)
#   --java-base DIR    where new JDKs are unpacked (default: the parent of --java-home)
#   --tar FILE         the JDK tarball (same as giving it as <tar>)        --restart       run RESTART_CMDS after apply
#   --force            allow a different major (e.g. 8 -> 11) when the product matrix permits it
#   --no-cacerts       do not copy extra CA aliases into the new cacerts
#   --dry-run  --yes  --json  --verbose  --run-dir DIR
#
# Config: java-patch.conf, ~/.java-patch.conf or the shared oracle.conf: JAVA_HOME, JAVA_BASE, MOS_TOKEN_FILE,
# CACERTS_PASSWORD (changeit), RESTART_CMDS ("ords=sudo systemctl restart ords,wls=/u01/.../restart.sh"), ORDS_URL,
# CHECK_URLS (comma list that must answer after the restart), EXTRA_REF_FILES (more files to search and edit).

# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="java-patch"; VERSION="1.0.0"
# shellcheck source=../../lib/oracle-lib.sh
. "$SCRIPT_DIR/../../lib/oracle-lib.sh" || { echo "lib/oracle-lib.sh not found" >&2; exit 1; }

OLD_JH="${JAVA_HOME:-}"; JAVA_BASE="${JAVA_BASE:-}"; TARBALL=""; DO_RESTART=0; NO_CACERTS=0; CACERTS_PASSWORD="${CACERTS_PASSWORD:-changeit}"
RESTART_CMDS="${RESTART_CMDS:-}"; CHECK_URLS="${CHECK_URLS:-}"; EXTRA_REF_FILES="${EXTRA_REF_FILES:-}"
OLD_REAL=""; OLD_VER=""; OLD_MAJOR=""; NEW_JH=""; NEW_VER=""; NEW_MAJOR=""; REFS=""; LINKED=0
USER_ORDS_URL="${ORDS_URL:-}"   # only a URL the operator gave (ords_detect invents a default we must not verify against)

usage() { usage_from_header "$0"; }
parse_opts() {
  ARGS=()
  while [ $# -gt 0 ]; do case "$1" in
    --java-home) optchk "$@"; OLD_JH="$2"; shift 2;; --java-base) optchk "$@"; JAVA_BASE="$2"; shift 2;; --tar) optchk "$@"; TARBALL="$2"; shift 2;; --restart) DO_RESTART=1; shift;;
    --force) FORCE=1; shift;; --no-cacerts) NO_CACERTS=1; shift;; --dry-run) DRY_RUN=1; shift;; --yes) ASSUME_YES=1; shift;; --json) JSON_OUT=1; shift;; --verbose) VERBOSE=1; shift;; --run-dir) optchk "$@"; RUN_DIR="$2"; shift 2;;
    -h|--help) usage; exit 0;; --*) die "Unknown option: $1";; *) ARGS+=("$1"); shift;; esac; done
}

# ---------------------------------------------------------------------------
# discovery: references to JDKs in product config
# ---------------------------------------------------------------------------
# ref_files: every file that may name a JAVA_HOME, one per line
ref_files() {
  { local h d
    for h in $(wls_homes); do
      echo "$h/oui/.globalEnv.properties"; echo "$h/oracle_common/common/bin/commEnv.sh"; echo "$h/oracle_common/common/bin/commExtEnv.sh"; echo "$h/wlserver/.product.properties"
      for d in $(wls_domains "$h"); do echo "$d/bin/setDomainEnv.sh"; echo "$d/bin/setNMJavaHome.sh"; echo "$d/nodemanager/nodemanager.properties"; echo "$d/bin/setUserOverrides.sh"; done
      echo "$h/wlserver/common/nodemanager/nodemanager.properties"; echo "$h/user_projects/domains/*/nodemanager/nodemanager.properties"
    done
    ords_detect >/dev/null 2>&1 && { local svc; svc="$(ords_service)"; [ -n "$svc" ] && systemctl show -p FragmentPath "$svc" 2>/dev/null | cut -d= -f2; ls /etc/systemd/system/"${svc:-ords}".service.d/*.conf 2>/dev/null; echo "${ORDS_HOME:-/nonexistent}/bin/ords.env"; echo "/etc/ords/ords.env"; }
    ls /etc/profile.d/*.sh /etc/environment "$HOME"/.bash_profile "$HOME"/.bashrc "$HOME"/.profile 2>/dev/null
    printf '%s\n' "${EXTRA_REF_FILES//,/ }" | tr ' ' '\n'
  } 2>/dev/null | while read -r f; do [ -n "$f" ] && [ -f "$f" ] && echo "$f"; done | sort -u
}
# refs_to <jdk path>: "file:line" where that path (or the symlink to it) is named
refs_to() { local p="$1" f; for f in $(ref_files); do grep -nF -- "$p" "$f" 2>/dev/null | grep -vE '^\s*[0-9]+:\s*#' | sed "s#^#$f:#"; done; }
jdk_version() { java_version_of "$1"; }
jdk_vendor() { "$1/bin/java" -version 2>&1 | sed -n '2s/ (build.*//p' | head -1; }
# cacerts_pw_file: CACERTS_PASSWORD in a 600-mode file for keytool -storepass:file - never on keytool's command line (ps); the caller removes it
cacerts_pw_file() { local f; f="$(mktemp "${TMPDIR:-/tmp}/javapatch.XXXXXX")" || return 1; chmod 600 "$f"; printf '%s' "$CACERTS_PASSWORD" >"$f"; printf '%s' "$f"; }
# cacerts_aliases <keytool> <keystore> <pwfile>: the trustedCertEntry aliases, sorted; returns 1 (keytool's last line on stderr) when the store cannot be opened
cacerts_aliases() {
  local out; out="$(to 60 "$1" -list -keystore "$2" -storepass:file "$3" 2>&1)" || { printf '%s\n' "$out" | tail -1 >&2; return 1; }
  # a store keytool listed with no trustedCertEntry is readable and empty, not unreadable (grep's 1 is not keytool's)
  printf '%s\n' "$out" | { grep trustedCertEntry || true; } | cut -d, -f1 | sort
}
# running_on <jdk real path>: "pid name" of JVMs whose exe lives under it. Status 1 = the process list could not be read (lib
# ps_pid_args, b728ff6): callers treat that as 'unknown', never as 'no JVM runs on it' - a restart gate that reads nothing to
# restart, or a verify that says nothing is left on the old JDK, because ps failed, is the false success this guards
ps_unreadable_msg() { printf '%s' "cannot read the process list (ps failed, $PROC_DIR unreadable)"; }
running_on() {
  local l; l="$(ps_pid_args)" || return 1
  printf '%s\n' "$l" | awk '$2 ~ /\/bin\/java$/ {print $1}' | while read -r p; do local exe; exe="$(readlink -f "/proc/$p/exe" 2>/dev/null)"; [ -z "$exe" ] && exe="$(readlink -f "$(ps -o args= -p "$p" | awk '{print $1}')" 2>/dev/null)"
    case "$exe" in "$1"/*) printf '%s %s\n' "$p" "$(tr '\0' ' ' <"/proc/$p/cmdline" 2>/dev/null | grep -oE 'weblogic\.Name=[^ ]+|ords\.war|ords serve|oracle\.dbtools[^ ]*|NodeManager|ServiceManager|adminsrvr|distsrvr|recvsrvr|pmsrvr|emagent' | head -1 | sed 's/weblogic.Name=//')";; esac; done
}
jvm_count() { local l; l="$(running_on "$1")" || { printf 'null'; return 1; }; printf '%s' "$l" | grep -c .; return 0; }   # 'null' in the JSON, status 1, when the list is unreadable
jvm_names() { local l; l="$(running_on "$1")" || { printf '? (%s)' "$(ps_unreadable_msg)"; return 1; }; printf '%s\n' "$l" | awk '{print $2}' | tr '\n' ' '; }
gg_exe_on() { local l; l="$(running_on "$1")" || { printf '? (%s)' "$(ps_unreadable_msg)"; return 1; }; printf '%s\n' "$l" | grep -E 'ServiceManager|adminsrvr' | head -1 | awk '{print $1}' | xargs -I{} readlink -f /proc/{}/exe 2>/dev/null; }
wls_major_ok() { # <wls version> <jdk major>: support matrix
  local w="$1" j="$2"
  case "$w" in 12.2.1.4*) [ "$j" = 8 ];; 14.1.1*) [ "$j" = 8 ] || [ "$j" = 11 ];; 14.1.2*) [ "$j" = 17 ] || [ "$j" = 21 ];; 15.*) [ "$j" = 17 ] || [ "$j" = 21 ];; *) return 2;; esac
}
ords_major_ok() { local o="$1" j="$2"; [ -z "$o" ] && return 2; if version_ge "$o" 25.1; then [ "$j" = 17 ] || [ "$j" = 21 ]; elif version_ge "$o" 22.1; then [ "$j" = 11 ] || [ "$j" = 17 ] || [ "$j" = 21 ]; else [ "$j" = 8 ] || [ "$j" = 11 ]; fi; }

discover() {
  [ -n "$OLD_REAL" ] && return 0
  if [ -z "$OLD_JH" ]; then
    local cands; cands="$( { for h in $(wls_homes); do wls_java_home "$h"; done; ords_detect >/dev/null 2>&1 && [ -n "${ORDS_PID:-}" ] && dirname "$(dirname "$(readlink -f "/proc/$ORDS_PID/exe" 2>/dev/null)")"; } 2>/dev/null | grep . | sort -u)"
    [ "$(printf '%s\n' "$cands" | grep -c .)" = 1 ] && OLD_JH="$cands"
    [ -z "$OLD_JH" ] && die "Which JDK? --java-home DIR (candidates: $(java_homes | tr '\n' ' '))"
  fi
  [ -x "$OLD_JH/bin/java" ] || die "$OLD_JH has no bin/java"
  OLD_REAL="$(readlink -f "$OLD_JH")"; [ -L "$OLD_JH" ] && LINKED=1
  OLD_VER="$(jdk_version "$OLD_JH")"; OLD_MAJOR="$(java_major_of "$OLD_JH")"
  [ -z "$JAVA_BASE" ] && JAVA_BASE="$(dirname "$OLD_REAL")"
  REFS="$(refs_to "$OLD_JH"; [ "$OLD_REAL" != "$OLD_JH" ] && refs_to "$OLD_REAL")"
}
# tar handling: TARBALL from ARGS/--tar/dir; NEW_* from it
pick_tar() {
  local a="${ARGS[0]:-$TARBALL}"; [ -n "$a" ] || die "which JDK? give the tar.gz (or a directory holding one, or --tar)"
  if [ -d "$a" ]; then
    local matches kinds
    matches="$(find "$a" -maxdepth 1 \( -iname 'jdk*.tar.gz' -o -iname 'jdk*.tgz' -o -iname 'server-jre*.tar.gz' -o -iname 'jre*.tar.gz' \) 2>/dev/null)"
    [ -n "$matches" ] || die "no JDK tarball (jdk*/server-jre*/jre*.tar.gz) in $a"
    # 'sort -V' on the whole name sorts by prefix first ('server-jre' > 'jre' > 'jdk'), so a dir holding more
    # than one kind of JDK would silently install the older one - refuse rather than downgrade
    kinds="$(printf '%s\n' "$matches" | while IFS= read -r f; do b="$(basename "$f")"; printf '%s\n' "${b%%[0-9]*}"; done | sort -u | tr '\n' ' ')"
    [ "$(printf '%s\n' "$kinds" | wc -w)" = 1 ] || die "$a holds more than one kind of JDK tarball ($kinds)- pass the exact tarball, not the directory"
    TARBALL="$(printf '%s\n' "$matches" | sort -V | tail -1)"
  else TARBALL="$a"; fi
  [ -f "$TARBALL" ] || die "$TARBALL not found"
  local listing top
  # read the listing once: 'tar -tzf | grep -q' ends grep on the match, tar takes SIGPIPE, and with pipefail
  # (lib/oracle-lib.sh) the pipeline returns 141 - a real JDK then died as 'not a JDK tarball'
  listing="$(tar -tzf "$TARBALL" 2>/dev/null)"; [ -n "$listing" ] || die "$TARBALL is not a readable tar.gz"
  top="${listing%%$'\n'*}"; top="${top%%/*}"
  printf '%s\n' "$listing" | grep -E "^$top/bin/java$" >/dev/null || die "$TARBALL has no $top/bin/java - not a JDK tarball"
  NEW_JH="$JAVA_BASE/$top"
  NEW_VER="$(tar -xzOf "$TARBALL" "$top/release" 2>/dev/null | sed -n 's/^JAVA_VERSION="\([^"]*\)".*/\1/p' | head -1)"
  [ -z "$NEW_VER" ] && NEW_VER="$(printf '%s' "$top" | grep -oE '[0-9][0-9._u]+' | head -1 | sed 's/^1\.8\.0_/8u/')"
  NEW_MAJOR="${NEW_VER%%.*}"; [ "$NEW_MAJOR" = 1 ] && { NEW_MAJOR="${NEW_VER#1.}"; NEW_MAJOR="${NEW_MAJOR%%.*}"; }
}

# ---------------------------------------------------------------------------
cmd_inspect() {
  discover
  if [ "$JSON_OUT" = 1 ]; then
    printf '{"target":{"java_home":"%s","real":"%s","version":"%s","major":"%s","symlink":%s,"vendor":"%s"},"jdks":[' "$OLD_JH" "$OLD_REAL" "$OLD_VER" "$OLD_MAJOR" "$LINKED" "$(json_escape "$(jdk_vendor "$OLD_JH")")"
    local first=1 j; for j in $(java_homes); do printf '%s{"path":"%s","version":"%s","running":%s}' "$([ $first = 1 ] || echo ,)" "$j" "$(jdk_version "$j")" "$(jvm_count "$j")"; first=0; done
    printf '],"references":['; first=1; printf '%s\n' "$REFS" | grep . | while IFS= read -r r; do printf '%s"%s"' "$([ $first = 1 ] || echo ,)" "$(json_escape "$r")"; first=0; done; echo ']}'; return
  fi
  echo "Target JDK      : $OLD_JH$([ "$LINKED" = 1 ] && echo " -> $OLD_REAL (symlink: switch = flip the link)") $OLD_VER ($(jdk_vendor "$OLD_JH")) major $OLD_MAJOR, base $JAVA_BASE"
  echo "JDKs on host    :"; local j; for j in $(java_homes); do printf '  %-50s %-14s %s  running JVMs: %s\n' "$j" "$(jdk_version "$j")" "$([ "$j" = "$OLD_REAL" ] && echo '[target]' || echo '        ')" "$(jvm_names "$j")"; done
  echo "/usr/java       : $(ls -l /usr/java/latest /usr/java/default 2>/dev/null | awk '{print $9" -> "$11}' | tr '\n' ';' || true) alternatives: $(readlink -f "$(command -v java 2>/dev/null || echo /nonexistent)" 2>/dev/null)"
  echo "Referenced in   :"; printf '%s\n' "$REFS" | grep . | sed 's/^/  /' | cut -c1-200; [ -z "$REFS" ] && echo "  (nothing names $OLD_JH explicitly$([ "$LINKED" = 1 ] && echo '; everything goes through the symlink'))"
  local h; for h in $(wls_homes); do echo "WebLogic $h : $(wls_version "$h") uses $(wls_java_home "$h") ; supported JDK major: $(for m in 8 11 17 21; do wls_major_ok "$(wls_version "$h")" $m && printf '%s ' $m; done)"; done
  # lib 487f88f: ords_detect sets ORDS_PS_UNREADABLE=1 when the process list could not be read - 'not running' is not known then
  if ords_detect >/dev/null 2>&1; then local ej; ej="$([ -n "$ORDS_PID" ] && dirname "$(dirname "$(readlink -f "/proc/$ORDS_PID/exe" 2>/dev/null)")")"; [ -z "$ej" ] && [ "${ORDS_PS_UNREADABLE:-0}" = 1 ] && ej="? ($(ps_unreadable_msg) - whether ORDS runs, and on which JDK, is NOT known)"; echo "ORDS ${ORDS_VER:-?}      : ${ORDS_HOME:-?} service $(ords_service) running on ${ej:-not running} ; supported JDK major: $(for m in 8 11 17 21; do ords_major_ok "${ORDS_VER:-}" $m && printf '%s ' $m; done)"; fi
  ogg_detect >/dev/null 2>&1 && [ "$OGG_MA" = 1 ] && echo "GoldenGate MA   : running on $(gg_exe_on "$OLD_REAL") (note only: GG MA ships its own JRE under its home; patch it with GG patches)"
  pgrep -f 'emagent|oracle.sysman.gcagent' >/dev/null 2>&1 && echo "EM agent        : present (note only: the agent uses its own JDK under the agent home; it is patched with agent patches, not here)"
  local cnt; if cnt="$(jvm_count "$OLD_REAL")"; then echo "Running on target: $cnt JVM(s)$([ "$cnt" != 0 ] && echo " - they need a restart after the switch (RESTART_CMDS / --restart)")"
  else echo "Running on target: UNKNOWN - $(ps_unreadable_msg); which JVMs need a restart after the switch is NOT known (preflight refuses until it is)"; fi
  local oc pf nca="(not counted)"; oc="$OLD_JH/$([ -f "$OLD_JH/jre/lib/security/cacerts" ] && echo jre/lib/security/cacerts || echo lib/security/cacerts)"
  if pf="$(cacerts_pw_file)"; then if cacerts_aliases "$OLD_JH/bin/keytool" "$oc" "$pf" >"$pf.lst" 2>/dev/null; then nca="$(grep -c . "$pf.lst") trusted certs"; else nca="UNREADABLE with CACERTS_PASSWORD (apply will refuse the CA carry-over)"; fi; rm -f "$pf" "$pf.lst"; fi
  echo "cacerts         : $oc $nca"
}

cmd_latest() {
  discover; [ -n "$RUN_DIR" ] || init_run_dir latest; mos_login
  local q; case "$OLD_MAJOR" in 8) q="JDK 8U";; *) q="JDK $OLD_MAJOR.0.";; esac
  log "Searching MOS for '$q' ($(mos_platform_name))"
  local rows; rows="$(mos_name_search "$q" | grep -iE "JDK[^|]*\b${OLD_MAJOR}[.u_]" | grep -viE 'windows|solaris|aix|arm|aarch|macos|docs|source' || true)"
  [ -n "$rows" ] || { mos_cleanup; die "no JDK $OLD_MAJOR rows from MOS search; get the patch number from Doc 1439822.2 (All Java SE Downloads on MOS) and run: download <dir> <patch>"; }
  local best; best="$(printf '%s\n' "$rows" | awk -F'|' '{match($2,/[0-9]+[uU._][0-9]+([._][0-9]+)*/); v=substr($2,RSTART,RLENGTH); gsub(/[uU]/,".0.",v); print v "|" $0}' | sort -t'|' -k1,1V | tail -1 | cut -d'|' -f2-)"
  mos_cleanup
  echo "  newest on MOS: ${best%%|*}  ${best#*|}   (installed: $OLD_VER)"; state_set latest "${best%%|*}"; PATCHES="${best%%|*}"
}
cmd_download() {
  discover; [ -n "$RUN_DIR" ] || init_run_dir download; local dir="${ARGS[0]:-}"; [ -n "$dir" ] || die "download needs <dir>"; local id="${ARGS[1]:-${PATCHES:-$(state_get latest 2>/dev/null || true)}}"; [ -n "$id" ] || die "no patch id: run latest first or give one"
  mkdir -p "$dir"; mos_login; local z; z="$(mos_download "$id" "$dir")" || die "download failed"; mos_cleanup
  case "$z" in *.zip) log "unzipping $z"; unzip -q -o "$z" -d "$dir" '*.tar.gz' 2>/dev/null || unzip -q -o "$z" -d "$dir";; esac
  ls -la "$dir"
}

cmd_preflight() {
  discover; [ -n "$RUN_DIR" ] || init_run_dir preflight; pick_tar; local fail=0
  log "Preflight: $OLD_JH ($OLD_VER) -> $NEW_JH ($NEW_VER) from $TARBALL"
  [ -d "$NEW_JH" ] && { [ -x "$NEW_JH/bin/java" ] && log "$NEW_JH already unpacked ($(jdk_version "$NEW_JH"))" || { err "$NEW_JH exists but is not a JDK"; fail=1; }; }
  [ "$NEW_VER" = "$OLD_VER" ] && { [ "$FORCE" = 1 ] && warn "the tarball is the same build as the current JDK ($OLD_VER) - going on because of --force" || { err "the tarball is the same build as the current JDK ($OLD_VER) (--force to reinstall)"; fail=1; }; }
  if [ "$NEW_MAJOR" != "$OLD_MAJOR" ]; then [ "$FORCE" = 1 ] && warn "major change $OLD_MAJOR -> $NEW_MAJOR (--force): check the product matrix below carefully" || { err "major change $OLD_MAJOR -> $NEW_MAJOR; same-major updates only unless --force"; fail=1; }; fi
  local h; for h in $(wls_homes); do [ "$(readlink -f "$(wls_java_home "$h")")" = "$OLD_REAL" ] || continue
    local wv; wv="$(wls_version "$h")"; wls_major_ok "$wv" "$NEW_MAJOR"; local r=$?
    case $r in 0) log "WebLogic $wv supports JDK $NEW_MAJOR";; 1) err "WebLogic $wv does NOT support JDK $NEW_MAJOR (12.2.1.4: 8; 14.1.1: 8/11; 14.1.2: 17/21)"; fail=1;; *) warn "WebLogic $wv: unknown to the matrix, check the certification";; esac; done
  if ords_detect >/dev/null 2>&1 && [ "${ORDS_PS_UNREADABLE:-0}" = 1 ]; then err "$(ps_unreadable_msg) - cannot tell whether ORDS runs on the old JDK, so its JDK $NEW_MAJOR support is NOT checked"; fail=1; fi
  if ords_detect >/dev/null 2>&1 && [ -n "${ORDS_PID:-}" ] && [ "$(dirname "$(dirname "$(readlink -f "/proc/$ORDS_PID/exe" 2>/dev/null)")")" = "$OLD_REAL" ]; then ords_major_ok "${ORDS_VER:-}" "$NEW_MAJOR"; case $? in 0) log "ORDS ${ORDS_VER} supports JDK $NEW_MAJOR";; 1) err "ORDS ${ORDS_VER} does NOT support JDK $NEW_MAJOR (<22: 8/11; 22-24: 11/17/21; 25.1+: 17/21)"; fail=1;; *) warn "ORDS version unknown";; esac; fi
  local need free; need=$(( $(file_size "$TARBALL") / 1048576 * 3 + 200 )); free="$(df -Pm "$JAVA_BASE" 2>/dev/null | awk 'NR==2{print $4}')"; [ "${free:-0}" -lt "$need" ] && { err "$JAVA_BASE has ${free} MB free, need ~${need} MB"; fail=1; } || log "disk: ${free} MB free in $JAVA_BASE"
  [ -w "$JAVA_BASE" ] || { err "$JAVA_BASE is not writable by $(id -un)"; fail=1; }
  [ "$LINKED" = 1 ] && { [ -w "$(dirname "$OLD_JH")" ] || { err "cannot replace the symlink $OLD_JH (parent not writable)"; fail=1; }; }
  local f; for f in $(printf '%s\n' "$REFS" | cut -d: -f1 | sort -u); do [ -w "$f" ] || { err "$f is not writable (reference must be edited)"; fail=1; }; done
  local run; if ! run="$(running_on "$OLD_REAL")"; then err "$(ps_unreadable_msg) - cannot tell which JVMs run on the old JDK and need a restart after the switch; preflight refuses"; fail=1; run=""; fi
  [ -n "$run" ] && { log "running on the old JDK (restart needed): $(printf '%s\n' "$run" | awk '{print $2"("$1")"}' | tr '\n' ' ')"; [ "$DO_RESTART" = 1 ] && [ -z "$RESTART_CMDS" ] && [ -z "$(ords_service)" ] && warn "--restart but no RESTART_CMDS and no ORDS service: restarts will have to be done by hand"; }
  [ "$NO_CACERTS" = 0 ] && { local pf; pf="$(cacerts_pw_file)" && { cacerts_aliases "$OLD_JH/bin/keytool" "$OLD_JH/$([ -f "$OLD_JH/jre/lib/security/cacerts" ] && echo jre/lib/security/cacerts || echo lib/security/cacerts)" "$pf" >/dev/null 2>&1 || { err "cannot open the old cacerts with CACERTS_PASSWORD: apply will refuse to continue without the CA carry-over (fix the password, or --no-cacerts)"; fail=1; }; rm -f "$pf"; }; }
  [ -f "$OLD_JH/jre/lib/security/local_policy.jar" ] && [ "$NEW_MAJOR" = 8 ] && log "JDK 8: unlimited crypto policy files - JDK 8u161+ has them unlimited by default (crypto.policy=unlimited)"
  state_set preflight "$([ "$fail" = 0 ] && echo ok || echo failed)"; state_set tarball "$TARBALL"; state_set old_jh "$OLD_JH"; state_set old_real "$OLD_REAL"; state_set new_jh "$NEW_JH"
  [ "$fail" = 0 ] && { log "Preflight OK"; return 0; } || { err "Preflight FAILED - see $LOG_FILE"; return 1; }
}

cmd_plan() {
  discover; pick_tar
  echo "PLAN: $OLD_JH ($OLD_VER) -> $NEW_JH ($NEW_VER)"
  echo "  1. preflight   JDK tarball, major $OLD_MAJOR->$NEW_MAJOR, WebLogic/ORDS matrix, disk in $JAVA_BASE, who runs on the old JDK"
  echo "  2. backup      $(printf '%s\n' "$REFS" | cut -d: -f1 | sort -u | grep -c .) reference file(s) copied to the run dir; the old JDK stays at $OLD_REAL"
  echo "  3. apply       tar -xzf $(basename "$TARBALL") -C $JAVA_BASE ; keytool import of CA aliases present only in the old cacerts$([ "$NO_CACERTS" = 1 ] && echo ' (skipped)')"
  [ "$LINKED" = 1 ] && echo "                 ln -sfn $NEW_JH $OLD_JH   (symlink flip, no file edits)" || echo "                 sed $OLD_JH -> $NEW_JH in: $(printf '%s\n' "$REFS" | cut -d: -f1 | sort -u | tr '\n' ' ')"
  echo "  4. restart     $([ "$DO_RESTART" = 1 ] && echo "${RESTART_CMDS:-ORDS service $(ords_service)}" || echo 'not requested (--restart): JVMs keep the old JDK until restarted')"
  echo "  5. verify      $NEW_JH/bin/java -version, references, running JVMs' /proc/pid/exe, URLs: ${CHECK_URLS:-${USER_ORDS_URL:-none}}"
  echo "  rollback       symlink back / files restored from the run dir, restart again"
}

cmd_backup() {
  discover; reuse_or_init backup; mkdir -p "$RUN_DIR/files"
  # a copy that failed used to be recorded as backed up all the same, and rollback would have found nothing to restore
  local f; for f in $(printf '%s\n' "$REFS" | cut -d: -f1 | sort -u); do cp -p "$f" "$RUN_DIR/files/$(printf '%s' "$f" | tr '/' '_')" || die "cannot back up $f into $RUN_DIR/files (cp failed): nothing changed"; state_append backed_files "$f"; done
  [ "$LINKED" = 1 ] && state_set link_target "$OLD_REAL"
  log "backed up $(state_get backed_files | wc -w | tr -d ' ') file(s) to $RUN_DIR/files"; state_set backup ok
}

cmd_apply() {
  discover; reuse_or_init apply; pick_tar
  case "$(state_get preflight || true)" in ok) ;; failed) [ "$FORCE" = 1 ] || die "preflight FAILED in this run dir ($RUN_DIR): fix it or --force";; *) warn "preflight has not run in this run dir";; esac
  [ "$NEW_VER" = "$OLD_VER" ] && { [ "$FORCE" = 1 ] && warn "the tarball is the same build as the current JDK ($OLD_VER) - reinstalling because of --force" || die "the tarball is the same build as the current JDK ($OLD_VER): nothing to do (--force to reinstall)"; }
  [ "$(state_get backup || true)" = ok ] || cmd_backup
  if [ ! -x "$NEW_JH/bin/java" ]; then
    log "unpacking $TARBALL into $JAVA_BASE"; confirm "tar -xzf into $JAVA_BASE (new dir $NEW_JH)?" || die "aborted"
    [ "$DRY_RUN" = 1 ] || { tar -xzf "$TARBALL" -C "$JAVA_BASE" || die "unpack failed"; [ -x "$NEW_JH/bin/java" ] || die "$NEW_JH/bin/java missing after unpack"; }
  fi
  [ "$DRY_RUN" = 1 ] || log "new JDK: $(jdk_version "$NEW_JH") ($(jdk_vendor "$NEW_JH"))"
  if [ "$NO_CACERTS" = 0 ] && [ "$DRY_RUN" = 0 ]; then
    local oc nc; oc="$OLD_JH/$([ -f "$OLD_JH/jre/lib/security/cacerts" ] && echo jre/lib/security/cacerts || echo lib/security/cacerts)"; nc="$NEW_JH/$([ -f "$NEW_JH/jre/lib/security/cacerts" ] && echo jre/lib/security/cacerts || echo lib/security/cacerts)"
    local pf olda newa; pf="$(cacerts_pw_file)" || die "cannot create the keytool password file under ${TMPDIR:-/tmp}"
    # both lists must really have been read: a wrong CACERTS_PASSWORD used to give an empty list, "0 CA alias(es) carried over"
    # and a new JDK without the corporate CAs - loudly refused now
    olda="$(cacerts_aliases "$OLD_JH/bin/keytool" "$oc" "$pf")" || { rm -f "$pf"; die "cannot list $oc (CACERTS_PASSWORD?): the CA aliases cannot be carried over - fix the password, or --no-cacerts if the new cacerts is already complete"; }
    newa="$(cacerts_aliases "$NEW_JH/bin/keytool" "$nc" "$pf")" || { rm -f "$pf"; die "cannot list $nc (CACERTS_PASSWORD?): fix the password, or --no-cacerts"; }
    local extra; extra="$(comm -23 <(printf '%s\n' "$olda") <(printf '%s\n' "$newa") | grep .)"
    local n=0 nf=0 a; for a in $extra; do
      if "$OLD_JH/bin/keytool" -exportcert -rfc -alias "$a" -keystore "$oc" -storepass:file "$pf" 2>>"$LOG_FILE" >"$RUN_DIR/ca_$a.pem" && "$NEW_JH/bin/keytool" -importcert -noprompt -alias "$a" -file "$RUN_DIR/ca_$a.pem" -keystore "$nc" -storepass:file "$pf" >>"$LOG_FILE" 2>&1; then n=$((n+1)); else nf=$((nf+1)); err "cacerts: alias $a NOT carried over (see $LOG_FILE)"; fi
    done
    rm -f "$pf"
    log "cacerts: $n CA alias(es) carried over ($(printf '%s' "$extra" | tr '\n' ' '))"; state_set cacerts_imported "$n"
    [ "$nf" = 0 ] || die "cacerts: $nf alias(es) failed to import into $nc - the new JDK would trust fewer CAs than the old one; fix the cause or --no-cacerts"
  fi
  if [ "$LINKED" = 1 ]; then
    log "flipping symlink $OLD_JH -> $NEW_JH"; confirm "ln -sfn $NEW_JH $OLD_JH ?" || die "aborted"
    [ "$DRY_RUN" = 1 ] || { ln -sfn "$NEW_JH" "$OLD_JH" || die "symlink flip failed"; [ "$(readlink "$OLD_JH")" = "$NEW_JH" ] || die "symlink flip did not take: $OLD_JH -> $(readlink "$OLD_JH" || echo '?') (is $OLD_JH a directory, not a link?)"; }
  else
    local files; files="$(printf '%s\n' "$REFS" | cut -d: -f1 | sort -u)"
    [ -z "$files" ] && warn "no file names $OLD_JH and it is not a symlink: nothing switched; set JAVA_HOME where your products read it (EXTRA_REF_FILES) or make $OLD_JH a symlink"
    confirm "edit $(printf '%s\n' "$files" | grep -c .) file(s): $OLD_JH -> $NEW_JH ?" || die "aborted"
    # the outcome of each edit is read back: sed's status, then the file must name the new JDK (and is told when the old path is still in it)
    local f efail=0; for f in $files; do log "editing $f"; [ "$DRY_RUN" = 1 ] && continue
      if sed -i.javapatch -e "s#$OLD_JH\([/\"' :;]\)#$NEW_JH\1#g" -e "s#$OLD_JH\$#$NEW_JH#" "$f"; then rm -f "$f.javapatch"; else err "editing $f failed (sed): left as it was"; efail=1; continue; fi
      grep -qF "$NEW_JH" "$f" || { err "$f does not reference $NEW_JH after the edit - the old path was in a form the edit does not match; change it by hand"; efail=1; }
      grep -qF "$OLD_JH" "$f" && warn "$f still mentions $OLD_JH somewhere (a comment, or a form the edit does not match) - check it"
    done
    [ "$efail" = 0 ] || { state_set apply failed; err "apply: not every file was switched to $NEW_JH (see above); rollback restores the backups"; return 1; }
  fi
  [ -d /usr/java ] && [ -L /usr/java/latest ] && [ "$(readlink -f /usr/java/latest)" = "$OLD_REAL" ] && [ -w /usr/java ] && { log "updating /usr/java/latest"; [ "$DRY_RUN" = 1 ] || ln -sfn "$NEW_JH" /usr/java/latest; }
  state_set apply ok; state_set new_jh "$NEW_JH"
}

cmd_restart() {
  discover; reuse_or_init restart; local fail=0
  # one entry per comma: the documented form 'ords=sudo systemctl restart ords' has spaces, and splitting on them ran 'systemctl', 'restart' and 'ords' as three commands
  if [ -n "$RESTART_CMDS" ]; then local m; while IFS= read -r m; do [ -n "$m" ] || continue; log "restart ${m%%=*}: ${m#*=}"; run_sh "${m#*=}" || { err "${m%%=*}: restart command returned an error (see $LOG_FILE)"; fail=1; }; done <<<"${RESTART_CMDS//,/$'\n'}"
  elif [ -n "$(ords_service)" ]; then run_sh "$SUDO systemctl restart $(ords_service)" || { err "systemctl restart $(ords_service) failed (see $LOG_FILE)"; fail=1; }
  else warn "no RESTART_CMDS and no ORDS service: restart WebLogic servers / node manager / ORDS yourself"; fi
  [ "$DRY_RUN" = 1 ] && return 0; sleep 10
  local u; for u in ${CHECK_URLS//,/ } ${USER_ORDS_URL:-}; do wait_for_url "$u" 300 && log "$u answers" || { err "$u does not answer after 300 s"; fail=1; }; done
  # "ok" only when every restart command succeeded and every URL answers: run and rollback act on this status
  state_set restart "$([ "$fail" = 0 ] && echo ok || echo failed)"; return "$fail"
}

cmd_verify() {
  discover; reuse_or_init verify; local fail=0
  local newjh; newjh="$(state_get new_jh || true)"; [ -n "$newjh" ] || die "no new JDK recorded in $RUN_DIR"
  [ -x "$newjh/bin/java" ] && log "$newjh: $(jdk_version "$newjh")" || { err "$newjh/bin/java missing"; fail=1; }
  if [ "$LINKED" = 1 ]; then [ "$(readlink -f "$OLD_JH")" = "$(readlink -f "$newjh")" ] && log "$OLD_JH -> $newjh" || { err "$OLD_JH points at $(readlink -f "$OLD_JH")"; fail=1; }
  else local left; left="$(refs_to "$(state_get old_real)" | grep -c .)"; [ "$left" = 0 ] && log "no reference to the old JDK left" || { err "$left reference(s) still name the old JDK: $(refs_to "$(state_get old_real)" | cut -c1-120 | tr '\n' ';')"; fail=1; }; fi
  local oldrun; if ! oldrun="$(running_on "$(state_get old_real)")"; then err "$(ps_unreadable_msg) - whether anything still runs on the old JDK is NOT known"; fail=1; oldrun=""
  elif [ -n "$oldrun" ]; then warn "still running on the OLD JDK (restart them): $(printf '%s\n' "$oldrun" | awk '{print $2"("$1")"}' | tr '\n' ' ')"; else log "no JVM runs on the old JDK"; fi
  local newrun; newrun="$(running_on "$(readlink -f "$newjh")" 2>/dev/null)" || newrun=""; [ -n "$newrun" ] && log "running on the new JDK: $(printf '%s\n' "$newrun" | awk '{print $2"("$1")"}' | tr '\n' ' ')"
  local u; for u in ${CHECK_URLS//,/ } ${USER_ORDS_URL:-}; do local c; c="$(url_code "$u" 15)"; [[ "$c" =~ ^(200|30[0-9]|401|403)$ ]] && log "$u: HTTP $c" || { err "$u: HTTP ${c:-none}"; fail=1; }; done
  local h; for h in $(wls_homes); do [ -x "$h/oracle_common/common/bin/wlst.sh" ] && [ "$DRY_RUN" = 0 ] && { echo "print 'WLST_OK'" | to 120 "$h/oracle_common/common/bin/wlst.sh" -skipWLSModuleScanning /dev/stdin 2>>"$LOG_FILE" | grep -q WLST_OK && log "WLST starts on the new JDK ($h)" || warn "WLST did not start cleanly in $h (see log)"; }; done
  state_set verify "$([ "$fail" = 0 ] && echo ok || echo failed)"; [ "$fail" = 0 ] && log "Verify OK" || err "Verify FAILED"; return "$fail"
}

cmd_rollback() {
  discover; reuse_or_init rollback
  local tgt; tgt="$(state_get link_target || true)"
  [ -n "$tgt" ] || [ -n "$(state_get backed_files || true)" ] || die "nothing to roll back in $RUN_DIR: no backup recorded there (the run dir of the apply: --run-dir DIR)"
  local rfail=0
  if [ -n "$tgt" ]; then confirm "ln -sfn $tgt $OLD_JH (back to the old JDK)?" || die "aborted"; if [ "$DRY_RUN" = 1 ] || ln -sfn "$tgt" "$OLD_JH"; then log "symlink restored -> $tgt"; else err "cannot restore the symlink $OLD_JH -> $tgt"; rfail=1; fi; fi
  # a missing or uncopyable backup used to be skipped silently and the rollback still said ok
  local f b; for f in $(state_get backed_files || true); do b="$RUN_DIR/files/$(printf '%s' "$f" | tr '/' '_')"
    if [ -f "$b" ]; then log "restoring $f"; if [ "$DRY_RUN" = 1 ] || cp -p "$b" "$f"; then :; else err "cannot restore $f from $b"; rfail=1; fi
    else err "no backup of $f in $RUN_DIR/files - not restored"; rfail=1; fi
  done
  [ -L /usr/java/latest ] && [ -n "$tgt" ] && [ -w /usr/java ] && { [ "$DRY_RUN" = 1 ] || ln -sfn "$tgt" /usr/java/latest; }
  log "the new JDK stays unpacked at $(state_get new_jh || echo '?') (harmless); restarting"
  # the files are back; the rollback is only "ok" when the services came back up on the old JDK as well
  if [ "$rfail" != 0 ]; then cmd_restart || true; state_set rollback failed; err "rollback incomplete: not every file is back on the old JDK (see above) - check them and the services by hand (see $LOG_FILE)"; return 1
  elif cmd_restart; then state_set rollback ok; log "rolled back"
  else state_set rollback failed; err "rollback incomplete: the old JDK is referenced again but the restart FAILED - check the services by hand (see $LOG_FILE)"; return 1; fi
}

cmd_run() {
  discover; init_run_dir run; pick_tar
  cmd_inspect; echo
  cmd_preflight || die "preflight failed - nothing changed"
  cmd_plan; confirm "Proceed with backup > apply > $([ "$DO_RESTART" = 1 ] && echo 'restart > ')verify?" || die "aborted"
  cmd_backup
  cmd_apply || { cmd_rollback; die "FAILED: apply (rolled back). Log: $LOG_FILE"; }
  [ "$DO_RESTART" = 1 ] && cmd_restart
  if ! cmd_verify; then err "verify failed"; confirm "Roll back to $OLD_VER?" && cmd_rollback; die "FAILED: verify. Log: $LOG_FILE"; fi
  echo "SUCCESS: $OLD_JH now $NEW_VER ($NEW_JH); old JDK kept at $OLD_REAL. $([ "$DO_RESTART" = 1 ] || echo 'Restart the JVMs to pick it up. ')Log: $LOG_FILE"
}

main() {
  load_config; refuse_root
  local cmd="${1:-}"; shift || true; parse_opts "$@"
  case "$cmd" in
    inspect) cmd_inspect;; latest) cmd_latest;; download) cmd_download;; plan) cmd_plan;; preflight) cmd_preflight;; backup) cmd_backup;; apply) cmd_apply;;
    restart) cmd_restart;; verify) cmd_verify;; rollback) cmd_rollback;; run) cmd_run;; ""|-h|--help|help) usage;; *) die "Unknown command: $cmd";;
  esac
}
main "$@"
