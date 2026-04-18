# Dataset contract: Logic App → Copilot agent

The Logic App posts the following JSON object as the `dataset` input to the
`WeeklySecurityReportAgent`. The agent must not compute or invent any value;
it only narrates what is present here.

```jsonc
{
  "reportPeriod": {
    "start": "2026-04-13T00:00:00Z",
    "end":   "2026-04-20T00:00:00Z",
    "timezone": "Europe/Berlin"
  },
  "customer": { "id": "contoso", "displayName": "Contoso AG", "tenantId": "..." },

  "vulnerabilities": {
    "newCriticalCount": 12,
    "newHighCount": 47,
    "exposedAssetCount": 318,
    "topCves": [
      { "cveId": "CVE-2026-1234", "cvss": 9.8, "exposedDevices": 41, "title": "..." }
    ]
  },

  "threatLandscape": {
    "activeCampaigns": [
      { "name": "Storm-####", "firstSeen": "2026-04-11", "industriesTargeted": ["Finance"], "summary": "..." }
    ],
    "newIocCount": 184
  },

  "xdrIncidents": {
    "openCount": 7,
    "newThisWeek": 3,
    "bySeverity": { "high": 1, "medium": 4, "low": 2 },
    "top": [
      { "id": "INC-1234", "title": "...", "severity": "High", "assignedTo": "soc@contoso.com", "createdUtc": "..." }
    ]
  },

  "sentinelIncidents": {
    "openCount": 11,
    "newThisWeek": 5,
    "bySeverity": { "high": 2, "medium": 6, "low": 3 },
    "top": [
      { "id": "...", "title": "...", "severity": "High", "owner": "...", "createdUtc": "..." }
    ]
  },

  "riskyIdentities": {
    "highRiskUserCount": 4,
    "riskySignInCount": 38,
    "top": [
      { "upn": "...", "riskLevel": "High", "lastSignIn": "..." }
    ]
  },

  "entraIdProtection": {
    "value": [
      { "id": "...", "userPrincipalName": "user@contoso.com", "riskLevel": "high",
        "riskState": "atRisk", "riskType": "unfamiliarFeatures",
        "detectedDateTime": "2026-04-15T10:12:00Z", "ipAddress": "203.0.113.5",
        "location": { "city": "...", "countryOrRegion": "..." } }
    ]
  },

  "intuneCompliance": {
    "value": [
      { "id": "...", "deviceName": "WIN10-NB-0421", "operatingSystem": "Windows",
        "complianceState": "noncompliant", "lastSyncDateTime": "2026-04-17T08:01:00Z",
        "userPrincipalName": "user@contoso.com" }
    ]
  },

  "mdtiArticles": {
    "value": [
      { "id": "...", "title": "Storm-#### targets manufacturing in EU",
        "summary": "...", "createdDateTime": "2026-04-12T09:00:00Z",
        "lastUpdatedDateTime": "2026-04-15T11:00:00Z",
        "indicators": { "totalCount": 47 },
        "tags": ["manufacturing", "ransomware"] }
    ]
  },

  "sentinelCost": {
    "currency": "EUR",
    "billingCycleStart": "2026-04-01T00:00:00Z",
    "billingCycleEnd":   "2026-04-30T23:59:59Z",
    "ingestedGbCycle": 1284.7,
    "ingestedGbLastWeek": 312.4,
    "estimatedCostCycle": 4216.55,
    "perWorkspace": [
      { "workspace": "law-prod-weu", "ingestedGb": 902.1, "estimatedCost": 2961.10 }
    ],
    "note": "Estimated from Log Analytics Usage table - not invoiced cost."
  }
}
```

Section keys may be `null` if collection failed; the agent must surface that
("Data unavailable for this section.") rather than guess.
