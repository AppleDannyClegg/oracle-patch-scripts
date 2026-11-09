# Oracle Enterprise Manager Lifecycle Management Pack — patching automation assessment

A short brief on whether Oracle Enterprise Manager (OEM) Cloud Control's
Lifecycle Management packs are worth using for patching an Oracle estate, and
what has to be true before they can do anything.

Written for someone handed "we have a licence for the Lifecycle Management Pack,
it does database and middleware" and wondering what that actually means in
practice. Nothing here is estate-specific; confirm the pack names against your
own entitlement before relying on any of it.

## 1. It is a set of packs, not one product

OEM Cloud Control is the on-prem management console. Its capabilities are
licensed as separate packs, and "does database and middleware" spans two of
them:

- **Lifecycle Management** is the umbrella family (configuration management,
  provisioning, compliance, patching). Inside it:
  - **Database Lifecycle Management Pack for Oracle Database** — patch and
    provision database homes, including RAC, RAC container and multitenant;
    there is a **Fleet Maintenance** GUI for patching many databases at once.
  - **Host Lifecycle Management** — the operating-system side.
  - **Middleware Lifecycle Management** — the WebLogic / Fusion Middleware side.
- **Middleware Management** — the **Oracle Fusion Middleware Management Pack**
  (WebLogic / FMW domain management) plus Site Guard.

So the database half and the middleware half are **separate entitlements**. If
only one pack is licensed, that is the one that applies. Confirm the exact list
before planning.

## 2. The prerequisite is the whole project

The packs can only act on targets OEM already manages. That means all of:

1. OEM Cloud Control (the management server, or OMS) deployed, with its
   repository.
2. A **management agent** on every host to be managed — database nodes and
   WebLogic hosts alike.
3. Targets **discovered and promoted** — hosts, databases, listeners, WebLogic
   domains.

If the servers are not yet discovered in OEM, the packs currently have nothing
to operate on. Onboarding and discovery is not a small side task; it is the
gating workstream, and it should be sized before anything else is promised.

## 3. The no-internet constraint is mostly fine

The managed targets do not need internet access. The **management server** does:
it downloads patches from My Oracle Support (MOS) into its software library, then
deploys them to the agents. So the real question is whether the OMS has a route
to MOS (directly or via the site's proxy / an offline self-update arrangement),
not whether the estate has one.

## 4. Licensing

A pack existing in the console is not the same as being licensed to use it.
Licences are per target type / per processor, and some features require another
pack first (the Oracle Cloud Management Pack for Oracle Database requires the
Database Lifecycle Management Pack, for example). Confirm:

- exactly which packs are entitled;
- which targets they cover;
- whether the OEM base and the agents are themselves properly licensed.

## 5. Who patches what

If a managed-services partner already runs OEM to patch the Grid Infrastructure
and database homes, the Database Lifecycle Management Pack duplicates that work
and the two processes can collide. The half that usually belongs to the
in-house DBA is the **middleware** tier (WebLogic / FMW), because that is
typically theirs to patch — and that is where the Middleware / Fusion Middleware
pack would actually remove effort.

Decide the ownership boundary before deploying anything.

## 6. opatchauto — the middle option

Between "OEM with a licence and a discovery project" and "run OPatch by hand"
sits **`opatchauto`**, the utility bundled with OPatch in the Grid Infrastructure
home. It applies one patch across a cluster, driving the right stop/start
sequence of GI and RAC database resources itself, so it gives rolling /
minimal-downtime patching of the Grid home and RAC DB homes without any
management server, repository or discovery.

Properties:

- Runs as root (`sudo -n opatchauto`), from the Grid home, against a specific
  GI home and/or DB home.
- It still needs the patch downloaded first — it has no MOS connection of its
  own.
- It is **per-cluster / per-home**, not a fleet console: no inventory across the
  estate, no compliance or configuration management, no reporting.
- It covers **Grid Infrastructure and database** homes only — nothing for
  WebLogic / middleware.

This repo's `db-patch.sh` already wraps it: `db-patch.sh run <patch-dir> --grid`
runs `opatchauto apply` for the Grid home after OPatch applies the database home,
with the preflight, backup and rollback around it. So opatchauto is not something
new to adopt — it is the automated-GI path already in use, just driven by the
script rather than by OEM.

For Exadata specifically, the compute-node (OS) layer has its own tool
(`dbnodeupdate.sh`); opatchauto covers the database and Grid layers.

## 7. How it compares with the scripts in this repo

The scripts here (`db-patch`, `wls-patch`, and the rest) are a different tool for
a different job:

- They run **per node, offline, as the `oracle`/`weblogic` user**, and follow the
  same shape: `inspect` → `plan` → `preflight` → `run` (backup, stop, apply,
  start, verify, automatic rollback).
- They need **no OEM infrastructure** and **no network**.

OEM / LMP is a fleet tool: it is worth the setup when there are many targets, a
compliance framework to evidence, and standardised quarterly RU/CPU rollout with
reporting. For a small number of domains and databases, the scripts are simpler
and match the offline constraint directly.

They are not mutually exclusive. LMP can orchestrate across the estate while the
scripts remain the per-node, safe, offline fallback (and the path when OEM is
unavailable).

## 8. What to confirm before committing

1. Is OEM Cloud Control deployed anywhere, at what version, and who runs it?
2. If yes — what DB / WebLogic targets are actually discovered today?
3. Which packs does the licence cover (Lifecycle Management, Database Lifecycle,
   Fusion Middleware Management)?
4. Can the management server reach My Oracle Support?
5. Does the database plug-in in use support the required versions (19c and 23ai)
   at the OEM 13.5 release update that would be run?

Until items 1–4 are answered, LMP is a licence waiting on infrastructure, not an
active patching solution.

## Sources

- OEM Cloud Control 13.5 documentation index (pack families and guides):
  https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/13.5/books.html
- Lifecycle Management family (Database Lifecycle Management Pack, patching
  tutorials, Fleet Maintenance):
  https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/13.5/lifecycle.html
- OPatch and opatchauto are documented in the OPatch User's Guide for the
  database release in use (My Oracle Support).
- Middleware Management family (Fusion Middleware Management Guide):
  https://docs.oracle.com/en/enterprise-manager/cloud-control/enterprise-manager-cloud-control/13.5/middleware.html
