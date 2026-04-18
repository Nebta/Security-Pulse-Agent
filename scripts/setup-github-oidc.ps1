<#
.SYNOPSIS
  One-shot setup of GitHub Actions -> Azure federated credential for the
  Security Pulse Agent repo. Idempotent.

.DESCRIPTION
  Creates (or reuses) an App Registration + service principal, assigns
  Contributor + User Access Administrator at subscription scope, adds three
  federated credentials (pull_request, main branch, tag v*), grants the SP
  Microsoft Graph Mail.Send (so weekly-ops.yml can send the digest), and
  prints the three values you paste into GitHub repo secrets.

.PARAMETER GitHubOrg
  GitHub org/user that owns the repo. Default: Nebta

.PARAMETER GitHubRepo
  Repo name. Default: Security-Pulse-Agent

.PARAMETER AppName
  App registration display name. Default: gh-secpulse-deploy

.EXAMPLE
  ./scripts/setup-github-oidc.ps1
#>
[CmdletBinding()]
param(
    [string]$GitHubOrg  = 'Nebta',
    [string]$GitHubRepo = 'Security-Pulse-Agent',
    [string]$AppName    = 'gh-secpulse-deploy'
)

$ErrorActionPreference = 'Stop'

function Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Ok($msg)   { Write-Host "    $msg" -ForegroundColor Green }

Step "Resolving subscription / tenant from current az login"
$subId    = az account show --query id       -o tsv
$tenantId = az account show --query tenantId -o tsv
if (-not $subId) { throw "Not logged in. Run 'az login' first." }
Ok "subscription = $subId"
Ok "tenant       = $tenantId"

# ---------------------------------------------------------------------------
Step "Ensuring App Registration '$AppName' exists"
$appId = az ad app list --display-name $AppName --query "[0].appId" -o tsv
if (-not $appId) {
    $appId = az ad app create --display-name $AppName --query appId -o tsv
    Ok "Created appId = $appId"
} else {
    Ok "Reusing  appId = $appId"
}

Step "Ensuring service principal exists"
$spId = az ad sp list --filter "appId eq '$appId'" --query "[0].id" -o tsv
if (-not $spId) {
    $spId = az ad sp create --id $appId --query id -o tsv
    Ok "Created spId = $spId"
} else {
    Ok "Reusing  spId = $spId"
}

# ---------------------------------------------------------------------------
Step "Assigning subscription-scope RBAC"
$scope = "/subscriptions/$subId"
foreach ($role in @('Contributor','User Access Administrator')) {
    $existing = az role assignment list --assignee $appId --scope $scope --role $role -o json | ConvertFrom-Json
    if (@($existing).Count -gt 0) {
        Ok "$role already assigned"
    } else {
        az role assignment create --assignee $appId --scope $scope --role $role --only-show-errors | Out-Null
        Ok "Granted $role"
    }
}

# ---------------------------------------------------------------------------
Step "Adding federated credentials (no client secret needed)"

$subjects = @(
    @{ name='gh-pr';   subject="repo:$GitHubOrg/$($GitHubRepo):pull_request" },
    @{ name='gh-main'; subject="repo:$GitHubOrg/$($GitHubRepo):ref:refs/heads/main" },
    @{ name='gh-tag';  subject="repo:$GitHubOrg/$($GitHubRepo):ref:refs/tags/v*" },
    @{ name='gh-env-prod'; subject="repo:$GitHubOrg/$($GitHubRepo):environment:prod" }
)

$existingFics = az ad app federated-credential list --id $appId --query "[].name" -o tsv
foreach ($s in $subjects) {
    if ($existingFics -contains $s.name) {
        Ok "FIC '$($s.name)' already present"
        continue
    }
    $body = @{
        name      = $s.name
        issuer    = 'https://token.actions.githubusercontent.com'
        subject   = $s.subject
        audiences = @('api://AzureADTokenExchange')
    } | ConvertTo-Json -Compress
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value $body -Encoding utf8
    az ad app federated-credential create --id $appId --parameters "@$tmp" --only-show-errors | Out-Null
    Remove-Item $tmp -Force
    Ok "Created FIC '$($s.name)' -> $($s.subject)"
}

# ---------------------------------------------------------------------------
Step "Granting Microsoft Graph 'Mail.Send' (application permission)"
$graphAppId        = '00000003-0000-0000-c000-000000000000'   # MS Graph
$mailSendRoleId    = 'b633e1c5-b582-4048-a93e-9f11b44c7e96'   # Mail.Send (app)

# Add app role to the App Registration's requiredResourceAccess
$current = az ad app show --id $appId --query "requiredResourceAccess" -o json | ConvertFrom-Json
$graphBlock = $current | Where-Object { $_.resourceAppId -eq $graphAppId }
$alreadyHasIt = $graphBlock -and ($graphBlock.resourceAccess | Where-Object { $_.id -eq $mailSendRoleId })
if ($alreadyHasIt) {
    Ok "Mail.Send already requested"
} else {
    az ad app permission add --id $appId --api $graphAppId `
        --api-permissions "$mailSendRoleId=Role" --only-show-errors | Out-Null
    Ok "Requested Mail.Send"
}

# Admin-consent (grant the app role on the SP)
try {
    az ad app permission grant --id $appId --api $graphAppId --scope "Mail.Send" --only-show-errors 2>$null | Out-Null
} catch { }
# The reliable consent path: assign app role directly via Graph
$graphSpId = az ad sp list --filter "appId eq '$graphAppId'" --query "[0].id" -o tsv
$existingGrants = az rest --method get `
    --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignments" `
    -o json | ConvertFrom-Json
$alreadyGranted = @($existingGrants.value | Where-Object { $_.appRoleId -eq $mailSendRoleId }).Count -gt 0
if ($alreadyGranted) {
    Ok "Mail.Send admin consent already granted"
} else {
    $body = @{
        principalId = $spId
        resourceId  = $graphSpId
        appRoleId   = $mailSendRoleId
    } | ConvertTo-Json -Compress
    $tmp = New-TemporaryFile
    Set-Content -Path $tmp -Value $body -Encoding utf8
    az rest --method post `
        --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$spId/appRoleAssignments" `
        --headers "Content-Type=application/json" `
        --body "@$tmp" --only-show-errors | Out-Null
    Remove-Item $tmp -Force
    Ok "Granted Mail.Send (admin consent)"
}

# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host " Paste these into:" -ForegroundColor Yellow
Write-Host "  https://github.com/$GitHubOrg/$GitHubRepo/settings/secrets/actions" -ForegroundColor Yellow
Write-Host "============================================================" -ForegroundColor Yellow
Write-Host ""
Write-Host "  AZURE_CLIENT_ID         = $appId"
Write-Host "  AZURE_TENANT_ID         = $tenantId"
Write-Host "  AZURE_SUBSCRIPTION_ID   = $subId"
Write-Host ""
Write-Host "Also add (free-text):"
Write-Host "  OPS_ALERT_EMAIL         = markus@threatninja.at"
Write-Host "  SENDER_MAILBOX          = <the mailbox the digest sends FROM>"
Write-Host ""
Write-Host "Then create environment 'prod':"
Write-Host "  https://github.com/$GitHubOrg/$GitHubRepo/settings/environments"
Write-Host ""
Write-Host "Test it:"
Write-Host "  - Open a trivial PR  -> pr-validate.yml runs"
Write-Host "  - 'Run workflow'     -> Actions tab -> 'Weekly ops digest' -> Run workflow"
Write-Host ""
