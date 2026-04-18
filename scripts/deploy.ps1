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
    [string] $DeploymentName = "secpulse-$(Get-Date -Format 'yyyyMMddHHmmss')",
    [int]    $WorkflowHangTimeoutSec = 360
)

$ErrorActionPreference = 'Stop'

Write-Host "==> Setting subscription $SubscriptionId" -ForegroundColor Cyan
az account set --subscription $SubscriptionId | Out-Null

Write-Host "==> Validating template" -ForegroundColor Cyan
az deployment sub validate `
    --location $Location `
    --template-file $TemplateFile `
    --parameters "@$ParametersFile" | Out-Null

$paramObj   = Get-Content $ParametersFile | ConvertFrom-Json
$customerId = $paramObj.parameters.customerId.value
$rgName     = "rg-secpulse-$($customerId.ToLower())"
$laName     = "la-secpulse-$customerId"

Write-Host "==> Deploying ($DeploymentName)" -ForegroundColor Cyan
$deployJob = Start-Job -ScriptBlock {
    param($name,$loc,$tmpl,$params)
    az deployment sub create --name $name --location $loc --template-file $tmpl --parameters "@$params" --output json 2>&1
} -ArgumentList $DeploymentName,$Location,$TemplateFile,$ParametersFile

$start = Get-Date
$workflowHangHandled = $false
while ($deployJob.State -eq 'Running') {
    Start-Sleep 30
    $elapsed = (New-TimeSpan -Start $start -End (Get-Date)).TotalSeconds
    Write-Host "    waiting ($([int]$elapsed)s elapsed)" -ForegroundColor DarkGray

    if ($elapsed -gt $WorkflowHangTimeoutSec -and -not $workflowHangHandled) {
        $logicAppDep = az deployment group show -g $rgName -n logicapp --query "properties.provisioningState" -o tsv 2>$null
        if ($logicAppDep -eq 'Running') {
            Write-Warning "Inner 'logicapp' deployment has been running >$WorkflowHangTimeoutSec s. Cancelling and switching to direct workflow PUT."
            az deployment group cancel -g $rgName -n logicapp 2>&1 | Out-Null
            Start-Sleep 15
            Stop-Job $deployJob -ErrorAction SilentlyContinue
            $workflowHangHandled = $true
            break
        }
    }
}

if (-not $workflowHangHandled) {
    $output = Receive-Job $deployJob
    Remove-Job $deployJob
    if ($LASTEXITCODE -ne 0) { Write-Host $output; throw "Deployment failed." }
    $result = $output | ConvertFrom-Json
    $out = $result.properties.outputs
} else {
    Remove-Job $deployJob -Force
    Write-Host "==> Direct workflow PUT (bypass hung Bicep)" -ForegroundColor Cyan
    & "$PSScriptRoot/repair-workflow.ps1" -CustomerId $customerId -SubscriptionId $SubscriptionId
    # Synthesise outputs from RG
    $sa = az resource list -g $rgName --resource-type "Microsoft.Storage/storageAccounts" --query "[0].name" -o tsv
    $uami = az resource show -g $rgName --name "uami-secpulse-$customerId" --resource-type "Microsoft.ManagedIdentity/userAssignedIdentities" --query "id" -o tsv
    $out = [pscustomobject]@{
        logicAppName               = @{ value = $laName }
        userAssignedIdentityResourceId = @{ value = $uami }
        templatesStorageAccountName    = @{ value = $sa }
        o365ConnectionResourceId       = @{ value = "/subscriptions/$SubscriptionId/resourceGroups/$rgName/providers/Microsoft.Web/connections/office365-$customerId" }
    }
}

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
Write-Host "==> Post-deploy steps (manual; see docs/ONBOARDING.md §4-12)" -ForegroundColor Yellow
Write-Host "  4. Grant Graph perms to UAMI            (./scripts/grant-graph-perms.ps1)"
Write-Host "  5. Grant Sentinel + LA Reader at workspace scope"
Write-Host "  6. Grant Defender XDR Reader (via sg-secpulse-defender-readers group)"
Write-Host "  7. Grant Security Copilot Contributor at subscription scope"
Write-Host "  8. Upload template assets               (./scripts/upload-templates.ps1)"
Write-Host "  9. Authorize O365 + Copilot connections (./scripts/repair-connection.ps1 if portal save fails)"
Write-Host " 10. Smoke test                           (./scripts/run-customer.ps1)"
