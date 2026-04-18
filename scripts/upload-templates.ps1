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

foreach ($file in $uploadList) {
    $blob = "$CustomerId/$($file.Name)"
    az storage blob upload `
        --account-name $StorageAccount `
        --auth-mode login `
        --container-name $Container `
        --name $blob `
        --file $file.FullName `
        --overwrite `
        --only-show-errors | Out-Null
    Write-Host "  uploaded $blob" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. Logic App will fetch these on the next run." -ForegroundColor Green
