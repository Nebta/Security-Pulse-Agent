<#
.SYNOPSIS
    Non-interactive onboarding driver for CI/CD.

.DESCRIPTION
    Backend-first Wave 7b entrypoint. Assumes:
      * infra/customers/<CustomerId>.parameters.json already exists
        (committed to the repo).
      * templates/customers/<CustomerId>/ already exists (or will
        inherit from _default on first run).
      * Caller is already logged in (az login or azure/login OIDC).

    Runs steps 2-7 of docs/ONBOARDING.md:
      2. Deploy infra (deploy.ps1)
      3. Grant Microsoft Graph + Defender ATP app perms  (best-effort)
      4. Grant Sentinel Reader + Log Analytics Reader at workspace scope
      5. Defender XDR Reader via sg-secpulse-defender-readers         (best-effort)
      6. Security Copilot Contributor + Cost Management Reader at sub scope
      7. Upload template assets to blob

    Step 8 (OAuth for O365 + Security Copilot connections) STILL
    requires a human and is emitted as a manual step in the summary.

    Steps that need Graph-admin privileges the OIDC SP might not have
    (step 3, step 5) are best-effort: failures are captured and surfaced
    in the JSON summary under `manualSteps` rather than aborting the
    whole run.

.PARAMETER CustomerId
    Uppercase short id, e.g. "ALPLA". Matches PORTAL_CUSTOMER_<id>.

.PARAMETER SubscriptionId
    Azure subscription to deploy into. Must match the sub encoded in
    the params file's sentinelWorkspaceResourceId if cross-sub isn't
    configured.

.PARAMETER SummaryPath
    Optional path to write a JSON summary. When running under GitHub
    Actions the caller should also append to $GITHUB_STEP_SUMMARY.

.EXAMPLE
    ./scripts/onboard-from-params.ps1 -CustomerId CONTOSO `
        -SubscriptionId 00000000-0000-0000-0000-000000000000
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $CustomerId,
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string] $RepoRoot     = (Resolve-Path "$PSScriptRoot/..").Path,
    [string] $SummaryPath,
    [switch] $SkipDeploy,
    [switch] $SkipRbac,
    [switch] $SkipGraphPerms,
    [switch] $SkipUpload
)

$ErrorActionPreference = 'Stop'

$paramFile   = Join-Path $RepoRoot "infra/customers/$CustomerId.parameters.json"
$templateDir = Join-Path $RepoRoot "templates/customers/$CustomerId"
$rgName      = "rg-secpulse-$($CustomerId.ToLower())"

if (-not (Test-Path $paramFile)) {
    throw "Parameters file not found: $paramFile. Commit it before running this workflow."
}

# Scaffold template dir from _default if the customer doesn't have one yet.
# (The wizard will commit per-customer templates; bare parameters-only
# commits should still deploy.)
$templateScaffolded = $false
if (-not (Test-Path $templateDir)) {
    Write-Host "==> Scaffolding template dir from _default (none committed for $CustomerId)"
    Copy-Item (Join-Path $RepoRoot "templates/customers/_default") $templateDir -Recurse
    $templateScaffolded = $true
}

$summary = [ordered]@{
    customerId     = $CustomerId
    subscriptionId = $SubscriptionId
    resourceGroup  = $rgName
    logicAppName   = "la-secpulse-$CustomerId"
    storageAccount = $null
    uamiPrincipalId = $null
    startedAt      = (Get-Date).ToUniversalTime().ToString('o')
    completed      = @()
    skipped        = @()
    manualSteps    = @()
    errors         = @()
    status         = 'running'
}

function Step($n, $msg) { Write-Host "`n=== Step $n : $msg ===" -ForegroundColor Cyan }
function Add-Manual([string]$action, [string]$reason) {
    $summary.manualSteps += [ordered]@{ action = $action; reason = $reason }
    Write-Warning "MANUAL STEP NEEDED: $action  ($reason)"
}
function Add-Done([string]$name)    { $summary.completed += $name; Write-Host "  [done] $name" -ForegroundColor Green }
function Add-Skipped([string]$name) { $summary.skipped   += $name; Write-Host "  [skip] $name" -ForegroundColor DarkGray }

try {
    az account set --subscription $SubscriptionId | Out-Null

    if ($templateScaffolded) {
        Add-Manual `
            "Commit per-customer templates to templates/customers/$CustomerId/ (currently scaffolded from _default; the deployed customer is using generic branding)" `
            "No templates/customers/$CustomerId/ directory was committed to the repo; the generic _default layout was used for the blob upload."
    }

    # -------- Step 2: deploy --------
    if ($SkipDeploy) {
        Add-Skipped 'deploy'
    } else {
        Step 2 'Deploy Azure infrastructure'
        & (Join-Path $PSScriptRoot 'deploy.ps1') `
            -SubscriptionId $SubscriptionId `
            -Location (Get-Content $paramFile | ConvertFrom-Json).parameters.location.value `
            -ParametersFile $paramFile
        if ($LASTEXITCODE -ne 0) { throw "deploy.ps1 exited $LASTEXITCODE" }
        Add-Done 'deploy'
    }

    # UAMI must exist after step 2 for everything downstream.
    $uamiPrincipalId = az identity show -g $rgName -n "uami-secpulse-$CustomerId" --query principalId -o tsv --only-show-errors
    if (-not $uamiPrincipalId) { throw "UAMI not found after deploy: uami-secpulse-$CustomerId in $rgName" }
    Write-Host "  UAMI principalId: $uamiPrincipalId"
    $summary.uamiPrincipalId = $uamiPrincipalId

    # -------- Step 3: Graph + Defender ATP app perms --------
    if ($SkipGraphPerms) {
        Add-Skipped 'graph-perms'
    } else {
        Step 3 'Grant Microsoft Graph + Defender ATP perms (best-effort)'
        try {
            & (Join-Path $PSScriptRoot 'grant-graph-perms.ps1') -UamiObjectId $uamiPrincipalId
            if ($LASTEXITCODE -ne 0) { throw "grant-graph-perms.ps1 exited $LASTEXITCODE" }
            Add-Done 'graph-perms'
        } catch {
            $errMsg = "$_"
            $summary.errors += [ordered]@{ step = 'graph-perms'; message = $errMsg }
            Add-Manual `
                "Run ./scripts/grant-graph-perms.ps1 -UamiObjectId $uamiPrincipalId  (locally, as a Global Admin or Privileged Role Admin)" `
                "grant-graph-perms.ps1 failed: $errMsg. Usually means the OIDC service principal lacks AppRoleAssignment.ReadWrite.All on Microsoft Graph."
        }
    }

    if (-not $SkipRbac) {
        $params = Get-Content $paramFile | ConvertFrom-Json
        $wsId   = $params.parameters.sentinelWorkspaceResourceId.value

        # -------- Step 4: workspace RBAC --------
        Step 4 'Grant Sentinel Reader + Log Analytics Reader at workspace scope'
        if (-not $wsId) {
            Add-Manual `
                "Set parameters.sentinelWorkspaceResourceId in infra/customers/$CustomerId.parameters.json, then grant 'Microsoft Sentinel Reader' and 'Log Analytics Reader' to UAMI (objectId $uamiPrincipalId) at that scope." `
                "sentinelWorkspaceResourceId is empty in the parameters file; cannot grant workspace-scoped RBAC."
        } else {
            foreach ($role in @('Microsoft Sentinel Reader','Log Analytics Reader')) {
                try {
                    $exists = (az role assignment list --assignee $uamiPrincipalId --scope $wsId --role $role -o json --only-show-errors | ConvertFrom-Json | Measure-Object).Count
                    if ($exists -gt 0) { Add-Skipped "workspace-rbac:$role"; continue }
                    az role assignment create `
                        --assignee-object-id $uamiPrincipalId `
                        --assignee-principal-type ServicePrincipal `
                        --role $role --scope $wsId --only-show-errors | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "az returned $LASTEXITCODE" }
                    Add-Done "workspace-rbac:$role"
                } catch {
                    $errMsg = "$_"
                    $summary.errors += [ordered]@{ step = "workspace-rbac:$role"; message = $errMsg }
                    Add-Manual `
                        "Grant '$role' to UAMI (objectId $uamiPrincipalId) at scope $wsId" `
                        "az role assignment create failed: $errMsg. Common causes: OIDC SP lacks User Access Administrator on the workspace, or the workspace resource id is wrong."
                }
            }
        }

        # -------- Step 5: Defender XDR group --------
        if ($SkipGraphPerms) {
            Add-Skipped 'defender-group'
        } else {
            Step 5 'Defender XDR Reader (sg-secpulse-defender-readers)'
            try {
                $grp = az ad group show --group 'sg-secpulse-defender-readers' --query id -o tsv 2>$null
                if (-not $grp) {
                    $grp = az ad group create --display-name 'sg-secpulse-defender-readers' --mail-nickname 'sg-secpulse-defender-readers' --query id -o tsv --only-show-errors
                    if (-not $grp) { throw "group create failed" }
                    Add-Manual `
                        "In security.microsoft.com -> Permissions -> Microsoft Defender XDR -> Roles, create 'SecPulse Reader' and assign to sg-secpulse-defender-readers." `
                        "First-time setup only: Defender role cannot be created via API."
                }
                $member = az ad group member check --group 'sg-secpulse-defender-readers' --member-id $uamiPrincipalId --query value -o tsv 2>$null
                if ($member -ne 'true') {
                    az ad group member add --group 'sg-secpulse-defender-readers' --member-id $uamiPrincipalId --only-show-errors | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "group member add returned $LASTEXITCODE" }
                }
                Add-Done 'defender-group'
            } catch {
                $errMsg = "$_"
                $summary.errors += [ordered]@{ step = 'defender-group'; message = $errMsg }
                Add-Manual `
                    "Add UAMI (objectId $uamiPrincipalId) to AAD group sg-secpulse-defender-readers" `
                    "az ad group command failed: $errMsg. Usually means the OIDC service principal lacks GroupMember.ReadWrite.All on Microsoft Graph."
            }
        }

        # -------- Step 6: subscription RBAC --------
        Step 6 'Security Copilot Contributor + Cost Management Reader at subscription scope'
        $subScope = "/subscriptions/$SubscriptionId"
        foreach ($role in @('Security Copilot Contributor','Cost Management Reader')) {
            try {
                $exists = (az role assignment list --assignee $uamiPrincipalId --scope $subScope --role $role -o json --only-show-errors | ConvertFrom-Json | Measure-Object).Count
                if ($exists -gt 0) { Add-Skipped "sub-rbac:$role"; continue }
                az role assignment create `
                    --assignee-object-id $uamiPrincipalId `
                    --assignee-principal-type ServicePrincipal `
                    --role $role --scope $subScope --only-show-errors | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "az returned $LASTEXITCODE" }
                Add-Done "sub-rbac:$role"
            } catch {
                $errMsg = "$_"
                $summary.errors += [ordered]@{ step = "sub-rbac:$role"; message = $errMsg }
                Add-Manual `
                    "Grant '$role' to UAMI (objectId $uamiPrincipalId) at scope $subScope" `
                    "az role assignment create failed: $errMsg. Common cause: OIDC SP lacks User Access Administrator / Role Based Access Control Administrator at subscription scope."
            }
        }
    }

    # -------- Step 7: templates --------
    if ($SkipUpload) {
        Add-Skipped 'template-upload'
    } else {
        Step 7 'Upload templates to blob'
        $sa = az resource list -g $rgName --resource-type 'Microsoft.Storage/storageAccounts' --query '[0].name' -o tsv --only-show-errors
        if (-not $sa) { throw "No storage account found in $rgName after deploy." }
        $summary.storageAccount = $sa

        # The MCAPS Gov tenant has a remediation policy that flips
        # publicNetworkAccess=Disabled on new storage accounts within
        # minutes of creation. Re-enable it right before the upload so
        # the CI runner (which is not on the VNet) can reach blob.
        $pna = az storage account show -g $rgName -n $sa --query publicNetworkAccess -o tsv --only-show-errors
        if ($pna -ne 'Enabled') {
            Write-Host "  publicNetworkAccess=$pna on $sa -> re-enabling for upload..."
            az storage account update -g $rgName -n $sa --public-network-access Enabled --only-show-errors | Out-Null
            Start-Sleep 10
        }

        & (Join-Path $PSScriptRoot 'upload-templates.ps1') -StorageAccount $sa -CustomerId $CustomerId
        if ($LASTEXITCODE -ne 0) { throw "upload-templates.ps1 exited $LASTEXITCODE" }
        Add-Done 'template-upload'
    }

    # -------- Step 8: OAuth (always manual) --------
    foreach ($conn in @("office365-$CustomerId","securitycopilot-$CustomerId")) {
        $cid = "/subscriptions/$SubscriptionId/resourceGroups/$rgName/providers/Microsoft.Web/connections/$conn"
        Add-Manual `
            "Authorize API connection: https://portal.azure.com/#@/resource$cid/edit  (click Authorize -> sign in -> Save)" `
            "OAuth requires a human. Cannot be done by the OIDC service principal."
    }

    if ($summary.errors.Count -gt 0) {
        $summary.status = 'succeeded-with-errors'
    } elseif ($summary.manualSteps.Count -gt 0) {
        $summary.status = 'succeeded-with-manual-steps'
    } else {
        $summary.status = 'succeeded'
    }
} catch {
    $summary.status = 'failed'
    $summary.errors += [ordered]@{ step = 'fatal'; message = "$_" }
    Write-Error $_
} finally {
    $summary.finishedAt = (Get-Date).ToUniversalTime().ToString('o')
    $json = $summary | ConvertTo-Json -Depth 6
    Write-Host "`n===== ONBOARDING SUMMARY =====" -ForegroundColor Cyan
    Write-Host $json
    if ($SummaryPath) {
        $json | Set-Content -Path $SummaryPath -Encoding utf8
    }
}

if ($summary.status -eq 'failed') { exit 1 }
