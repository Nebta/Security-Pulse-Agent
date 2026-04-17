// =============================================================================
// User-assigned managed identity used by the Logic App.
//
// Bicep-managed assignments (pure Azure RBAC, idempotent):
//   - Log Analytics Reader on the Sentinel workspace (KQL data plane).
//     Done via the workspace-role.bicep module so the assignment scope can
//     legally cross subscription / resource group boundaries.
//
// NOT managed here (must be assigned out-of-band, see README.md):
//   - Security Copilot role (Contributor) on the UAMI.
//   - Microsoft Defender XDR Unified RBAC role.
//   - Microsoft Graph application permissions:
//         IdentityRiskyUser.Read.All
//         SecurityIncident.Read.All
//         SecurityEvents.Read.All
//         ThreatIndicators.Read.All
//   - Microsoft Sentinel Reader on the workspace.
// =============================================================================
param location string
param customerId string
param sentinelWorkspaceResourceId string

var uamiName = 'uami-secpulse-${customerId}'

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: location
}

// Built-in role: Log Analytics Reader = 73c42c96-874c-492b-b04d-ab87d138a893
var logAnalyticsReaderRoleId = '73c42c96-874c-492b-b04d-ab87d138a893'

var workspaceParts = split(sentinelWorkspaceResourceId, '/')
var workspaceSubId = workspaceParts[2]
var workspaceRg    = workspaceParts[4]
var workspaceName  = workspaceParts[8]

module laReader 'workspace-role.bicep' = {
  name: 'la-reader-${customerId}'
  scope: resourceGroup(workspaceSubId, workspaceRg)
  params: {
    principalId: uami.properties.principalId
    roleDefinitionId: logAnalyticsReaderRoleId
    workspaceName: workspaceName
  }
}

output userAssignedIdentityResourceId string = uami.id
output userAssignedIdentityPrincipalId string = uami.properties.principalId
output userAssignedIdentityClientId string = uami.properties.clientId
