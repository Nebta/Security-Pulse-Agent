// Static Web App (Free tier) + dedicated UAMI for the Wave 6 portal scaffold.
// No role assignments here; per-customer storage RBAC is granted from the
// per-customer module when the portal goes live.

param portalName string
param repoUrl string
param repoBranch string

resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: 'uami-${portalName}'
  location: resourceGroup().location
}

resource swa 'Microsoft.Web/staticSites@2023-12-01' = {
  name: portalName
  // SWA is a global resource but ARM still wants a regional anchor.
  location: 'westeurope'
  sku: {
    name: 'Free'
    tier: 'Free'
  }
  properties: {
    repositoryUrl: empty(repoUrl) ? null : repoUrl
    branch: empty(repoUrl) ? null : repoBranch
    buildProperties: {
      appLocation: '/portal/swa'
      apiLocation: '/portal/api'
      outputLocation: ''
    }
    stagingEnvironmentPolicy: 'Enabled'
    allowConfigFileUpdates: true
  }
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: {
      '${uami.id}': {}
    }
  }
}

output defaultHostname string = swa.properties.defaultHostname
output uamiPrincipalId string = uami.properties.principalId
