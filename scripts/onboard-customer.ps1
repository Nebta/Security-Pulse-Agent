<#
.SYNOPSIS
    One-shot onboarding for a new Security Pulse customer.

.DESCRIPTION
    Runs every step of docs/ONBOARDING.md in sequence:

      1. Scaffolds infra/customers/<CUST>.parameters.json (if missing)
      2. Scaffolds templates/customers/<CUST>/ from _default (if missing)
      3. Deploys Azure infrastructure (deploy.ps1)
      4. Grants Microsoft Graph + Defender ATP app perms to the UAMI
      5. Grants Sentinel Reader + Log Analytics Reader at workspace scope
      6. Adds the UAMI to sg-secpulse-defender-readers (creates group if missing)
      7. Grants Security Copilot Contributor + Cost Management Reader at
         subscription scope
      8. Uploads template assets to blob
      9. Opens the Portal Edit blades for both API connections so the
         operator can authorize them (still manual; OAuth requires a human)

    Idempotent: re-running on an existing customer skips steps that are
    already done.

.EXAMPLE
    ./scripts/onboard-customer.ps1 -CustomerId CONTOSO `
        -SubscriptionId <sub-guid> `
        -RecipientEmail ciso@contoso.com `
        -SenderMailbox secpulse@yourtenant.onmicrosoft.com `
        -SentinelWorkspaceResourceId /subscriptions/.../workspaces/contoso-sentinel
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $CustomerId,
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string] $Location = 'westeurope',
    [string] $RecipientEmail,
    [string] $SenderMailbox,
    [string] $SentinelWorkspaceResourceId,
    [string] $OpsAlertEmail,
    [int]    $CostCapMonthlyEur = 50,
    [ValidateSet('en','de')] [string] $ReportLanguage = 'en',
    [string] $RepoRoot = (Resolve-Path "$PSScriptRoot/..").Path,
    [switch] $SkipScaffold,
    [switch] $SkipDeploy,
    [switch] $SkipRbac,
    [switch] $SkipUpload,
    [switch] $SkipAuthorize
)

$ErrorActionPreference = 'Stop'

function Step($n, $msg) { Write-Host "`n=== Step $n : $msg ===" -ForegroundColor Cyan }

$paramFile    = Join-Path $RepoRoot "infra/customers/$CustomerId.parameters.json"
$templateDir  = Join-Path $RepoRoot "templates/customers/$CustomerId"
$rgName       = "rg-secpulse-$($CustomerId.ToLower())"

az account set --subscription $SubscriptionId | Out-Null

# -------- Step 1: parameters file --------
if (-not $SkipScaffold) {
    Step 1 "Scaffold parameters file"
    if (Test-Path $paramFile) {
        Write-Host "  exists: $paramFile (skipping scaffold)"
    } else {
        if (-not $RecipientEmail -or -not $SenderMailbox -or -not $SentinelWorkspaceResourceId) {
            throw "First-time scaffold needs -RecipientEmail, -SenderMailbox and -SentinelWorkspaceResourceId."
        }
        $defaultFile = Join-Path $RepoRoot "infra/customers/_default.parameters.json"
        $obj = Get-Content $defaultFile | ConvertFrom-Json -Depth 100
        $obj.parameters.customerId.value         = $CustomerId
        $obj.parameters.resourceGroupName.value  = $rgName
        $obj.parameters.location.value           = $Location
        $obj.parameters.recipientEmail.value     = $RecipientEmail
        $obj.parameters.senderMailbox.value      = $SenderMailbox
        $obj.parameters.sentinelWorkspaceResourceId.value = $SentinelWorkspaceResourceId
        # Add new wave-1 params if the _default file doesn't have them
        if (-not $obj.parameters.PSObject.Properties.Match('costCapMonthlyEur')) {
            $obj.parameters | Add-Member -NotePropertyName costCapMonthlyEur -NotePropertyValue ([pscustomobject]@{ value = $CostCapMonthlyEur })
        } else { $obj.parameters.costCapMonthlyEur.value = $CostCapMonthlyEur }
        if (-not $obj.parameters.PSObject.Properties.Match('opsAlertEmail')) {
            $obj.parameters | Add-Member -NotePropertyName opsAlertEmail -NotePropertyValue ([pscustomobject]@{ value = (if ($OpsAlertEmail) { $OpsAlertEmail } else { $RecipientEmail }) })
        }
        if (-not $obj.parameters.PSObject.Properties.Match('reportLanguage')) {
            $obj.parameters | Add-Member -NotePropertyName reportLanguage -NotePropertyValue ([pscustomobject]@{ value = $ReportLanguage })
        }
        $obj | ConvertTo-Json -Depth 100 | Out-File -Encoding utf8 $paramFile
        Write-Host "  created: $paramFile" -ForegroundColor Green
    }

    if (-not (Test-Path $templateDir)) {
        Copy-Item (Join-Path $RepoRoot "templates/customers/_default") $templateDir -Recurse
        Write-Host "  scaffolded template folder: $templateDir" -ForegroundColor Green
        Write-Host "  IMPORTANT: edit templates/customers/$CustomerId/config.json before running again." -ForegroundColor Yellow
    } else {
        Write-Host "  exists: $templateDir (skipping)"
    }
}

# -------- Step 2: deploy --------
if (-not $SkipDeploy) {
    Step 2 "Deploy Azure infrastructure"
    & (Join-Path $PSScriptRoot 'deploy.ps1') -SubscriptionId $SubscriptionId -Location $Location -ParametersFile $paramFile
}

$uamiPrincipalId = az identity show -g $rgName -n "uami-secpulse-$CustomerId" --query principalId -o tsv
if (-not $uamiPrincipalId) { throw "UAMI not found after deploy: uami-secpulse-$CustomerId in $rgName" }
Write-Host "  UAMI principalId: $uamiPrincipalId"

# -------- Step 3: RBAC --------
if (-not $SkipRbac) {
    Step 3 "Grant Microsoft Graph + Defender ATP perms"
    & (Join-Path $PSScriptRoot 'grant-graph-perms.ps1') -UamiObjectId $uamiPrincipalId

    $params = Get-Content $paramFile | ConvertFrom-Json
    $wsId = $params.parameters.sentinelWorkspaceResourceId.value

    Step 4 "Grant Sentinel Reader + Log Analytics Reader at workspace scope"
    foreach ($role in @('Microsoft Sentinel Reader','Log Analytics Reader')) {
        $exists = (az role assignment list --assignee $uamiPrincipalId --scope $wsId --role $role -o json | ConvertFrom-Json | Measure-Object).Count
        if ($exists -gt 0) {
            Write-Host "  EXISTS: $role"
        } else {
            az role assignment create --assignee-object-id $uamiPrincipalId --assignee-principal-type ServicePrincipal --role $role --scope $wsId --only-show-errors | Out-Null
            Write-Host "  GRANTED: $role" -ForegroundColor Green
        }
    }

    Step 5 "Defender XDR Reader (sg-secpulse-defender-readers)"
    $grp = az ad group show --group "sg-secpulse-defender-readers" --query id -o tsv 2>$null
    if (-not $grp) {
        $grp = az ad group create --display-name "sg-secpulse-defender-readers" --mail-nickname "sg-secpulse-defender-readers" --query id -o tsv
        Write-Host "  created group $grp" -ForegroundColor Green
        Write-Host "  ACTION REQUIRED: in security.microsoft.com -> Permissions -> Microsoft Defender XDR -> Roles," -ForegroundColor Yellow
        Write-Host "    create role 'SecPulse Reader' (Security operations: read) and assign to this group." -ForegroundColor Yellow
    }
    $member = az ad group member check --group "sg-secpulse-defender-readers" --member-id $uamiPrincipalId --query value -o tsv 2>$null
    if ($member -ne 'true') {
        az ad group member add --group "sg-secpulse-defender-readers" --member-id $uamiPrincipalId --only-show-errors | Out-Null
        Write-Host "  added UAMI to sg-secpulse-defender-readers" -ForegroundColor Green
    } else {
        Write-Host "  EXISTS: UAMI already in sg-secpulse-defender-readers"
    }

    Step 6 "Security Copilot Contributor + Cost Management Reader at subscription scope"
    $subScope = "/subscriptions/$SubscriptionId"
    foreach ($role in @('Security Copilot Contributor','Cost Management Reader')) {
        $exists = (az role assignment list --assignee $uamiPrincipalId --scope $subScope --role $role -o json | ConvertFrom-Json | Measure-Object).Count
        if ($exists -gt 0) {
            Write-Host "  EXISTS: $role"
        } else {
            az role assignment create --assignee-object-id $uamiPrincipalId --assignee-principal-type ServicePrincipal --role $role --scope $subScope --only-show-errors | Out-Null
            Write-Host "  GRANTED: $role" -ForegroundColor Green
        }
    }
}

# -------- Step 7: upload templates --------
if (-not $SkipUpload) {
    Step 7 "Upload templates to blob"
    $sa = az resource list -g $rgName --resource-type "Microsoft.Storage/storageAccounts" --query "[0].name" -o tsv
    & (Join-Path $PSScriptRoot 'upload-templates.ps1') -StorageAccount $sa -CustomerId $CustomerId
}

# -------- Step 8: authorize --------
if (-not $SkipAuthorize) {
    Step 8 "Authorize API connections (manual)"
    foreach ($conn in @("office365-$CustomerId","securitycopilot-$CustomerId")) {
        $cid = "/subscriptions/$SubscriptionId/resourceGroups/$rgName/providers/Microsoft.Web/connections/$conn"
        Write-Host "  Open: https://portal.azure.com/#@/resource$cid/edit"
        Write-Host "    -> Click Authorize -> sign in -> Save"
        Start-Process "https://portal.azure.com/#@/resource$cid/edit"
        Read-Host "  Press ENTER once $conn shows Connected"
    }
    Write-Host "`nIf save hangs > 5 min, see docs/ONBOARDING.md sections 9-10 for designer fallback." -ForegroundColor Yellow
}

Write-Host "`n==================================================================" -ForegroundColor Green
Write-Host " Onboarding complete. Smoke test with:" -ForegroundColor Green
Write-Host "   ./scripts/run-customer.ps1 -CustomerId $CustomerId -SubscriptionId $SubscriptionId" -ForegroundColor Green
Write-Host "==================================================================" -ForegroundColor Green
