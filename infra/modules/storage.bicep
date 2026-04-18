// =============================================================================
// Storage account holding per-customer HTML templates + KPI snapshots.
//
// Layout in container `templates/`:
//   <customerId>/template.html            (legacy fallback)
//   <customerId>/template-tech.html       (full report variant)
//   <customerId>/template-exec.html       (executive variant)
//   <customerId>/section.html
//   <customerId>/config.json
//
// Layout in container `snapshots/`:
//   <customerId>/history.json             (rolling 13-week KPI history)
//
// Templates are uploaded out-of-band by scripts/upload-templates.ps1.
// The Logic App's UAMI is granted Storage Blob Data Reader on the templates
// container, and Storage Blob Data Contributor on the snapshots container
// (scoped narrowly so the workflow can never overwrite templates).
// =============================================================================
param location string
param customerId string
param userAssignedIdentityPrincipalId string

// Storage account name: 3-24 lowercase alphanumeric. Add a short hash for uniqueness.
var saName = toLower('stpulse${replace(customerId,'-','')}${substring(uniqueString(resourceGroup().id),0,6)}')

resource sa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: saName
  location: location
  sku: { name: 'Standard_LRS' }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
    allowSharedKeyAccess: false
    publicNetworkAccess: 'Enabled'
    networkAcls: { defaultAction: 'Allow', bypass: 'AzureServices' }
  }
}

resource blobSvc 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: sa
  name: 'default'
}

resource templatesContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobSvc
  name: 'templates'
  properties: { publicAccess: 'None' }
}

resource snapshotsContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: blobSvc
  name: 'snapshots'
  properties: { publicAccess: 'None' }
}

// Storage Blob Data Reader      = 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1
// Storage Blob Data Contributor = ba92f5b4-2d11-453d-a403-e96b0029c9fe
var blobDataReaderRoleId      = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'
var blobDataContributorRoleId = 'ba92f5b4-2d11-453d-a403-e96b0029c9fe'

resource templatesReaderAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(templatesContainer.id, userAssignedIdentityPrincipalId, blobDataReaderRoleId)
  scope: templatesContainer
  properties: {
    principalId: userAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataReaderRoleId)
  }
}

resource snapshotsContributorAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(snapshotsContainer.id, userAssignedIdentityPrincipalId, blobDataContributorRoleId)
  scope: snapshotsContainer
  properties: {
    principalId: userAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataContributorRoleId)
  }
}

output storageAccountName string = sa.name
output storageAccountResourceId string = sa.id

