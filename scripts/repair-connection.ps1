<#
.SYNOPSIS
    Deletes and recreates an API connection with the correct connector-specific
    `parameterValueSet` shape, then refreshes the workflow's $connections cache.

.DESCRIPTION
    Hard-won connector-specific rules:

      Office 365 (`office365`):
          MUST NOT have `parameterValueSet` at all.
          Otherwise Send_Email fails with HTTP 400
          "Unexpected connection parameter set name: 'oauth'".

      Security Copilot (`Securitycopilot`):
          MUST have `parameterValueSet = { name: 'Oauth', values: {} }`.
          Otherwise listConsentLinks returns
          "No consent server information was associated with this request"
          and the connection is stuck in Error state.

    After deleting + recreating the connection ARM resource, this script
    re-PUTs the Logic App workflow so its cached connection token endpoint
    refreshes (otherwise runs fail with
    "Error from token exchange: The connection (...) is not found").

    The actual OAuth authorization (sign-in) is still a manual step: open
    the printed Portal URL, click Authorize -> sign in -> Save.

.EXAMPLE
    # Recreate broken Copilot connection for SPAR
    ./scripts/repair-connection.ps1 -CustomerId SPAR -Connector Copilot -SubscriptionId <guid>

.EXAMPLE
    # Recreate broken O365 connection for SPAR
    ./scripts/repair-connection.ps1 -CustomerId SPAR -Connector O365 -SubscriptionId <guid>
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $CustomerId,
    [Parameter(Mandatory)] [ValidateSet('O365','Copilot')] [string] $Connector,
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string] $Location          = 'westeurope',
    [string] $ResourceGroupName,
    [switch] $SkipWorkflowRePut
)

$ErrorActionPreference = 'Stop'

if (-not $ResourceGroupName) { $ResourceGroupName = "rg-secpulse-$($CustomerId.ToLower())" }

az account set --subscription $SubscriptionId | Out-Null

if ($Connector -eq 'O365') {
    $connName     = "office365-$CustomerId"
    $managedApi   = 'office365'
    $displayName  = "O365 Outlook (Security Pulse - $CustomerId)"
    $paramSet     = $null    # MUST be absent
} else {
    $connName     = "securitycopilot-$CustomerId"
    $managedApi   = 'Securitycopilot'
    $displayName  = "Security Copilot (Security Pulse - $CustomerId)"
    $paramSet     = @{ name = 'Oauth'; values = @{} }
}

$cid = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Web/connections/$connName"

Write-Host "==> Deleting connection $connName" -ForegroundColor Cyan
az resource delete --ids $cid 2>&1 | Out-Null

$props = @{
    displayName = $displayName
    api = @{ id = "/subscriptions/$SubscriptionId/providers/Microsoft.Web/locations/$Location/managedApis/$managedApi" }
}
if ($paramSet) { $props.parameterValueSet = $paramSet }

$body = @{
    location   = $Location
    kind       = 'V1'
    properties = $props
} | ConvertTo-Json -Depth 10 -Compress

$f = New-TemporaryFile
[IO.File]::WriteAllText($f.FullName, $body, [Text.UTF8Encoding]::new($false))
try {
    Write-Host "==> Recreating connection $connName (parameterValueSet=$([bool]$paramSet))" -ForegroundColor Cyan
    az rest --method put `
        --uri "https://management.azure.com$($cid)?api-version=2018-07-01-preview" `
        --body "@$($f.FullName)" `
        --headers "Content-Type=application/json" `
        --query "properties.overallStatus" -o tsv | Out-Null
} finally {
    Remove-Item $f.FullName -ErrorAction SilentlyContinue
}

if (-not $SkipWorkflowRePut) {
    & "$PSScriptRoot/repair-workflow.ps1" -CustomerId $CustomerId -SubscriptionId $SubscriptionId
}

Write-Host ""
Write-Host "==> NEXT: authorize the connection in the Portal" -ForegroundColor Yellow
Write-Host "  1. Portal -> API Connections -> $connName -> Edit API connection"
Write-Host "  2. Click Authorize -> sign in -> Save"
Write-Host ""
Write-Host "  Direct link (note: the .com/#@/resource/.../edit URL often lands on portal home;"
Write-Host "  if so, navigate manually as above):"
Write-Host "  https://portal.azure.com/#@/resource$cid/edit"
Write-Host ""
Write-Host "  Verify with:"
Write-Host "  az rest --method get --uri `"https://management.azure.com$($cid)?api-version=2018-07-01-preview`" --query `"properties.overallStatus`" -o tsv"
