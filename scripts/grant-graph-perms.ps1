#requires -Version 7
<#
.SYNOPSIS
  Grants application permissions to a User-Assigned Managed Identity (UAMI)
  on Microsoft Graph and on the Windows Defender ATP API service principal,
  via the Azure CLI's az rest. Uses the existing `az login` session.

.DESCRIPTION
  The signed-in user must hold one of:
    - Privileged Role Administrator
    - Application Administrator (for app role assignments to MSIs)
    - Global Administrator

  Defaults grant the permissions required by the Security Pulse Logic App.

.EXAMPLE
  ./grant-graph-perms.ps1 -UamiObjectId 9cda0aa9-0fce-4baf-95e4-36fb9dfb2f26
#>
param(
  [Parameter(Mandatory)] [string]$UamiObjectId,
  [string[]]$GraphPermissions = @(
    'SecurityIncident.Read.All',
    'SecurityEvents.Read.All',
    'ThreatIndicators.Read.All',
    'IdentityRiskyUser.Read.All',
    'IdentityRiskEvent.Read.All',
    'DeviceManagementManagedDevices.Read.All',
    'ThreatIntelligence.Read.All',
    # SecurityAlert.Read.All is required for the Purview DLP section
    # (Graph /security/alerts_v2 filtered by serviceSource =
    # microsoftDataLossPrevention). Skip if no customer enables purviewDlp.
    'SecurityAlert.Read.All',
    # Files.ReadWrite.All is only required if any customer config sets
    # `pdfAttachment: true` — used to upload report HTML to OneDrive and
    # request a PDF render via Graph drive convert. Skip if PDF is not used.
    'Files.ReadWrite.All'
  ),
  [string[]]$DefenderAtpPermissions = @(
    'Vulnerability.Read.All'
  )
)

$ErrorActionPreference = 'Stop'

function Grant-AppRoles {
  param(
    [string]$ResourceAppId,
    [string]$ResourceLabel,
    [string[]]$Permissions
  )

  $sp = az rest --method GET `
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$ResourceAppId'" `
    -o json 2>$null | ConvertFrom-Json
  $resourceSp = $sp.value[0]
  if (-not $resourceSp) {
    Write-Warning "Service principal for $ResourceLabel ($ResourceAppId) not found in tenant; skipping."
    return
  }
  Write-Host "`n>>> $ResourceLabel ($($resourceSp.id))" -ForegroundColor Cyan

  $roles = $resourceSp.appRoles |
    Where-Object { $Permissions -contains $_.value -and $_.allowedMemberTypes -contains 'Application' }

  foreach ($r in $roles) {
    $body = @{ principalId = $UamiObjectId; resourceId = $resourceSp.id; appRoleId = $r.id } |
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

  $missing = $Permissions | Where-Object { $_ -notin ($roles | ForEach-Object value) }
  foreach ($m in $missing) {
    Write-Warning "$ResourceLabel does not expose application role '$m' in this tenant."
  }
}

# Microsoft Graph - appId is constant across tenants
Grant-AppRoles `
  -ResourceAppId  '00000003-0000-0000-c000-000000000000' `
  -ResourceLabel  'Microsoft Graph' `
  -Permissions    $GraphPermissions

# WindowsDefenderATP (api.securitycenter.microsoft.com) - first-party MDE app
Grant-AppRoles `
  -ResourceAppId  'fc780465-2017-40d4-a0c5-307022471b92' `
  -ResourceLabel  'WindowsDefenderATP' `
  -Permissions    $DefenderAtpPermissions

Write-Host "`n--- Current app role assignments on UAMI ---" -ForegroundColor Cyan
$cur = az rest --method GET `
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$UamiObjectId/appRoleAssignments" `
  -o json 2>$null | ConvertFrom-Json
$cur.value | ForEach-Object {
  $sp = az rest --method GET `
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($_.resourceId)?`$select=displayName,appRoles" `
    -o json 2>$null | ConvertFrom-Json
  $role = $sp.appRoles | Where-Object id -eq $_.appRoleId
  "{0,-25} {1}" -f $sp.displayName, $role.value
}

