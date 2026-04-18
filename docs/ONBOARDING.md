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

> **Known hang**: the Bicep `Microsoft.Logic/workflows` resource can stall
> on long `workflow.json` bodies. If the deployment hangs for more than 10
> minutes on the workflow step, Ctrl-C and `PUT` the workflow directly:
> ```powershell
> az rest --method put `
>   --uri "https://management.azure.com/subscriptions/<sub>/resourceGroups/rg-secpulse-<cust>/providers/Microsoft.Logic/workflows/la-secpulse-<CUST>?api-version=2019-05-01" `
>   --body "@infra\modules\workflow.wrapped.json"
> ```
> Everything else (connections, UAMI, storage) will already be in place.

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

> **Bug workaround**: authorizing an *existing* connection sometimes fails
> with *"Failed to edit API connection"*. If this happens, delete the
> connection (it has no downstream dependencies) and re-deploy the Bicep
> – the freshly-created connection authorizes cleanly on the first try.
> Ensure the Bicep does **not** set `parameterValueSet: 'oauth'` on
> Office 365 connections; that property is incompatible with the portal
> authorize flow.

## 10. Authorize the Security Copilot connection

Same flow for `securitycopilot-<CUST>`. If the portal Authorize dialog
redirects to `ema1.exp.azure.com` and that domain is unreachable, use the
consent-link escape hatch:

```powershell
$cid = "<connection-resource-id>"
$link = az rest --method post --uri "https://management.azure.com$cid/listConsentLinks?api-version=2018-07-01-preview" `
                --body '{"parameters":[{"parameterName":"token","redirectUrl":"https://portal.azure.com"}]}' `
                --query "value[0].link" -o tsv
Start-Process $link
```

Sign in; the final redirect to `ema1.exp.azure.com` will 404, which is
harmless – the consent has been saved. Refresh the portal and the
connection should show **Connected**.

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
| `Unexpected connection parameter set name: 'oauth'` (Send_Email)     | Office 365 connection was created with `parameterValueSet`. Delete + redeploy the connection resource without that property.                                 |
| `Value cannot be null. Parameter name: processPromptBody`            | `SkillInputs.Dataset` isn't being sent as a JSON-serialized string. `Build_Dataset` values must be objects (unquoted `@if(...)`); SkillInputs wraps `string()`. |
| Copilot returns JSON wrapped in ```` ```json ... ``` ````            | Handled by `Parse_Copilot_Response` (strips code fences). If Copilot changes wrapping, update the `replace()` expression.                                    |
| Logo doesn't show in Outlook Desktop                                 | Classic Outlook strips base64 data URIs. MSO conditional in the template falls back to styled text (acceptable). For CID inline attachments see §Future work. |
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
