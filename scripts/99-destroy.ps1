<#
.SYNOPSIS
    Tears down the validation environment completely.

.DESCRIPTION
    Terraform destroy alone is not sufficient. Two things need handling:

      1. The Foundry account is managed by azapi, so azurerm's
         purge_soft_delete_on_destroy feature does not apply to it. Deleting it
         leaves a soft-deleted account that continues to hold the name and, in
         network-injected deployments, blocks VNet deletion. It must be purged
         explicitly.

      2. A soft-deleted account's resource group is at index 8 of its resource
         ID. The 'resourceGroup' property on that object is the provider
         namespace, not the resource group, which is a genuinely easy mistake.

    Probe service principals are Terraform-managed and removed by destroy; this
    script verifies that and cleans up any strays.

.PARAMETER Force
    Skip the confirmation prompt.

.PARAMETER SkipRefresh
    Build the destroy plan from the last Terraform state without refreshing
    resources first. Use only after a successful no-drift plan or verified run,
    when policy denies provider key-list operations needed by refresh.

.PARAMETER DeleteResourceGroupFallback
    If Terraform cannot delete individual resources because provider actions are
    denied, delete the exact dedicated lab resource group. Terraform state is
    cleared only after Azure confirms that the group no longer exists.
#>
[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$SkipRefresh,
    [switch]$DeleteResourceGroupFallback
)

$ErrorActionPreference = 'Stop'
$terraformDir = Join-Path $PSScriptRoot '..\terraform'
$modernContainersMarker = Join-Path $terraformDir 'modern-containers.auto.tfvars.json'

if (-not $Force) {
    Write-Host 'This destroys the entire validation environment.' -ForegroundColor Yellow
    $answer = Read-Host 'Type DESTROY to continue'
    if ($answer -ne 'DESTROY') { Write-Host 'Aborted.'; exit 1 }
}

# Capture identifiers before state is gone.
$accountName = terraform -chdir="$terraformDir" output -raw foundry_account_name 2>$null
$rg = terraform -chdir="$terraformDir" output -raw resource_group_name 2>$null
$stateSubscriptionId = terraform -chdir="$terraformDir" output -raw subscription_id 2>$null
$probeIdentities = terraform -chdir="$terraformDir" output -json probe_identities 2>$null | ConvertFrom-Json
$probeApplicationIds = @($probeIdentities.PSObject.Properties | ForEach-Object { $_.Value.client_id })

if (-not $accountName -or -not $rg -or -not $stateSubscriptionId) {
    $state = terraform "-chdir=$terraformDir" show -json 2>$null | ConvertFrom-Json
    $stateResources = @($state.values.root_module.resources)

    $accountName = ($stateResources | Where-Object address -eq 'azapi_resource.foundry').values.name
    $rg = ($stateResources | Where-Object address -eq 'azurerm_resource_group.main').values.name
    $stateSubscriptionId = ($stateResources | Where-Object address -eq 'data.azurerm_client_config.current').values.subscription_id
    $probeApplicationIds = @(
        $stateResources |
            Where-Object type -eq 'azuread_application' |
            ForEach-Object { $_.values.client_id }
    )
}

if (-not $accountName -or -not $rg -or -not $stateSubscriptionId) {
    throw 'Could not recover deployment identifiers from Terraform outputs or structured state. Refusing an unscoped teardown.'
}

$subId = az account show --query id -o tsv
if ($subId -ne $stateSubscriptionId) {
    throw "Azure CLI is using subscription '$subId', but Terraform state targets '$stateSubscriptionId'."
}

# A steady-state hardened deployment requires this generated marker. Recreate
# it if necessary so the fail-closed Terraform guard permits a destroy plan.
if (-not (Test-Path $modernContainersMarker)) {
    @{ modern_containers_exist = $true } | ConvertTo-Json | Set-Content $modernContainersMarker -Encoding utf8
}

$cleanupFailures = @()

Write-Host "`n=== 1/3  terraform destroy ===" -ForegroundColor Cyan
Write-Host 'Capability hosts delete before their projects, which delete before the account.' -ForegroundColor DarkGray
$destroyArguments = @("-chdir=$terraformDir", 'destroy', '-auto-approve', '-no-color')
if ($SkipRefresh) {
    $destroyArguments += '-refresh=false'
    Write-Host 'Using the last verified Terraform state; provider refresh is disabled.' -ForegroundColor Yellow
}
& terraform @destroyArguments
$destroyFailed = $LASTEXITCODE -ne 0
if ($destroyFailed -and $DeleteResourceGroupFallback) {
    Write-Warning "Terraform could not delete every resource. Deleting dedicated lab resource group '$rg'."
    az group delete --name $rg --yes --only-show-errors
    $destroyFailed = $LASTEXITCODE -ne 0
    if ($destroyFailed) {
        Write-Warning 'Resource-group fallback also reported an error. Continuing with residue checks.'
    }
}
elseif ($destroyFailed) {
    Write-Warning 'Destroy reported errors. Continuing to the purge step so the account name is not left held.'
}
if ($destroyFailed) {
    $cleanupFailures += 'Terraform destroy reported an error.'
}

Write-Host "`n=== 2/3  Purging soft-deleted Foundry accounts ===" -ForegroundColor Cyan
$deleted = az cognitiveservices account list-deleted -o json 2>$null | ConvertFrom-Json
$targets = @($deleted | Where-Object { $_.name -eq $accountName })

if (-not $targets) {
    Write-Host '  Nothing to purge.' -ForegroundColor Green
}
foreach ($acct in $targets) {
    # NOT $acct.resourceGroup - that returns the provider namespace.
    $acctRg = ($acct.id -split '/')[8]
    $acctLoc = $acct.location
    Write-Host "  Purging $($acct.name) in $acctRg / $acctLoc ..."
    az cognitiveservices account purge --name $acct.name --resource-group $acctRg --location $acctLoc --only-show-errors
    if ($LASTEXITCODE -eq 0) { Write-Host '    purged' -ForegroundColor Green }
    else {
        Write-Warning "    purge failed for $($acct.name); a network-injected account can sit in Deleting for 15-20 minutes. Retry later."
        $cleanupFailures += "Soft-deleted Foundry account '$($acct.name)' was not purged."
    }
}

Write-Host "`n=== 3/3  Checking for stray probe identities ===" -ForegroundColor Cyan
if (-not $probeApplicationIds) {
    Write-Host '  None found.' -ForegroundColor Green
}
foreach ($applicationId in $probeApplicationIds) {
    $existingApplicationId = az ad app show --id $applicationId --query appId -o tsv 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $existingApplicationId) { continue }

    Write-Host "  Deleting probe application $applicationId"
    az ad app delete --id $applicationId --only-show-errors
    if ($LASTEXITCODE -ne 0) { $cleanupFailures += "Probe application '$applicationId' was not deleted." }
}

# The resource group should be gone; report it if not.
$rgExists = az group exists --name $rg 2>$null
if ($rgExists -ne 'false') {
    Write-Warning "Resource group '$rg' still exists. Inspect it before re-deploying - a leftover resource will collide."
    $cleanupFailures += "Resource group '$rg' still exists."
}

$accountStillDeleted = @(az cognitiveservices account list-deleted -o json 2>$null | ConvertFrom-Json | Where-Object { $_.name -eq $accountName })
if ($accountStillDeleted) {
    $cleanupFailures += "Foundry account '$accountName' remains soft-deleted."
}

if ($DeleteResourceGroupFallback -and $rgExists -eq 'false' -and -not $cleanupFailures) {
    $stateAddresses = @(terraform "-chdir=$terraformDir" state list 2>$null)
    if ($LASTEXITCODE -ne 0) {
        $cleanupFailures += 'Terraform state could not be inspected after resource-group deletion.'
    }
    elseif ($stateAddresses.Count -gt 0) {
        Write-Host "  Azure confirms the lab group is absent; removing $($stateAddresses.Count) stale Terraform state entries." -ForegroundColor DarkGray
        terraform "-chdir=$terraformDir" state rm @stateAddresses | Out-Null
        if ($LASTEXITCODE -ne 0) {
            $cleanupFailures += 'Stale Terraform state entries could not be removed.'
        }
    }
}

$remainingState = @(terraform "-chdir=$terraformDir" state list 2>$null)
if ($LASTEXITCODE -ne 0) {
    $cleanupFailures += 'Terraform state could not be inspected during final verification.'
}
elseif ($remainingState.Count -gt 0) {
    $cleanupFailures += "Terraform state still contains $($remainingState.Count) entries."
}

if ($cleanupFailures) {
    Write-Host "`nTeardown incomplete:" -ForegroundColor Red
    $cleanupFailures | Sort-Object -Unique | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Remove-Item $modernContainersMarker -Force -ErrorAction SilentlyContinue
Write-Host "`nTeardown complete." -ForegroundColor Green
