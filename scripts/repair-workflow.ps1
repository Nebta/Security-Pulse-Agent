<#
.SYNOPSIS
    Re-PUTs a customer's Logic App workflow definition directly via ARM REST,
    bypassing the (sometimes-hanging) Bicep workflow deployment.

.DESCRIPTION
    Use cases:
      * Bicep workflow PUT has been hanging > 5 min during deploy.
      * An API connection was deleted+recreated; the workflow's $connections
        token cache must be refreshed by re-PUTting the workflow.

    Reads infra/modules/workflow.json, substitutes parameters from the
    customer's parameters file, and PUTs to the live Logic App.

.EXAMPLE
    ./scripts/repair-workflow.ps1 -CustomerId SPAR -SubscriptionId <guid>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $CustomerId,
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string] $ResourceGroupName,
    [string] $LogicAppName,
    [string] $WorkflowFile = "$PSScriptRoot/../infra/modules/workflow.json"
)

$ErrorActionPreference = 'Stop'

if (-not $ResourceGroupName) { $ResourceGroupName = "rg-secpulse-$($CustomerId.ToLower())" }
if (-not $LogicAppName)      { $LogicAppName      = "la-secpulse-$CustomerId" }

az account set --subscription $SubscriptionId | Out-Null

$laId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Logic/workflows/$LogicAppName"
$la = az resource show --ids $laId -o json | ConvertFrom-Json -Depth 100

# Take the live $parameters (preserves connection ids + customer params) and
# replace the definition with the latest workflow.json from the repo.
$newDef = Get-Content $WorkflowFile -Raw | ConvertFrom-Json -Depth 100

$body = @{
    location = $la.location
    identity = $la.identity
    properties = @{
        state      = 'Enabled'
        definition = $newDef
        parameters = $la.properties.parameters
    }
} | ConvertTo-Json -Depth 100 -Compress

$f = New-TemporaryFile
[IO.File]::WriteAllText($f.FullName, $body, [Text.UTF8Encoding]::new($false))
try {
    Write-Host "==> PUT workflow $LogicAppName (definition from $WorkflowFile)" -ForegroundColor Cyan
    az rest --method put `
        --uri "https://management.azure.com$($laId)?api-version=2019-05-01" `
        --body "@$($f.FullName)" `
        --headers "Content-Type=application/json" `
        --query "properties.provisioningState" -o tsv
} finally {
    Remove-Item $f.FullName -ErrorAction SilentlyContinue
}
