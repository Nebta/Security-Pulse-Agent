<#
.SYNOPSIS
    Manually triggers a Security Pulse Agent Logic App for one customer.

.DESCRIPTION
    Resolves the Logic App's HTTP trigger callback URL for the named customer
    and POSTs to it, starting a single run. Useful as the deterministic
    alternative to the (now removed) weekly Recurrence trigger.

.PARAMETER CustomerId
    Customer short ID (matches the resource-name suffix, e.g. ALPLA, SPAR).

.PARAMETER SubscriptionId
    Azure subscription that hosts the customer's resource group.

.PARAMETER ResourceGroupName
    Optional override. Defaults to "rg-secpulse-<lowercase customerId>".

.PARAMETER LogicAppName
    Optional override. Defaults to "la-secpulse-<CustomerId>".

.EXAMPLE
    ./scripts/run-customer.ps1 -CustomerId ALPLA -SubscriptionId 00000000-0000-0000-0000-000000000000

.EXAMPLE
    ./scripts/run-customer.ps1 -CustomerId SPAR  -SubscriptionId 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $CustomerId,
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string] $ResourceGroupName,
    [string] $LogicAppName,
    [string] $TriggerName = 'manual'
)

$ErrorActionPreference = 'Stop'

if (-not $ResourceGroupName) { $ResourceGroupName = "rg-secpulse-$($CustomerId.ToLower())" }
if (-not $LogicAppName)      { $LogicAppName      = "la-secpulse-$CustomerId" }

Write-Host "==> Setting subscription $SubscriptionId" -ForegroundColor Cyan
az account set --subscription $SubscriptionId | Out-Null

$listUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Logic/workflows/$LogicAppName/triggers/$TriggerName/listCallbackUrl?api-version=2019-05-01"
Write-Host "==> Resolving callback URL for trigger '$TriggerName'" -ForegroundColor Cyan
$cb = az rest --method post --uri $listUri | ConvertFrom-Json
if (-not $cb.value) { throw "Could not resolve callback URL for $LogicAppName/$TriggerName." }

Write-Host "==> Triggering run" -ForegroundColor Cyan
$resp = Invoke-WebRequest -Method Post -Uri $cb.value -UseBasicParsing -TimeoutSec 60
Write-Host "    HTTP $($resp.StatusCode) $($resp.StatusDescription)" -ForegroundColor Green
$runId = $resp.Headers['x-ms-workflow-run-id']
if ($runId -is [array]) { $runId = $runId[0] }
if ($runId) {
    Write-Host "    Run id: $runId" -ForegroundColor Green
    $statusUri = "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Logic/workflows/$LogicAppName/runs/$runId" + '?api-version=2019-05-01'
    Write-Host ""
    Write-Host "Tail status with:" -ForegroundColor Yellow
    Write-Host "  az rest --method get --uri `"$statusUri`" --query `"{status:properties.status,end:properties.endTime}`""
}
