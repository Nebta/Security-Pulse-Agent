// infra/portal.bicep
// Wave 6 — Self-Service Portal v1
//
// Provisions a Static Web App (Standard) + a linked Azure Function App, both
// running under a single user-assigned managed identity that the deploy
// script later grants Storage Blob Data Contributor + Logic App Operator on
// each customer's resources.
//
// This template is INTENTIONALLY NOT included in the default deploy.ps1 path.
// Use scripts/deploy-portal.ps1 to provision the portal stack opt-in.
//
// Scope: resource group (typically `rg-secpulse-portal`).
//
// Notes:
//   * SWA Standard is required for linked-backend (BYOF) Functions and for
//     custom Entra app registrations. Free tier cannot link a separate
//     Function App and cannot use a UAMI for backend resource access.
//   * Entra app registration for SWA auth is created OUT-OF-BAND by
//     deploy-portal.ps1 (Microsoft Graph client doesn't fit cleanly into
//     Bicep). Its clientId/secret are written into the SWA app settings
//     after this template runs.

targetScope = 'resourceGroup'

@description('Short name (e.g. "secpulse"). Used to derive resource names.')
param namePrefix string = 'secpulse'

@description('Azure region. SWA itself ends up in westeurope; this is for storage + funcs + UAMI.')
param location string = resourceGroup().location

@description('Comma-separated list of customer IDs the portal should be aware of (e.g. "ALPLA,SPAR"). Per-customer RBAC is granted by deploy-portal.ps1.')
param customers string = ''

@description('Comma-separated list of UPNs allowed to administer the portal (allowlist). Empty = locked.')
param allowedUpns string = ''

@description('Per-customer connection strings. One entry per customer in `customers`. Format: "ALPLA=stpulsealplahisxpz;rg-secpulse-alpla;la-secpulse-ALPLA;<subId>".')
param customerBindings array = []

var uniq        = uniqueString(resourceGroup().id, namePrefix)
var uamiName    = 'uami-${namePrefix}-portal'
var swaName     = '${namePrefix}-portal-${take(uniq, 6)}'
var funcAppName = 'func-${namePrefix}-portal-${take(uniq, 6)}'
var planName    = 'plan-${namePrefix}-portal'
// Function App's required AzureWebJobsStorage account (separate from per-customer SAs).
var funcStorage = take(toLower('st${namePrefix}portfn${uniq}'), 24)
var aiName      = 'ai-${namePrefix}-portal'

// -------------------- UAMI --------------------
resource uami 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: uamiName
  location: location
}

// -------------------- Function App backing storage --------------------
resource fnSa 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: funcStorage
  location: location
  kind: 'StorageV2'
  sku: { name: 'Standard_LRS' }
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

// -------------------- App Insights --------------------
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: aiName
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
    publicNetworkAccessForIngestion: 'Enabled'
    publicNetworkAccessForQuery: 'Enabled'
  }
}

// -------------------- Function App (Linux, Consumption Y1, Node 20) --------------------
resource plan 'Microsoft.Web/serverfarms@2023-01-01' = {
  name: planName
  location: location
  sku: { name: 'Y1', tier: 'Dynamic' }
  kind: 'linux'
  properties: { reserved: true }
}

var customerBindingSettings = [for b in customerBindings: {
  name: 'PORTAL_CUSTOMER_${toUpper(split(b, '=')[0])}'
  value: split(b, '=')[1]
}]

resource funcApp 'Microsoft.Web/sites@2023-01-01' = {
  name: funcAppName
  location: location
  kind: 'functionapp,linux'
  identity: {
    type: 'UserAssigned'
    userAssignedIdentities: { '${uami.id}': {} }
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    siteConfig: {
      linuxFxVersion: 'Node|20'
      ftpsState: 'Disabled'
      minTlsVersion: '1.2'
      cors: {
        // SWA proxies /api/* to the linked function, so direct browser CORS isn't needed.
        // Empty allowedOrigins blocks third-party browser callers.
        allowedOrigins: []
      }
      appSettings: concat([
        // Identity-based AzureWebJobsStorage. The tenant disallows shared-key
        // access on storage accounts, so we wire the runtime through the UAMI
        // (which has Storage Blob/Queue/Table Data Owner/Contributor below).
        { name: 'AzureWebJobsStorage__accountName',   value: fnSa.name }
        { name: 'AzureWebJobsStorage__credential',    value: 'managedidentity' }
        { name: 'AzureWebJobsStorage__clientId',      value: uami.properties.clientId }
        { name: 'FUNCTIONS_EXTENSION_VERSION',        value: '~4' }
        { name: 'FUNCTIONS_WORKER_RUNTIME',           value: 'node' }
        // Required on Linux Consumption — without it the Node worker fails
        // to start ("Exceeded language worker restart retry count for
        // runtime:node") and the v4 programming model never registers any
        // functions. WEBSITE_NODE_DEFAULT_VERSION alone is a Windows-only
        // setting and is silently ignored on Linux.
        { name: 'FUNCTIONS_WORKER_RUNTIME_VERSION',   value: '~20' }
        { name: 'WEBSITE_NODE_DEFAULT_VERSION',       value: '~20' }
        { name: 'APPLICATIONINSIGHTS_CONNECTION_STRING', value: appInsights.properties.ConnectionString }
        { name: 'PORTAL_UAMI_CLIENT_ID',              value: uami.properties.clientId }
        { name: 'PORTAL_ALLOWED_UPNS',                value: allowedUpns }
        { name: 'PORTAL_CUSTOMERS',                   value: customers }
        { name: 'PORTAL_TEMPLATES_CONTAINER',         value: 'templates' }
      ], customerBindingSettings)
    }
  }
}

// Built-in role definition IDs (subscription-scoped).
var roleDefinitions = {
  storageBlobOwner:    '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/b7e6dc6d-f1e8-4753-8033-0f276bb0955b'
  storageQueueContrib: '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/974c5e8b-45b9-4653-ba55-5f855dd0fb88'
  storageTableContrib: '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/0a9a7e1f-b9d0-4cc4-a60d-0319b160aaa3'
}

resource fnSaBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: fnSa
  name: guid(fnSa.id, uami.id, 'blob-owner')
  properties: {
    roleDefinitionId: roleDefinitions.storageBlobOwner
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
resource fnSaQueueContrib 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: fnSa
  name: guid(fnSa.id, uami.id, 'queue-contrib')
  properties: {
    roleDefinitionId: roleDefinitions.storageQueueContrib
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
resource fnSaTableContrib 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: fnSa
  name: guid(fnSa.id, uami.id, 'table-contrib')
  properties: {
    roleDefinitionId: roleDefinitions.storageTableContrib
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}

// -------------------- Static Web App (Standard) --------------------
resource swa 'Microsoft.Web/staticSites@2023-01-01' = {
  name: swaName
  location: 'westeurope'
  sku: { name: 'Standard', tier: 'Standard' }
  properties: {
    // Repo wiring is done out-of-band via `swa deploy` in deploy-portal.ps1
    // (so contributors can iterate without granting GitHub OAuth on every deploy).
    provider: 'None'
  }
}

// SWA-level app settings that staticwebapp.config.json references.
// AAD_CLIENT_ID + AAD_CLIENT_SECRET are written by deploy-portal.ps1 after it
// creates the Entra app registration. We seed empty values here so the
// references in staticwebapp.config.json don't fail on the first deploy.
resource swaSettings 'Microsoft.Web/staticSites/config@2023-01-01' = {
  parent: swa
  name: 'appsettings'
  properties: {
    AAD_CLIENT_ID: ''
    AAD_CLIENT_SECRET: ''
  }
}

// -------------------- Outputs --------------------
output uamiPrincipalId string = uami.properties.principalId
output uamiClientId    string = uami.properties.clientId
output uamiResourceId  string = uami.id
output funcAppName     string = funcApp.name
output funcAppHostname string = funcApp.properties.defaultHostName
output swaName         string = swa.name
output swaHostname     string = swa.properties.defaultHostname
output appInsightsName string = appInsights.name
