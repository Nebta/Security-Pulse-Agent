#requires -Version 7
<#
.SYNOPSIS
    Provisions and deploys the Security Pulse self-service portal (Wave 6 v1).

.DESCRIPTION
    Opt-in. Not invoked by deploy.ps1.

    Steps:
    1) Create / ensure portal RG.
    2) Deploy infra/portal.bicep (UAMI, Function App, Storage, AppInsights, SWA Standard).
    3) Grant the portal UAMI Storage Blob Data Contributor + Logic App Contributor
       on each customer's storage account + Logic App.
    4) Build and zip-deploy the Functions API (portal/api).
    5) Build the SWA frontend (no build step — vanilla JS) and `swa deploy`.
    6) Create / reuse an Entra app registration for SWA's `aad` provider,
       set redirect URIs, write client id + secret into SWA + Function settings.
    7) Print follow-up runbook (assign your UPN to allowlist, sign in, test).

    Requirements:
    - Azure CLI logged in (az login) with Owner on the portal RG and on each
      customer RG (for role assignments).
    - Application Administrator (or Privileged Role Admin) on the tenant
      to create the SWA Entra app registration.
    - Static Web Apps CLI installed (`npm i -g @azure/static-web-apps-cli`).
    - Node 20+ for building the Functions API.

.PARAMETER NamePrefix
    Short name baked into resources. Default: "secpulse".

.PARAMETER PortalRg
    Resource group for the portal stack. Default: "rg-secpulse-portal".

.PARAMETER PortalLocation
    Azure region. Default: "westeurope".

.PARAMETER Customers
    Hashtable of customerId -> object with Subscription, ResourceGroup,
    StorageAccount, LogicApp. Example:

      @{
        ALPLA = @{ Subscription='...'; ResourceGroup='rg-secpulse-alpla';
                   StorageAccount='stpulsealpla...'; LogicApp='la-secpulse-ALPLA' }
      }

.PARAMETER AllowedUpns
    Comma-separated UPNs allowed to administer the portal (PORTAL_ALLOWED_UPNS).
#>
[CmdletBinding()]
param(
    [string]$NamePrefix = 'secpulse',
    [string]$PortalRg = 'rg-secpulse-portal',
    [string]$PortalLocation = 'westeurope',
    [Parameter(Mandatory)] [hashtable]$Customers,
    [Parameter(Mandatory)] [string]$AllowedUpns
)

$ErrorActionPreference = 'Stop'

function require($cmd, $hint) {
    if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
        throw "Required command '$cmd' not found. $hint"
    }
}
require 'az'   "Install Azure CLI."
require 'node' "Install Node.js 20+."
require 'npm'  "Install Node.js 20+."
require 'swa'  "Install with: npm i -g `@azure/static-web-apps-cli"

$root      = Split-Path -Parent $PSScriptRoot
$bicep     = Join-Path $root 'infra' 'portal.bicep'
$apiDir    = Join-Path $root 'portal' 'api'
$swaDir    = Join-Path $root 'portal' 'swa'

Write-Host "==> Ensuring resource group $PortalRg in $PortalLocation" -ForegroundColor Cyan
az group create -n $PortalRg -l $PortalLocation --only-show-errors | Out-Null

# Build customerBindings list as it's expected by the bicep
$bindings = foreach ($k in $Customers.Keys) {
    $c = $Customers[$k]
    "{0}={1};{2};{3};{4}" -f $k, $c.StorageAccount, $c.ResourceGroup, $c.LogicApp, $c.Subscription
}
$customersList = ($Customers.Keys -join ',')

Write-Host "==> Deploying infra/portal.bicep" -ForegroundColor Cyan
# PowerShell + az CLI mangle inline JSON arrays. Use a parameter file instead.
$basePortalParams = @{
    namePrefix       = @{ value = $NamePrefix }
    location         = @{ value = $PortalLocation }
    customers        = @{ value = $customersList }
    allowedUpns      = @{ value = $AllowedUpns }
    customerBindings = @{ value = @($bindings) }
}

function Invoke-PortalBicep([bool]$SkipRbac) {
    $p = @{}
    foreach ($k in $basePortalParams.Keys) { $p[$k] = $basePortalParams[$k] }
    $p['skipRbac'] = @{ value = $SkipRbac }
    $wrapper = @{
        '$schema' = 'https://schema.management.azure.com/schemas/2019-04-01/deploymentParameters.json#'
        contentVersion = '1.0.0.0'
        parameters = $p
    }
    $f = Join-Path $env:TEMP "portal.parameters.$([guid]::NewGuid()).json"
    $wrapper | ConvertTo-Json -Depth 10 | Set-Content -Path $f -Encoding utf8
    try {
        $raw = az deployment group create `
            -g $PortalRg `
            --template-file $bicep `
            --parameters "@$f" `
            --query properties.outputs `
            -o json 2>&1
        return @{ ExitCode = $LASTEXITCODE; Raw = $raw }
    } finally {
        Remove-Item $f -ErrorAction SilentlyContinue
    }
}

$res = Invoke-PortalBicep $false
if ($res.ExitCode -ne 0) {
    $msg = ($res.Raw -join "`n")
    if ($msg -match 'RoleAssignmentExists') {
        Write-Warning "Bicep hit RoleAssignmentExists on rerun; retrying with skipRbac=true (RBAC already granted in a prior deploy)."
        $res = Invoke-PortalBicep $true
    }
    if ($res.ExitCode -ne 0) {
        Write-Host ($res.Raw -join "`n")
        throw "Bicep deployment failed."
    }
}
$dep = $res.Raw | Out-String
if (-not $dep) { throw "Bicep deployment returned no outputs — check 'az deployment group list -g $PortalRg' for the failure." }
$out = $dep | ConvertFrom-Json
$uamiPrincipalId = $out.uamiPrincipalId.value
$funcAppName     = $out.funcAppName.value
$swaName         = $out.swaName.value
$swaHostname     = $out.swaHostname.value
Write-Host "    UAMI principalId : $uamiPrincipalId"
Write-Host "    Function App     : $funcAppName"
Write-Host "    SWA              : https://$swaHostname"

# --- 3) per-customer RBAC ------------------------------------------------------
Write-Host "==> Granting RBAC on customer resources to portal UAMI" -ForegroundColor Cyan
foreach ($k in $Customers.Keys) {
    $c = $Customers[$k]
    $saId = "/subscriptions/$($c.Subscription)/resourceGroups/$($c.ResourceGroup)/providers/Microsoft.Storage/storageAccounts/$($c.StorageAccount)"
    $laId = "/subscriptions/$($c.Subscription)/resourceGroups/$($c.ResourceGroup)/providers/Microsoft.Logic/workflows/$($c.LogicApp)"
    foreach ($pair in @(
        @{ Scope=$saId; Role='Storage Blob Data Contributor' },
        @{ Scope=$laId; Role='Logic App Contributor' }
    )) {
        $exists = az role assignment list --assignee $uamiPrincipalId --scope $pair.Scope --role $pair.Role --query "[0].id" -o tsv 2>$null
        if ($exists) {
            Write-Host "    [$k] already has '$($pair.Role)' on $(Split-Path $pair.Scope -Leaf)"
        } else {
            az role assignment create --assignee-object-id $uamiPrincipalId --assignee-principal-type ServicePrincipal `
                --role $pair.Role --scope $pair.Scope --only-show-errors | Out-Null
            if ($LASTEXITCODE -ne 0) { throw "Failed to grant '$($pair.Role)' on $($pair.Scope) to UAMI $uamiPrincipalId" }
            Write-Host "    [$k] granted '$($pair.Role)' on $(Split-Path $pair.Scope -Leaf)"
        }
    }
}

# --- 4) build + deploy Functions API ------------------------------------------
Write-Host "==> Building Functions API ($apiDir)" -ForegroundColor Cyan
Push-Location $apiDir
try {
    npm install --no-audit --no-fund | Out-Host
    npm run build | Out-Host
    $zip = Join-Path $env:TEMP "secpulse-portal-api.zip"
    if (Test-Path $zip) { Remove-Item $zip }
    # Stage only what the runtime needs.
    $stage = Join-Path $env:TEMP "secpulse-portal-api-stage"
    if (Test-Path $stage) { Remove-Item -Recurse -Force $stage }
    New-Item -ItemType Directory -Path $stage | Out-Null
    Copy-Item host.json,package.json -Destination $stage
    Copy-Item -Recurse dist -Destination $stage
    Push-Location $stage
    try { npm install --omit=dev --no-audit --no-fund | Out-Host } finally { Pop-Location }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -Force

    # Tenant policy disallows shared-key auth on storage, so config-zip won't
    # work. Upload the zip to the func storage account and point the runtime
    # at it via WEBSITE_RUN_FROM_PACKAGE — the function's UAMI has Blob Data
    # Owner so the runtime can fetch the package via managed identity.
    $fnSa = az resource list -g $PortalRg --resource-type 'Microsoft.Storage/storageAccounts' --query "[?starts_with(name,'st${NamePrefix}portfn')].name | [0]" -o tsv
    if (-not $fnSa) { throw "Could not find Function App backing storage account in $PortalRg." }
    $me = az ad signed-in-user show --query id -o tsv
    $fnSaId = az storage account show -g $PortalRg -n $fnSa --query id -o tsv
    $hasMyRbac = az role assignment list --assignee $me --scope $fnSaId --role 'Storage Blob Data Contributor' --query "[0].id" -o tsv 2>$null
    if (-not $hasMyRbac) {
        Write-Host "    granting Storage Blob Data Contributor to $($me) on $fnSa (for one-time upload)"
        az role assignment create --assignee-object-id $me --assignee-principal-type User --role 'Storage Blob Data Contributor' --scope $fnSaId --only-show-errors | Out-Null
        Start-Sleep 60   # RBAC propagation
    }
    az storage container create --account-name $fnSa --name 'app-package' --auth-mode login --only-show-errors | Out-Null
    $blobName = "api-$(Get-Date -Format yyyyMMddHHmmss).zip"
    az storage blob upload --account-name $fnSa --container-name 'app-package' --name $blobName --file $zip --auth-mode login --overwrite --only-show-errors | Out-Null
    $packageUrl = "https://$fnSa.blob.core.windows.net/app-package/$blobName"
    Write-Host "    uploaded $blobName, pointing WEBSITE_RUN_FROM_PACKAGE → $packageUrl"
    az functionapp config appsettings set -g $PortalRg -n $funcAppName --settings "WEBSITE_RUN_FROM_PACKAGE=$packageUrl" --only-show-errors | Out-Null
    az functionapp restart -g $PortalRg -n $funcAppName --only-show-errors | Out-Null
} finally { Pop-Location }

# --- 5) deploy SWA frontend ---------------------------------------------------
Write-Host "==> Deploying SWA frontend ($swaDir)" -ForegroundColor Cyan
$swaToken = az staticwebapp secrets list -n $swaName -g $PortalRg --query properties.apiKey -o tsv
swa deploy $swaDir --deployment-token $swaToken --env production --no-use-keychain | Out-Host

# --- 6) link Function App as the SWA backend ----------------------------------
Write-Host "==> Linking Function App as SWA backend" -ForegroundColor Cyan
$funcRid = az functionapp show -g $PortalRg -n $funcAppName --query id -o tsv
$alreadyLinked = az staticwebapp backends show -n $swaName -g $PortalRg --query "[0].backendResourceId" -o tsv 2>$null
if (-not $alreadyLinked) {
    az staticwebapp backends link -n $swaName -g $PortalRg --backend-resource-id $funcRid --backend-region $PortalLocation --only-show-errors | Out-Null
    Write-Host "    linked"
} else {
    Write-Host "    backend already linked"
}

# --- 7) Entra app registration for SWA AAD provider ---------------------------
Write-Host "==> Ensuring Entra app registration for SWA AAD provider" -ForegroundColor Cyan
$appName = "$NamePrefix-portal-$swaName"
$existing = az ad app list --display-name $appName --query "[0]" -o json | ConvertFrom-Json
if (-not $existing) {
    Write-Host "    creating app registration '$appName'"
    $created = az ad app create --display-name $appName `
        --sign-in-audience AzureADMyOrg `
        --web-redirect-uris "https://$swaHostname/.auth/login/aad/callback" `
        --enable-id-token-issuance true `
        -o json | ConvertFrom-Json
    $appId  = $created.appId
    $appOid = $created.id
    az ad sp create --id $appId --only-show-errors | Out-Null
} else {
    $appId  = $existing.appId
    $appOid = $existing.id
    az ad app update --id $appId --web-redirect-uris "https://$swaHostname/.auth/login/aad/callback" --enable-id-token-issuance true --only-show-errors | Out-Null
    Write-Host "    reusing existing app '$appName' (appId=$appId)"
}

Write-Host "    issuing client secret (12 months)"
$secret = az ad app credential reset --id $appId --append --display-name "swa-$(Get-Date -Format yyyyMMdd)" --years 1 --query password -o tsv

$tenantId = az account show --query tenantId -o tsv
Write-Host "==> Writing AAD settings into SWA + Function App" -ForegroundColor Cyan
az staticwebapp appsettings set -n $swaName -g $PortalRg --setting-names "AAD_CLIENT_ID=$appId" "AAD_CLIENT_SECRET=$secret" --only-show-errors | Out-Null
# Patch staticwebapp.config.json's openIdIssuer placeholder by replacing it on the wire.
# SWA reads the deployed file as-is, so we substitute and re-deploy.
$cfgPath = Join-Path $swaDir 'staticwebapp.config.json'
$cfg = Get-Content $cfgPath -Raw
if ($cfg -match '\{TENANT_ID\}') {
    Write-Host "    substituting tenant id into staticwebapp.config.json (in-place, redeploying)"
    $patched = $cfg -replace '\{TENANT_ID\}', $tenantId
    [IO.File]::WriteAllText($cfgPath, $patched, [Text.UTF8Encoding]::new($false))
    swa deploy $swaDir --deployment-token $swaToken --env production --no-use-keychain | Out-Host
    [IO.File]::WriteAllText($cfgPath, $cfg, [Text.UTF8Encoding]::new($false))
}

Write-Host ""
Write-Host "==> Done." -ForegroundColor Green
Write-Host "    Portal: https://$swaHostname"
Write-Host "    Sign in with: $AllowedUpns"
Write-Host ""
Write-Host "Smoke test:"
Write-Host "  curl -s https://$swaHostname/.auth/me   # should return {clientPrincipal: null} when not signed in"
Write-Host "  Open the portal URL, sign in with Entra, you should land in the customer config page."
