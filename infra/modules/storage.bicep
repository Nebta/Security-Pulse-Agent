// =============================================================================
// Storage account holding per-customer HTML templates.
//
// Layout in container `templates/`:
//   <customerId>/template.html
//   <customerId>/section.html
//   <customerId>/config.json
//
// Templates are uploaded out-of-band by scripts/upload-templates.ps1.
// The Logic App's UAMI is granted Storage Blob Data Reader so it can fetch
// the template at runtime via the data plane (no shared keys).
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

// Storage Blob Data Reader = 2a2b9908-6ea1-4ae2-8e65-a410df84e7d1
var blobDataReaderRoleId = '2a2b9908-6ea1-4ae2-8e65-a410df84e7d1'

resource readerAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(sa.id, userAssignedIdentityPrincipalId, blobDataReaderRoleId)
  scope: sa
  properties: {
    principalId: userAssignedIdentityPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', blobDataReaderRoleId)
  }
}

output storageAccountName string = sa.name
output storageAccountResourceId string = sa.id
