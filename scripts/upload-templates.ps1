<#
.SYNOPSIS
    Uploads a customer's HTML template (template.html, section.html, config.json)
    from templates/customers/<CustomerId>/ to the templates blob container.

.EXAMPLE
    ./scripts/upload-templates.ps1 -StorageAccount stpulsedefault123abc -CustomerId default
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $StorageAccount,
    [Parameter(Mandatory)] [string] $CustomerId,
    [string] $Container    = 'templates',
    [string] $TemplatesDir = "$PSScriptRoot/../templates/customers"
)

$ErrorActionPreference = 'Stop'

$src = Join-Path $TemplatesDir $CustomerId
if (-not (Test-Path $src)) { throw "Template folder not found: $src" }

# Required: at least one of template.html / template-tech.html, plus section.html and config.json.
$required = @('section.html','config.json')
foreach ($f in $required) {
    if (-not (Test-Path (Join-Path $src $f))) { throw "Missing required file: $f in $src" }
}
if (-not (Test-Path (Join-Path $src 'template.html')) -and `
    -not (Test-Path (Join-Path $src 'template-tech.html'))) {
    throw "Customer '$CustomerId' must have either template.html or template-tech.html in $src"
}

# Collect everything we'll upload: templates, sections, config, optional logos.
$uploadList = @()
foreach ($pattern in @('template*.html','section*.html','config*.json','logo.*')) {
    $uploadList += Get-ChildItem -Path $src -File -Filter $pattern -ErrorAction SilentlyContinue
}
$uploadList = $uploadList | Sort-Object FullName -Unique

if (-not $uploadList) { throw "Nothing to upload from $src" }

Write-Host "==> Uploading $($uploadList.Count) file(s) for customer '$CustomerId' to $StorageAccount/$Container/$CustomerId/" -ForegroundColor Cyan

# Pre-flight: warn early if the storage account blocks public network access. Uploads from a
# workstation outside the private endpoint would 403 silently otherwise (only-show-errors swallows
# the warning text returned to stderr).
$pna = az storage account show --name $StorageAccount --query publicNetworkAccess -o tsv 2>$null
if ($pna -eq 'Disabled') {
    Write-Warning "Storage account '$StorageAccount' has publicNetworkAccess=Disabled. Uploads from this workstation will fail unless you are on its VNet/private endpoint. Temporarily enable public access (e.g. 'az storage account update -n $StorageAccount -g <rg> --public-network-access Enabled --default-action Deny --bypass AzureServices' plus an IP rule for your address) and disable it again after templates are uploaded."
}

$failed = @()
foreach ($file in $uploadList) {
    $blob = "$CustomerId/$($file.Name)"
    $err = $null
    & az storage blob upload `
        --account-name $StorageAccount `
        --auth-mode login `
        --container-name $Container `
        --name $blob `
        --file $file.FullName `
        --overwrite `
        --only-show-errors 2>&1 | Tee-Object -Variable err | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  FAILED  $blob" -ForegroundColor Red
        if ($err) { $err | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkRed } }
        $failed += $blob
    } else {
        Write-Host "  uploaded $blob" -ForegroundColor Green
    }
}

Write-Host ""
if ($failed.Count -gt 0) {
    throw "Upload failed for $($failed.Count)/$($uploadList.Count) blob(s): $($failed -join ', '). See messages above (often caused by publicNetworkAccess=Disabled on the storage account)."
}
Write-Host "Done. Logic App will fetch these on the next run." -ForegroundColor Green
