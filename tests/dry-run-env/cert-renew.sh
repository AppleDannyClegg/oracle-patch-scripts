# shellcheck shell=bash disable=SC2034,SC2016   # sourced by tests/dry-run-gate.sh and tests/false-success-gate.sh: ARGS*, FAIL_*, OK* are read there
# cert-renew: ORDS standalone under $T/env/ords serving HTTPS on 8443 with a certificate file, renewed from a self-signed cert made here;
# the restart goes through systemctl (ORDS_SERVICE), which is the change the gates can see - the properties edit itself is a file write
O="$T/env/ords"; mkdir -p "$O/home/bin" "$O/config/global/standalone/certs" "$T/env/pki"
printf '#!/bin/sh\n[ "$1" = --version ] && { echo 24.4.0; exit 0; }\nexec "%s/ords" "$@"\n' "$STUB" >"$O/home/bin/ords"; chmod +x "$O/home/bin/ords"
touch "$O/config/global/settings.xml"
# the certificate ORDS serves today (expired soon) and the new one to install, both self-signed for localhost; chain = the cert itself
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=localhost -days 20 -keyout "$O/config/global/standalone/certs/old.key" -out "$O/config/global/standalone/certs/old.pem" >/dev/null 2>&1
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=localhost -days 365 -keyout "$T/env/pki/new.key" -out "$T/env/pki/new.pem" >/dev/null 2>&1
printf 'standalone.https.port=8443\nstandalone.https.cert=%s\nstandalone.https.cert.key=%s\n' "$O/config/global/standalone/certs/old.pem" "$O/config/global/standalone/certs/old.key" >"$O/config/global/standalone/standalone.properties"
export ORDS_HOME="$O/home" ORDS_CONFIG="$O/config" ORDS_SERVICE=ords CHECK_HOST=localhost VERIFY_WAIT=1
ARGS="ords --cert $T/env/pki/new.pem --key $T/env/pki/new.key --chain $T/env/pki/new.pem --restart --no-scan"
ARGS_backup="ords"; ARGS_rollback=""; ARGS_cleanup=""; ARGS_csr="probe --cn localhost"
# a run dir as 'apply' left it, for rollback and cleanup: the properties file backed up, the target recorded, the backup fresh
R="$T/home/cert-renew/runs/r1"; mkdir -p "$R/backup/ords"; cp "$O/config/global/standalone/standalone.properties" "$R/backup/ords/"; touch "$R/backup/.kept"
printf 'target=ords\nbackup_dir=%s/backup/ords\napply_ords=ok\nnew_serial=01\nords_files=%s/config/global/standalone/certs/new.pem %s/config/global/standalone/certs/new.der\n' "$R" "$O" "$O" >"$R/state"
ln -sfn "$R" "$T/home/cert-renew/runs/latest"
# OK_apply / OK_run: apply_<target>=ok is NOT forbidden. cmd_apply records two things separately: apply_<target> is the file/config switch
# (the new PEM/DER written, standalone.properties pointing at them - openssl and sed, nothing the stub can fail) and restart_<target> is
# the restart; when systemctl fails the script writes restart_ords=failed, says the config now names the new certificate but the running
# process still serves the old one, and exits 1 - the state 'apply_ords=ok restart_ords=failed' is what happened and what rollback needs
# (last_change_run finds the run by its apply_ line). What a failed restart must not produce: restart_<t>=ok, verify=ok, rollback=ok.
OK_apply='^(restart_[^=]*=ok|verify=ok|rollback=ok)$'; OK_run="$OK_apply"
