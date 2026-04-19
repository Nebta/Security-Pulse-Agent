# Security guidance for the Security Pulse Agent

This document collects the operational security recommendations that
sit *outside* the IaC — things you set up once in your tenant and the
Logic App relies on at runtime.

It is split into four sections:

1. [Outbound email signing (DKIM, SPF, DMARC)](#1-outbound-email-signing-dkim-spf-dmarc)
2. [Conditional Access for the sender mailbox + UAMI](#2-conditional-access-for-the-sender-mailbox--uami)
3. [Outbound PII guard](#3-outbound-pii-guard)
4. [Audit log shipping](#4-audit-log-shipping)

---

## 1. Outbound email signing (DKIM, SPF, DMARC)

Customers receive the report from `senderMailbox` (an Exchange Online
mailbox in your tenant — typically `secpulse@<yourtenant>.onmicrosoft.com`
or a custom-domain alias). Recipients' mail systems will increasingly
soft- or hard-fail unsigned mail from any external domain. Configure
all three records on the *sender domain* before going live with real
customers.

### SPF (DNS TXT)

```
v=spf1 include:spf.protection.outlook.com -all
```

`-all` (hard fail) is what you want once you've confirmed only Exchange
Online sends from this domain. Use `~all` (soft fail) during initial
rollout if you have other senders to migrate.

### DKIM

Exchange Online publishes two DKIM CNAMEs per accepted domain. From
the Microsoft 365 Defender portal:

> **Email & collaboration → Policies & rules → Threat policies →
> Email authentication settings → DKIM**

Pick the sender domain → click **Create DKIM keys** → publish the two
returned `selector1._domainkey.<domain>` and
`selector2._domainkey.<domain>` CNAME records → return to the same
blade and toggle **Enable** to *On*. Selector rotation happens
automatically.

### DMARC (DNS TXT)

```
v=DMARC1; p=quarantine; pct=100; rua=mailto:dmarc-reports@<yourdomain>; ruf=mailto:dmarc-forensics@<yourdomain>; fo=1; adkim=s; aspf=s
```

Start at `p=none` for two weeks while you check `rua` aggregate
reports for unexpected sources, then move to `p=quarantine`, then
`p=reject`. `adkim=s` and `aspf=s` (strict alignment) are appropriate
because the report is sent from a single mailbox in your tenant — no
forwarding gymnastics expected.

### S/MIME (optional, per-customer)

Some regulated customers require per-message S/MIME signing of
outbound notification mail. The Logic App currently uses the
**Office 365 Outlook** connector's `Send Email (V2)` action, which
does *not* expose an `S/MIME` flag. To support this:

1. Issue an S/MIME certificate for the `senderMailbox` (e.g. via your
   internal CA or a public CA like Sectigo).
2. Install the cert into the mailbox via OWA → Settings → Mail →
   S/MIME → *Encryption* → upload the .pfx.
3. In Exchange admin → **Mail flow → Rules**, add a transport rule:
   - *If* `Sender's address matches: secpulse@<yourdomain>`
   - *and* `Recipient's domain matches: <customer-domain>`
   - *Apply this action*: `Apply Office 365 Message Encryption and
     rights protection` → choose *Encrypt only* (or your custom OME
     template configured to S/MIME-sign).

This wraps the outbound mail with OME / S/MIME without requiring
Logic App changes. Document per-customer in
`templates/customers/<id>/notes.md`.

---

## 2. Conditional Access for the sender mailbox + UAMI

The sender mailbox and the per-customer User-Assigned Managed Identity
(UAMI) are the two principals that this system relies on. Both need
explicit Conditional Access (CA) policies to keep their blast radius
small.

### Sender mailbox

| Setting               | Recommended value                                     |
|-----------------------|-------------------------------------------------------|
| Sign-in risk          | Block on `medium` and `high`                          |
| User risk             | Block on `medium` and `high`                          |
| MFA                   | Required (passkey / FIDO2 preferred)                  |
| Session lifetime      | Force re-auth every 4 hours                           |
| Locations             | Allow only your operations office IPs + emergency-break-glass account exceptions |
| Client apps           | Block legacy authentication (POP/IMAP/SMTP basic)     |
| Device compliance     | Require Intune-compliant device when accessed interactively (not enforced for the Logic App's connector OAuth refresh — that uses the stored refresh token) |

The Logic App's **Office 365 Outlook** API connection uses an OAuth
refresh token captured at *Authorize* time. Refresh-token issuance
respects CA policy at the moment of authorization — i.e. an
unconditional MFA + compliant-device policy *will* be evaluated when
the operator clicks **Authorize**, but the resulting refresh token
then runs unattended. If you rotate the policy stricter later (e.g.
add a sign-in-frequency control), the refresh token is revoked at
that point and the connection silently breaks; re-authorize via the
Portal → API connection → Edit → *Authorize*.

### UAMI

The UAMI is a *workload identity* and lives in
`https://management.azure.com` + `https://graph.microsoft.com`. CA
policies that target *workload identities* require **Microsoft Entra
Workload Identities Premium**. With that licence in place:

| Setting               | Recommended value                                     |
|-----------------------|-------------------------------------------------------|
| Service principal     | This Logic App's UAMI (`uami-secpulse-<customer>`)    |
| Locations             | Allow only Azure datacenter IP ranges (the Logic App's outbound IPs are listed under the resource's *Properties → Outbound IPs*). Block everything else. |
| Risk                  | Block on `medium` and `high` (Identity Protection for workload identities). |

For cost-conscious deployments without Workload Identities Premium,
at minimum:

- Scope the UAMI's Graph application permissions to the *exact* set
  required by the sections you've enabled (see top-level README §
  *Post-deploy steps*).
- Use **PIM for Groups** to put the UAMI's high-impact role
  assignments (e.g. `Cost Management Reader`, `Security Copilot
  Contributor`) behind eligible-with-activation rather than active.
- Audit UAMI sign-ins via:
  ```
  AADServicePrincipalSignInLogs
  | where ServicePrincipalId == "<uami-object-id>"
  | summarize count() by ResourceDisplayName, ResultType, bin(TimeGenerated, 1d)
  ```

---

## 3. Outbound PII guard

Wave 5 introduced a simple substring-based outbound PII guard in the
Logic App. Configure per customer in `templates/customers/<id>/config.json`:

```jsonc
"pii": {
  "blockSubstrings": [
    "Project Olympus",          // codename that should never leak
    "AT00 1100 0123 4567 8900", // a known sensitive IBAN
    "SEC-INC-2025-0042"          // a sensitive incident ID
  ],
  "abortOnFinding": true        // route to opsAlertEmail instead of the
                                 // configured recipient when any pattern hits.
}
```

Behaviour:

- `Scan_For_Pii_Patterns` runs after the final HTML is composed.
- The match is a case-insensitive **literal substring** check on the
  rendered HTML body. (Regex / Presidio is a planned follow-up — the
  gate's other actions don't need to change to switch the detector.)
- When at least one pattern matches *and* `abortOnFinding == true`,
  the email is routed to `opsAlertEmail` (set at deploy time) instead
  of the customer recipients, with subject prefix
  `[PII GUARD] held back: <customer> - matched <N> pattern(s)` and
  importance `High`. The history snapshot is still saved.
- If `opsAlertEmail` is empty the mail goes to the normal recipients
  rather than being silently dropped — this is intentional, so a
  misconfigured ops mailbox can never cause the report to vanish.
- When `abortOnFinding == false` (or `pii` is omitted entirely from
  config), the gate is a no-op and the email is sent normally. This
  keeps the feature opt-in.

**Limitations** (be honest about these to customers):

- The substring check will **not** catch generic credit-card numbers,
  SSNs, IBANs, or arbitrary email addresses unless you list them
  explicitly. For pattern-based detection, integrate a Presidio /
  regex worker as a tracked follow-up — see GitHub issue
  `#w5-pii-presidio` (TODO open).
- The check runs against the *final HTML*, after all template
  substitutions. It does not see the raw Copilot JSON, so a pattern
  that's only present in Copilot output but doesn't make it into the
  rendered HTML will not be flagged (which is the correct behaviour
  — only what we actually send is policy-relevant).

---

## 4. Audit log shipping

Wave 5 adds a `Microsoft.Insights/diagnosticSettings` resource to
each customer's Logic App that ships:

- `WorkflowRuntime` logs (every action in every run, with status,
  start/end times, and any error envelopes), and
- `AllMetrics` (run count, action throttling, Action Failure rate)

…to the **same Log Analytics workspace** that the Logic App already
queries for Sentinel data (`sentinelWorkspaceResourceId`). The
customer can therefore audit *what we ran on their behalf* using the
same workspace they already trust:

```kusto
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.LOGIC"
| where Resource startswith "LA-SECPULSE-"
| project TimeGenerated, OperationName, status_s, resource_action_name_s,
          startTime_t, endTime_t, durationMs = todouble(durationInMilliseconds_s),
          tracking = trackedProperties_s, _ResourceId
| order by TimeGenerated desc
```

Useful queries:

```kusto
// Failed actions in the last 7 days
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.LOGIC" and TimeGenerated > ago(7d)
| where status_s == "Failed"
| summarize count() by Resource, resource_action_name_s, code_s
| order by count_ desc

// PII guard hits (held-back mails)
AzureDiagnostics
| where ResourceProvider == "MICROSOFT.LOGIC"
| where resource_action_name_s == "Compose_PiiHoldback"
| where TimeGenerated > ago(30d)
| project TimeGenerated, Resource, status_s, _ResourceId
```

Diagnostic settings cannot be removed by the Logic App's MSI — the
customer's Sentinel workspace owner can revoke at any time via
**Diagnostic settings** on the Logic App resource.

> **Note on cost**: Logic App diagnostic logs are billed at standard
> Log Analytics ingestion rates. With the current weekly trigger
> cadence and ~40 actions per run, expect well under 1 MB / customer
> / week — negligible vs the customer's existing Sentinel ingestion.

---

## 5. Storage account network posture (template uploads)

The per-customer template storage account is created with
`publicNetworkAccess = Disabled` so customer-branded templates,
config, and logos are reachable only via Azure trusted services
(the Logic App itself) — they are never world-readable.

Operational consequence: `scripts/upload-templates.ps1`, run from a
workstation, will fail with HTTP 403 unless the workstation is on the
storage account's VNet / private endpoint. To push template changes
ad-hoc, temporarily allow your IP and revert when done:

```powershell
$sa  = '<storage-account-name>'
$rg  = 'rg-secpulse-<customer>'
$ip  = (Invoke-RestMethod 'https://api.ipify.org')

# Open: Enabled with default Deny + an IP allow rule for you
az storage account update -n $sa -g $rg `
  --public-network-access Enabled --default-action Deny --bypass AzureServices
az storage account network-rule add --account-name $sa -g $rg --ip-address $ip

# ... ./scripts/upload-templates.ps1 ...

# Close again
az storage account network-rule remove --account-name $sa -g $rg --ip-address $ip
az storage account update -n $sa -g $rg --public-network-access Disabled
```

`upload-templates.ps1` will warn pre-flight when it detects
`publicNetworkAccess = Disabled`, and will now **throw** if any
individual blob upload fails (rather than silently swallowing the
403). Long-term option: deploy the workstation into a VNet with a
private endpoint to the storage account and skip the toggling.
