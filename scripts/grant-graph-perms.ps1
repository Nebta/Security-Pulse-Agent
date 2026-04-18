#requires -Version 7
<#
.SYNOPSIS
  Grants Microsoft Graph application permissions to a User-Assigned Managed
  Identity (UAMI) via the Azure CLI's az rest. Uses the existing `az login`
  session — no separate Microsoft.Graph PowerShell module install required.

.DESCRIPTION
  The signed-in user must hold one of:
    - Privileged Role Administrator
    - Application Administrator (for app role assignments to MSIs)
    - Global Administrator

.EXAMPLE
  ./grant-graph-perms.ps1 -UamiObjectId 9cda0aa9-0fce-4baf-95e4-36fb9dfb2f26
#>
param(
  [Parameter(Mandatory)] [string]$UamiObjectId,
  [string[]]$Permissions = @(
    'SecurityIncident.Read.All',
    'SecurityEvents.Read.All',
    'ThreatIndicators.Read.All',
    'IdentityRiskyUser.Read.All'
  )
)

$ErrorActionPreference = 'Stop'

$graph = az rest --method GET `
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'" `
  -o json 2>$null | ConvertFrom-Json
$graphSp = $graph.value[0]
if (-not $graphSp) { throw 'Could not resolve the Microsoft Graph service principal.' }

$wanted = $graphSp.appRoles |
  Where-Object { $Permissions -contains $_.value -and $_.allowedMemberTypes -contains 'Application' }

foreach ($r in $wanted) {
  $body = @{ principalId = $UamiObjectId; resourceId = $graphSp.id; appRoleId = $r.id } |
    ConvertTo-Json -Compress
  $tmp = New-TemporaryFile
  Set-Content $tmp $body -NoNewline
  $res = az rest --method POST `
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$UamiObjectId/appRoleAssignments" `
    --headers "Content-Type=application/json" `
    --body "@$tmp" 2>&1
  Remove-Item $tmp -ErrorAction SilentlyContinue
  if ($LASTEXITCODE -eq 0) {
    Write-Host "GRANTED: $($r.value)" -ForegroundColor Green
  } elseif ($res -match 'Permission being assigned already exists') {
    Write-Host "EXISTS:  $($r.value)" -ForegroundColor Yellow
  } else {
    Write-Host ("FAIL:    {0} -> {1}" -f $r.value, $res) -ForegroundColor Red
  }
}

Write-Host '--- Current Graph app role assignments on UAMI ---' -ForegroundColor Cyan
$cur = az rest --method GET `
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$UamiObjectId/appRoleAssignments" `
  -o json 2>$null | ConvertFrom-Json
$cur.value | ForEach-Object {
  ($graphSp.appRoles | Where-Object id -eq $_.appRoleId).value
}
