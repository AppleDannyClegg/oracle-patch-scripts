# apex-export.sh — APEX applications in git, nightly, with restore

"Who changed page 12 yesterday and can we have it back" has no answer unless the applications are
exported somewhere with history. This script exports every application (one file per component,
export dates stripped so unchanged apps make no diff), the workspace definitions, the workspace
users (their web password hashes replaced by a placeholder: a hash in a remote is a credential) and the instance parameters (secrets masked) into a git repository laid out
`<repo>/<db>/<pdb>/<WORKSPACE>/f<ID>/`, commits only when something changed with the changed apps
and their last editor in the message, pushes if asked, reports the changes, and restores an
application from any commit or date, into the same id or a new one, after committing the current
state first. SQLcl `apex export` with the password on stdin; the `APEXExport` java class as a
fallback, refused by default because it takes the password on its command line (visible in `ps`
to every user while the export runs; `APEX_JAVA_PASSWORD_ON_ARGV=yes` accepts that). Runs anywhere
SQLcl can reach the database.

## Quick start

```bash
cd operations/apex-export && cp apex-export.conf.example apex-export.conf && chmod 600 apex-export.conf && vi apex-export.conf
./apex-export.sh inspect                    # workspaces, apps, last change and by whom, what the repo has
./apex-export.sh export && ./apex-export.sh commit        # first full export; later: --since 1, --app 100, --workspace SALES
./apex-export.sh install-cron               # 02:30 nightly: run --all = export --since 1, commit (+push with APEX_PUSH=1), report
./apex-export.sh diff --since 7 --report    # what changed this week: apps, pages, who; REPORT.md in APEX_OUT
./apex-export.sh restore --app 100 --to "2026-10-30 16:00"           # back to how it was then (current state committed first)
./apex-export.sh restore --app 100 --to a1b2c3d --as-new-id 1100     # side by side as f1100 for comparison
./apex-export.sh verify                     # repo clean, pushed, every app exported and current, cron present
```

## Repository layout

```
<repo>/<DB>/<PDB>/instance/applications.txt      id|workspace|name|pages|last change|by|version|owner
                          workspaces.txt, parameters.txt (secrets ***), export.meta
                  <WORKSPACE>/workspace/w<ID>.sql   workspace definition (+ files, ACLs), users.txt, schemas.txt
                  <WORKSPACE>/f<ID>/install.sql, application/pages/page_00012.sql, ...   (-split)
                  <WORKSPACE>/f<ID>.meta            name, pages, last_updated_on/by, version; deleted_in_db=<date> when gone
```

`--since DAYS` exports the applications whose `last_updated_on` (application or any page) moved,
plus those not yet in the repo; the rest is untouched, so the nightly run is cheap. An application
deleted in the database keeps its last export and gets a `deleted_in_db` line (WARN in reports).

## Restore

`restore --app ID --to <commit|date>` resolves the revision (hash, tag, or the last commit before
a date), exports and commits the current state, extracts `f<ID>` from the revision with `git
archive`, and imports it with `apex_application_install` (`set_workspace`, `set_application_id`,
`set_schema`, `set_keep_sessions(false)`; with `--as-new-id N` also `generate_offset` and a new
alias) followed by `@install.sql`. The group id must be typed (non-interactive: `--force`). Same-id
restores replace the application and end its sessions.

## Options and config

`--app ID` (repeatable), `--workspace`, `--since DAYS`, `--pdb NAME`, `--all`, `--push`, `--rev`,
`--to`, `--as-new-id`, `--repo`, `--out`, `--report`, `--dry-run`, `--yes`, `--force`, `--verbose`.
Config keys in `apex-export.conf.example`: `APEX_EXPORT_CONNECT` (and `_NAME` variants), `APEX_REPO`,
`APEX_REMOTE`, `APEX_PUSH`, `SQLCL`, `APEX_HOME`/`JAVA_HOME`/`OJDBC_JAR`, `APEX_EXPORT_OPTS`,
`APEX_CRON`, `APEX_OUT`, `RUN_BASE`, `APEX_STALE_DAYS`. The conf must be mode 600 (the script warns).
Needs `lib/oracle-lib.sh` one folder up and git on the host.

Tested against a fake SQLcl (split exports, date stripping, --since, deleted apps, several
connections, restore by hash and by date, verify, cron line); not yet on a real APEX instance.
