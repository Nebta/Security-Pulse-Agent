<#
.SYNOPSIS
    Deploys the Security Pulse Agent (Logic App + UAMI + storage) for one customer.

.EXAMPLE
    ./scripts/deploy.ps1 `
        -SubscriptionId 00000000-0000-0000-0000-000000000000 `
        -Location westeurope `
        -ParametersFile ./infra/customers/_default.parameters.json
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [Parameter(Mandatory)] [string] $Location,
    [Parameter(Mandatory)] [string] $ParametersFile,
    [string] $TemplateFile   = "$PSScriptRoot/../infra/main.bicep",
    [string] $DeploymentName = "secpulse-$(Get-Date -Format 'yyyyMMddHHmmss')"
)

$ErrorActionPreference = 'Stop'

Write-Host "==> Setting subscription $SubscriptionId" -ForegroundColor Cyan
az account set --subscription $SubscriptionId | Out-Null

Write-Host "==> Validating template" -ForegroundColor Cyan
az deployment sub validate `
    --location $Location `
    --template-file $TemplateFile `
    --parameters "@$ParametersFile" | Out-Null

Write-Host "==> Deploying ($DeploymentName)" -ForegroundColor Cyan
$result = az deployment sub create `
    --name $DeploymentName `
    --location $Location `
    --template-file $TemplateFile `
    --parameters "@$ParametersFile" `
    --output json | ConvertFrom-Json

if ($LASTEXITCODE -ne 0) { throw "Deployment failed." }

$out = $result.properties.outputs
$customerId = (Get-Content $ParametersFile | ConvertFrom-Json).parameters.customerId.value

Write-Host ""
Write-Host "Deployment succeeded." -ForegroundColor Green
Write-Host "  Logic App           : $($out.logicAppName.value)"
Write-Host "  UAMI resource id    : $($out.userAssignedIdentityResourceId.value)"
Write-Host "  Templates SA        : $($out.templatesStorageAccountName.value)"
Write-Host "  O365 connection id  : $($out.o365ConnectionResourceId.value)"
Write-Host ""
Write-Host "==> Next: upload the customer template" -ForegroundColor Cyan
Write-Host "  ./scripts/upload-templates.ps1 -StorageAccount $($out.templatesStorageAccountName.value) -CustomerId $customerId"
Write-Host ""
Write-Host "==> Post-deploy steps (manual)" -ForegroundColor Yellow
Write-Host "  1. Authorize the Office 365 Outlook API connection (Portal > sign in as sender)."
Write-Host "  2. Security Copilot > Roles: assign Contributor to the UAMI."
Write-Host "  3. Grant the UAMI Microsoft Graph application permissions:"
Write-Host "       SecurityIncident.Read.All, SecurityEvents.Read.All,"
Write-Host "       ThreatIndicators.Read.All, IdentityRiskyUser.Read.All"
Write-Host "  4. Defender XDR Unified RBAC: assign 'Security data - read' to the UAMI."
Write-Host "  5. Sentinel workspace: assign 'Microsoft Sentinel Reader' to the UAMI."
Write-Host "  6. Upload agent/weekly-security-report.yaml in Security Copilot > Agents > Import."
Write-Host "  7. Manually trigger the Logic App to validate (./scripts/run-customer.ps1)."
