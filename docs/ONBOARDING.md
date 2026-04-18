# Security Pulse Agent – Customer Onboarding Runbook

Step-by-step procedure for onboarding a new customer (`<CUST>`) to the
Security Pulse Agent platform. Each customer gets an isolated resource
group, Logic App, UAMI, storage account and O365 connection.

> Naming convention used throughout: `<CUST>` is the short customer ID
> (e.g. `ALPLA`, `CONTOSO`). It must match folder name in
> `templates/customers/<CUST>/` and the parameters file basename in
> `infra/customers/<CUST>.parameters.json`.

## 0. Prerequisites (one time per tenant)

- Azure subscription with Owner (or Contributor + User Access Administrator).
- Security Copilot capacity provisioned (SCU) in the tenant.
- A Microsoft Sentinel workspace reachable by the customer's resource group.
- A licensed Office 365 sender mailbox (shared or service mailbox) for
  outbound email. The mailbox *owns* the outgoing address; recipients are
  configured per-customer.
- Installed locally:
  - Azure CLI 2.60+ (`az`)
  - PowerShell 7 (`pwsh`)
  - Git, Node.js 18+ (only if regenerating customer logo PNGs from SVG)

### Connector quirks reference (read once, save hours)

These rules are encoded in `infra/modules/logicapp.bicep` and the
`scripts/repair-connection.ps1` helper. Documented here because both
behaviors are undocumented quirks that took an entire onboarding cycle
to debug.

| Connector              | `parameterValueSet` rule                          | If wrong, you'll see…                                                                            |
|------------------------|---------------------------------------------------|--------------------------------------------------------------------------------------------------|
| `office365` (Outlook)  | **Must be absent**                                | `Send_Email -> 400 "Unexpected connection parameter set name: 'oauth'"`                          |
| `Securitycopilot`      | **Must be `{ name: 'Oauth', values: {} }`**       | `listConsentLinks` returns "No consent server information was associated with this request"; the connection cannot authorize and stays in Error. |

Other field-tested rules:

- **Workflow `uri` strings must URL-encode spaces** (`%20`) inside any
  `$filter` / `$orderby` clause. The Logic Apps runtime is forgiving but
  the designer's URI validator is not — it will block `Save`.
- **After delete+recreate of any API connection**, re-PUT the workflow
  (`./scripts/repair-workflow.ps1`) so its cached connection token
  endpoint refreshes. Otherwise next run fails with
  `"Error from token exchange: The connection (...) is not found"`.
- **Portal "Edit API connection → Save" can hang for >5 min** and never
  persist. Reliable fallback: open the Logic App **designer**, pick the
  connection from any action, authorize, save the workflow.

## 1. Create customer parameters file

Copy the ALPLA example and edit the values:

```powershell
Copy-Item infra\customers\ALPLA.parameters.json infra\customers\<CUST>.parameters.json
```

Required parameters (see `infra/main.bicep`):

| Parameter              | Meaning                                                |
|------------------------|--------------------------------------------------------|
| `customerId`           | Short ID. Must match template folder name.             |
| `location`             | Azure region (e.g. `westeurope`).                      |
| `sentinelWorkspaceId`  | `/subscriptions/.../Microsoft.OperationalInsights/...` |
| `senderMailbox`        | O365 UPN that sends the report.                        |
| `recipientEmail`       | Who receives the weekly report.                        |
| `copilotAgentEndpoint` | Security Copilot Direct API URL.                       |
| `copilotAgentName`     | Agent display name (set in step 11).                   |

Customer parameters files are **gitignored** (see `.gitignore` –
`infra/customers/*.parameters.json`, except `_default.parameters.json`).

## 2. Create customer template folder

```powershell
New-Item -ItemType Directory -Path templates\customers\<CUST> -Force
Copy-Item templates\customers\_default\* templates\customers\<CUST>\ -Recurse
```

Then edit `templates/customers/<CUST>/config.json` with customer branding
(colours, footer text, audience, focus areas) and optionally provide a
customer logo (see §8 below for logo handling).

Customer template folders other than `_default` are **gitignored**
(`templates/customers/*` except `_default`).

## 3. Deploy Azure infrastructure

```powershell
.\scripts\deploy.ps1 -CustomerId <CUST> -SubscriptionId <sub-guid>
```

This runs `az deployment sub create` against `infra/main.bicep` with the
customer parameters file. It creates:

- Resource group `rg-secpulse-<cust>` (lowercased)
- UAMI `uami-secpulse-<cust>`
- Storage account `stpulse<cust><hash>` with a `templates` container
- Logic App `la-secpulse-<CUST>` (Consumption)
- API connections: `securitycopilot-<CUST>`, `office365-<CUST>`

> **Known hang**: the Bicep `Microsoft.Logic/workflows` resource often
> stalls on long `workflow.json` bodies (>5 min). `deploy.ps1` now
> auto-detects this: after `WorkflowHangTimeoutSec` (default 360s) it
> cancels the inner `logicapp` deployment and falls back to a direct
> workflow PUT via `repair-workflow.ps1`. All other resources
> (connections, UAMI, storage) are already in place by then.
>
> Manual fallback if needed:
> ```powershell
> az deployment group cancel -g rg-secpulse-<cust> -n logicapp
> ./scripts/repair-workflow.ps1 -CustomerId <CUST> -SubscriptionId <sub>
> ```

Capture the UAMI `principalId` from deployment outputs – needed in steps 4–7.

## 4. Grant Microsoft Graph application permissions to the UAMI

Graph app perms cannot be set through the portal for managed identities;
use the script:

```powershell
.\scripts\grant-graph-perms.ps1 -UamiObjectId <principal-id>
```

The script assigns: `SecurityIncident.Read.All`, `SecurityEvents.Read.All`,
`ThreatIndicators.Read.All`, `IdentityRiskyUser.Read.All`,
and `WindowsDefenderATP / AdvancedQuery.Read.All` (Defender for Endpoint
advanced hunting).

## 5. Grant Microsoft Sentinel / Log Analytics permissions

At the Sentinel workspace scope, assign the UAMI:

- `Microsoft Sentinel Reader` (incidents + entity reads)
- `Log Analytics Reader` (Usage table for cost estimation)

```powershell
az role assignment create `
  --assignee-object-id <principal-id> --assignee-principal-type ServicePrincipal `
  --role "Microsoft Sentinel Reader" `
  --scope <sentinelWorkspaceId>
az role assignment create `
  --assignee-object-id <principal-id> --assignee-principal-type ServicePrincipal `
  --role "Log Analytics Reader" `
  --scope <sentinelWorkspaceId>
```

## 6. Grant Defender XDR Unified RBAC role

Defender XDR's Unified RBAC UI does not let you pick managed identities
directly. Work around it with an Entra security group:

1. Create (or re-use) group `sg-secpulse-defender-readers`:
   ```powershell
   az ad group create --display-name sg-secpulse-defender-readers `
                      --mail-nickname sg-secpulse-defender-readers
   ```
2. Add the UAMI as a member:
   ```powershell
   az ad group member add --group sg-secpulse-defender-readers `
                          --member-id <principal-id>
   ```
3. In **security.microsoft.com → Permissions & roles → Microsoft Defender
   XDR → Roles**, create a role `SecPulse Reader` with *Security
   operations* read permissions and assign it to the group.

## 7. Grant Security Copilot access to the UAMI

At subscription (or tenant root) scope:

```powershell
az role assignment create `
  --assignee-object-id <principal-id> --assignee-principal-type ServicePrincipal `
  --role "Security Copilot Contributor" `
  --scope /subscriptions/<sub>
```

## 8. Upload customer template assets to blob storage

```powershell
.\scripts\upload-templates.ps1 -CustomerId <CUST>
```

This uploads `templates/customers/<CUST>/` (template.html, section.html,
config.json, and optionally a logo asset) to the customer's storage
account under `templates/<CUST>/`.

### Logo handling

Email logos are embedded as **base64 PNG data URIs** inside `template.html`
(rendered in Outlook Web, Apple Mail, Gmail and all mobile clients). Classic
Outlook Desktop strips data URIs; the MSO conditional comment in the
template provides a branded text fallback.

To regenerate a customer's PNG from an SVG source:

```powershell
# One-time: npm install sharp in a scratch dir
mkdir $env:TEMP\svgconv -ErrorAction SilentlyContinue
pushd $env:TEMP\svgconv; npm init -y | Out-Null; npm install sharp; popd

# Convert
$svg = (Resolve-Path templates\customers\<CUST>\logo.svg).Path -replace '\\','/'
$png = (Join-Path (Get-Location) 'templates\customers\<CUST>\logo.png') -replace '\\','/'
$sharp = (Join-Path $env:TEMP\svgconv 'node_modules\sharp') -replace '\\','/'
node -e "const s=require('$sharp');const fs=require('fs');s(fs.readFileSync('$svg'),{density:400}).resize(400).png().toFile('$png').then(()=>console.log('OK'))"
```

Then inline the base64 into `template.html` (`<img src="data:image/png;base64,..." />`).

> Why not a public blob URL? Many Azure tenants enforce Azure Policy that
> forces `allowBlobPublicAccess=false` on storage accounts, making
> https://... logo URLs unreachable. Base64 data URIs bypass this, are
> self-contained, and work offline/air-gapped.

## 9. Authorize the Office 365 connection

1. Portal → resource group → API connection **`office365-<CUST>`** → **Edit
   API connection**.
2. Click **Authorize**, sign in with the sender mailbox account.
3. Click **Save**.

> **Connector-specific quirk** – Office 365 connections **must NOT** be
> deployed with `parameterValueSet`. The Bicep already follows this rule.
> If a connection ends up with `parameterValueSet=oauth`, runs fail with
> `Send_Email -> HTTP 400 "Unexpected connection parameter set name: 'oauth'"`.
> Fix:
> ```powershell
> ./scripts/repair-connection.ps1 -CustomerId <CUST> -Connector O365 -SubscriptionId <sub>
> ```
> then authorize via Portal as above.

## 10. Authorize the Security Copilot connection

Same flow for `securitycopilot-<CUST>`.

> **Connector-specific quirk** – Security Copilot connections **must** have
> `parameterValueSet: { name: 'Oauth', values: {} }`. The Bicep already
> follows this rule. Without it, `listConsentLinks` returns "No consent
> server information was associated with this request" and the connection
> never authorizes. Fix:
> ```powershell
> ./scripts/repair-connection.ps1 -CustomerId <CUST> -Connector Copilot -SubscriptionId <sub>
> ```

> **Portal save hangs?** The "Edit API connection → Authorize → Save" path
> sometimes hangs >5 min and never persists. Reliable fallback: open the
> Logic App in the **designer**, expand any Copilot action, click
> **Change connection**, pick (or **+ Add new**) the connection, authorize,
> then **Save** the workflow. Designer save commits the auth atomically.
>
> If designer save complains *"Whitespaces must be encoded for URIs"* on
> the HTTP actions, the workflow.json in your branch hasn't yet
> URL-encoded its `$filter` strings — pull latest from `main` and redeploy
> (or run `./scripts/repair-workflow.ps1`).

> **After delete+recreate of any connection**, you MUST re-PUT the workflow
> so its cached connection token endpoint refreshes. Otherwise next run
> fails with "Error from token exchange: The connection (...) is not
> found." `repair-connection.ps1` does this automatically.

## 11. Upload the agent YAML to Security Copilot

1. Open https://securitycopilot.microsoft.com → **Plugins / Agents** →
   **Agent builder**.
2. **Import from YAML**.
3. Choose `agent/weekly-security-report.yaml`.
4. On the **Skills / tools** panel, confirm each AGENT tool has at least
   one skill (the YAML ships with GPT + AGENT tools; re-upload if it
   flags *"No agent tools detected"*).
5. **Publish**. Copy the resulting agent name into the customer parameters
   file as `copilotAgentName` and redeploy if it changed.
6. When prompted by Copilot to provide `Dataset` and `CustomerContext` at
   agent-setup time, enter:
   - `Dataset` → `{}` (placeholder – populated at runtime)
   - `CustomerContext` → `{"customerId":"<CUST>","displayName":"..."}`
   These are just schema placeholders for the UI; the Logic App overrides
   them on every invocation.

## 12. Smoke test

Fire the Logic App manually via the helper script (it resolves the
`manual` HTTP trigger callback URL and POSTs to it):

```powershell
.\scripts\run-customer.ps1 -CustomerId <CUST> -SubscriptionId <sub>
```

Or by hand:

```powershell
$cb = az rest --method post `
  --uri "https://management.azure.com/subscriptions/<sub>/resourceGroups/rg-secpulse-<cust>/providers/Microsoft.Logic/workflows/la-secpulse-<CUST>/triggers/manual/listCallbackUrl?api-version=2019-05-01" `
  | ConvertFrom-Json
Invoke-WebRequest -Method Post -Uri $cb.value
```

Then inspect the latest run in the portal or via:

```powershell
az rest --method get `
  --uri "https://management.azure.com/.../workflows/la-secpulse-<CUST>/runs?api-version=2019-05-01" `
  --query "value[0].{status:properties.status, end:properties.endTime}"
```

Confirm the email arrives at `recipientEmail`.

## Troubleshooting

| Symptom                                                              | Cause / fix                                                                                                                                                  |
|----------------------------------------------------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `InvalidWorkflowManagedIdentitySpecified` on run                     | Workflow references a UAMI that was rotated/re-created. Redeploy the Bicep – it re-wires `identity.userAssignedIdentities`.                                  |
| `Send_Email -> 400 "Unexpected connection parameter set name: 'oauth'"` | O365 connection has `parameterValueSet`. Run `./scripts/repair-connection.ps1 -CustomerId <CUST> -Connector O365 -SubscriptionId <sub>` then re-authorize.   |
| Copilot connection stuck in **Error**, consent link 400s with "No consent server information was associated with this request" | Copilot connection is missing `parameterValueSet={Oauth,{}}`. Run `./scripts/repair-connection.ps1 -CustomerId <CUST> -Connector Copilot -SubscriptionId <sub>` then re-authorize. |
| `Send_Email -> 404 "Error from token exchange: The connection (...) is not found"` | Connection was deleted+recreated but workflow's `$connections` cache still points at the old internal id. Run `./scripts/repair-workflow.ps1 -CustomerId <CUST> -SubscriptionId <sub>`. |
| Designer save: *"Whitespaces must be encoded for URIs"*              | `workflow.json` HTTP `uri` values contain literal spaces in `$filter` clauses. Replace with `%20`. The repo workflow.json is already encoded; this only happens if older copies are deployed. |
| Portal "Edit API connection → Save" hangs > 5 min                    | Use the Logic App **designer** instead: open any Copilot/O365 action → Change connection → Authorize → save the workflow. Designer save commits auth atomically. |
| `Value cannot be null. Parameter name: processPromptBody`            | `SkillInputs.Dataset` isn't being sent as a JSON-serialized string. `Build_Dataset` values must be objects (unquoted `@if(...)`); SkillInputs wraps `string()`. |
| Copilot returns JSON wrapped in ```` ```json ... ``` ````            | Handled by `Parse_Copilot_Response` (strips code fences). If Copilot changes wrapping, update the `replace()` expression.                                    |
| Logo doesn't show in Outlook Desktop                                 | Classic Outlook strips base64 data URIs. MSO conditional in the template falls back to styled text (acceptable). For CID inline attachments see §Future work. |
| Bicep `logicapp` deployment hangs > 5 min                            | Known issue with workflow PUT for large definitions. `deploy.ps1` auto-recovers; or run `./scripts/repair-workflow.ps1` manually after cancelling the inner `logicapp` deployment. |
| Consent-link redirect to `ema1.exp.azure.com` fails DNS              | Expected. The consent was saved before the redirect – refresh the portal and verify the connection shows **Connected**.                                      |
| Storage `allowBlobPublicAccess` flips back to `false` after update   | Azure Policy at management-group level is enforcing it. Use base64 data URIs in templates instead (current approach).                                        |

## Future work

- **CID inline attachments** for Outlook Desktop logo support – requires
  switching `Send_Email` from the O365 `/v2/Mail` connector action to a
  direct HTTP `POST` against `graph.microsoft.com/.../sendMail` with the
  UAMI (Mail.Send app permission), and adding `attachments[].isInline=true`
  with `contentId` references.
- **KPI metric strip** (four numeric tiles: vulns, XDR incidents, risky
  users, Sentinel cost) – requires workflow to surface the counts from
  `Build_Dataset` as separate template placeholders.
