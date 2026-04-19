# Self-Service Portal (Wave 6 v1)

> **Status:** v1 shipped — opt-in deploy, not part of the default
> `deploy.ps1` path. The Logic-App-driven email pipeline keeps working
> with or without the portal.

A small **Static Web App (Standard)** with a **linked Azure Functions API**
that lets authorised admins view past runs, edit `config.json`, and trigger
ad-hoc runs for one or more customers.

## What it does

| Capability                        | API route                              | Backing call                          |
|-----------------------------------|----------------------------------------|---------------------------------------|
| Show signed-in user + roles       | `GET  /api/me`                         | reads `x-ms-client-principal`         |
| List customers I can access       | `GET  /api/customers`                  | env allowlist + `PORTAL_CUSTOMERS`    |
| Read a customer's `config.json`   | `GET  /api/customers/{id}/config`      | blob read (UAMI)                      |
| Update a customer's `config.json` | `PUT  /api/customers/{id}/config`      | validates → blob write (UAMI)         |
| List recent Logic-App runs        | `GET  /api/customers/{id}/runs`        | ARM `workflows/.../runs`              |
| Trigger an ad-hoc run             | `POST /api/customers/{id}/trigger`     | ARM `triggers/manual/run`             |

**Out of scope for v1:** template editor, billing dashboard, multi-tenant
onboarding (still done via `scripts/onboard-customer.ps1`), branded login.

## Architecture

```
   Browser ── /api/* ─►  SWA (Standard, westeurope)
                          │   injects x-ms-client-principal
                          ▼
                       Function App (Linux Y1, Node 20, BYOF)
                          │   identity: UAMI uami-secpulse-portal
                          ▼
                       Customer Storage Account  (Blob Data Contributor)
                       Customer Logic App        (Logic App Operator)
```

* SWA runs the auth handshake (Entra ID) and proxies `/api/*` to the
  linked Function App, adding the `x-ms-client-principal` header that
  carries the user's UPN, oid, and roles.
* The Function App runs as a single User-Assigned Managed Identity that's
  granted the *minimum* role per customer resource — `Storage Blob Data
  Contributor` on the customer SA, `Logic App Operator` on the customer
  Logic App. No service-principal secret lives in the portal.
* Authorisation is a **UPN allowlist** (`PORTAL_ALLOWED_UPNS`) for v1.
  Per-customer Entra app roles (`SecPulse.<id>.Admin`) are the planned
  upgrade — the seam is in `portal/api/src/auth.ts`.

## Customer binding

Each customer is one app setting on the Function App:

```
PORTAL_CUSTOMERS               = ALPLA,SPAR
PORTAL_CUSTOMER_ALPLA          = stpulsealplahisxpz;rg-secpulse-alpla;la-secpulse-ALPLA;<subId>
PORTAL_CUSTOMER_SPAR           = stpulsesparwcsjrn;rg-secpulse-spar;la-secpulse-SPAR;<subId>
PORTAL_ALLOWED_UPNS            = markus@threatninja.at,...
PORTAL_UAMI_CLIENT_ID          = <uami clientId>
```

`deploy-portal.ps1` writes all of these as part of the Bicep deployment.

## Directory layout

```
portal/
  README.md                       (this file)
  swa/                            SWA frontend (vanilla ES module — no build step)
    index.html                    UI shell
    app.js                        Auth + customer config form + runs table
    staticwebapp.config.json      Auth + route rules + CSP
  api/                            Azure Functions (TypeScript, Functions v4 model)
    package.json
    tsconfig.json
    host.json
    src/
      index.ts                    Routes (me, customers, config, runs, trigger)
      auth.ts                     ClientPrincipal + allowlist + customer binding
      azure.ts                    UAMI credential + ARM fetch helper
      config-schema.ts            validateConfig() — mirrors Logic App schema
infra/
  portal.bicep                    SWA Standard + Function App + UAMI + AppInsights
scripts/
  deploy-portal.ps1               Opt-in provision + deploy + Entra app reg
```

## How to deploy

```pwsh
$customers = @{
  ALPLA = @{ Subscription='<subId>'; ResourceGroup='rg-secpulse-alpla'
             StorageAccount='stpulsealplahisxpz'; LogicApp='la-secpulse-ALPLA' }
  SPAR  = @{ Subscription='<subId>'; ResourceGroup='rg-secpulse-spar'
             StorageAccount='stpulsesparwcsjrn'; LogicApp='la-secpulse-SPAR' }
}

scripts/deploy-portal.ps1 `
  -Customers   $customers `
  -AllowedUpns 'markus@threatninja.at'
```

The script provisions infra, builds + zip-deploys the API, deploys the SWA
frontend, creates an Entra app registration for SWA's `aad` provider, and
prints the portal URL.

## Local dev

```pwsh
# In two terminals:
cd portal/api && npm install && npm run start    # Functions host on :7071
cd portal/swa && swa start . --api-location http://localhost:7071
```

`swa start` injects a synthetic `x-ms-client-principal` header so the
allowlist still applies — set yourself in `PORTAL_ALLOWED_UPNS` in
`portal/api/local.settings.json` before testing.

## Security notes

* The Function App takes **no inbound traffic outside SWA** — the SWA
  linked-backend feature gates `/api/*` and rejects direct calls to the
  Function App's hostname.
* Allowlist is **fail-closed**: empty `PORTAL_ALLOWED_UPNS` blocks
  everyone (even before any role check).
* `PUT /config` runs every payload through `validateConfig()` — colour
  hex, recipient shape, known section names — before writing the blob.
* `POST /trigger` only calls the Logic App's `manual` trigger via ARM.
  The trigger's callback URL never leaves the Function App.
