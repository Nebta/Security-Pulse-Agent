# Customer templates

Each customer gets a folder under `templates/customers/<customerId>/` with:

| File              | Purpose                                                                                  |
|-------------------|------------------------------------------------------------------------------------------|
| `template.html`   | Outer email shell. Contains placeholders (see below).                                    |
| `section.html`    | Snippet rendered once per section, then concatenated into `{{SECTIONS_BLOCK}}`.          |
| `config.json`     | Per-customer branding + Copilot context + section toggles.                               |

At deploy time (or any later upload) `scripts/upload-templates.ps1` syncs this
folder to the Storage container `templates` under the prefix `<customerId>/`.

The Logic App reads `<customerId>/template.html`, `<customerId>/section.html`
and `<customerId>/config.json` from blob at runtime, so you can change a
customer's branding **without redeploying**.

## Placeholders rendered by the Logic App

### `template.html` (outer shell)

| Placeholder                  | Replaced with                                              |
|------------------------------|------------------------------------------------------------|
| `{{CUSTOMER_DISPLAY_NAME}}`  | `config.displayName`                                       |
| `{{CUSTOMER_LOGO_URL}}`      | `config.logoUrl` (must be HTTPS, embed-friendly)           |
| `{{PRIMARY_COLOR}}`          | `config.primaryColor` (hex, e.g. `#0b3d91`)                |
| `{{ACCENT_COLOR}}`           | `config.accentColor`                                       |
| `{{REPORT_PERIOD_START}}`    | `yyyy-MM-dd`                                               |
| `{{REPORT_PERIOD_END}}`      | `yyyy-MM-dd`                                               |
| `{{RISK_RATING}}`            | Copilot output                                             |
| `{{RISK_COLOR}}`             | Derived from `RISK_RATING`                                 |
| `{{EXECUTIVE_SUMMARY}}`      | Copilot output                                             |
| `{{TOP_ACTIONS_LIST}}`       | `<li>…</li><li>…</li>` rendered list                       |
| `{{SECTIONS_BLOCK}}`         | One rendered `section.html` per enabled section            |
| `{{GENERATED_UTC}}`          | ISO timestamp                                              |
| `{{FOOTER_TEXT}}`            | `config.footerText`                                        |

### `section.html` (per section)

| Placeholder           | Replaced with                                                                |
|-----------------------|------------------------------------------------------------------------------|
| `{{SECTION_TITLE}}`   | Human label (`Vulnerabilities`, `Sentinel cost`, …)                          |
| `{{SECTION_HEADLINE}}`| Copilot `sections.<key>.headline`                                            |
| `{{SECTION_BODY}}`    | Copilot `sections.<key>.commentary`                                          |
| `{{SECTION_RECS}}`    | `<ul><li>…</li></ul>` from `sections.<key>.recommendations` (empty if none)  |
| `{{PRIMARY_COLOR}}`   | as above                                                                     |
| `{{ACCENT_COLOR}}`    | as above                                                                     |

## `config.json` schema

```jsonc
{
  "customerId": "contoso",
  "displayName": "Contoso AG",
  "logoUrl": "https://contoso.example/logo.png",
  "primaryColor": "#0b3d91",
  "accentColor":  "#16a34a",
  "footerText":   "Confidential. For internal use of Contoso AG only.",
  "audience":     "C-level + SOC lead",
  "industry":     "Financial services",
  "tone":         "Concise, executive-friendly, action-oriented",
  "focusAreas":   ["Ransomware", "Insider risk", "Fourth-party SaaS"],
  "sectionsEnabled": {
    "vulnerabilities":   true,
    "threatLandscape":   true,
    "mdtiHighlights":    true,
    "xdrIncidents":      true,
    "sentinelIncidents": true,
    "riskyIdentities":   true,
    "entraIdProtection": true,
    "intuneCompliance":  true,
    "purviewDlp":        true,   // Microsoft Purview DLP alerts via Graph
                                  //   /security/alerts_v2 (Wave 3).
    "sentinelCost":      true     // Sentinel Usage-table estimate + actual
                                  //   MDC + MDE billing from Cost Management.
  },

  // Wave 4: optional fields
  "language": "en",                     // "en" or "de"; controls subject,
                                        // KPI labels, section titles, and
                                        // the tone/language of Copilot text.
  "recipients": {                       // Per-mode To: list (semicolon-joined).
    "default": ["soc@contoso.example"], //   used when no mode-specific list set
    "exec":    ["ciso@contoso.example"],//   used when templateVariant=exec
    "tech":    ["soc@contoso.example"]  //   used when templateVariant=tech
  },                                    // Falls back to deploy-time
                                        // recipientEmail parameter if empty.
  "pdfAttachment":   false,             // attach PDF render alongside HTML
  "pdfDriveUserUpn": "",                // OneDrive used as PDF render scratch;
                                        // defaults to senderMailbox if empty.
                                        // Requires Files.ReadWrite.All on UAMI.
  "teamsWebhookUrl": "",                // optional Teams Incoming Webhook URL
                                        // for an adaptive-card KPI summary.

  // Wave 5: outbound PII guard (literal substring deny-list)
  "pii": {
    "blockSubstrings": [                //   case-insensitive substring matches
      "Project Olympus",                //     against the *final HTML body*.
      "AT00 1100 0123 4567 8900"        //     Add codenames, known-sensitive
    ],                                  //     IBANs, doc IDs, etc.
    "abortOnFinding": true              //   when true + match found, the email
                                        //     is routed to opsAlertEmail (set
                                        //     at deploy time) with subject
                                        //     prefix '[PII GUARD] held back'
                                        //     instead of the customer
                                        //     recipients. Falls through to
                                        //     normal recipients if
                                        //     opsAlertEmail is empty (so a
                                        //     misconfigured ops mailbox
                                        //     never silently drops the
                                        //     report). Omit the whole block
                                        //     to disable the gate.
  }
}
```

`audience`, `industry`, `tone`, `focusAreas` are passed to the Copilot agent
as `customerContext` so it can adapt phrasing — **without** changing facts.

## Adding a new customer

1. Copy `templates/customers/_default/` to `templates/customers/<id>/`.
2. Edit `config.json`, replace logo, adjust colors and `focusAreas`.
3. Tweak `template.html` / `section.html` if the customer wants a different
   layout (most do not).
4. Upload:
   ```powershell
   ./scripts/upload-templates.ps1 -StorageAccount <acct> -CustomerId <id>
   ```
5. Deploy a Logic App for that customer:
   ```powershell
   ./scripts/deploy.ps1 -SubscriptionId ... -Location westeurope `
       -ParametersFile ./infra/customers/<id>.parameters.json
   ```
