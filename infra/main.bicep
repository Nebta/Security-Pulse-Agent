// =============================================================================
// Top-level deployment for the Security Pulse Agent (per customer).
// Scope: subscription. Creates an RG and deploys identity, storage (templates)
// and the Logic App into it. One deployment per customer.
// =============================================================================
targetScope = 'subscription'

@description('Azure region for all resources.')
param location string = 'westeurope'

@description('Resource group name. One RG per customer.')
param resourceGroupName string

@description('Customer identifier. Lower-case, alphanumeric or dashes. Used in resource names and as the blob prefix for the customer template.')
@minLength(2)
@maxLength(20)
param customerId string

@description('Recipient email address(es) for the weekly report. Comma-separated for multiple.')
param recipientEmail string

@description('Sender mailbox. Must be the mailbox used to authorize the O365 connection post-deploy.')
param senderMailbox string

@description('Hour-of-day (0-23) for the Monday recurrence.')
param scheduleHour int = 6

@description('Windows time-zone ID (e.g. "W. Europe Standard Time").')
param scheduleTimeZone string = 'W. Europe Standard Time'

@description('Resource ID of the Microsoft Sentinel Log Analytics workspace.')
param sentinelWorkspaceResourceId string

@description('Tenant ID. Defaults to current.')
param tenantId string = subscription().tenantId

@description('Estimated Log Analytics ingestion price per GB.')
param estimatedPricePerGb string = '2.30'

@description('Pricing currency code (display only).')
param currencyCode string = 'EUR'

@description('Optional: name of an existing storage account to reuse for templates. If empty, a new one is created in this RG.')
param existingTemplatesStorageAccountName string = ''

@description('Per-customer monthly cost cap (EUR). The Logic App aborts a run if the projected monthly cost (Sentinel + Copilot SCU + ARM) is forecast to exceed this cap. 0 disables.')
param costCapMonthlyEur int = 50

@description('Email address that receives ops alerts (cost cap, drift, health digest).')
param opsAlertEmail string = ''

@description('Report language. Currently supported: en, de.')
@allowed(['en', 'de'])
param reportLanguage string = 'en'

@description('Template variant to render. tech = full report (KPI strip + sections + top-5 tables). exec = executive summary only.')
@allowed(['tech', 'exec'])
param templateVariant string = 'tech'

@description('Snapshots blob container name (for week-over-week trends).')
param snapshotsContainerName string = 'snapshots'

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: resourceGroupName
  location: location
}

module identity 'modules/identity.bicep' = {
  name: 'identity'
  scope: rg
  params: {
    location: location
    customerId: customerId
    sentinelWorkspaceResourceId: sentinelWorkspaceResourceId
  }
}

module storage 'modules/storage.bicep' = if (empty(existingTemplatesStorageAccountName)) {
  name: 'storage'
  scope: rg
  params: {
    location: location
    customerId: customerId
    userAssignedIdentityPrincipalId: identity.outputs.userAssignedIdentityPrincipalId
  }
}

module logicapp 'modules/logicapp.bicep' = {
  name: 'logicapp'
  scope: rg
  params: {
    location: location
    customerId: customerId
    recipientEmail: recipientEmail
    senderMailbox: senderMailbox
    scheduleHour: scheduleHour
    scheduleTimeZone: scheduleTimeZone
    sentinelWorkspaceResourceId: sentinelWorkspaceResourceId
    tenantId: tenantId
    userAssignedIdentityResourceId: identity.outputs.userAssignedIdentityResourceId
    estimatedPricePerGb: estimatedPricePerGb
    currencyCode: currencyCode
    templatesStorageAccountName: empty(existingTemplatesStorageAccountName) ? storage!.outputs.storageAccountName : existingTemplatesStorageAccountName
    templatesContainerName: 'templates'
    costCapMonthlyEur: costCapMonthlyEur
    opsAlertEmail: empty(opsAlertEmail) ? recipientEmail : opsAlertEmail
    reportLanguage: reportLanguage
    templateVariant: templateVariant
    snapshotsContainerName: snapshotsContainerName
  }
}

output logicAppName string = logicapp.outputs.logicAppName
output logicAppResourceId string = logicapp.outputs.logicAppResourceId
output userAssignedIdentityResourceId string = identity.outputs.userAssignedIdentityResourceId
output userAssignedIdentityPrincipalId string = identity.outputs.userAssignedIdentityPrincipalId
output o365ConnectionResourceId string = logicapp.outputs.o365ConnectionResourceId
output templatesStorageAccountName string = empty(existingTemplatesStorageAccountName) ? storage!.outputs.storageAccountName : existingTemplatesStorageAccountName
