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

$files = @('template.html','section.html','config.json')
foreach ($f in $files) {
    $local = Join-Path $src $f
    if (-not (Test-Path $local)) { throw "Missing $local" }
}

Write-Host "==> Uploading templates for customer '$CustomerId' to $StorageAccount/$Container/$CustomerId/" -ForegroundColor Cyan

foreach ($f in $files) {
    $local = Join-Path $src $f
    $blob  = "$CustomerId/$f"
    az storage blob upload `
        --account-name $StorageAccount `
        --auth-mode login `
        --container-name $Container `
        --name $blob `
        --file $local `
        --overwrite `
        --only-show-errors | Out-Null
    Write-Host "  uploaded $blob" -ForegroundColor Green
}

Write-Host ""
Write-Host "Done. Logic App will fetch these on the next run." -ForegroundColor Green
