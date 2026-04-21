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

@description('Skip the per-storage-account role assignments on rerun. ARM throws RoleAssignmentExists when these are re-deployed against a scope that already contains the same assignment from a prior run (the guid is deterministic, but property updates are rejected). Set to true on rerun if you already granted RBAC.')
param skipRbac bool = false

@description('GitHub owner for the Wave 7c wizard (commits + workflow dispatches target this org/user).')
param githubOwner string = 'Nebta'

@description('GitHub repo name for the Wave 7c wizard.')
param githubRepo string = 'Security-Pulse-Agent'

@description('Shared Sentinel workspace used as the default for customers created via the wizard. Full ARM resource id. Empty string leaves the setting unset (the create-customer endpoint will reject requests until it is set).')
param defaultWorkspaceResourceId string = ''

var uniq        = uniqueString(resourceGroup().id, namePrefix)
var uamiName    = 'uami-${namePrefix}-portal'
var swaName     = '${namePrefix}-portal-${take(uniq, 6)}'
var funcAppName = 'func-${namePrefix}-portal-${take(uniq, 6)}'
var planName    = 'plan-${namePrefix}-portal'
// Function App's required AzureWebJobsStorage account (separate from per-customer SAs).
var funcStorage = take(toLower('st${namePrefix}portfn${uniq}'), 24)
var aiName      = 'ai-${namePrefix}-portal'
var kvName      = take('kv-${namePrefix}-portal-${uniq}', 24)

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

// Wave 7c: the wizard writes onboarding request state and a customer
// registry into this container. The onboard.yml workflow uploads the
// final summary JSON here too.
resource fnSaBlob 'Microsoft.Storage/storageAccounts/blobServices@2023-05-01' = {
  parent: fnSa
  name: 'default'
}
resource trackingContainer 'Microsoft.Storage/storageAccounts/blobServices/containers@2023-05-01' = {
  parent: fnSaBlob
  name: 'tracking'
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
    // Key Vault references require an identity. Because this func has
    // no system-assigned MI, we must explicitly tell the runtime to
    // use the UAMI for KV lookups. Without this the GITHUB_APP_*
    // settings resolve to literal "@Microsoft.KeyVault(...)" strings.
    keyVaultReferenceIdentity: uami.id
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
        { name: 'PORTAL_TRACKING_STORAGE_ACCOUNT',    value: fnSa.name }
        { name: 'PORTAL_TRACKING_CONTAINER',          value: 'tracking' }
        // Wave 7c wizard.
        { name: 'GITHUB_OWNER',                       value: githubOwner }
        { name: 'GITHUB_REPO',                        value: githubRepo }
        { name: 'GITHUB_APP_ID',                      value: '@Microsoft.KeyVault(VaultName=${kvName};SecretName=GitHubAppId)' }
        { name: 'GITHUB_APP_INSTALLATION_ID',         value: '@Microsoft.KeyVault(VaultName=${kvName};SecretName=GitHubAppInstallationId)' }
        { name: 'GITHUB_APP_PRIVATE_KEY',             value: '@Microsoft.KeyVault(VaultName=${kvName};SecretName=GitHubAppPrivateKey)' }
        { name: 'PORTAL_DEFAULT_WORKSPACE_RESOURCE_ID', value: defaultWorkspaceResourceId }
        // Linux Consumption fetches the package from the blob URL on every
        // cold start. The func has no system-assigned MI (UAMI only), so the
        // runtime needs to be told which UAMI to use for the blob read.
        // Without this the runtime silently registers 0 functions and every
        // /api/* request returns 404 from the linked SWA backend.
        { name: 'WEBSITE_RUN_FROM_PACKAGE_BLOB_MI_RESOURCE_ID', value: uami.id }
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

resource fnSaBlobOwner 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipRbac) {
  scope: fnSa
  name: guid(fnSa.id, uami.id, 'blob-owner')
  properties: {
    roleDefinitionId: roleDefinitions.storageBlobOwner
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
resource fnSaQueueContrib 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipRbac) {
  scope: fnSa
  name: guid(fnSa.id, uami.id, 'queue-contrib')
  properties: {
    roleDefinitionId: roleDefinitions.storageQueueContrib
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
  }
}
resource fnSaTableContrib 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipRbac) {
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

// -------------------- Function App EasyAuth (SWA-linked backend) --------------------
// Required for the SWA -> func proxy hop: SWA injects a short-lived token as
// `x-ms-auth-token`, EasyAuth's `azureStaticWebApps` provider validates it and
// synthesises `x-ms-client-principal` which the handlers read. Without this
// resource, the SPA reaches /api/me but sees 401 "unauthorized" because the
// function never sees a principal. With requireAuthentication=false the direct
// func hostname still works for probes / master-key callers; SWA is the auth
// boundary.
resource funcAuth 'Microsoft.Web/sites/config@2023-01-01' = {
  parent: funcApp
  name: 'authsettingsV2'
  properties: {
    platform: {
      enabled: true
      runtimeVersion: '~1'
    }
    globalValidation: {
      requireAuthentication: false
      unauthenticatedClientAction: 'AllowAnonymous'
    }
    identityProviders: {
      azureStaticWebApps: {
        enabled: true
        registration: {
          clientId: swa.properties.defaultHostname
        }
      }
    }
    httpSettings: {
      requireHttps: true
      forwardProxy: {
        convention: 'NoProxy'
      }
    }
    login: {
      tokenStore: {
        enabled: false
      }
      preserveUrlFragmentsForLogins: false
    }
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

// -------------------- Key Vault (Wave 7c: GitHub App credentials) --------------------
resource kv 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: kvName
  location: location
  properties: {
    tenantId: subscription().tenantId
    sku: { family: 'A', name: 'standard' }
    enableRbacAuthorization: true
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    publicNetworkAccess: 'Enabled'
  }
}

// Key Vault Secrets User = read secret values.
var kvSecretsUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6'
resource kvUamiSecretsUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!skipRbac) {
  scope: kv
  name: guid(kv.id, uami.id, 'kv-secrets-user')
  properties: {
    roleDefinitionId: '/subscriptions/${subscription().subscriptionId}/providers/Microsoft.Authorization/roleDefinitions/${kvSecretsUserRoleId}'
    principalId: uami.properties.principalId
    principalType: 'ServicePrincipal'
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
output keyVaultName    string = kv.name
output trackingStorageAccount string = fnSa.name
