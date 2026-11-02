#!/usr/bin/env bash
# ru-date.sh - regression gate for the RU-date extractors in patching/patch-status/patch-status.sh.
#
# row() turns an empty date into UNKNOWN with no finding, so a description shape the extractor cannot
# read is a status drop: the home renders clean, however many CPUs behind it is. 19c/21c RUs carry a
# 6-digit yymmdd (19.24.0.0.240716); 23ai RUs carry YY.MM as the last two version parts (23.6.0.24.10)
# and the real lspatches / dba_registry_sqlpatch line ends in the patch id in parens, which is what the
# call sites pass. The first 23ai fix (271e39c) anchored its regex to end-of-string and so matched a
# bare version but never a real line - a vacuous fix that three verifications passed because they
# tested the bare string (board, 2 Nov 11:59). Every case here is the call-site shape.
#
# The functions are extracted from the script by name (no main runs, no tools, no database) and the
# lib is sourced for cpu_date / yymmdd_to_date. A missing function is a FAIL, never a skipped case.
#
# Usage: tests/ru-date.sh [repo-root]

set -uo pipefail
ROOT="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PS="$ROOT/patching/patch-status/patch-status.sh"
[ -f "$PS" ] || { echo "ru-date gate: $PS not found"; exit 2; }
# shellcheck disable=SC1091
source "$ROOT/lib/oracle-lib.sh" 2>/dev/null || { echo "ru-date gate: cannot source lib/oracle-lib.sh"; exit 2; }
eval "$(sed -n '/^date_from_desc() {/p; /^db_ru_date_from_desc() {/,/^}/p' "$PS")"

pass=0; fail=0
t() { # t <function> <description> <expected date or "">
  local fn="$1" desc="$2" want="$3" got
  if ! declare -F "$fn" >/dev/null; then fail=$((fail + 1)); echo "FAIL $fn not defined in ${PS#"$ROOT"/} :: '$desc'"; return; fi
  got="$("$fn" "$desc")"
  if [ "$got" = "$want" ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL $fn '$desc' -> [${got}] want [${want}]"; fi
}
# database / Grid RU lines as opatch lspatches prints them (id;description (id)) and as the registry stores them
t db_ru_date_from_desc '36582781;Database Release Update : 19.24.0.0.240716 (36582781)'   2024-07-16
t db_ru_date_from_desc '36878697;Database Release Update : 23.6.0.24.10 (36878697)'       2024-10-15
t db_ru_date_from_desc 'Database Release Update : 23.6.0.24.10 (36878697)'                2024-10-15
t db_ru_date_from_desc 'Database Release Update : 23.7.0.25.01 (37260974)'                2025-01-21
t db_ru_date_from_desc '36878698;OCW RELEASE UPDATE 23.6.0.24.10 (36878698)'              2024-10-15
t db_ru_date_from_desc 'Database Release Update : 23.6.0.24.10'                           2024-10-15
t db_ru_date_from_desc '37102264;OJVM RELEASE UPDATE: 19.26.0.0.250121 (37102264)'        2025-01-21
t db_ru_date_from_desc 'Database Release Update : 23.6.0.24.13 (1)'                       ''   # month 13 is not a date
t db_ru_date_from_desc 'Coherence 14.1.1.0.20 Cumulative Patch (123)'                     ''   # no 5-part version: nothing invented
t db_ru_date_from_desc ''                                                                 ''
# the plain yymmdd extractor every other product uses must be unchanged
t date_from_desc       'WLS PATCH SET UPDATE 14.1.2.0.250107'                             2025-01-07
t date_from_desc       '36878697;Database Release Update : 23.6.0.24.10 (36878697)'       ''   # by design: 23ai is the db_ru_ path
t date_from_desc       'EM-OMS RU 24.1.0.10 (39193593)'                                   ''   # EM has no date in the name (its row warns)

echo "ru-date gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
