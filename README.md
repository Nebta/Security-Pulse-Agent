# Security Pulse Agent

A Microsoft **Security Copilot custom agent** plus an **Azure Logic App** that
emails an HTML weekly security report — **per customer**, with each customer's
HTML template, branding and tone loaded at runtime from Azure Blob Storage.

## What it does

Every Monday morning, for each deployed customer:

1. Logic App deterministically collects last-week security data:
   - Defender Vulnerability Management — critical/high vulns
   - Defender Threat Intelligence — active intel profiles
   - Defender XDR open incidents (Microsoft Graph)
   - Microsoft Sentinel incidents (Log Analytics KQL)
   - Entra ID high-risk users (Microsoft Graph)
   - Sentinel ingestion cost — current billing cycle (Log Analytics `Usage`)
2. Logic App POSTs the normalized JSON dataset + the customer's
   `audience / industry / tone / focusAreas` to the
   `WeeklySecurityReportAgent` in Security Copilot.
3. Copilot returns strict JSON: executive summary, risk rating,
   per-section commentary, top-3 actions. **Copilot never authors numbers
   or HTML.**
4. Logic App fetches the customer's `template.html`, `section.html` and
   `config.json` from blob, substitutes placeholders, and sends the email
   via the Office 365 Outlook connector.

## Architecture

```
Recurrence (Mon @ scheduleHour, scheduleTimeZone)
       │
       ▼
Azure Logic App (Consumption)  ─UAMI auth─►  Blob Storage  (template.html, section.html, config.json)
   ├─ Parallel deterministic data collection
   │     ├─ Defender Vulnerability Management
   │     ├─ Defender TI / intelligence profiles
   │     ├─ Defender XDR open incidents
   │     ├─ Sentinel incidents (KQL)
   │     ├─ Entra risky users
   │     └─ Sentinel cost (Usage KQL)
   ├─ Build normalized JSON dataset
   ├─ POST → Security Copilot agent (narrative synthesis)
   ├─ Substitute placeholders into customer template
   └─ Send via Office 365 Outlook connector → recipient
```

## Repository layout

```
agent/
  weekly-security-report.yaml     # Security Copilot Agent Builder skeleton
  dataset-contract.md             # JSON contract Logic App ↔ agent
templates/
  README.md                       # placeholder reference + how to add a customer
  customers/
    _default/
      template.html               # outer email shell
      section.html                # per-section snippet
      config.json                 # branding + Copilot context + section toggles
infra/
  main.bicep                      # subscription-scope deployment (one per customer)
  customers/
    _default.parameters.json      # template parameter file
  modules/
    identity.bicep                # UAMI + Log Analytics Reader
    storage.bicep                 # storage account + templates container + Blob Reader
    logicapp.bicep                # workflow + O365 API connection
    workflow.json                 # Logic App definition body
scripts/
  deploy.ps1                      # az deployment wrapper
  upload-templates.ps1            # syncs templates/customers/<id>/ to blob
portal/                           # self-service portal (Wave 6 v1, opt-in deploy)
  README.md
  swa/                            # Static Web App frontend (vanilla ES module)
  api/                            # Azure Functions API (TypeScript, Functions v4)
```

## Quick start (default customer)

```powershell
# 1. Edit parameters (resource group, sentinel workspace id, recipient, sender)
notepad .\infra\customers\_default.parameters.json

# 2. Deploy the customer's stack
./scripts/deploy.ps1 `
    -SubscriptionId <sub-id> `
    -Location westeurope `
    -ParametersFile .\infra\customers\_default.parameters.json

# 3. Upload the default template into the new storage account
#    (the deploy.ps1 output prints the storage account name)
./scripts/upload-templates.ps1 -StorageAccount <printed-name> -CustomerId default

# 4. Complete the post-deploy manual steps (printed by deploy.ps1).
# 5. Trigger the Logic App once to validate.
```

## Adding a new customer

1. Copy `templates/customers/_default/` → `templates/customers/<id>/` and edit
   `config.json`, swap the logo, adjust colors and `focusAreas`.
2. Copy `infra/customers/_default.parameters.json` → `infra/customers/<id>.parameters.json`.
   Set `customerId`, `resourceGroupName`, `recipientEmail`, `senderMailbox`,
   `sentinelWorkspaceResourceId`. Optionally set
   `existingTemplatesStorageAccountName` to share one storage account across
   customers.
3. `./scripts/deploy.ps1 -ParametersFile .\infra\customers\<id>.parameters.json ...`
4. `./scripts/upload-templates.ps1 -StorageAccount <sa> -CustomerId <id>`

## Prerequisites

- Azure subscription with Owner + User Access Administrator on the target RG.
- Microsoft Sentinel workspace.
- Security Copilot provisioned with SCUs.
- Azure CLI ≥ 2.60 with the Bicep extension.
- Exchange Online mailbox to use as the sender of the report.

## Post-deploy steps (manual, one-time per customer)

These cannot be automated in Bicep:

1. **Authorize the Office 365 Outlook connection.** Portal → connection →
   *Edit API connection* → *Authorize* → sign in as `senderMailbox`.
2. **Security Copilot role.** Security Copilot → Owner settings → Role
   assignment → assign **Contributor** to the user-assigned managed identity.
3. **Microsoft Graph application permissions** (admin consent):
   `SecurityIncident.Read.All`, `SecurityEvents.Read.All`,
   `ThreatIndicators.Read.All`, `IdentityRiskyUser.Read.All`,
   `IdentityRiskEvent.Read.All`, `DeviceManagementManagedDevices.Read.All`,
   `ThreatIntelligence.Read.All` *(only used if the tenant has a
   Microsoft Defender Threat Intelligence licence; otherwise the
   `mdtiHighlights` section is skipped via the existing graceful-degrade
   path — no error in the email)*,
   `SecurityAlert.Read.All` *(used by the `purviewDlp` section to read
   Microsoft Purview DLP policy alerts via `/security/alerts_v2`)*,
   `Files.ReadWrite.All` *(only required if any customer config sets
   `pdfAttachment: true` — used to upload report HTML to OneDrive and
   request a PDF render via Graph drive convert. Skip this scope if
   you don't enable PDF attachments)*.
   Use `scripts/grant-graph-perms.ps1` to grant + admin-consent in one shot.
   Note: after granting new scopes, the Logic App MSI may serve cached tokens
   without them for up to ~1 hour — re-trigger the run after that window.
4. **Defender XDR Unified RBAC** — assign the UAMI a role with read access
   on Vulnerability Management, Incidents and Threat Intelligence.
5. **Sentinel workspace** — assign the UAMI **Microsoft Sentinel Reader**
   (data-plane, on top of the Bicep-assigned Log Analytics Reader).
6. **Cost Management Reader at subscription scope** — assign the UAMI
   **Cost Management Reader** on the subscription that owns the
   Sentinel workspace. Required by the Defender for Cloud + Defender
   for Endpoint cost block in the `sentinelCost` section. Without it
   the cost-mgmt query returns 401 and the section gracefully shows
   only the Sentinel estimate. `onboard-customer.ps1` grants this
   automatically; the same script is safe to re-run on existing
   customers to retroactively add the role.
7. **Upload the agent.** Security Copilot → Agents → *Import* →
   `agent/weekly-security-report.yaml`. **Reconcile field names against the
   current Agent Builder schema** before saving.

## Customer template model

See `templates/README.md` for the full placeholder reference. Summary:

- `template.html` — outer shell with `{{CUSTOMER_DISPLAY_NAME}}`,
  `{{PRIMARY_COLOR}}`, `{{EXECUTIVE_SUMMARY}}`, `{{TOP_ACTIONS_LIST}}`,
  `{{SECTIONS_BLOCK}}`, `{{FOOTER_TEXT}}`, …
- `section.html` — per-section snippet with `{{SECTION_TITLE}}`,
  `{{SECTION_HEADLINE}}`, `{{SECTION_BODY}}`, `{{SECTION_RECS}}`,
  `{{PRIMARY_COLOR}}`.
- `config.json` — branding (`logoUrl`, `primaryColor`, `accentColor`,
  `footerText`), Copilot context (`audience`, `industry`, `tone`,
  `focusAreas`), and `sectionsEnabled` to disable individual sections.
  Available section keys: `vulnerabilities`, `threatLandscape`,
  `mdtiHighlights` (Defender Threat Intelligence articles),
  `xdrIncidents`, `sentinelIncidents`, `riskyIdentities`,
  `entraIdProtection` (Entra ID Protection risk detections),
  `intuneCompliance` (non-compliant managed devices),
  `purviewDlp` (Microsoft Purview DLP alerts via Graph
  `/security/alerts_v2`),
  `sentinelCost` (now includes Defender for Cloud + Defender for
  Endpoint billing-cycle cost from Azure Cost Management,
  alongside the Log Analytics Usage-table estimate).

Templates can be edited and re-uploaded with `upload-templates.ps1` **without
redeploying** the Logic App.

## Wave 4 distribution options (per-customer, opt-in via `config.json`)

- **Multi-language (`language`):** set to `"de"` to localise the email
  subject, KPI tile labels, section titles, and instruct the Copilot
  agent to write all narrative text in German. Default is `"en"`.
- **Per-mode recipient lists (`recipients`):** an object with
  `default` / `exec` / `tech` arrays. The Logic App picks the list
  matching the trigger's `templateVariant`, falls back to `default`,
  and finally to the deploy-time `recipientEmail` parameter. Lists
  are sent as a single semicolon-joined `To:` (no per-section split
  in v1 — defer to a later iteration).
- **PDF attachment (`pdfAttachment`):** when `true`, the rendered HTML
  is uploaded to a OneDrive scratch folder (`/secpulse-tmp/`),
  converted to PDF via the Graph drive `?format=pdf` API, attached
  to the email as `security-pulse-report.pdf`, and the scratch file
  is deleted. `pdfDriveUserUpn` overrides which user's OneDrive is
  used (defaults to `senderMailbox`). Requires `Files.ReadWrite.All`
  on the UAMI. Image fidelity in the PDF depends on Graph's HTML
  renderer — verify with your customer template before going live.
- **Teams adaptive card (`teamsWebhookUrl`):** when non-empty, after
  the email send the Logic App POSTs an adaptive card with the eight
  KPI tiles to the configured Teams Incoming Webhook URL. Failures
  are non-fatal (the run still succeeds).

## Wave 5 security & compliance

See [`docs/SECURITY.md`](docs/SECURITY.md) for full guidance on:

- DKIM, SPF, DMARC, and optional S/MIME for the sender mailbox.
- Conditional Access policies for the sender mailbox and the per-customer
  UAMI (workload identity).
- Outbound **PII guard** — per-customer literal-substring deny-list;
  hits are routed to `opsAlertEmail` instead of the customer with subject
  prefix `[PII GUARD] held back`. Configured under `pii` in
  `templates/customers/<id>/config.json`. Opt-in (no-op when omitted).
- **Audit log shipping** — every Logic App run + action lands in the
  customer's own Sentinel workspace via a `Microsoft.Insights/diagnosticSettings`
  resource on the Logic App. The KQL queries to drive a "what did Security
  Pulse do for me last week" view are in `docs/SECURITY.md`.
- **Secret scanning in CI** — `gitleaks/gitleaks-action@v2` runs on every
  PR and fails the build on findings. See `.github/workflows/pr-validate.yml`.

## Wave 6 self-service portal (opt-in)

A small Static Web App + Functions API that lets allow-listed admins view
recent runs, edit a customer's `config.json`, and trigger ad-hoc runs
without touching the Azure portal.

* **Status:** v1 shipped, opt-in. Not provisioned by `deploy.ps1`.
* **Deploy:** `scripts/deploy-portal.ps1` (see `portal/README.md`).
* **Architecture:** SWA Standard (Entra auth) → linked Function App
  (Linux Y1, Node 20) running as a UAMI with `Storage Blob Data
  Contributor` + `Logic App Operator` per customer.
* **Authorisation:** UPN allowlist via `PORTAL_ALLOWED_UPNS` (fail-closed).
  Per-customer Entra app roles are the planned upgrade.

## Risks / known limitations

- **Agent Builder YAML schema is evolving.** `agent/weekly-security-report.yaml`
  ships as a *documented skeleton*. Verify field names marked `TODO-VERIFY`
  against the schema currently visible in your tenant before upload.
- **MI auth to Security Copilot Direct API** is not officially documented as
  GA. If your tenant rejects UAMI auth against
  `https://api.securitycopilot.microsoft.com`, switch the
  `Invoke_Copilot_Agent` action to use an app-only bearer token from a
  Key Vault secret (app registration with certificate credential).
- **Office 365 connector requires interactive authorization** and cannot be
  fully IaC-deployed. For unattended pipelines, swap `Send_Email` for a
  Microsoft Graph `sendMail` HTTP call using the same UAMI.
- **Sentinel cost is *estimated*** from the `Usage` table. The
  `sentinelCost` section also includes the *invoiced* Defender for Cloud +
  Defender for Endpoint billing-cycle cost via the Azure Cost Management
  Query API (requires `Cost Management Reader` on the subscription).
- **No idempotency key** — re-running the trigger sends another email.

## License

MIT.
