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
    "xdrIncidents":      true,
    "sentinelIncidents": true,
    "riskyIdentities":   true,
    "sentinelCost":      true
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
