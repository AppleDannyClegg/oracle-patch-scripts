#!/usr/bin/env bash
# Stopgap for CVE-2026-91403 (eMudhra compromised intermediate CAs): add their SHA-256
# fingerprints to a JDK's own certificate blocklist. The real fix is a patched JDK
# (Java 8: 8u511-b33 or later; Java 17: 17.0.21 plus the alert's follow-up build).
#
#   ./java-blocklist.sh /path/to/jdk            dry run: says what it would add
#   ./java-blocklist.sh /path/to/jdk --apply    backs the file up, then appends
#   ./java-blocklist.sh /path/to/jdk --apply --with-alternates
#                                                        also adds the 32 alternate encodings
#   ./java-blocklist.sh /path/to/jdk --rollback restores the newest backup
#
# Java 8 file: <jdk>/jre/lib/security/blacklisted.certs (a JRE: <jre>/lib/security/blacklisted.certs)
# Java 11+:    <jdk>/lib/security/blocked.certs
# Restart every JVM that runs from this JDK afterwards; the list is read at start-up.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JDK="${1:?usage: $0 <jdk-or-jre-home> [--apply] [--with-alternates] [--rollback]}"
shift
APPLY=0 ALTS=0 ROLLBACK=0
for a in "$@"; do
  case "$a" in
    --apply) APPLY=1 ;;
    --with-alternates) ALTS=1 ;;
    --rollback) ROLLBACK=1 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

target=""
for f in "$JDK/jre/lib/security/blacklisted.certs" "$JDK/lib/security/blacklisted.certs" "$JDK/lib/security/blocked.certs"; do
  if [[ -f "$f" ]]; then target="$f"; break; fi
done
[[ -n "$target" ]] || { echo "STOP: no blacklisted.certs or blocked.certs under $JDK" >&2; exit 1; }
echo "JDK:    $JDK"
"$JDK/bin/java" -version 2>&1 | head -1 | sed 's/^/        /' || true
echo "file:   $target"

if (( ROLLBACK )); then
  bak="$(ls -1t "$target".bak.* 2>/dev/null | head -1 || true)"
  [[ -n "$bak" ]] || { echo "STOP: no backup beside $target" >&2; exit 1; }
  cp -p "$bak" "$target"
  echo "restored $bak -> $target. Restart the JVMs."
  exit 0
fi

head1="$(head -1 "$target")"
[[ "$head1" == "Algorithm=SHA-256" ]] || { echo "STOP: first line is '$head1', not 'Algorithm=SHA-256'; not touching it" >&2; exit 1; }

lists=("$HERE/emudhra-16.sha256")
(( ALTS )) && lists+=("$HERE/emudhra-32-alternates.sha256")
for l in "${lists[@]}"; do
  tr -d '\r' <"$l" 2>/dev/null | grep -E '^[0-9A-F]{64}$' >/dev/null|| { echo "STOP: fingerprint list $l is missing or holds no fingerprint; copy the whole blocklist folder" >&2; exit 1; }
done
# a carriage return is dropped first: git on Windows (core.autocrlf) checks the lists out as CRLF
want="$(cat "${lists[@]}" | tr -d '\r' | grep -E '^[0-9A-F]{64}$')"
# The JDK reads this file as java.util.Properties and looks a certificate up by its UPPERCASE SHA-256
# (X509CertImpl), so only an exact uppercase line blocks anything: a lowercase copy already in the file does
# not count as present, and every line written here is uppercase.
have="$(grep -oE '^[0-9A-F]{64}' "$target" || true)"
add="$(comm -23 <(sort -u <<<"$want") <(sort -u <<<"$have"))"
n_want="$(grep -c . <<<"$want")"
n_add="$(grep -c . <<<"$add" || true)"
echo "lists:  ${lists[*]##*/}  ($n_want fingerprints, $((n_want - n_add)) already present, $n_add to add)"

if (( n_add == 0 )); then echo "nothing to add."; exit 0; fi
if (( ! APPLY )); then echo "dry run: nothing changed. Add --apply to write."; exit 0; fi

before="$(grep -cE '^[0-9A-Fa-f]{64}' "$target" || true)"
bak="$target.bak.$(date +%Y%m%d-%H%M%S)"
cp -p "$target" "$bak"
{ echo "# eMudhra compromised intermediates - CVE-2026-91403 (added $(date +%Y-%m-%d))"; printf '%s\n' "$add"; } >> "$target"
after="$(grep -cE '^[0-9A-Fa-f]{64}' "$target" || true)"
echo "backup: $bak"
echo "count:  $before -> $after (expected +$n_add)"
[[ $((after - before)) -eq $n_add ]] || { echo "STOP: count is wrong; restoring the backup" >&2; cp -p "$bak" "$target"; exit 1; }
echo "done. Restart every JVM that runs from $JDK."
