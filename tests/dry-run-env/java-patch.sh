# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# java-patch: a symlinked JDK 17.0.8 ($J/jdk -> jdk-17.0.8), a 17.0.9 tarball waiting in $T/env/dl, ORDS restarted through systemctl
J="$T/env/java"; mkdir -p "$J/jdk-17.0.8/bin" "$J/jdk-17.0.8/lib/security" "$T/env/dl" "$T/env/tarsrc/jdk-17.0.9/bin" "$T/env/tarsrc/jdk-17.0.9/lib/security"
# each JDK's java answers -version itself (the gate's java stub says nothing) and hands anything else to the stub
fake_java() { printf '#!/bin/sh\n[ "$1" = -version ] && { echo "openjdk version \\"%s\\" 2024-07-16" >&2; echo "OpenJDK Runtime Environment (build %s)" >&2; exit 0; }\nexec "%s/java" "$@"\n' "$1" "$1" "$STUB" >"$2"; chmod +x "$2"; }
fake_java 17.0.8 "$J/jdk-17.0.8/bin/java"; fake_java 17.0.9 "$T/env/tarsrc/jdk-17.0.9/bin/java"
# keytool: -list names one trusted CA in the OLD cacerts and none in the new, so apply has an alias to carry over; the
# -exportcert / -importcert that follow go to the stub - the import is the change both gates look at
for kt in "$J/jdk-17.0.8/bin/keytool" "$T/env/tarsrc/jdk-17.0.9/bin/keytool"; do
  printf '#!/bin/sh\ncase " $* " in *" -list "*) case " $* " in *jdk-17.0.9*) ;; *) echo "corp-root-ca, 2024-01-01, trustedCertEntry,";; esac; exit 0;; esac\nexec "%s/keytool" "$@"\n' "$STUB" >"$kt"; chmod +x "$kt"
done
: >"$J/jdk-17.0.8/lib/security/cacerts"; : >"$T/env/tarsrc/jdk-17.0.9/lib/security/cacerts"; echo 'JAVA_VERSION="17.0.9"' >"$T/env/tarsrc/jdk-17.0.9/release"
(cd "$T/env/tarsrc" && tar -czf "$T/env/dl/jdk-17.0.9_linux-x64_bin.tar.gz" jdk-17.0.9)
ln -sfn "$J/jdk-17.0.8" "$J/jdk"
export RESTART_CMDS="ords=systemctl restart ords" CACERTS_PASSWORD=changeit
ARGS="$T/env/dl --java-home $J/jdk --restart"; ARGS_backup="--java-home $J/jdk"; ARGS_restart="--java-home $J/jdk"; ARGS_rollback="--java-home $J/jdk"; ARGS_verify="--java-home $J/jdk"; ARGS_download="$T/env/dl"
# a run dir as 'apply' leaves it: rollback flips the link back and restarts (the restart is its change)
mkdir -p "$T/home/java-patch/runs/r1"; printf 'preflight=ok\ntarball=%s\nold_jh=%s\nold_real=%s\nnew_jh=%s\nlink_target=%s\nbackup=ok\napply=ok\n' "$T/env/dl/jdk-17.0.9_linux-x64_bin.tar.gz" "$J/jdk" "$J/jdk-17.0.8" "$J/jdk-17.0.9" "$J/jdk-17.0.8" >"$T/home/java-patch/runs/r1/state"
ln -sfn "$T/home/java-patch/runs/r1" "$T/home/java-patch/runs/latest"
# run: preflight=ok and backup=ok are written before the first changing call (the cacerts import) and are true - preflight
# passed, the files were copied; what must not appear once the import failed is a claim about the change itself
OK_run='^(apply=ok|restart=ok|verify=ok|rollback=ok)$'
# run:ps_unreadable - ps cannot run (the gate's $T/ps.fail) and PROC_DIR is an empty dir, so lib's /proc fallback finds nothing too
# (5cc183f's lesson: on a Linux box the fallback would read the real list and prove nothing). No stub call is meant to fail, so
# FAIL_* matches nothing and the ps stub's own FAILED lines are what the gate counts. 638cf52: before it running_on dropped ps'
# status, preflight read 'no JVM runs on the old JDK', said Preflight OK and run went on to apply and restart - rc 0 with 13 failed
# ps calls; now preflight refuses and run stops 'nothing changed', rc 1. download/backup never read the list; apply/restart/rollback
# do not call running_on (apply trusts the run dir's preflight=ok, which the gate's seeded r1 state carries), so run is the case.
CASES_run='ps_unreadable'; FAIL_run__ps_unreadable='^never matches$'
case "$CMD:${CASE:-}" in run:ps_unreadable) : >"$T/ps.fail"; mkdir -p "$T/env/noproc"; export PROC_DIR="$T/env/noproc";; esac
