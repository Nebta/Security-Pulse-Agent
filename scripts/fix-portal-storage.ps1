# Re-enable public network access on the portal func's package storage account
# and restart the function host. Needed because an MCAPS Gov tenant policy
# flips publicNetworkAccess back to Disabled nightly, which breaks the
# Linux Consumption WEBSITE_RUN_FROM_PACKAGE URL fetch -> 0 functions loaded.
#
# Symptom this fixes: signing in to the portal shows "404 - Ask the operator
# to add your UPN to PORTAL_ALLOWED_UPNS" because /api/me returns 404 from
# the SWA edge (the linked function has no functions registered).
#
# Long-term fix: get a policy exemption for stsecpulseportfnepgwmpun, or move
# the func to Premium SKU with a private endpoint into the storage account.

[CmdletBinding()]
param(
  [string]$ResourceGroup = "rg-secpulse-portal",
  [string]$FuncName = "func-secpulse-portal-epgwmp",
  [string]$StorageAccount = "stsecpulseportfnepgwmpun",
  [hashtable[]]$CustomerStorage = @(
    @{ rg = "rg-secpulse-alpla"; sa = "stpulsealplahisxpz" },
    @{ rg = "rg-secpulse-spar";  sa = "stpulsesparwcsjrn"  }
  )
)

$ErrorActionPreference = "Stop"

Write-Host "Re-enabling publicNetworkAccess on $StorageAccount..."
az storage account update -g $ResourceGroup -n $StorageAccount `
  --public-network-access Enabled --query "publicNetworkAccess" -o tsv

foreach ($c in $CustomerStorage) {
  Write-Host ("Re-enabling publicNetworkAccess on customer SA {0}..." -f $c.sa)
  az storage account update -g $c.rg -n $c.sa --public-network-access Enabled --query "publicNetworkAccess" -o tsv
}

Write-Host "Restarting $FuncName..."
az functionapp restart -g $ResourceGroup -n $FuncName

Write-Host "Waiting 90s for host to load functions from the package URL..."
Start-Sleep -Seconds 90

$mk = az functionapp keys list -g $ResourceGroup -n $FuncName --query "masterKey" -o tsv
$resp = Invoke-WebRequest -Uri "https://$FuncName.azurewebsites.net/admin/functions" `
  -UseBasicParsing -Headers @{ "x-functions-key" = $mk }
$names = ($resp.Content | ConvertFrom-Json) | ForEach-Object { $_.name }
Write-Host ("Loaded {0} functions: {1}" -f $names.Count, ($names -join ", "))
if ($names.Count -lt 9) {
  Write-Warning "Expected at least 9 functions. Check WEBSITE_RUN_FROM_PACKAGE blob URL is reachable."
  exit 1
}
Write-Host "OK - portal API back online."
