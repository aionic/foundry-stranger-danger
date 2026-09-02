<#
.SYNOPSIS
    Finds a region that can actually provision Azure AI Search right now.

.DESCRIPTION
    Azure AI Search capacity is constrained independently of everything else and
    there is no API to query it - the only reliable signal is attempting a
    create. Search can use var.search_location independently from the Foundry
    account/model region.

    This provisions a throwaway service per region/SKU in a temporary resource
    group, records the outcome, and deletes it immediately. Failures return in
    seconds; successes take a minute or two.

    The first available region/SKU is returned as the Terraform
    search_location/search_sku pair.

.PARAMETER Regions
    Candidate regions, in preference order.

.PARAMETER Skus
    SKUs to try per region.
#>
[CmdletBinding()]
param(
    [string[]]$Regions = @('eastus', 'westus2', 'swedencentral', 'uksouth', 'westus3', 'southcentralus', 'westeurope', 'canadaeast'),
    [string[]]$Skus = @('basic', 'standard')
)

$ErrorActionPreference = 'Continue'
$rnd = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
$tempRg = "rg-searchcap-$rnd"
$results = @()

Write-Host "Temporary resource group: $tempRg`n" -ForegroundColor DarkGray

try {
    az group create -n $tempRg -l $Regions[0] --only-show-errors -o none 2>$null
    if ($LASTEXITCODE -ne 0) { throw "Could not create temporary resource group '$tempRg'." }

    :regionLoop
    foreach ($region in $Regions) {
        foreach ($sku in $Skus) {
            $regionToken = $region -replace '[^a-z0-9]', ''
            $name = "srchcap-$sku-$regionToken-$rnd"
            $output = az search service create -n $name -g $tempRg -l $region --sku $sku `
                --partition-count 1 --replica-count 1 -o none 2>&1
            $ok = ($LASTEXITCODE -eq 0)

            if ($ok) {
                Write-Host ("{0,-16} {1,-10} AVAILABLE" -f $region, $sku) -ForegroundColor Green
                az search service delete -n $name -g $tempRg --yes -o none 2>$null
            }
            else {
                $code = if ($output -match '(ResourcesForSkuUnavailable|InsufficientResourcesAvailable)') { $Matches[1] } else { 'error' }
                Write-Host ("{0,-16} {1,-10} {2}" -f $region, $sku, $code) -ForegroundColor Red
            }

            $results += [pscustomobject]@{
                region         = $region
                sku            = $sku
                search         = if ($ok) { 'available' } else { 'unavailable' }
            }

            if ($ok) { break regionLoop }
        }
    }
}
finally {
    Write-Host "`nCleaning up $tempRg ..." -ForegroundColor DarkGray
    az group delete -n $tempRg --yes --no-wait -o none 2>$null
}

$winner = $results | Where-Object { $_.search -eq 'available' } | Select-Object -First 1

Write-Host "`n==== Summary ====" -ForegroundColor Cyan
$results | Format-Table -AutoSize

if ($winner) {
    Write-Host "Use:" -ForegroundColor Green
    Write-Host "  search_location = `"$($winner.region)`""
    Write-Host "  search_sku      = `"$($winner.sku)`""
}
else {
    Write-Host 'No candidate region could provision Azure AI Search.' -ForegroundColor Red
    Write-Host 'Search is only present to satisfy the capability host vectorStoreConnections'
    Write-Host 'requirement - the agents perform no retrieval. Consider retrying later.'
}
