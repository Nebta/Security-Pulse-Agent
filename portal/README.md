# Self-Service Portal (Wave 6 — scaffold only, build deferred)

> **Status:** scaffolding + design doc. Code is intentionally minimal.
> No Azure resources are deployed by default. The deploy.ps1 / GitHub
> Actions pipelines do **not** touch this folder.

## Why this exists in the repo

Per the feature plan (Wave 6), the goal is to land the *bones* of a
self-service portal — directory layout, infra Bicep, README — so that
the build can start without re-litigating shape. The actual UI/API work
is left for a later iteration.

## Target shape

A small **Static Web App** (with linked Azure Functions API) that lets
authorized customer admins:

| Capability                        | Reads / writes                              |
|-----------------------------------|---------------------------------------------|
| View past report runs             | Logic-App run history (RBAC: read)          |
| Toggle sections on/off            | `config.json` in customer blob container    |
| Edit recipient list               | `config.json` (`recipients`, future)        |
| Upload / preview a new template   | `template.html`, `section.html` blobs       |
| Trigger an ad-hoc run             | Logic App trigger callback URL              |
| See current data-source health    | `Compute_KPIs.sourcesOk` snapshot           |

**Out of scope for v1:** billing, multi-tenant onboarding, branding
designer (just text fields for colour + logo URL).

## Auth strategy

- **Identity provider:** Entra ID (the same tenant that owns the
  Logic Apps). Customers without their own Entra tenant get B2B-invited
  into the host tenant.
- **Authorization:** an Entra app role per customer
  (`SecPulse.<CustomerId>.Admin`) gated on the SWA route. The Functions
  API checks the role and the requested `customerId` match before
  touching any blob / Logic App.
- The portal has **no service-principal secret of its own** — it uses
  the calling user's delegated token to call ARM (run history, trigger)
  and a UAMI (`uami-secpulse-portal`, separate from the per-customer
  ones) for blob writes, scoped to the relevant container only.

## Directory layout

```
portal/
  README.md                 (this file)
  swa/                      Static Web App content (HTML/JS placeholder)
    index.html              Landing page
    staticwebapp.config.json  Auth + route rules
  api/                      Azure Functions (TypeScript stub)
    package.json
    host.json
    GetCustomerConfig/
      function.json
      index.ts              Stub returning placeholder JSON
infra/
  portal.bicep              SWA + UAMI + role assignments (NOT deployed)
```

## How to deploy (when the build is started)

```pwsh
# 1. provision the SWA + portal UAMI
az deployment sub create `
  --location westeurope `
  --template-file infra/portal.bicep `
  --parameters portalName=secpulse-portal

# 2. wire the SWA to this repo (one-time, in the Azure portal):
#      Source: GitHub
#      Repo:   Nebta/Security-Pulse-Agent
#      Branch: main
#      App location:  /portal/swa
#      API location:  /portal/api
#      Output:        (empty)

# 3. add per-customer Entra app roles + assign to admins
```

## Open questions

- Should the portal call the Logic App's **trigger callback URL**
  directly, or go via an ARM `triggerWorkflow` to keep the secret
  out of the browser? (Plan: ARM, via the Functions API, never
  shipping the callback URL to the browser.)
- Do we expose **history.json** via the API, or compute trends server-side?
- How do we handle a customer who wants to **rotate** their template
  while a run is mid-flight? (Plan: copy-on-write template blob with
  versioned name; runs always pin the version they started with.)

## Why no Bicep deploy yet

Even the SWA Free tier is free, but adding it to the default deploy
path means every contributor onboarding has to think about it. Until
we actually start the portal build, this folder stays scaffold-only and
the Bicep is ignored by `deploy.ps1`.
