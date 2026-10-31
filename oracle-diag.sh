#!/usr/bin/env bash
# oracle-diag.sh - read-only health check of an Oracle server (Database, APEX, ORDS, WebLogic,
# the host itself). Collects everything into one Markdown report plus a tarball of raw logs, so
# the report can be copied off the server and handed to Claude (or a human) for analysis.
# Changes nothing. Runs as the oracle/weblogic owner; root is not required (a few host checks
# use sudo -n if it is allowed, otherwise they are skipped and noted).
#
# Usage: oracle-diag.sh [options]
#
#   --out DIR          where to write (default: $HOME/oracle-diag). Report is DIR/<host>_<ts>/REPORT.md
#   --days N           how far back to look in logs (default 3)
#   --lines N          max lines of any one log kept in REPORT.md (default 200; raw/ holds more)
#   --pdb NAME         run the database queries in this PDB as well as CDB$ROOT
#   --sid SID          only this database (default: every running instance in /etc/oratab)
#   --skip db|ords|apex|wls|host   skip a component (repeatable)
#   --threads          also take a thread dump of running WebLogic / ORDS JVMs (jcmd)
#   --no-redact        keep passwords in copied config files (default: redacted)
#   --no-tar           leave the directory, do not create the .tar.gz
#   --quiet            no progress on the terminal
#
# Config file (optional): ./oracle-diag.conf or ~/.oracle-diag.conf, KEY=VALUE lines. Everything
# the patch scripts understand is honoured here too: ORACLE_HOME, ORACLE_SID, DOMAIN_HOME, JAVA_HOME,
# SQL_CMD, SQL_CONNECT, PDB, ORDS_HOME, ORDS_CONFIG, ORDS_URL, ORDS_SERVICE, ADMIN_URL,
# APEX_IMAGES_DIR, DIAG_OUT, DIAG_DAYS, DIAG_LINES.
#
# Output: REPORT.md starts with FINDINGS (what the script itself thinks is wrong, by severity),
# then one section per area with the evidence. raw/ has the untruncated command output and logs.
# Hand REPORT.md (or the whole tarball) to Claude with: "analyse this oracle-diag report".

set -o pipefail
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DIAG_OUT="${DIAG_OUT:-$HOME/oracle-diag}"
DIAG_DAYS="${DIAG_DAYS:-3}"
DIAG_LINES="${DIAG_LINES:-200}"
ONLY_SID=""; SKIP=" "; THREADS=0; REDACT=1; MAKE_TAR=1; QUIET=0
SQL_TIMEOUT="${SQL_TIMEOUT:-90}"; CMD_TIMEOUT="${CMD_TIMEOUT:-60}"
HOST="$(hostname -s 2>/dev/null || hostname)"
STAMP="$(date '+%Y%m%d_%H%M%S')"
OUT=""; RAW=""; REPORT=""; FINDINGS=""; NCRIT=0; NWARN=0; NINFO=0
HAVE_TIMEOUT=0; command -v timeout >/dev/null 2>&1 && HAVE_TIMEOUT=1
SUDO=""; command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null && SUDO="sudo -n"

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
ts() { date '+%Y-%m-%d %H:%M:%S'; }
say()  { [ "$QUIET" = 1 ] || printf '%s  %s\n' "$(ts)" "$*" >&2; }
warn() { printf '%s  WARN %s\n' "$(ts)" "$*" >&2; }
die()  { printf '%s  ERROR %s\n' "$(ts)" "$*" >&2; exit 1; }
skipped() { case "$SKIP" in *" $1 "*) return 0;; esac; return 1; }

# to <secs> <cmd...>: run with a timeout when 'timeout' exists; never lets a hung tool hang the report
to() { local s="$1"; shift; if [ "$HAVE_TIMEOUT" = 1 ]; then timeout -k 5 "$s" "$@"; else "$@"; fi; }

# finding <CRIT|WARN|INFO> <area> <text>
finding() {
  case "$1" in CRIT) NCRIT=$((NCRIT+1));; WARN) NWARN=$((NWARN+1));; *) NINFO=$((NINFO+1));; esac
  FINDINGS="${FINDINGS}- **$1** [$2] $3"$'\n'
}

# report plumbing: everything goes to REPORT.md; big things also to raw/<name>
h1() { printf '\n# %s\n\n' "$*" >>"$REPORT"; }
h2() { printf '\n## %s\n\n' "$*" >>"$REPORT"; }
h3() { printf '\n### %s\n\n' "$*" >>"$REPORT"; }
para() { printf '%s\n\n' "$*" >>"$REPORT"; }
kv() { printf -- '- %s: `%s`\n' "$1" "${2:-n/a}" >>"$REPORT"; }
kv_end() { printf '\n' >>"$REPORT"; }
fence_start() { printf '```%s\n' "${1:-text}" >>"$REPORT"; }
fence_end() { printf '```\n\n' >>"$REPORT"; }

# redact: passwords in xml/properties/shell/ini style config
redact() {
  if [ "$REDACT" = 1 ]; then
    sed -E \
      -e 's/(<entry key="[^"]*(password|passwd|secret|credential)[^"]*">)[^<]*(<\/entry>)/\1***REDACTED***\3/Ig' \
      -e 's/(<(password|passwd|secret|credential-store-password|db\.password|node-manager-password)[^>]*>)[^<]*(<\/)/\1***REDACTED***\3/Ig' \
      -e 's/((password|passwd|secret|pwd)[A-Za-z0-9_.-]*[[:space:]]*[=:][[:space:]]*)[^[:space:]"]+/\1***REDACTED***/Ig' \
      -e 's/(password=")[^"]*(")/\1***REDACTED***\2/Ig' \
      -e 's#(//[^/:@[:space:]]+:)[^@[:space:]]+(@)#\1***REDACTED***\2#g'
  else
    cat
  fi
}

# section <name> <cmd...>: run a command, full output to raw/<name>.txt, up to DIAG_LINES lines into the report
section() {
  local name="$1"; shift
  local f="$RAW/$name.txt" rc n
  { printf '$ %s\n' "$*"; to "$CMD_TIMEOUT" "$@" 2>&1; rc=$?; printf '\n[exit %s]\n' "$rc"; } | redact >"$f"
  n="$(wc -l <"$f" | tr -d ' ')"
  fence_start
  if [ "$n" -gt "$DIAG_LINES" ]; then head -n "$DIAG_LINES" "$f" >>"$REPORT"; printf '... (%s lines total, full output in raw/%s.txt)\n' "$n" "$name" >>"$REPORT"
  else cat "$f" >>"$REPORT"; fi
  fence_end
}
# section_sh <name> <shell snippet>
section_sh() { local name="$1"; shift; section "$name" bash -c "$*"; }

# tail_file <name> <file>: last DIAG_LINES lines into the report, last 5000 into raw
tail_file() {
  local name="$1" f="$2"
  [ -r "$f" ] || { para "_$f: not readable_"; return 0; }
  tail -n 5000 "$f" 2>/dev/null | redact >"$RAW/$name.log"
  printf '%s (%s, %s lines, modified %s)\n\n' "$f" "$(du -h "$f" 2>/dev/null | cut -f1)" "$(wc -l <"$f" | tr -d ' ')" "$(date -r "$f" '+%Y-%m-%d %H:%M' 2>/dev/null)" >>"$REPORT"
  fence_start; tail -n "$DIAG_LINES" "$RAW/$name.log" >>"$REPORT"; fence_end
}

# recent_errors <name> <file> <regex>: lines matching regex from the last DIAG_DAYS days (by file mtime cut), counted by message
recent_errors() {
  local name="$1" f="$2" re="$3"
  [ -r "$f" ] || return 0
  # files are not always dated per line; take the tail that fits the window by size heuristic (last 200k lines)
  tail -n 200000 "$f" 2>/dev/null | grep -aE "$re" | redact >"$RAW/$name.errors"
  local n; n="$(wc -l <"$RAW/$name.errors" | tr -d ' ')"
  printf 'Error lines in the last %s lines of %s: **%s**\n\n' 200000 "$f" "$n" >>"$REPORT"
  [ "$n" = 0 ] && return 0
  para "Most frequent messages (count, message):"
  fence_start
  sed -E 's/^[0-9T:. -]+//; s/[0-9]{4,}/N/g' "$RAW/$name.errors" | cut -c1-160 | sort | uniq -c | sort -rn | head -25 >>"$REPORT"
  fence_end
  para "Last ${DIAG_LINES} error lines:"
  fence_start; tail -n "$DIAG_LINES" "$RAW/$name.errors" >>"$REPORT"; fence_end
  printf '%s\n' "$n"
}

pct_of() { # used% of a df line or "a of b"
  awk -v a="$1" -v b="$2" 'BEGIN{ if (b+0==0) print 0; else printf "%d", a*100/b }'
}

load_config() {
  local f
  for f in "$SCRIPT_DIR/oracle-diag.conf" "$HOME/.oracle-diag.conf" "$SCRIPT_DIR/apex-patch.conf" "$SCRIPT_DIR/ords-patch.conf" "$SCRIPT_DIR/wls-patch.conf"; do
    [ -f "$f" ] || continue
    while IFS='=' read -r k v; do
      case "$k" in ''|\#*) continue;; esac
      k="$(printf '%s' "$k" | tr -d '[:space:]')"; v="${v%\"}"; v="${v#\"}"
      [ -z "${!k:-}" ] && export "$k=$v"
    done <"$f"
  done
}

# ---------------------------------------------------------------------------
# host
# ---------------------------------------------------------------------------
diag_host() {
  say "host"
  h1 "Host"
  kv "hostname" "$(hostname -f 2>/dev/null || hostname)"
  kv "os" "$( (. /etc/os-release 2>/dev/null && printf '%s' "$PRETTY_NAME") || uname -sr)"
  kv "kernel" "$(uname -r)"; kv "arch" "$(uname -m)"
  kv "uptime" "$(uptime 2>/dev/null | sed 's/^ *//')"
  kv "date / tz" "$(date '+%Y-%m-%d %H:%M:%S %Z (%z)')"
  kv "running as" "$(id)"
  kv "sudo -n available" "$([ -n "$SUDO" ] && echo yes || echo no)"
  kv "virtualisation" "$(systemd-detect-virt 2>/dev/null || echo unknown)"
  kv "cpus" "$(nproc 2>/dev/null || grep -c ^processor /proc/cpuinfo)"
  kv "cpu model" "$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | sed 's/^ *//')"
  kv "selinux" "$(getenforce 2>/dev/null || echo n/a)"
  kv "time sync" "$( (chronyc tracking 2>/dev/null | grep -E 'Leap|System time' | tr '\n' ' ') || (ntpq -p 2>/dev/null | tail -n +3 | head -3 | tr '\n' ' ') || timedatectl 2>/dev/null | grep -i 'synchronized' )"
  kv "ksplice" "$( (uptrack-uname -r 2>/dev/null) || ([ -x /usr/sbin/ksplice ] && ksplice -y all show 2>/dev/null | tail -1) || echo 'not installed')"
  kv_end

  h2 "Memory and swap"
  section host_mem free -m
  local mem_total mem_avail swap_total swap_used
  mem_total="$(awk '/MemTotal/{print $2}' /proc/meminfo)"; mem_avail="$(awk '/MemAvailable/{print $2}' /proc/meminfo)"
  swap_total="$(awk '/SwapTotal/{print $2}' /proc/meminfo)"; swap_used="$(awk '/SwapTotal/{t=$2}/SwapFree/{f=$2}END{print t-f}' /proc/meminfo)"
  [ -n "$mem_total" ] && [ "$(pct_of "$mem_avail" "$mem_total")" -lt 10 ] && finding CRIT host "Less than 10% of RAM available ($((mem_avail/1024)) MB of $((mem_total/1024)) MB)"
  [ -n "$swap_total" ] && [ "$swap_total" -gt 0 ] && [ "$(pct_of "$swap_used" "$swap_total")" -gt 50 ] && finding WARN host "Swap more than half used ($((swap_used/1024)) MB of $((swap_total/1024)) MB) - memory pressure, check SGA/PGA/JVM heap sizing"
  section_sh host_hugepages "grep -E 'Huge|Shmem|Commit|Dirty' /proc/meminfo; echo; echo 'THP:'; cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null; echo 'THP defrag:'; cat /sys/kernel/mm/transparent_hugepage/defrag 2>/dev/null; echo; echo 'vm.nr_hugepages / swappiness / overcommit:'; sysctl -n vm.nr_hugepages vm.swappiness vm.overcommit_memory 2>/dev/null"
  grep -q '\[always\]' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null && pgrep -f ora_pmon >/dev/null 2>&1 && finding WARN host "Transparent HugePages are [always] on a database host - Oracle recommends 'never' (Doc ID 1557478.1)"

  h2 "Load and processes"
  section_sh host_load "cat /proc/loadavg; echo; vmstat 1 5 2>/dev/null; echo; echo 'Top CPU:'; ps -eo pid,user,pcpu,pmem,rss,etime,args --sort=-pcpu 2>/dev/null | head -15 | cut -c1-200; echo; echo 'Top memory:'; ps -eo pid,user,pcpu,pmem,rss,etime,args --sort=-rss 2>/dev/null | head -15 | cut -c1-200; echo; echo 'Zombies / D-state:'; ps -eo pid,stat,args | awk '\$2 ~ /^[ZD]/' | head -20"
  local load1 cpus; load1="$(cut -d' ' -f1 /proc/loadavg)"; cpus="$(nproc 2>/dev/null || echo 1)"
  awk -v l="$load1" -v c="$cpus" 'BEGIN{exit !(l > c*2)}' && finding WARN host "1-minute load average $load1 is more than twice the CPU count ($cpus)"
  section_sh host_limits "echo 'ulimit (this user):'; ulimit -a; echo; echo '/etc/security/limits.d + limits.conf (oracle/grid/weblogic lines):'; grep -hE '^\s*(oracle|grid|weblogic|\*)\s' /etc/security/limits.conf /etc/security/limits.d/* 2>/dev/null; echo; echo 'kernel:'; sysctl -n fs.file-max fs.aio-max-nr fs.aio-nr kernel.shmmax kernel.shmall kernel.sem net.core.rmem_max net.core.wmem_max net.ipv4.ip_local_port_range 2>/dev/null | paste - - - - - - - - - | awk '{print \"file-max=\"\$1, \"aio-max-nr=\"\$2, \"aio-nr=\"\$3, \"shmmax=\"\$4, \"shmall=\"\$5, \"sem=\"\$6\" \"\$7\" \"\$8\" \"\$9}'; echo; echo 'open files (system-wide):'; cat /proc/sys/fs/file-nr 2>/dev/null"
  local nofile; nofile="$(ulimit -n)"; [ "$nofile" != unlimited ] && [ "${nofile:-0}" -lt 65536 ] && finding WARN host "ulimit -n for this user is $nofile (Oracle recommends 65536)"

  h2 "Disk space"
  section_sh host_df "df -hP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null || df -hP; echo; echo 'inodes:'; df -iP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR==1 || \$5+0 > 70'"
  df -P -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1 {gsub("%","",$5); print $5, $6, $4}' | while read -r pct mnt avail; do
    if [ "$pct" -ge 95 ]; then finding CRIT host "Filesystem $mnt is ${pct}% full ($((avail/1024)) MB free)"
    elif [ "$pct" -ge 85 ]; then finding WARN host "Filesystem $mnt is ${pct}% full ($((avail/1024)) MB free)"; fi
  done
  df -iP -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null | awk 'NR>1 {gsub("%","",$5); if ($5+0 >= 90) print $5, $6}' | while read -r pct mnt; do finding CRIT host "Filesystem $mnt has ${pct}% of inodes used"; done
  section_sh host_mounts "mount 2>/dev/null | grep -vE 'cgroup|proc |sysfs|devpts|tmpfs|securityfs|debugfs|mqueue|hugetlbfs|pstore|bpf|tracefs|configfs|autofs|binfmt|fusectl|selinuxfs|rpc_pipefs|nsfs'; echo; echo 'NFS / ACFS / DBFS mounts:'; mount 2>/dev/null | grep -E ' type (nfs|nfs4|acfs|fuse\.dbfs|cifs)'; echo; echo 'multipath:'; \$SUDO multipath -ll 2>/dev/null | head -40"
  section_sh host_bigfiles "echo 'Largest files under common Oracle/log paths (>500M):'; find /u01 /u02 /u03 /opt/oracle /var/log /tmp /home/oracle /home/weblogic -xdev -type f -size +500M -printf '%s\t%TY-%Tm-%Td\t%p\n' 2>/dev/null | sort -rn | head -30 | awk -F'\t' '{printf \"%6d MB  %s  %s\n\", \$1/1048576, \$2, \$3}'; echo; echo 'Deleted-but-open files still holding space:'; \$SUDO lsof -nP +L1 2>/dev/null | awk 'NR==1 || \$7+0 > 104857600' | head -20; echo; echo '/tmp usage:'; du -sh /tmp 2>/dev/null; echo 'core dumps:'; find / -xdev -maxdepth 4 -type f -name 'core.[0-9]*' -o -type f -name 'hs_err_pid*.log' 2>/dev/null | head -20"

  h2 "Network"
  section_sh host_net "ip -br addr 2>/dev/null || ifconfig -a; echo; echo 'routes:'; ip route 2>/dev/null; echo; echo 'listening:'; (ss -ltnp 2>/dev/null || netstat -ltnp 2>/dev/null) | head -60; echo; echo 'connection states:'; (ss -tan 2>/dev/null || netstat -tan 2>/dev/null) | awk 'NR>1{print \$1}' | sort | uniq -c | sort -rn; echo; echo 'TIME-WAIT/CLOSE-WAIT to listener-like ports:'; (ss -tan 2>/dev/null) | awk '\$1 ~ /CLOSE-WAIT/' | wc -l | sed 's/^/CLOSE-WAIT total: /'; echo; echo 'resolv/hosts:'; grep -vE '^\s*#' /etc/resolv.conf 2>/dev/null; echo; grep -vE '^\s*#|^\s*$' /etc/hosts 2>/dev/null | head -30; echo; echo 'name resolution of own host:'; getent hosts \$(hostname) 2>/dev/null; echo; echo 'firewall:'; \$SUDO firewall-cmd --list-all 2>/dev/null | head -20 || \$SUDO iptables -S 2>/dev/null | head -30; echo; echo 'nic errors/drops:'; ip -s link 2>/dev/null | grep -A3 -E '^[0-9]+: (eth|en|bond|ib)' | grep -E '^[0-9]+:|errors|dropped' | head -40"
  local cw; cw="$(ss -tan 2>/dev/null | awk '$1 ~ /CLOSE-WAIT/' | wc -l | tr -d ' ')"; [ "${cw:-0}" -gt 500 ] && finding WARN host "$cw sockets in CLOSE-WAIT - an application is leaking connections"

  h2 "System log errors (last ${DIAG_DAYS} days)"
  if [ -n "$SUDO" ] || [ "$(id -u)" = 0 ]; then
    section_sh host_dmesg "\$SUDO dmesg -T --level=emerg,alert,crit,err 2>/dev/null | tail -100 || \$SUDO dmesg 2>/dev/null | grep -iE 'error|oom|killed process|I/O error|segfault|hung task|call trace|link down|nfs.*not responding' | tail -100"
    section_sh host_journal "\$SUDO journalctl -p err --since '-${DIAG_DAYS}d' --no-pager -q 2>/dev/null | tail -150 || \$SUDO grep -ihE 'error|oom|killed process|segfault|hung task' /var/log/messages 2>/dev/null | tail -150"
    grep -qiE 'out of memory|killed process' "$RAW/host_dmesg.txt" "$RAW/host_journal.txt" 2>/dev/null && finding CRIT host "The kernel OOM killer has fired - see host_dmesg / host_journal in raw/ for which process was killed"
    grep -qiE 'I/O error|hung task|nfs.*not responding|EXT4-fs error|XFS .*error' "$RAW/host_dmesg.txt" 2>/dev/null && finding CRIT host "Storage / I/O errors in dmesg"
  else
    para "_dmesg and journalctl need root (sudo -n not permitted for this user) - skipped. Run as root, or allow 'sudo -n dmesg' / 'sudo -n journalctl', to include them._"
    finding INFO host "Kernel and system log were not readable (no root) - OOM kills and I/O errors would not be seen"
  fi
  section_sh host_units "systemctl --failed --no-legend 2>/dev/null; echo; echo 'oracle-ish units:'; systemctl list-units --type=service --all --no-legend 2>/dev/null | grep -iE 'oracle|ords|weblogic|wls|nodemanager|apex|ohs|goldengate|ogg|gcagent|emagent|tfa|ahf|oswbb|okv|avdf|ksplice|uptrack|chrony|ntp' | cut -c1-160"
  local failed; failed="$(systemctl --failed --no-legend 2>/dev/null | wc -l | tr -d ' ')"; [ "${failed:-0}" -gt 0 ] && finding WARN host "$failed systemd unit(s) in failed state"
  section_sh host_reboots "last -x reboot shutdown 2>/dev/null | head -10; echo; echo 'who -b:'; who -b 2>/dev/null"
  section_sh host_cron "for u in oracle grid weblogic ords \$(id -un); do echo \"== crontab \$u\"; crontab -l -u \$u 2>/dev/null || ( [ \"\$u\" = \"\$(id -un)\" ] && crontab -l 2>/dev/null ); done; echo; ls -la /etc/cron.d 2>/dev/null"
  section_sh host_packages "rpm -qa 2>/dev/null | grep -iE 'oracle|preinstall|ksplice|uptrack|java|jdk|compat-libcap|libaio|ahf|tfa|exadata|okv|avdf|oswatcher|chrony' | sort | head -60"
  section_sh host_yum_history "\$SUDO yum history list 2>/dev/null | head -15 || \$SUDO dnf history list 2>/dev/null | head -15 || apt list --installed 2>/dev/null | wc -l"
  section_sh host_lastlog "echo 'last logins:'; last -n 20 2>/dev/null | head -20; echo; echo 'failed ssh / su (needs root):'; \$SUDO grep -ihE 'authentication failure|Failed password|invalid user' /var/log/secure /var/log/auth.log 2>/dev/null | tail -20"
}

# ---------------------------------------------------------------------------
# database
# ---------------------------------------------------------------------------
# sql <sid> <sql>: run in instance <sid> as sysdba (or SQL_CONNECT), formatted for reading. Stdout = result.
sql() {
  local sid="$1"; shift
  local home; home="$(oratab_home "$sid")"
  [ -z "$home" ] && home="${ORACLE_HOME:-}"
  local cmd="${SQL_CMD:-$home/bin/sqlplus -S}"
  [ -x "${cmd%% *}" ] || command -v "${cmd%% *}" >/dev/null 2>&1 || { echo "no sqlplus for $sid ($cmd)"; return 1; }
  ORACLE_SID="$sid" ORACLE_HOME="$home" LD_LIBRARY_PATH="$home/lib:${LD_LIBRARY_PATH:-}" PATH="$home/bin:$PATH" NLS_DATE_FORMAT='YYYY-MM-DD HH24:MI:SS' NLS_LANG="${NLS_LANG:-AMERICAN_AMERICA.AL32UTF8}" \
    to "$SQL_TIMEOUT" bash -c "printf 'set pagesize 500 linesize 250 trimspool on tab off feedback off verify off echo off colsep \"  \"\nset numwidth 14\nalter session set nls_date_format=\"YYYY-MM-DD HH24:MI:SS\";\n%s\n%s\nexit\n' \"\${PDB_SET:-}\" \"\$1\" | $cmd \"\${SQL_CONNECT:-/ as sysdba}\" 2>&1" _ "$*"
}
# sqlsec <sid> <name> <title> <sql>: a titled, fenced block in the report; full output in raw/
sqlsec() {
  local sid="$1" name="$2" title="$3" q="$4" f
  f="$RAW/db_${sid}_${name}.txt"
  { printf -- '-- %s\n%s\n\n' "$title" "$q"; sql "$sid" "$q"; } >"$f" 2>&1
  h3 "$title"
  local n; n="$(wc -l <"$f" | tr -d ' ')"
  fence_start
  if [ "$n" -gt "$DIAG_LINES" ]; then head -n "$DIAG_LINES" "$f" >>"$REPORT"; printf '... (%s lines, full in raw/db_%s_%s.txt)\n' "$n" "$sid" "$name" >>"$REPORT"; else cat "$f" >>"$REPORT"; fi
  fence_end
}
sqlval() { sql "$1" "set heading off\nselect $2 from dual;" 2>/dev/null | sed '/^[[:space:]]*$/d' | head -1 | sed 's/^ *//;s/ *$//'; }
oratab_home() { grep -E "^$1:" /etc/oratab /var/opt/oracle/oratab 2>/dev/null | head -1 | cut -d: -f2; }

db_instances() { # SIDs with a pmon
  ps -eo args 2>/dev/null | sed -n 's/^ora_pmon_\([A-Za-z0-9_$]*\).*/\1/p; s/^db_pmon_\([A-Za-z0-9_$]*\).*/\1/p' | sort -u
}

diag_db_env() {
  h1 "Oracle environment"
  section_sh ora_oratab "grep -vE '^\s*#|^\s*$' /etc/oratab /var/opt/oracle/oratab 2>/dev/null"
  section_sh ora_inventory "for l in /etc/oraInst.loc /var/opt/oracle/oraInst.loc; do [ -f \$l ] && { echo \"== \$l\"; cat \$l; inv=\$(sed -n 's/^inventory_loc=//p' \$l); echo; echo 'Homes:'; grep -oE 'HOME NAME=\"[^\"]*\" LOC=\"[^\"]*\"( TYPE=\"[^\"]*\")?( IDX=\"[0-9]*\")?( CRS=\"true\")?' \$inv/ContentsXML/inventory.xml 2>/dev/null; }; done"
  section_sh ora_processes "ps -eo pid,user,etime,rss,args 2>/dev/null | grep -E '_pmon_|tnslsnr|ora_[a-z0-9]+_|asm_|ocssd|crsd|evmd|ohasd|mgr |extract |replicat |java .*(weblogic|ords|ohs|emagent|oms|tfa|okv|avagent)|httpd|opmn|tuxedo|tmboot|timesten|cmadmin' | grep -v grep | awk '{\$5=substr(\$0, index(\$0,\$5)); print \$1, \$2, \$3, \$4\"K\", substr(\$5,1,120)}' | sort -k5 | head -80"
  section_sh ora_homes_versions "for h in \$(grep -hvE '^\s*#|^\s*$' /etc/oratab /var/opt/oracle/oratab 2>/dev/null | cut -d: -f2 | sort -u); do echo \"== \$h\"; [ -x \$h/bin/sqlplus ] && \$h/bin/sqlplus -V 2>/dev/null | grep -i version; [ -x \$h/OPatch/opatch ] && { echo -n 'OPatch: '; \$h/OPatch/opatch version 2>/dev/null | head -1; timeout 120 \$h/OPatch/opatch lspatches 2>/dev/null | head -40; }; echo; done"
  local n; n="$(db_instances | wc -l | tr -d ' ')"
  kv "running instances" "$(db_instances | tr '\n' ' ')"; kv_end
  if grep -qE '^[^#].*:Y' /etc/oratab 2>/dev/null; then
    for s in $(grep -E '^[^#]' /etc/oratab 2>/dev/null | awk -F: '$3=="Y"{print $1}'); do
      case "$s" in +ASM*|-MGMTDB) continue;; esac
      db_instances | grep -qx "$s" || finding CRIT db "Instance $s is flagged :Y in /etc/oratab but has no pmon process (database down?)"
    done
  fi
}

diag_listener() {
  h2 "Listener"
  local homes h lsn
  homes="$(ps -eo args 2>/dev/null | grep -E '^[^ ]*/bin/tnslsnr ' | awk '{print $1, $2}' | sort -u)"
  if [ -z "$homes" ]; then finding CRIT db "No tnslsnr process running - nothing can connect to the database over the network"; para "_no tnslsnr process_"; return; fi
  printf '%s\n' "$homes" | while read -r bin lsn; do
    h="${bin%/bin/tnslsnr}"
    section "lsnr_${lsn}_status" env ORACLE_HOME="$h" "$h/bin/lsnrctl" status "$lsn"
    local logf; logf="$(sed -n 's/^Listener Log File *//p' "$RAW/lsnr_${lsn}_status.txt" | head -1)"
    [ -z "$logf" ] && logf="$(sed -n 's/^Listener Log File *//p' "$RAW/lsnr_${lsn}_status.txt")"
    if [ -n "$logf" ]; then
      logf="${logf%alert/log.xml}"; logf="${logf}trace/${lsn,,}.log"
      [ -f "$logf" ] || logf="$(find "$(dirname "$(dirname "$logf")")" -name '*.log' -path '*trace*' 2>/dev/null | head -1)"
      h3 "Listener log errors ($lsn)"
      local n; n="$(recent_errors "lsnr_${lsn}" "$logf" 'TNS-[0-9]+|ORA-[0-9]+|Error|refused|timed? ?out' | tail -1)"
      [ "${n:-0}" -gt 50 ] && finding WARN db "Listener $lsn log has $n recent TNS-/ORA- error lines (see raw/lsnr_${lsn}.errors)"
    fi
    grep -qE 'TNS-12541|TNS-12560|TNS-00511' "$RAW/lsnr_${lsn}_status.txt" && finding CRIT db "Listener $lsn is not responding to lsnrctl status"
    grep -qE 'The listener supports no services|Services Summary.*0 service' "$RAW/lsnr_${lsn}_status.txt" && finding CRIT db "Listener $lsn has no registered services - databases are not registered (check local_listener / alter system register)"
  done
  section_sh lsnr_config "for h in \$(ps -eo args 2>/dev/null | grep -E '^[^ ]*/bin/tnslsnr ' | awk '{print \$1}' | sed 's#/bin/tnslsnr##' | sort -u); do for f in listener.ora sqlnet.ora tnsnames.ora; do for d in \${TNS_ADMIN:-} \$h/network/admin; do [ -f \"\$d/\$f\" ] && { echo \"== \$d/\$f\"; grep -vE '^\s*#|^\s*$' \$d/\$f | head -80; echo; }; done; done; done"
}

# ADR alert log for an instance: resolve via v$diag_info, fall back to a find
diag_alert_log() {
  local sid="$1" alert
  alert="$(sqlval "$sid" "value || '/alert_${sid}.log'" 2>/dev/null)"
  [ -n "$alert" ] && alert="$(sql "$sid" "set heading off\nselect value||'/alert_${sid}.log' from v\$diag_info where name='Diag Trace';" 2>/dev/null | sed '/^[[:space:]]*$/d' | head -1 | sed 's/^ *//')"
  [ -f "$alert" ] || alert="$(find /u01/app/oracle/diag/rdbms /opt/oracle/diag/rdbms "${ORACLE_BASE:-/nonexistent}/diag/rdbms" -name "alert_${sid}.log" 2>/dev/null | head -1)"
  h3 "Alert log ($sid)"
  if [ ! -f "$alert" ]; then para "_alert log for $sid not found_"; return; fi
  kv "file" "$alert"; kv_end
  local n; n="$(recent_errors "alert_${sid}" "$alert" 'ORA-[0-9]+|TNS-[0-9]+|Errors in file|Checkpoint not complete|Thread [0-9]+ cannot allocate|deadlock|Instance terminated|Shutting down|PMON \(ospid|archiver (stuck|error)|unable to extend|Process .* exceeded|ORA-00020|immediate kill' | tail -1)"
  [ "${n:-0}" -gt 0 ] && {
    grep -qE 'ORA-00257|archiver (stuck|error)' "$RAW/alert_${sid}.errors" && finding CRIT db "$sid: archiver stuck (ORA-00257) in the alert log - FRA / archive destination full"
    grep -qE 'ORA-01555' "$RAW/alert_${sid}.errors" && finding WARN db "$sid: ORA-01555 snapshot too old in the alert log - undo retention / long queries"
    grep -qE 'ORA-0060|deadlock' "$RAW/alert_${sid}.errors" && finding WARN db "$sid: deadlocks (ORA-00060) in the alert log"
    grep -qE 'ORA-04031|ORA-04030' "$RAW/alert_${sid}.errors" && finding CRIT db "$sid: memory errors ORA-04031/ORA-04030 in the alert log - SGA/PGA sizing"
    grep -qE 'ORA-00020|ORA-00018' "$RAW/alert_${sid}.errors" && finding CRIT db "$sid: ORA-00020 maximum processes exceeded in the alert log"
    grep -qE 'ORA-01653|ORA-01654|ORA-01652|unable to extend' "$RAW/alert_${sid}.errors" && finding CRIT db "$sid: 'unable to extend' (ORA-0165x) in the alert log - a tablespace is full"
    grep -qE 'ORA-00600|ORA-07445|ORA-00700' "$RAW/alert_${sid}.errors" && finding CRIT db "$sid: internal errors ORA-600/ORA-7445 in the alert log - raise an SR with the incident package"
    grep -qE 'Checkpoint not complete|cannot allocate new log' "$RAW/alert_${sid}.errors" && finding WARN db "$sid: 'Checkpoint not complete' - redo logs too small or too few"
    grep -qE 'Instance terminated|Shutting down instance' "$RAW/alert_${sid}.errors" && finding WARN db "$sid: an instance shutdown/termination appears in the recent alert log"
    grep -qE 'ORA-28374|ORA-28365|wallet is not open|ORA-12578' "$RAW/alert_${sid}.errors" && finding CRIT db "$sid: TDE wallet / Key Vault errors in the alert log (ORA-28365/28374) - encrypted tablespaces unreadable until the keystore is open"
  }
  tail_file "alert_${sid}_tail" "$alert"
}

# checks emitted by SQL as  CHECK|SEV|text  are turned into findings
sql_checks() { # <sid> <label> <sql>
  local sid="$1" label="$2" q="$3"
  sql "$sid" "set heading off\n$q" 2>/dev/null | grep -a '^CHECK|' | while IFS='|' read -r _ sev txt; do finding "$sev" db "$label: $txt"; done
}

diag_db_instance() {
  local sid="$1"
  say "database $sid"
  h2 "Database instance $sid"
  local ok; ok="$(sqlval "$sid" "'ok'" 2>&1)"
  if [ "$ok" != ok ]; then
    para "Cannot connect to $sid as sysdba: \`$ok\`"
    finding CRIT db "$sid: sqlplus '/ as sysdba' failed (${ok:0:120}) - instance hung, wrong ORACLE_HOME in oratab, or run as the wrong user"
    diag_alert_log "$sid"; return
  fi
  sqlsec "$sid" overview "Overview" "col host_name for a30
col version_full for a14
col db_unique_name for a20
col open_mode for a12
col database_role for a16
col log_mode for a12
col flashback_on for a10
col force_logging for a8
select i.instance_name, i.host_name, i.status, i.database_status, i.startup_time, i.logins, i.archiver, i.version_full
from v\$instance i;
select d.name, d.db_unique_name, d.open_mode, d.database_role, d.log_mode, d.flashback_on, d.force_logging, d.cdb, d.protection_mode, d.switchover_status, d.created
from v\$database d;
select banner_full from v\$version;
select to_char(sysdate,'YYYY-MM-DD HH24:MI:SS') db_time, dbtimezone, sessiontimezone from dual;
select con_id, name, open_mode, restricted, total_size/1024/1024/1024 gb, to_char(open_time,'YYYY-MM-DD HH24:MI') open_time from v\$pdbs order by con_id;
col comp_name for a40
col version_full for a14
select comp_id, comp_name, version_full, status from dba_registry order by comp_id;
col action for a10
col description for a70
select to_char(action_time,'YYYY-MM-DD HH24:MI') applied, patch_id, action, status, substr(description,1,70) description from (select * from dba_registry_sqlpatch order by action_time desc) where rownum<=10;"

  sqlsec "$sid" params "Key parameters (non-default + important)" "col name for a40
col value for a70
select name, value, isdefault from v\$parameter where name in ('processes','sessions','open_cursors','cpu_count','sga_target','sga_max_size','pga_aggregate_target','pga_aggregate_limit','memory_target','memory_max_target','db_recovery_file_dest','db_recovery_file_dest_size','log_archive_dest_1','log_archive_dest_2','undo_retention','undo_tablespace','compatible','db_files','local_listener','remote_listener','dispatchers','shared_servers','use_large_pages','filesystemio_options','db_block_size','audit_trail','wallet_root','tde_configuration','encrypt_new_tablespaces','enable_ddl_logging','job_queue_processes','aq_tm_processes','parallel_max_servers','resource_manager_plan','cluster_database','instance_number','diagnostic_dest','max_string_size','sec_case_sensitive_logon','inmemory_size') order by name;
select 'non-default: '||name||' = '||substr(value,1,80) from v\$parameter where isdefault='FALSE' and name not in ('processes','sessions','sga_target','pga_aggregate_target','db_name','db_unique_name','control_files','db_recovery_file_dest','db_recovery_file_dest_size','diagnostic_dest','audit_file_dest','open_cursors','compatible','undo_tablespace','nls_language','nls_territory','local_listener','remote_listener','dispatchers','db_block_size','db_domain','log_archive_format','instance_number','thread','cluster_database','spfile','audit_trail','memory_target','sga_max_size','enable_pluggable_database','db_create_file_dest','pga_aggregate_limit','cpu_count') order by 1;"

  sqlsec "$sid" memory "Memory (SGA / PGA / hugepages fit)" "select name, round(bytes/1024/1024) mb from v\$sga;
select component, round(current_size/1024/1024) cur_mb, round(min_size/1024/1024) min_mb, round(max_size/1024/1024) max_mb, oper_count from v\$sga_dynamic_components where current_size>0;
select name, round(value/1024/1024) mb from v\$pgastat where name in ('aggregate PGA target parameter','aggregate PGA auto target','maximum PGA allocated','total PGA allocated','total PGA inuse','cache hit percentage','over allocation count');
select pool, name, round(bytes/1024/1024) free_mb from v\$sgastat where name='free memory';"

  sqlsec "$sid" resources "Resource limits, sessions, blocking" "col resource_name for a28
select resource_name, current_utilization, max_utilization, limit_value from v\$resource_limit where resource_name in ('processes','sessions','enqueue_locks','transactions','parallel_max_servers','dml_locks');
select status, type, count(*) from v\$session group by status, type order by 1,2;
col machine for a30
col program for a30
col username for a20
select * from (select username, machine, substr(program,1,30) program, count(*) sess, sum(decode(status,'ACTIVE',1,0)) active from v\$session where type='USER' group by username, machine, substr(program,1,30) order by 4 desc) where rownum<=20;
col blocked for a60
select s.sid||','||s.serial# blocker, s.username, s.machine, s.event, s.seconds_in_wait, (select listagg(w.sid, ',') within group (order by w.sid) from v\$session w where w.blocking_session=s.sid) blocked from v\$session s where s.sid in (select blocking_session from v\$session where blocking_session is not null);
select sid, serial#, username, status, event, seconds_in_wait, sql_id, substr(machine,1,25) machine from v\$session where status='ACTIVE' and type='USER' and wait_class<>'Idle' and rownum<=25 order by seconds_in_wait desc;
select 'long transaction: sid '||s.sid||' user '||s.username||' started '||t.start_time||' undo blocks '||t.used_ublk from v\$transaction t join v\$session s on s.taddr=t.addr where t.start_date < sysdate-1/24;
col opname for a30
select sid, substr(opname,1,30) opname, round(sofar*100/totalwork) pct, time_remaining, elapsed_seconds, sql_id from v\$session_longops where totalwork>0 and sofar<totalwork;
select wait_class, round(sum(time_waited_micro)/1e6) secs, sum(total_waits) waits from v\$system_wait_class where wait_class<>'Idle' group by wait_class order by 2 desc;
select * from (select event, total_waits, round(time_waited_micro/1e6) secs, round(average_wait*10) avg_ms from v\$system_event where wait_class<>'Idle' order by time_waited_micro desc) where rownum<=15;"

  sqlsec "$sid" storage "Tablespaces, FRA, ASM, redo" "col tablespace_name for a25
select t.tablespace_name, t.contents, round(u.used_mb) used_mb, round(f.cur_mb) cur_mb, round(f.max_mb) max_mb, round(u.used_mb*100/f.cur_mb) pct_cur, round(u.used_mb*100/f.max_mb) pct_max, f.files
from dba_tablespaces t
join (select tablespace_name, sum(bytes)/1048576 cur_mb, sum(greatest(bytes, decode(autoextensible,'YES',maxbytes,bytes)))/1048576 max_mb, count(*) files from dba_data_files group by tablespace_name) f on f.tablespace_name=t.tablespace_name
left join (select tablespace_name, sum(bytes)/1048576 used_mb from dba_segments group by tablespace_name) u on u.tablespace_name=t.tablespace_name
where t.contents<>'TEMPORARY' order by pct_max desc nulls last;
select tablespace_name, round(tablespace_size*8/1024) size_mb_blk8, round(allocated_space*8/1024) alloc_mb, round(free_space*8/1024) free_mb from dba_temp_free_space;
select 'undo: '||tablespace_name||' size '||round(sum(bytes)/1048576)||' MB, used '||(select round(sum(bytes)/1048576) from dba_undo_extents where status in ('ACTIVE','UNEXPIRED')) ||' MB active/unexpired' from dba_data_files where tablespace_name=(select value from v\$parameter where name='undo_tablespace') group by tablespace_name;
select 'datafiles: '||count(*)||' of db_files='||(select value from v\$parameter where name='db_files') from dba_data_files;
select name fra, round(space_limit/1073741824,1) limit_gb, round(space_used/1073741824,1) used_gb, round(space_reclaimable/1073741824,1) reclaimable_gb, round((space_used-space_reclaimable)*100/space_limit) pct_net, number_of_files from v\$recovery_file_dest;
select file_type, percent_space_used, percent_space_reclaimable, number_of_files from v\$recovery_area_usage where percent_space_used>0;
select name, state, type, round(total_mb/1024) total_gb, round(free_mb/1024) free_gb, round((total_mb-free_mb)*100/total_mb) pct_used, round(usable_file_mb/1024) usable_gb, offline_disks from v\$asm_diskgroup;
select 'redo: '||count(*)||' groups, '||round(max(bytes)/1048576)||' MB each, threads '||count(distinct thread#) from v\$log;
select to_char(first_time,'YYYY-MM-DD HH24') hour, count(*) switches, round(sum(blocks*block_size)/1048576) redo_mb from v\$archived_log where first_time>sysdate-1 and dest_id=1 group by to_char(first_time,'YYYY-MM-DD HH24') order by 1;
select dest_id, status, target, archiver, error from v\$archive_dest_status where status<>'INACTIVE';
select 'files in hot backup mode: '||count(*) from v\$backup where status='ACTIVE';
select status, enabled, count(*) files from v\$datafile group by status, enabled;
select file#, name, status, error, recover from v\$datafile_header where error is not null or recover='YES';"
  sql_checks "$sid" "$sid" "select 'CHECK|'||case when pct>=97 then 'CRIT' else 'WARN' end||'|tablespace '||tablespace_name||' is '||pct||'% of its maximum size ('||round(max_mb/1024,1)||' GB)' from (
  select t.tablespace_name, round(u.used_mb*100/f.max_mb) pct, f.max_mb from dba_tablespaces t join (select tablespace_name, sum(greatest(bytes, decode(autoextensible,'YES',maxbytes,bytes)))/1048576 max_mb from dba_data_files group by tablespace_name) f on f.tablespace_name=t.tablespace_name join (select tablespace_name, sum(bytes)/1048576 used_mb from dba_segments group by tablespace_name) u on u.tablespace_name=t.tablespace_name where t.contents<>'TEMPORARY') where pct>=90;
select 'CHECK|'||case when p>=95 then 'CRIT' else 'WARN' end||'|FRA is '||p||'% full net of reclaimable space ('||round(space_used/1073741824)||' of '||round(space_limit/1073741824)||' GB)' from (select space_used, space_limit, round((space_used-space_reclaimable)*100/space_limit) p from v\$recovery_file_dest) where p>=85;
select 'CHECK|WARN|ASM diskgroup '||name||' is '||round((total_mb-free_mb)*100/total_mb)||'% used' from v\$asm_diskgroup where total_mb>0 and (total_mb-free_mb)*100/total_mb>=85;
select 'CHECK|CRIT|ASM diskgroup '||name||' has '||offline_disks||' offline disk(s)' from v\$asm_diskgroup where offline_disks>0;
select 'CHECK|'||case when current_utilization*100/to_number(limit_value)>=95 then 'CRIT' else 'WARN' end||'|'||resource_name||' at '||current_utilization||' of '||limit_value||' (max seen '||max_utilization||')' from v\$resource_limit where resource_name in ('processes','sessions') and limit_value not like '%UNLIMITED%' and current_utilization*100/to_number(limit_value)>=80;
select 'CHECK|CRIT|'||count(*)||' session(s) blocked by sid '||blocking_session||' for up to '||max(seconds_in_wait)||'s' from v\$session where blocking_session is not null and seconds_in_wait>60 group by blocking_session;
select 'CHECK|CRIT|archive destination '||dest_id||' error: '||error from v\$archive_dest_status where status='ERROR';
select 'CHECK|WARN|'||count(*)||' datafile(s) in hot backup mode' from v\$backup where status='ACTIVE' having count(*)>0;
select 'CHECK|CRIT|datafile '||file#||' '||name||' needs recovery / error '||error from v\$datafile_header where error is not null or recover='YES';
select 'CHECK|WARN|redo switching '||max(c)||' times in an hour in the last day (aim for 4-6)' from (select count(*) c from v\$archived_log where first_time>sysdate-1 and dest_id=1 group by to_char(first_time,'YYYY-MM-DD HH24')) having max(c)>12;
select 'CHECK|WARN|PGA over-allocation count '||value||' - pga_aggregate_target too small' from v\$pgastat where name='over allocation count' and value>0;
select 'CHECK|WARN|'||name||' has '||status||' PDB open_mode '||open_mode from v\$pdbs where open_mode not in ('READ WRITE') and name<>'PDB\$SEED';
select 'CHECK|WARN|database is in NOARCHIVELOG mode - no point-in-time recovery' from v\$database where log_mode='NOARCHIVELOG';
select 'CHECK|WARN|registry component '||comp_name||' is '||status from dba_registry where status not in ('VALID','OPTION OFF','REMOVED');"

  sqlsec "$sid" backup "RMAN backups (14 days), restore points, Data Guard" "col status for a24
col input_type for a14
select to_char(start_time,'YYYY-MM-DD HH24:MI') started, input_type, status, round(elapsed_seconds/60) mins, round(input_bytes/1073741824,1) in_gb, round(output_bytes/1073741824,1) out_gb, output_device_type dev from v\$rman_backup_job_details where start_time>sysdate-14 order by start_time desc;
select 'last successful DB backup: '||max(start_time) from v\$rman_backup_job_details where status like 'COMPLETED%' and input_type like 'DB%';
select 'last successful archivelog backup: '||max(start_time) from v\$rman_backup_job_details where status like 'COMPLETED%' and input_type in ('ARCHIVELOG','DB INCR','DB FULL');
select 'archivelogs not backed up: '||count(*)||' ('||round(nvl(sum(blocks*block_size),0)/1073741824,1)||' GB)' from v\$archived_log where backup_count=0 and deleted='NO' and dest_id=1 and standby_dest='NO';
col output for a120
select to_char(start_time,'YYYY-MM-DD HH24:MI') t, substr(output,1,120) output from (select * from v\$rman_output where output like '%RMAN-%' or output like '%ORA-%' order by recid desc) where rownum<=20;
select 'controlfile autobackup: '||(select nvl(max(to_char(completion_time,'YYYY-MM-DD HH24:MI')),'never') from v\$backup_set where controlfile_included='BACKUP') from dual;
select name, guarantee_flashback_database guaranteed, to_char(time,'YYYY-MM-DD HH24:MI') created, round(storage_size/1073741824,1) gb, scn from v\$restore_point;
select 'flashback retention target (min): '||value from v\$parameter where name='db_flashback_retention_target';
select name, value, unit, time_computed from v\$dataguard_stats;
select dest_id, status, database_mode, recovery_mode, gap_status, error from v\$archive_dest_status where dest_id in (select dest_id from v\$archive_dest where target='STANDBY' and status<>'INACTIVE');
select process, status, thread#, sequence#, block#, delay_mins from v\$managed_standby where process in ('MRP0','RFS','LNS') and rownum<=10;
select * from v\$archive_gap;
select to_char(timestamp,'YYYY-MM-DD HH24:MI') t, substr(message,1,120) message from (select * from v\$dataguard_status where severity in ('Error','Fatal') order by timestamp desc) where rownum<=15;"
  sql_checks "$sid" "$sid" "select 'CHECK|'||case when nvl(max(start_time),sysdate-99)<sysdate-7 then 'CRIT' else 'WARN' end||'|last successful database backup was '||nvl(to_char(max(start_time),'YYYY-MM-DD'),'never (no RMAN history in the controlfile - ZDLRA/catalog may hold it)') from v\$rman_backup_job_details where status like 'COMPLETED%' and input_type like 'DB%' having nvl(max(start_time),sysdate-99)<sysdate-2;
select 'CHECK|CRIT|RMAN job '||to_char(start_time,'YYYY-MM-DD HH24:MI')||' ('||input_type||') status '||status from v\$rman_backup_job_details where start_time>sysdate-3 and status not like 'COMPLETED%' and status<>'RUNNING';
select 'CHECK|WARN|guaranteed restore point '||name||' is '||round(sysdate-time)||' days old and holds '||round(storage_size/1073741824,1)||' GB of flashback logs' from v\$restore_point where guarantee_flashback_database='YES' and time<sysdate-7;
select 'CHECK|CRIT|Data Guard '||name||' is '||value||' (standby lagging)' from v\$dataguard_stats where name in ('apply lag','transport lag') and value is not null and (value like '+%' and (substr(value,2,2)<>'00' or substr(value,5,2)<>'00' or to_number(substr(value,8,2))>=30));
select 'CHECK|CRIT|standby destination '||dest_id||' '||gap_status||' / '||error from v\$archive_dest_status where dest_id in (select dest_id from v\$archive_dest where target='STANDBY' and status<>'INACTIVE') and (status='ERROR' or gap_status not in ('NO GAP'));
select 'CHECK|CRIT|standby: no MRP (managed recovery) process running' from v\$database where database_role='PHYSICAL STANDBY' and not exists (select 1 from v\$managed_standby where process like 'MRP%');
select 'CHECK|WARN|'||count(*)||' archivelogs ('||round(sum(blocks*block_size)/1073741824,1)||' GB) not yet backed up' from v\$archived_log where backup_count=0 and deleted='NO' and dest_id=1 and standby_dest='NO' having count(*)>200;"

  sqlsec "$sid" security "Security: TDE / Key Vault, Database Vault, audit, accounts" "col wrl_type for a10
col wrl_parameter for a60
col wallet_type for a14
select wrl_type, substr(wrl_parameter,1,60) wrl_parameter, status, wallet_type, keystore_mode, con_id from v\$encryption_wallet;
select 'encrypted tablespaces: '||count(*) from v\$encrypted_tablespaces;
select 'encrypted tablespaces: '||count(*)||' (CDB view)' from cdb_tablespaces where encrypted='YES';
select 'Database Vault: '||listagg(name||'='||status,', ') within group (order by name) from dba_dv_status;
select 'unified audit rows: '||count(*) from unified_audit_trail where event_timestamp>sysdate-1;
select 'aud\$ rows: '||count(*) from sys.aud\$;
select 'audit tablespace: '||tablespace_name from dba_segments where segment_name='AUD\$' and owner='SYS';
select 'fga rows: '||count(*) from sys.fga_log\$;
col username for a30
col profile for a24
col account_status for a20
select username, account_status, to_char(expiry_date,'YYYY-MM-DD') expires, profile, to_char(lock_date,'YYYY-MM-DD') locked, oracle_maintained from dba_users where account_status<>'OPEN' and oracle_maintained='N' or username in ('APEX_PUBLIC_USER','ORDS_PUBLIC_USER','ORDS_METADATA','APEX_LISTENER','APEX_REST_PUBLIC_USER','DBSNMP','SYSMAN','GGADMIN','OGGADMIN','RMAN','RCAT','AVSRC','SYS','SYSTEM') order by username;
select username, account_status, to_char(expiry_date,'YYYY-MM-DD') expires from dba_users where expiry_date between sysdate and sysdate+14 order by expiry_date;
select profile, resource_name, limit from dba_profiles where resource_name in ('PASSWORD_LIFE_TIME','FAILED_LOGIN_ATTEMPTS','PASSWORD_GRACE_TIME','SESSIONS_PER_USER') and profile in (select distinct profile from dba_users where oracle_maintained='N' or username like '%PUBLIC_USER') order by 1,2;
select 'failed logins last 24h (unified): '||count(*) from unified_audit_trail where action_name='LOGON' and return_code<>0 and event_timestamp>sysdate-1;
select 'sec_case_sensitive_logon / sqlnet allowed_logon_version: see sqlnet.ora' from dual where 1=0;"
  sql_checks "$sid" "$sid" "select 'CHECK|CRIT|TDE keystore '||substr(wrl_parameter,1,50)||' status '||status||' (con '||con_id||') - encrypted data is unreadable' from v\$encryption_wallet where wallet_type<>'UNKNOWN' and status not in ('OPEN','OPEN_NO_MASTER_KEY','NOT_AVAILABLE') and con_id<>2;
select 'CHECK|CRIT|'||username||' is '||account_status||case when username like 'APEX%' or username like 'ORDS%' then ' - APEX/ORDS will return 503/404' else '' end from dba_users where username in ('APEX_PUBLIC_USER','ORDS_PUBLIC_USER','APEX_LISTENER','APEX_REST_PUBLIC_USER','ORDS_METADATA') and account_status<>'OPEN';
select 'CHECK|WARN|'||username||' password expires '||to_char(expiry_date,'YYYY-MM-DD')||' (profile '||profile||')' from dba_users where expiry_date between sysdate and sysdate+14 and (oracle_maintained='N' or username in ('APEX_PUBLIC_USER','ORDS_PUBLIC_USER','APEX_LISTENER','APEX_REST_PUBLIC_USER','DBSNMP','GGADMIN'));
select 'CHECK|WARN|APEX/ORDS public user '||username||' uses profile '||profile||' with PASSWORD_LIFE_TIME '||(select limit from dba_profiles p where p.profile=u.profile and p.resource_name='PASSWORD_LIFE_TIME')||' - will expire and break ORDS' from dba_users u where username in ('APEX_PUBLIC_USER','ORDS_PUBLIC_USER','APEX_LISTENER','APEX_REST_PUBLIC_USER') and (select limit from dba_profiles p where p.profile=u.profile and p.resource_name='PASSWORD_LIFE_TIME') not in ('UNLIMITED','DEFAULT');
select 'CHECK|WARN|'||count(*)||' failed logons in the last 24h (unified audit)' from unified_audit_trail where action_name='LOGON' and return_code<>0 and event_timestamp>sysdate-1 having count(*)>100;
select 'CHECK|WARN|sys.aud\$ has '||count(*)||' rows in SYSTEM tablespace - purge/relocate (DBMS_AUDIT_MGMT)' from sys.aud\$ having count(*)>5000000;"

  sqlsec "$sid" jobs "Scheduler, alerts, AWR, stats, invalid objects (container-wide)" "col job_name for a40
col owner for a20
select owner, job_name, status, to_char(actual_start_date,'YYYY-MM-DD HH24:MI') started, substr(additional_info,1,80) info from (select * from dba_scheduler_job_run_details where status<>'SUCCEEDED' and log_date>sysdate-$DIAG_DAYS order by log_date desc) where rownum<=25;
select owner, job_name, state, failure_count, to_char(last_start_date,'YYYY-MM-DD HH24:MI') last_start, to_char(next_run_date,'YYYY-MM-DD HH24:MI') next_run from dba_scheduler_jobs where (failure_count>0 or state in ('BROKEN','FAILED')) and enabled='TRUE' order by failure_count desc;
select job, what, broken, failures, to_char(last_date,'YYYY-MM-DD HH24:MI') last_date from dba_jobs where broken='Y' or failures>0;
col reason for a90
select object_type, substr(object_name,1,20) obj, substr(reason,1,90) reason, to_char(creation_time,'YYYY-MM-DD HH24:MI') t from (select * from dba_outstanding_alerts order by creation_time desc) where rownum<=20;
select window_name, enabled, active, to_char(last_start_date,'YYYY-MM-DD HH24:MI') last_start from dba_scheduler_windows;
select client_name, status, consumer_group from dba_autotask_client;
select client_name, job_status, to_char(job_start_time,'YYYY-MM-DD HH24:MI') started, substr(job_info,1,60) info from (select * from dba_autotask_job_history where job_start_time>sysdate-$DIAG_DAYS and job_status<>'SUCCEEDED' order by job_start_time desc) where rownum<=10;
select 'AWR: interval '||extract(hour from snap_interval)*60+extract(minute from snap_interval)||' min, retention '||extract(day from retention)||' days' from dba_hist_wr_control where dbid=(select dbid from v\$database);
select 'AWR last snapshot: '||max(end_interval_time) from dba_hist_snapshot where dbid=(select dbid from v\$database);
select 'stale stats (tables): '||count(*) from dba_tab_statistics where stale_stats='YES' and owner not in ('SYS','SYSTEM');
select 'tables never analysed: '||count(*) from dba_tab_statistics where last_analyzed is null and owner not in ('SYS','SYSTEM') and object_type='TABLE' and (owner not like 'APEX%');
select owner, object_type, count(*) invalid from cdb_objects where status<>'VALID' group by owner, object_type order by 3 desc;
select 'recyclebin objects: '||count(*)||', '||round(nvl(sum(space),0)*8/1024)||' MB (8K blocks)' from dba_recyclebin;
select 'db links: '||count(*) from dba_db_links;
select name, network_name, con_name, enabled from (select s.name, s.network_name, (select name from v\$containers c where c.con_id=s.con_id) con_name, s.enabled from v\$services s) order by 1;"
  sql_checks "$sid" "$sid" "select 'CHECK|WARN|'||count(*)||' scheduler job run(s) failed in the last $DIAG_DAYS days' from dba_scheduler_job_run_details where status<>'SUCCEEDED' and log_date>sysdate-$DIAG_DAYS having count(*)>0;
select 'CHECK|WARN|'||count(*)||' invalid objects (excluding SYS/SYSTEM/APEX internal)' from cdb_objects where status<>'VALID' and owner not in ('SYS','SYSTEM','PUBLIC') having count(*)>0;
select 'CHECK|CRIT|outstanding alert: '||substr(reason,1,120) from dba_outstanding_alerts where creation_time>sysdate-$DIAG_DAYS and rownum<=10;
select 'CHECK|WARN|AWR last snapshot is '||round((sysdate-cast(max(end_interval_time) as date))*24)||'h old - MMON / snapshots not running' from dba_hist_snapshot where dbid=(select dbid from v\$database) having max(end_interval_time)<sysdate-3/24;
select 'CHECK|WARN|automatic optimizer stats gathering is '||status from dba_autotask_client where client_name='auto optimizer stats collection' and status<>'ENABLED';
select 'CHECK|WARN|'||count(*)||' tables with stale statistics' from dba_tab_statistics where stale_stats='YES' and owner not in ('SYS','SYSTEM') having count(*)>200;"

  diag_alert_log "$sid"
  diag_adr "$sid"
}

diag_adr() { # ADR incidents and problems for the instance
  local sid="$1" home; home="$(oratab_home "$sid")"; [ -z "$home" ] && home="${ORACLE_HOME:-}"
  [ -x "$home/bin/adrci" ] || return 0
  h3 "ADR incidents / problems ($sid, last ${DIAG_DAYS} days)"
  section "adr_${sid}" env ORACLE_HOME="$home" ORACLE_SID="$sid" "$home/bin/adrci" exec="set home $(ls -d "${ORACLE_BASE:-/u01/app/oracle}"/diag/rdbms/*/"$sid" 2>/dev/null | head -1 | sed "s#^${ORACLE_BASE:-/u01/app/oracle}/##"); show problem -last 10; show incident -last 20 -p \"create_time > systimestamp - interval '$DIAG_DAYS' day\""
  local inc; inc="$(grep -cE '^[0-9]+ +[0-9]+ +ORA-' "$RAW/adr_${sid}.txt" 2>/dev/null)"
  [ "${inc:-0}" -gt 0 ] && finding WARN db "$sid: $inc ADR incident(s) in the last $DIAG_DAYS days (adrci output in raw/adr_${sid}.txt) - 'adrci> ips pack' for an SR"
}

# ---------------------------------------------------------------------------
# APEX (per container)
# ---------------------------------------------------------------------------
diag_apex_in() { # <sid> <container label>  (PDB_SET already exported by caller)
  local sid="$1" con="$2" tag="${2//[^A-Za-z0-9]/_}"
  local ver; ver="$(sqlval "$sid" "(select version_no from apex_release)" 2>/dev/null)"
  [ -z "$ver" ] && { para "_APEX not installed in $con_"; return 0; }
  say "apex $sid/$con"
  h3 "APEX in $con (version $ver)"
  sqlsec "$sid" "apex_${tag}" "APEX $con: release, schema, accounts, jobs" "select version_no, patch_applied_on, api_compatibility from apex_release;
col comp_name for a30
select comp_id, comp_name, version, status, schema from dba_registry where comp_id in ('APEX','ORDS');
select 'APEX schema: '||schema||', status '||status from dba_registry where comp_id='APEX';
select 'ORDS schema version in DB: '||(select installed_version from dba_objects o, ords_metadata.ords_version v where o.object_name='ORDS_VERSION' and rownum=1) from dual;
select username, account_status, to_char(expiry_date,'YYYY-MM-DD') expires, profile from dba_users where username like 'APEX%' or username like 'ORDS%' or username in ('FLOWS_FILES') order by 1;
select 'workspaces: '||count(*) from apex_workspaces;
select 'applications: '||count(*)||', last changed '||max(last_updated_on) from apex_applications;
select owner, job_name, state, failure_count, to_char(last_start_date,'YYYY-MM-DD HH24:MI') last_start, to_char(next_run_date,'YYYY-MM-DD HH24:MI') next_run from dba_scheduler_jobs where owner like 'APEX%' order by 2;
select 'invalid objects in APEX schema: '||count(*) from dba_objects where owner=(select schema from dba_registry where comp_id='APEX') and status<>'VALID';
select 'invalid objects in parsing schemas: '||count(*) from dba_objects where owner in (select distinct schema from apex_workspace_schemas) and status<>'VALID';
col application_name for a40
select application_id, substr(application_name,1,40) application_name, owner, to_char(last_updated_on,'YYYY-MM-DD') updated, availability_status from (select * from apex_applications where availability_status not like 'Available%' order by last_updated_on desc) where rownum<=20;
select 'errors in last 24h (apex_workspace_activity_log): '||count(*) from apex_workspace_activity_log where view_date>sysdate-1 and error_message is not null;
col error_message for a80
select application_id, page_id, count(*) n, substr(min(error_message),1,80) error_message from apex_workspace_activity_log where view_date>sysdate-1 and error_message is not null group by application_id, page_id order by 3 desc fetch first 20 rows only;
select 'page views last 24h: '||count(*)||', avg elapsed '||round(avg(elapsed_time),2)||'s, max '||round(max(elapsed_time),2)||'s' from apex_workspace_activity_log where view_date>sysdate-1;
select application_id, page_id, count(*) views, round(avg(elapsed_time),2) avg_s, round(max(elapsed_time),2) max_s from apex_workspace_activity_log where view_date>sysdate-1 group by application_id, page_id order by 4 desc fetch first 15 rows only;
select 'activity log rows: '||(select count(*) from apex_workspace_activity_log)||', sessions: '||(select count(*) from apex_workspace_sessions)||', debug rows: '||(select count(*) from apex_debug_messages) from dual;
select name, value from apex_instance_parameters where name in ('IMAGE_PREFIX','WORKSPACE_PROVISION_DEMO_OBJECTS','SESSION_TIMEOUT_MAX_SESSION_LENGTH_SEC','SESSION_TIMEOUT_MAX_IDLE_TIME_SEC','SMTP_HOST_ADDRESS','SMTP_HOST_PORT','WALLET_PATH','PRINT_BIB_LICENSED','PLSQL_EDITING','EXPIRE_FND_USER_ACCOUNTS','RESTFUL_SERVICES_ENABLED','ALLOW_HOSTNAMES','MAX_SESSION_LENGTH_SEC','MAX_SESSION_IDLE_SEC','SERVICE_REQUESTS_ENABLED','ERROR_RATE','ACL_ENABLED','APPLICATION_ACTIVITY_LOGGING','HTTP_RESPONSE_HEADERS') order by 1;
select 'mail queue: '||count(*)||' queued, '||sum(case when mail_send_error is not null then 1 else 0 end)||' with errors' from apex_mail_queue;
select 'tablespace of APEX: '||default_tablespace from dba_users where username=(select schema from dba_registry where comp_id='APEX');
select 'wallet for APEX web services: '||nvl((select value from apex_instance_parameters where name='WALLET_PATH'),'(none set)') from dual;"
  sql_checks "$sid" "APEX $con" "select 'CHECK|WARN|APEX component is '||status from dba_registry where comp_id='APEX' and status<>'VALID';
select 'CHECK|WARN|APEX job '||job_name||' is '||state||' with '||failure_count||' failures' from dba_scheduler_jobs where owner like 'APEX%' and (state in ('BROKEN','FAILED','DISABLED') or failure_count>0);
select 'CHECK|WARN|'||count(*)||' APEX page errors in the last 24h (see apex_workspace_activity_log)' from apex_workspace_activity_log where view_date>sysdate-1 and error_message is not null having count(*)>50;
select 'CHECK|WARN|'||count(*)||' invalid objects in the APEX schema - run apxrecom.sql / utlrp' from dba_objects where owner=(select schema from dba_registry where comp_id='APEX') and status<>'VALID' having count(*)>0;
select 'CHECK|WARN|APEX mail queue has '||count(*)||' message(s) with send errors' from apex_mail_queue where mail_send_error is not null having count(*)>0;
select 'CHECK|INFO|more than one APEX schema present ('||listagg(username,',') within group (order by username)||') - old releases can be dropped after upgrade' from dba_users where username like 'APEX\_______' escape '\' having count(*)>1;"
  APEX_DB_VER="$ver"
}

diag_pdbs() { # per-container checks for a CDB
  local sid="$1" pdbs p
  local cdb; cdb="$(sqlval "$sid" "cdb" 2>/dev/null)"
  if [ "$cdb" != YES ]; then
    h3 "APEX / per-schema checks (non-CDB)"
    diag_apex_in "$sid" "$sid"; return
  fi
  pdbs="$(sql "$sid" "set heading off\nselect name from v\$pdbs where open_mode like 'READ%' and name<>'PDB\$SEED' order by con_id;" 2>/dev/null | sed '/^[[:space:]]*$/d;s/^ *//;s/ *$//' | head -12)"
  [ -n "${PDB:-}" ] && pdbs="$(printf '%s\n%s\n' "$PDB" "$pdbs" | awk '!s[$0]++')"
  for p in $pdbs; do
    export PDB_SET="alter session set container=$p;"
    h3 "Container $p"
    sqlsec "$sid" "pdb_${p}_space" "$p: tablespaces, invalid objects, accounts" "col tablespace_name for a25
select t.tablespace_name, round(u.used_mb) used_mb, round(f.max_mb) max_mb, round(u.used_mb*100/f.max_mb) pct_max from dba_tablespaces t join (select tablespace_name, sum(greatest(bytes, decode(autoextensible,'YES',maxbytes,bytes)))/1048576 max_mb from dba_data_files group by tablespace_name) f on f.tablespace_name=t.tablespace_name left join (select tablespace_name, sum(bytes)/1048576 used_mb from dba_segments group by tablespace_name) u on u.tablespace_name=t.tablespace_name where t.contents<>'TEMPORARY' order by 4 desc nulls last;
select owner, object_type, count(*) invalid from dba_objects where status<>'VALID' group by owner, object_type order by 3 desc;
select username, account_status, to_char(expiry_date,'YYYY-MM-DD') expires, profile from dba_users where oracle_maintained='N' and (account_status<>'OPEN' or expiry_date<sysdate+14) order by 1;
select 'local undo: '||property_value from database_properties where property_name='LOCAL_UNDO_ENABLED';
select name, value from v\$parameter where ispdb_modifiable='TRUE' and isdefault='FALSE' and name in ('open_cursors','sessions','resource_manager_plan','cpu_count','sga_target','pga_aggregate_target') order by 1;"
    sql_checks "$sid" "$sid/$p" "select 'CHECK|'||case when pct>=97 then 'CRIT' else 'WARN' end||'|tablespace '||tablespace_name||' is '||pct||'% of max' from (select t.tablespace_name, round(u.used_mb*100/f.max_mb) pct from dba_tablespaces t join (select tablespace_name, sum(greatest(bytes, decode(autoextensible,'YES',maxbytes,bytes)))/1048576 max_mb from dba_data_files group by tablespace_name) f on f.tablespace_name=t.tablespace_name join (select tablespace_name, sum(bytes)/1048576 used_mb from dba_segments group by tablespace_name) u on u.tablespace_name=t.tablespace_name where t.contents<>'TEMPORARY') where pct>=90;
select 'CHECK|CRIT|'||username||' is '||account_status from dba_users where username in ('APEX_PUBLIC_USER','ORDS_PUBLIC_USER','APEX_LISTENER','APEX_REST_PUBLIC_USER','ORDS_METADATA') and account_status<>'OPEN';
select 'CHECK|WARN|'||count(*)||' invalid objects in application schemas' from dba_objects where status<>'VALID' and owner not in ('SYS','SYSTEM','PUBLIC') and owner not like 'APEX%' having count(*)>0;"
    diag_apex_in "$sid" "$p"
  done
  unset PDB_SET
}

# ---------------------------------------------------------------------------
# ORDS
# ---------------------------------------------------------------------------
diag_ords() {
  say "ords"
  h1 "ORDS"
  if [ -z "${ORDS_HOME:-}" ]; then local c; c="$(command -v ords 2>/dev/null)"; [ -n "$c" ] && ORDS_HOME="$(cd "$(dirname "$c")/.." && pwd)"; fi
  [ -z "${ORDS_HOME:-}" ] && for d in /opt/oracle/ords /opt/ords /u01/ords /u01/app/oracle/ords "$HOME/ords"; do [ -x "$d/bin/ords" ] && { ORDS_HOME="$d"; break; }; done
  local pid; pid="$(pgrep -f 'ords.war|ords serve|ords --config|ords\.standalone|oracle.dbtools' 2>/dev/null | head -1)"
  if [ -z "${ORDS_HOME:-}" ] && [ -z "$pid" ]; then para "_ORDS not found on this host (no bin/ords, no ORDS java process)_"; return 0; fi
  [ -z "${ORDS_CONFIG:-}" ] && [ -n "$pid" ] && ORDS_CONFIG="$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | sed -n 's/.*--config \([^ ]*\).*/\1/p; s/.*-Dconfig.url=\([^ ]*\).*/\1/p' | head -1)"
  [ -z "${ORDS_CONFIG:-}" ] && for d in /etc/ords/config /opt/oracle/ords/config "${ORDS_HOME:-/nonexistent}/config" "$(dirname "$(readlink -f "${ORDS_HOME:-/nonexistent}")")/config"; do [ -f "$d/global/settings.xml" ] && { ORDS_CONFIG="$d"; break; }; done
  local ver=""; [ -x "${ORDS_HOME:-}/bin/ords" ] && ver="$(to 60 "$ORDS_HOME/bin/ords" --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  kv "ORDS_HOME" "${ORDS_HOME:-}"; kv "real path" "$(readlink -f "${ORDS_HOME:-}" 2>/dev/null)"; kv "version (bin/ords)" "$ver"; kv "config dir" "${ORDS_CONFIG:-}"
  kv "running pid" "${pid:-NOT RUNNING}"; kv "service" "$(systemctl list-units --type=service --all --no-legend 2>/dev/null | grep -i ords | awk '{print $1, $3, $4}' | head -1)"
  [ -n "$pid" ] && { kv "java" "$(readlink -f "/proc/$pid/exe" 2>/dev/null)"; kv "owner / started / rss" "$(ps -o user=,lstart=,rss= -p "$pid" 2>/dev/null)"; kv "open files" "$(ls "/proc/$pid/fd" 2>/dev/null | wc -l | tr -d ' ') of $(grep -s 'Max open files' "/proc/$pid/limits" | awk '{print $4}')"; kv "heap / jvm args" "$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | grep -oE -- '-X[a-z]+[0-9a-zA-Z:=/]*|-D[a-zA-Z.]+=[^ ]*' | grep -v -i password | tr '\n' ' ')"; }
  kv "java on PATH" "$(java -version 2>&1 | head -1)"; kv_end
  [ -z "$pid" ] && finding CRIT ords "ORDS is not running on this host"
  if [ -n "${ORDS_CONFIG:-}" ]; then
    h2 "ORDS configuration (passwords redacted)"
    section_sh ords_settings "cat '$ORDS_CONFIG/global/settings.xml' 2>/dev/null; for p in '$ORDS_CONFIG'/databases/*/; do echo; echo \"== pool \$(basename \$p)\"; cat \$p/pool.xml 2>/dev/null; ls -la \$p 2>/dev/null; done; echo; echo '== standalone'; cat '$ORDS_CONFIG/global/standalone/standalone.properties' 2>/dev/null; echo; ls -la '$ORDS_CONFIG/global' '$ORDS_CONFIG/global/standalone' 2>/dev/null; echo; echo 'doc_root / wallet / keystore:'; ls -la '$ORDS_CONFIG'/global/doc_root '$ORDS_CONFIG'/global/standalone/*.jks '$ORDS_CONFIG'/databases/*/wallet 2>/dev/null"
    section_sh ords_perms "find '$ORDS_CONFIG' -maxdepth 3 -printf '%M %u:%g %6s %TY-%Tm-%Td %p\n' 2>/dev/null | head -60"
    [ -n "$pid" ] && { local owner; owner="$(ps -o user= -p "$pid")"; find "$ORDS_CONFIG" ! -user "$owner" 2>/dev/null | grep -q . && finding WARN ords "Files under $ORDS_CONFIG are not owned by the ORDS user ($owner) - pool/wallet edits may be unreadable"; }
    # pools vs images
    local imgs; imgs="$(sed -n 's/.*<entry key="standalone.static.path">\([^<]*\)<.*/\1/p' "$ORDS_CONFIG/global/standalone/standalone.properties" "$ORDS_CONFIG/global/settings.xml" 2>/dev/null | head -1)"
    [ -z "$imgs" ] && imgs="$(sed -n 's/^standalone.static.path=//p' "$ORDS_CONFIG/global/standalone/standalone.properties" 2>/dev/null | head -1)"
    [ -z "$imgs" ] && imgs="${APEX_IMAGES_DIR:-}"
    if [ -n "$imgs" ]; then
      local iv; iv="$(cat "$imgs/apex_version.txt" 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
      kv "APEX images dir" "$imgs"; kv "images version (apex_version.txt)" "${iv:-unknown}"; kv "APEX in database" "${APEX_DB_VER:-unknown}"; kv_end
      [ -d "$imgs" ] || finding CRIT ords "APEX images dir $imgs does not exist - pages will load without CSS/JS"
      [ -n "$iv" ] && [ -n "${APEX_DB_VER:-}" ] && [ "${iv%.*}" != "${APEX_DB_VER%.*}" ] && finding CRIT apex "APEX images on disk are $iv but the database has ${APEX_DB_VER} - mismatch breaks the UI, repoint ORDS static path"
    fi
    h2 "ORDS logs"
    local lf; for lf in $(ls -t "$ORDS_CONFIG"/global/standalone/logs/*.log "$ORDS_CONFIG"/global/logs/*.log "${ORDS_HOME:-/nonexistent}"/logs/*.log /var/log/ords/*.log "$HOME"/ords*.log 2>/dev/null | head -3); do
      recent_errors "ords_$(basename "$lf" .log)" "$lf" 'SEVERE|WARNING|ERROR|ORA-[0-9]+|Exception|Unable to|503|Connection pool|not open|Pool' >/dev/null
      tail_file "ords_$(basename "$lf" .log)_tail" "$lf"
    done
    local unit; unit="$(systemctl list-units --type=service --no-legend 2>/dev/null | grep -i ords | awk '{print $1}' | head -1)"
    [ -n "$unit" ] && { h3 "journal for $unit"; section_sh ords_journal "$SUDO journalctl -u $unit --since '-${DIAG_DAYS}d' --no-pager -q 2>/dev/null | grep -aE 'SEVERE|WARNING|ERROR|ORA-|Exception|Started|Stopped|Stopping|Starting' | tail -150"; }
    grep -lqE 'ORA-28000|ORA-28001|ORA-01017' "$RAW"/ords_*.errors 2>/dev/null && finding CRIT ords "ORDS log shows ORA-28000/28001/01017 - the pool's database user is locked, expired or has a wrong password"
    grep -lqE 'ORA-12541|ORA-12514|ORA-12170|IO Error: The Network Adapter' "$RAW"/ords_*.errors 2>/dev/null && finding CRIT ords "ORDS log shows TNS connection failures (ORA-12541/12514/12170) - listener/service name/firewall between ORDS and the DB"
    grep -lqE 'Connection pool .* exhausted|Timeout waiting for a connection|UCP-45' "$RAW"/ords_*.errors 2>/dev/null && finding WARN ords "ORDS connection pool exhaustion in the log - raise jdbc.MaxLimit or find the slow pages"
    grep -lqE 'OutOfMemoryError' "$RAW"/ords_*.errors 2>/dev/null && finding CRIT ords "ORDS JVM OutOfMemoryError in the log - raise -Xmx"
  fi
  h2 "ORDS endpoint check"
  local url="${ORDS_URL:-}"
  [ -z "$url" ] && { local port; port="$(sed -n 's/^standalone.http.port=//p' "${ORDS_CONFIG:-/nonexistent}/global/standalone/standalone.properties" 2>/dev/null | head -1)"; url="http://localhost:${port:-8080}/ords/"; }
  section_sh ords_curl "for u in '$url' '${url%/}/_/landing' '${url%/}/r/apex' '${url%/}/apex' '${url%/}/../i/apex_version.txt' '${url%/}/_/db-api/stable/metadata-catalog/'; do printf '%-70s ' \"\$u\"; curl -sk -o /dev/null -m 15 -w '%{http_code} %{time_total}s %{redirect_url}\n' \"\$u\" 2>&1 || echo 'curl failed'; done; echo; echo 'TLS certificate (if https):'; echo | openssl s_client -connect \$(echo '$url' | sed -E 's#https?://([^/]+).*#\1#' | sed 's/$/:443/;s/:[0-9]*:443$/:443/') -servername localhost 2>/dev/null | openssl x509 -noout -dates -subject 2>/dev/null"
  local code; code="$(curl -sk -o /dev/null -m 15 -w '%{http_code}' "$url" 2>/dev/null)"
  case "$code" in 200|30[0-9]) ;; 503) finding CRIT ords "ORDS answers 503 at $url - usually the database pool is down (locked user, wrong password, DB/listener down)";; 404) finding WARN ords "ORDS answers 404 at $url - running but the pool/APEX path may be wrong";; 000|"") [ -n "$pid" ] && finding CRIT ords "ORDS process is running but $url does not answer";; *) finding WARN ords "ORDS answers HTTP $code at $url";; esac
  [ "$THREADS" = 1 ] && [ -n "$pid" ] && jvm_threads "ords" "$pid"
}

jvm_threads() { # <name> <pid>: thread dump with jcmd from the same JDK as the process
  local name="$1" pid="$2" jbin; jbin="$(dirname "$(readlink -f "/proc/$pid/exe" 2>/dev/null)")"
  local jcmd="$jbin/jcmd"; [ -x "$jcmd" ] || jcmd="$(command -v jcmd 2>/dev/null)"; [ -x "$jcmd" ] || return 0
  to 60 "$jcmd" "$pid" Thread.print >"$RAW/threads_${name}_$pid.txt" 2>&1
  to 60 "$jcmd" "$pid" GC.heap_info >"$RAW/heap_${name}_$pid.txt" 2>&1
  h3 "Thread dump summary ($name pid $pid)"
  fence_start
  { grep -c '^"' "$RAW/threads_${name}_$pid.txt" | sed 's/^/threads: /'; grep -oE 'java.lang.Thread.State: [A-Z_]+' "$RAW/threads_${name}_$pid.txt" | sort | uniq -c; echo; echo 'heap:'; cat "$RAW/heap_${name}_$pid.txt"; echo; echo "full dump: raw/threads_${name}_$pid.txt"; } >>"$REPORT"
  fence_end
}

# ---------------------------------------------------------------------------
# WebLogic / Fusion Middleware
# ---------------------------------------------------------------------------
wls_homes() { # every FMW home we can find (inventory + guesses + running JVMs)
  { for inv in /etc/oraInst.loc /var/opt/oracle/oraInst.loc; do
      [ -f "$inv" ] || continue; local d; d="$(sed -n 's/^inventory_loc=//p' "$inv")"
      sed -n 's/.*<HOME NAME="[^"]*" LOC="\([^"]*\)".*/\1/p' "$d/ContentsXML/inventory.xml" 2>/dev/null
    done
    ls -d /u01/app/oracle/product/*/fmw* /u01/app/oracle/middleware* /u01/oracle/* /opt/oracle/* /opt/oracle/product/* "$HOME"/Oracle/Middleware* 2>/dev/null
    [ -n "${ORACLE_HOME:-}" ] && echo "$ORACLE_HOME"; [ -n "${MW_HOME:-}" ] && echo "$MW_HOME"
    ps -eo args 2>/dev/null | grep -oE '[^ ]*/wlserver/' | sed 's#/wlserver/##'
  } 2>/dev/null | while read -r h; do [ -d "$h/wlserver" ] && echo "$h"; done | sort -u
}
wls_domains() { # <home>
  { sed -n 's/.*<domain location="\([^"]*\)".*/\1/p' "$1/domain-registry.xml" 2>/dev/null; ls -d "$1"/user_projects/domains/* 2>/dev/null; [ -n "${DOMAIN_HOME:-}" ] && echo "$DOMAIN_HOME"
    ps -eo args 2>/dev/null | grep -oE -- '-Ddomain.home=[^ ]+|-Dweblogic.home=[^ ]+' | cut -d= -f2; } | while read -r d; do [ -f "$d/config/config.xml" ] && echo "$d"; done | sort -u
}

diag_wls() {
  local homes; homes="$(wls_homes)"
  [ -z "$homes" ] && { ps -eo args | grep -q '[w]eblogic.Server' || return 0; }
  say "weblogic"
  h1 "WebLogic / Fusion Middleware"
  local h
  for h in $homes; do
    h2 "Oracle home $h"
    local ver; ver="$(sed -n 's/.*name="WebLogic Server"[^>]*version="\([0-9.]*\)".*/\1/p' "$h/inventory/registry.xml" 2>/dev/null | head -1)"
    [ -z "$ver" ] && ver="$(sed -n 's/^WLS_PRODUCT_VERSION=//p' "$h/wlserver/.product.properties" 2>/dev/null)"
    kv "WebLogic version" "$ver"
    kv "products in this home" "$(grep -oE 'name="[^"]*" version="[0-9.]+"' "$h/inventory/registry.xml" 2>/dev/null | grep -vE 'name="(WebLogic Server|Oracle Common|Oracle Installer)' | sed 's/name=//; s/ version=/ /; s/"//g' | tr '\n' ';' | cut -c1-300)"
    kv "JDK (oui/.globalEnv)" "$(sed -n 's/^JAVA_HOME=//p' "$h/oui/.globalEnv.properties" 2>/dev/null | head -1)"
    kv "OPatch" "$("$h/OPatch/opatch" version 2>/dev/null | sed -n 's/^OPatch Version: *//p')"
    kv "PSU level" "$(to 120 "$h/OPatch/opatch" lspatches 2>/dev/null | grep -i 'PATCH SET UPDATE' | sed -n 's/.*UPDATE *\([0-9.]*\).*/\1/p' | sort -V | tail -1)"
    kv_end
    section "wls_patches_$(basename "$h")" env ORACLE_HOME="$h" "$h/OPatch/opatch" lspatches
    [ -f "$h/.patch_storage/patch_locked" ] && finding WARN wls "$h has a stale OPatch lock (.patch_storage/patch_locked)"
    local psu; psu="$(grep -i 'PATCH SET UPDATE' "$RAW/wls_patches_$(basename "$h").txt" | sed -n 's/.*UPDATE *[0-9.]*\.\([0-9]\{6\}\).*/\1/p' | sort | tail -1)"
    if [ -n "$psu" ]; then local age; age="$(( ( $(date +%s) - $(date -d "20${psu:0:2}-${psu:2:2}-${psu:4:2}" +%s 2>/dev/null || date +%s) ) / 86400 ))"; [ "$age" -gt 200 ] && finding WARN wls "$h: newest WLS PSU is dated 20${psu:0:2}-${psu:2:2}, $age days old - at least two CPUs behind"; fi
    local d
    for d in $(wls_domains "$h"); do diag_wls_domain "$h" "$d"; done
  done
}

diag_wls_domain() {
  local h="$1" d="$2" cfg="$2/config/config.xml"
  h2 "Domain $(basename "$d")  ($d)"
  kv "domain version" "$(sed -n 's/.*<domain-version>\([^<]*\)<.*/\1/p' "$cfg" | head -1)"
  kv "admin server" "$(sed -n 's/.*<admin-server-name>\([^<]*\)<.*/\1/p' "$cfg" | head -1)"
  kv "production mode" "$(sed -n 's/.*<production-mode-enabled>\([^<]*\)<.*/\1/p' "$cfg" | head -1)"
  kv "disk used by domain" "$(du -sh "$d" 2>/dev/null | cut -f1)"
  kv "servers/*/tmp + data/store" "$(du -shc "$d"/servers/*/tmp "$d"/servers/*/data 2>/dev/null | tail -1 | cut -f1)"
  kv_end
  # servers: name, port, machine, cluster
  h3 "Servers configured vs running"
  fence_start
  awk '/<server>/{inblk=1;inssl=0;name="";port="";machine="";cluster=""} inblk&&/<ssl>/{inssl=1} inblk&&/<\/ssl>/{inssl=0}
       inblk&&name==""&&match($0,/<name>[^<]*<\/name>/){name=substr($0,RSTART+6,RLENGTH-13)}
       inblk&&!inssl&&port==""&&match($0,/<listen-port>[^<]*<\/listen-port>/){port=substr($0,RSTART+13,RLENGTH-27)}
       inblk&&match($0,/<machine>[^<]*<\/machine>/){machine=substr($0,RSTART+9,RLENGTH-19)}
       inblk&&match($0,/<cluster>[^<]*<\/cluster>/){cluster=substr($0,RSTART+9,RLENGTH-19)}
       inblk&&/<\/server>/{inblk=0; printf "%-30s port=%-6s machine=%-15s cluster=%s\n", name, (port==""?"7001":port), machine, cluster}' "$cfg" >"$RAW/wls_$(basename "$d")_servers.txt"
  cat "$RAW/wls_$(basename "$d")_servers.txt" >>"$REPORT"
  echo >>"$REPORT"; echo "running JVMs (weblogic.Name pid etime rss heap):" >>"$REPORT"
  ps -eo pid,etime,rss,args 2>/dev/null | grep '[w]eblogic.Server' | grep -- "$d\|$(basename "$d")" | awk '{n=""; x=""; for(i=4;i<=NF;i++){ if($i ~ /^-Dweblogic.Name=/) n=substr($i,17); if($i ~ /^-Xmx|^-Xms/) x=x" "$i } printf "%-30s pid=%-7s up=%-12s rss=%dMB %s\n", n, $1, $2, $3/1024, x}' | tee -a "$REPORT" >"$RAW/wls_$(basename "$d")_running.txt"
  echo >>"$REPORT"; echo "node manager:" >>"$REPORT"; ps -eo pid,etime,args | grep '[w]eblogic.NodeManager' | cut -c1-120 >>"$REPORT"
  fence_end
  # configured-but-not-running on this machine: only flag servers whose machine maps to this host or which have no machine
  local names; names="$(awk '{print $1}' "$RAW/wls_$(basename "$d")_servers.txt")"
  local running; running="$(awk '{print $1}' "$RAW/wls_$(basename "$d")_running.txt")"
  local s; for s in $names; do printf '%s\n' "$running" | grep -qx "$s" || finding INFO wls "$(basename "$d"): server $s is configured but no JVM for it is running on this host (fine if it lives on another node)"; done
  [ -z "$running" ] && finding CRIT wls "$(basename "$d"): no WebLogic server JVM is running on this host"
  ps -eo args | grep -q '[w]eblogic.NodeManager' || finding WARN wls "Node Manager is not running - servers cannot be started from the console / auto-restarted"
  # deployments: this is where FLEXCUBE / OBP / SOA / OSB / Forms / OBIEE etc. show up
  h3 "Deployments, data sources, JMS, clusters"
  section_sh "wls_$(basename "$d")_config" "echo 'app-deployments:'; sed -n 's/.*<app-deployment>.*//p' '$cfg' >/dev/null; awk '/<app-deployment>|<library>/{b=1;n=\"\";t=\"\";tg=\"\"} b&&match(\$0,/<name>[^<]*<\/name>/)&&n==\"\"{n=substr(\$0,RSTART+6,RLENGTH-13)} b&&match(\$0,/<target>[^<]*<\/target>/){tg=substr(\$0,RSTART+8,RLENGTH-17)} b&&match(\$0,/<source-path>[^<]*<\/source-path>/){t=substr(\$0,RSTART+13,RLENGTH-27)} b&&/<\/app-deployment>|<\/library>/{b=0; printf \"  %-45s -> %-25s %s\n\", n, tg, t}' '$cfg'; echo; echo 'clusters:'; sed -n 's/.*<cluster>.*//p' '$cfg' >/dev/null; grep -A3 '<cluster>' '$cfg' | grep -E '<name>|<cluster-address>|<multicast' | sed 's/^ *//' | head -20; echo; echo 'jdbc data sources (jndi, url, driver):'; for f in '$d'/config/jdbc/*.xml; do [ -f \"\$f\" ] || continue; printf '  %s: ' \"\$(basename \$f)\"; grep -oE '<jndi-name>[^<]*|<url>[^<]*|<driver-name>[^<]*|<max-capacity>[^<]*|<test-table-name>[^<]*' \"\$f\" | sed 's/<[a-z-]*>//' | tr '\n' ' '; echo; done; echo; echo 'jms modules:'; ls '$d'/config/jms 2>/dev/null; echo; echo 'security realm / providers:'; grep -oE '<sec:authentication-provider[^>]*>|<sec:name>[^<]*' '$cfg' | head -10; echo; echo 'machines / node manager:'; grep -A6 '<machine>' '$cfg' | grep -E '<name>|<listen-address>|<listen-port>|<nm-type>' | sed 's/^ *//' | head -30; echo; cat '$d'/nodemanager/nodemanager.properties 2>/dev/null | grep -vE '^#|^\$'"
  grep -q 'FCUBS\|FLEXCUBE\|fcubs' "$cfg" 2>/dev/null && finding INFO wls "FLEXCUBE (FCUBS) is deployed in $(basename "$d")"
  grep -qE 'soa-infra|service-bus|OBP|obp\.|OFSAA|ofsaa|oam_server|oim_server|FormsApp|analytics|bi_server' "$cfg" 2>/dev/null && finding INFO wls "$(basename "$d") hosts FMW products: $(grep -oE 'soa-infra|service-bus|OBP|OFSAA|oam_server|oim_server|FormsApp|analytics|bi_server' "$cfg" | sort -u | tr '\n' ' ')"
  # keystores / certs expiry
  h3 "Certificates"
  section_sh "wls_$(basename "$d")_certs" "kt=\$(ls -d '$h'/../jdk*/bin/keytool '$h'/jdk/bin/keytool \$(sed -n 's/^JAVA_HOME=//p' '$h/oui/.globalEnv.properties' 2>/dev/null | head -1)/bin/keytool 2>/dev/null | head -1); [ -z \"\$kt\" ] && kt=\$(command -v keytool); for ks in \$(grep -ohE '<(custom-identity-keystore-file-name|custom-trust-keystore-file-name|key-store-file|keystore)>[^<]*' '$cfg' '$d'/config/fmwconfig/*.xml 2>/dev/null | sed 's/<[^>]*>//' | sort -u) '$d'/security/DemoIdentity.jks; do [ -f \"\$ks\" ] || continue; echo \"== \$ks\"; \$kt -list -v -keystore \"\$ks\" -storepass changeit 2>/dev/null | grep -E 'Alias|Valid|Owner' | head -12 || echo '(needs the keystore password; not tried)'; done; echo; echo 'listening TLS ports and their certs:'; for p in \$(grep -oE '<listen-port>[0-9]+' '$cfg' | sed 's/.*>//' | sort -u); do echo | timeout 5 openssl s_client -connect localhost:\$p 2>/dev/null | openssl x509 -noout -subject -enddate 2>/dev/null | sed \"s/^/  port \$p: /\"; done"
  grep -E 'port [0-9]+: notAfter' "$RAW/wls_$(basename "$d")_certs.txt" 2>/dev/null | while read -r line; do
    local exp; exp="$(printf '%s' "$line" | sed 's/.*notAfter=//')"; local es; es="$(date -d "$exp" +%s 2>/dev/null)"; [ -z "$es" ] && continue
    local days=$(( (es - $(date +%s)) / 86400 )); [ "$days" -lt 0 ] && finding CRIT wls "TLS certificate EXPIRED on $(printf '%s' "$line" | grep -oE 'port [0-9]+') ($exp)"; [ "$days" -ge 0 ] && [ "$days" -lt 30 ] && finding WARN wls "TLS certificate expires in $days days on $(printf '%s' "$line" | grep -oE 'port [0-9]+')"
  done
  grep -q 'DemoIdentity' "$cfg" 2>/dev/null && ! grep -q 'custom-identity-keystore-file-name' "$cfg" && finding WARN wls "$(basename "$d") uses the Demo identity keystore - not acceptable in production"
  # logs
  h3 "Server logs"
  local lg; for lg in "$d"/servers/*/logs; do
    local sname; sname="$(basename "$(dirname "$lg")")"
    local f; for f in "$lg/$sname.log" "$lg/$sname.out"; do
      [ -f "$f" ] || continue
      h3 "$sname: $(basename "$f")"
      local n; n="$(recent_errors "wls_${sname}_$(basename "$f" | tr . _)" "$f" '<Error>|<Critical>|<Emergency>|<Alert>|BEA-[0-9]+.*(Error|Critical)|OutOfMemoryError|StuckThread|STUCK|Too many open files|Deadlock|java.lang.Exception|SQLException|ORA-[0-9]+|BEA-000337|BEA-002616|BEA-149500|Connection refused|unable to resolve|JTA transaction.*timed out|GC overhead|FORCE SHUTDOWN|BEA-310003' | tail -1)"
      [ "${n:-0}" -gt 100 ] && finding WARN wls "$sname: $n error lines recently in $(basename "$f")"
      grep -qE 'OutOfMemoryError|GC overhead' "$RAW/wls_${sname}_$(basename "$f" | tr . _).errors" 2>/dev/null && finding CRIT wls "$sname: OutOfMemoryError in $(basename "$f") - heap exhausted (raise -Xmx or find the leak with a heap dump)"
      grep -qE 'BEA-000337|StuckThread|STUCK' "$RAW/wls_${sname}_$(basename "$f" | tr . _).errors" 2>/dev/null && finding WARN wls "$sname: stuck threads (BEA-000337) - slow DB/backend calls; take thread dumps while it happens (--threads)"
      grep -qE 'Too many open files' "$RAW/wls_${sname}_$(basename "$f" | tr . _).errors" 2>/dev/null && finding CRIT wls "$sname: 'Too many open files' - raise nofile ulimit for the WebLogic user"
      grep -qE 'BEA-310003' "$RAW/wls_${sname}_$(basename "$f" | tr . _).errors" 2>/dev/null && finding WARN wls "$sname: free memory below 5% of heap (BEA-310003)"
      grep -qE 'BEA-149500|BEA-149205|Failed to deploy' "$RAW/wls_${sname}_$(basename "$f" | tr . _).errors" 2>/dev/null && finding CRIT wls "$sname: deployment failures (BEA-149xxx) in the log"
      grep -qE 'BEA-001112|BEA-001129|BEA-001153|Could not create pool connection|ORA-01017|ORA-28000|ORA-12541|ORA-12514' "$RAW/wls_${sname}_$(basename "$f" | tr . _).errors" 2>/dev/null && finding CRIT wls "$sname: JDBC data source connection failures (BEA-0011xx / ORA-01017 / TNS) - DB user or listener"
      grep -qE 'FORCE SHUTDOWN|Server state changed to FAILED|FAILED_NOT_RESTARTABLE' "$RAW/wls_${sname}_$(basename "$f" | tr . _).errors" 2>/dev/null && finding CRIT wls "$sname: server went to FAILED / forced shutdown recently"
    done
    section_sh "wls_${sname}_logdir" "ls -la --sort=size '$lg' 2>/dev/null | head -20; echo; du -sh '$lg' 2>/dev/null; echo 'hs_err / heap dumps:'; ls -la '$d'/servers/$sname/*.hprof '$d'/servers/$sname/hs_err* '$d'/hs_err* '$d'/*.hprof 2>/dev/null"
    ls "$d"/servers/"$sname"/*.hprof "$d"/*.hprof >/dev/null 2>&1 && finding WARN wls "$sname: heap dump (.hprof) present in the domain - a JVM ran out of memory; also eats disk"
    ls "$d"/servers/"$sname"/hs_err* "$d"/hs_err* >/dev/null 2>&1 && finding CRIT wls "$sname: JVM crash file hs_err_pid*.log present"
  done
  [ -f "$d/nodemanager/nodemanager.log" ] && { h3 "nodemanager.log"; recent_errors wls_nodemanager "$d/nodemanager/nodemanager.log" '<SEVERE>|<WARNING>|Exception|failed' >/dev/null; tail_file wls_nodemanager_tail "$d/nodemanager/nodemanager.log"; }
  # admin URL
  local admin_port; admin_port="$(awk '$1=="'"$(sed -n 's/.*<admin-server-name>\([^<]*\)<.*/\1/p' "$cfg" | head -1)"'"{print $2}' "$RAW/wls_$(basename "$d")_servers.txt" | sed 's/port=//')"
  local url="${ADMIN_URL:-http://localhost:${admin_port:-7001}}"
  section_sh "wls_$(basename "$d")_console" "for u in '$url/console' '$url/weblogic/ready'; do printf '%-50s ' \"\$u\"; curl -sk -o /dev/null -m 15 -w '%{http_code} %{time_total}s\n' \"\$u\" || echo 'no answer'; done"
  local code; code="$(curl -sk -o /dev/null -m 15 -w '%{http_code}' "$url/weblogic/ready" 2>/dev/null)"
  [ -n "$running" ] && [ "$code" != 200 ] && finding WARN wls "$(basename "$d"): admin server ready-check $url/weblogic/ready returned '$code'"
  if [ "$THREADS" = 1 ]; then ps -eo pid,args | grep '[w]eblogic.Server' | grep -- "$d\|$(basename "$d")" | while read -r pid rest; do jvm_threads "$(printf '%s' "$rest" | grep -oE 'weblogic.Name=[^ ]+' | cut -d= -f2)" "$pid"; done; fi
}
