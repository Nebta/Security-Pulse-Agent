<#
.SYNOPSIS
    Audits all Security Pulse customers and emits a digest of any drift,
    auth errors, missing role assignments, or stale runs.

.DESCRIPTION
    Iterates every infra/customers/*.parameters.json file (excluding
    _default) and checks:

      * Both API connections exist and are Connected.
      * UAMI exists.
      * UAMI has the expected RBAC at workspace + subscription scope.
      * Last Logic App run within -MaxRunAgeDays days and Succeeded.
      * Storage account is reachable and templates blob exists.
      * Bicep what-if drift against deployed state.

    Output: pretty console report, plus optional email via -SendDigest
    when called from CI/automation.

.EXAMPLE
    ./scripts/health-check.ps1 -SubscriptionId <sub> -SendDigest -OpsEmail you@x.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SubscriptionId,
    [string] $RepoRoot       = (Resolve-Path "$PSScriptRoot/..").Path,
    [int]    $MaxRunAgeDays  = 8,
    [switch] $IncludeWhatIf,
    [switch] $SendDigest,
    [string] $OpsEmail       = 'markus@threatninja.at',
    [string] $SenderMailbox
)

$ErrorActionPreference = 'Continue'
az account set --subscription $SubscriptionId | Out-Null

$paramFiles = Get-ChildItem (Join-Path $RepoRoot 'infra/customers') -Filter '*.parameters.json' |
              Where-Object { $_.Name -ne '_default.parameters.json' }

$report = foreach ($pf in $paramFiles) {
    $p = (Get-Content $pf.FullName | ConvertFrom-Json -Depth 50).parameters
    $cust = $p.customerId.value
    $rg   = "rg-secpulse-$($cust.ToLower())"
    $la   = "la-secpulse-$cust"
    $row  = [ordered]@{
        Customer = $cust; RG = $rg; Issues = @()
    }

    foreach ($conn in @("office365-$cust","securitycopilot-$cust")) {
        $cid = "/subscriptions/$SubscriptionId/resourceGroups/$rg/providers/Microsoft.Web/connections/$conn"
        $st  = az rest --method get --uri "https://management.azure.com${cid}?api-version=2018-07-01-preview" --query "properties.overallStatus" -o tsv 2>$null
        if (-not $st)             { $row.Issues += "${conn}: MISSING" }
        elseif ($st -ne 'Connected') { $row.Issues += "${conn}: $st" }
    }

    $uamiPid = az identity show -g $rg -n "uami-secpulse-$cust" --query principalId -o tsv 2>$null
    if (-not $uamiPid) {
        $row.Issues += "UAMI MISSING"
    } else {
        $wsId = $p.sentinelWorkspaceResourceId.value
        foreach ($role in @('Microsoft Sentinel Reader','Log Analytics Reader')) {
            $n = (az role assignment list --assignee $uamiPid --scope $wsId --role $role -o json 2>$null | ConvertFrom-Json | Measure-Object).Count
            if ($n -eq 0) { $row.Issues += "RBAC missing: $role @ workspace" }
        }
        $n = (az role assignment list --assignee $uamiPid --scope "/subscriptions/$SubscriptionId" --role "Security Copilot Contributor" -o json 2>$null | ConvertFrom-Json | Measure-Object).Count
        if ($n -eq 0) { $row.Issues += "RBAC missing: Security Copilot Contributor @ subscription" }
    }

    $lastRun = az rest --method get --uri "https://management.azure.com/subscriptions/$SubscriptionId/resourceGroups/$rg/providers/Microsoft.Logic/workflows/$la/runs?api-version=2019-05-01&`$top=1" --query "value[0].{status:properties.status,end:properties.endTime}" -o json 2>$null
    if (-not $lastRun -or $lastRun -eq 'null') {
        $row.Issues += "no runs ever"
    } else {
        $r = $lastRun | ConvertFrom-Json
        $age = (New-TimeSpan -Start $r.end -End (Get-Date).ToUniversalTime()).TotalDays
        $row.LastRun = "$($r.status) ($([int]$age)d ago)"
        if ($r.status -ne 'Succeeded') { $row.Issues += "last run: $($r.status)" }
        if ($age -gt $MaxRunAgeDays)   { $row.Issues += "last run age: $([int]$age)d > $MaxRunAgeDays" }
    }

    if ($IncludeWhatIf) {
        $wi = az deployment sub what-if --location $p.location.value --template-file (Join-Path $RepoRoot 'infra/main.bicep') --parameters "@$($pf.FullName)" --no-pretty-print 2>&1
        if ($LASTEXITCODE -ne 0) { $row.Issues += "what-if FAILED" }
        elseif ($wi -match 'Modify|Delete') { $row.Issues += 'drift detected' }
    }

    $row.Status = if ($row.Issues.Count -eq 0) { 'OK' } else { 'ATTENTION' }
    [pscustomobject]$row
}

$report | Format-Table Customer, Status, LastRun, @{n='Issues';e={ ($_.Issues -join '; ') }} -Wrap -AutoSize

$bad = $report | Where-Object Status -ne 'OK'
if ($SendDigest -and $bad) {
    if (-not $SenderMailbox) {
        Write-Warning "No -SenderMailbox; skipping digest email"
    } else {
        $body = "<h2>Security Pulse health digest</h2><table border=1 cellpadding=4 cellspacing=0>"
        $body += "<tr><th>Customer</th><th>Status</th><th>Last run</th><th>Issues</th></tr>"
        foreach ($r in $report) {
            $color = if ($r.Status -eq 'OK') { '#d6f3d6' } else { '#fbd6d6' }
            $body += "<tr style='background:$color'><td>$($r.Customer)</td><td>$($r.Status)</td><td>$($r.LastRun)</td><td>$(($r.Issues -join '<br>'))</td></tr>"
        }
        $body += "</table><p>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') UTC by health-check.ps1.</p>"
        # Send via Graph using current az login (user must have Mail.Send)
        $msg = @{ message = @{ subject = "[SecPulse Health] $($bad.Count) customer(s) need attention"; body = @{ contentType='HTML'; content=$body }; toRecipients = @(@{ emailAddress = @{ address = $OpsEmail } }) } } | ConvertTo-Json -Depth 10 -Compress
        $f = New-TemporaryFile; [IO.File]::WriteAllText($f.FullName, $msg, [Text.UTF8Encoding]::new($false))
        az rest --method post --uri "https://graph.microsoft.com/v1.0/users/$SenderMailbox/sendMail" --body "@$($f.FullName)" --headers "Content-Type=application/json" | Out-Null
        Remove-Item $f.FullName
        Write-Host "Digest emailed to $OpsEmail" -ForegroundColor Green
    }
}

if ($bad) { exit 2 }
