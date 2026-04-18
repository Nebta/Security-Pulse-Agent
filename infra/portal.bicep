// Self-service portal infra (Wave 6 — scaffold only, not deployed by default).
//
// Deploy explicitly with:
//   az deployment sub create -l westeurope -f infra/portal.bicep \
//     --parameters portalName=secpulse-portal repoUrl=https://github.com/Nebta/Security-Pulse-Agent
//
// deploy.ps1 / CI pipelines intentionally do NOT include this template.

targetScope = 'subscription'

@description('Name of the portal Static Web App and its resource group suffix.')
param portalName string = 'secpulse-portal'

@description('Azure region for the portal resource group. SWA itself is global; nearest deployment region only matters for linked Functions.')
param location string = 'westeurope'

@description('GitHub repo URL backing the SWA. Leave blank to wire up later in the portal.')
param repoUrl string = ''

@description('Branch the SWA tracks.')
param repoBranch string = 'main'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${portalName}'
  location: location
}

module portal './modules/portal-swa.bicep' = {
  name: 'portal-swa'
  scope: rg
  params: {
    portalName: portalName
    repoUrl: repoUrl
    repoBranch: repoBranch
  }
}

output portalDefaultHostname string = portal.outputs.defaultHostname
output portalUamiPrincipalId string = portal.outputs.uamiPrincipalId
