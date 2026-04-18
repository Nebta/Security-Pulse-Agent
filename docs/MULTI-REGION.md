# Multi-region deployments

The Security Pulse Agent is region-agnostic at the Bicep level: each customer
picks its own `location` in `infra/customers/<CUST>.parameters.json`.

## Supported regions

The whole stack runs anywhere all four of these are GA:

| Component                          | Notes                                                                          |
|------------------------------------|--------------------------------------------------------------------------------|
| Microsoft.Logic/workflows          | Available in every Azure public region                                         |
| Microsoft.Web/connections (O365)   | Connector available globally; the connection lives in the chosen region        |
| Microsoft.Web/connections (Securitycopilot) | Currently GA in `westeurope`, `northeurope`, `eastus`, `eastus2`, `westus2`, `australiaeast`. Verify before picking. |
| Microsoft.Storage                  | Everywhere                                                                     |
| Microsoft.ManagedIdentity (UAMI)   | Everywhere                                                                     |

> The Sentinel workspace can be in a *different* region from the Logic App
> &mdash; the `sentinelWorkspaceResourceId` parameter is just an ID and the
> Log Analytics REST API is multi-region.

## Failover pattern (active/passive)

For DR, deploy a second customer parameters file with a different region:

```jsonc
// infra/customers/CONTOSO.parameters.json       location = "westeurope"
// infra/customers/CONTOSO-DR.parameters.json    location = "northeurope"
```

Both files target the same `customerId` (and therefore the same blob prefix),
but get different RGs (`rg-secpulse-contoso` and `rg-secpulse-contoso-dr`).
The DR Logic App stays disabled until needed:

```bash
az logic workflow update -g rg-secpulse-contoso-dr -n la-secpulse-CONTOSO-DR --state Disabled
```

To fail over, flip state on the DR workflow and disable the primary.

## Caveats

- **Connector versions** can lag in non-EU regions. After deploying to a
  new region, run `./scripts/health-check.ps1` immediately and verify both
  connections show `Connected`.
- **Outbound IPs** for Logic App connectors differ per region. If your
  customer has IP allowlists for SMTP relay, fetch the new region's
  outbound IPs from `az logic workflow show ... --query "properties.accessControl"`
  and update the allowlist.
- **OAuth consent** is per-connection-resource, not per-region. The user
  who authorizes the primary connection does NOT automatically authorize
  the DR connection &mdash; reauthorize after each DR-region deploy.
