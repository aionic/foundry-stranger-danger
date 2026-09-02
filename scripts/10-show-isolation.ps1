<#
.SYNOPSIS
    Inventories the real container layout and the exact RBAC scopes behind it.

.DESCRIPTION
    Answers the first two of the three isolation questions:

      1. Storage layout  - which containers exist, and which project owns each
      2. Authorization   - what scope each grant actually carries

    Container names are DISCOVERED and correlated back to each project's
    internalId, never assumed. If Microsoft ever changes the naming convention
    this script keeps telling the truth and the docs become the thing that is
    wrong, which is the correct way round.

    Question 3 (is it enforced?) is answered by 11-test-cross-access.ps1.

.NOTES
    Read-only. Safe to run repeatedly.
#>
[CmdletBinding()]
param(
    [string]$EvidenceDir = (Join-Path $PSScriptRoot '..\evidence')
)

$ErrorActionPreference = 'Stop'
$terraformDir = Join-Path $PSScriptRoot '..\terraform'
. (Join-Path $PSScriptRoot 'EvidenceContract.ps1')
$runId = if ($env:FOUNDRY_EVIDENCE_RUN_ID) {
    $env:FOUNDRY_EVIDENCE_RUN_ID
}
else {
    New-EvidenceRunId
}

function Get-TerraformOutputs {
    $json = terraform -chdir="$terraformDir" output -json | ConvertFrom-Json
    $result = @{}
    foreach ($p in $json.PSObject.Properties) { $result[$p.Name] = $p.Value.value }
    return $result
}

Write-Host 'Reading Terraform outputs...' -ForegroundColor Cyan
$tf = Get-TerraformOutputs

$rg = $tf.resource_group_name
$cosmosAccount = $tf.cosmos_account_name
$cosmosDb = $tf.cosmos_database_name
$storageAccount = $tf.storage_account_name
$searchService = $tf.search_service_name
$subId = $tf.subscription_id

# Map internalId (and its dashed GUID form) back to a project name.
$ownerByInternalId = @{}
$ownerByGuid = @{}
foreach ($p in $tf.projects.PSObject.Properties) {
    $ownerByInternalId[$p.Value.internal_id.ToLower()] = $p.Name
    $ownerByGuid[$p.Value.guid.ToLower()] = $p.Name
}

function Resolve-Owner {
    param([string]$ContainerName)
    $lower = $ContainerName.ToLower()
    foreach ($guid in $ownerByGuid.Keys) {
        if ($lower.StartsWith("$guid-")) { return $ownerByGuid[$guid] }
    }
    foreach ($id in $ownerByInternalId.Keys) {
        if ($lower.StartsWith("$id-")) { return $ownerByInternalId[$id] }
    }
    return '<unattributed>'
}

# ---------------------------------------------------------------------------
# Cosmos containers
# ---------------------------------------------------------------------------
Write-Host "`nCosmos containers in $cosmosDb" -ForegroundColor Cyan

$cosmosContainers = @()
$dbExists = az cosmosdb sql database exists --account-name $cosmosAccount --resource-group $rg --name $cosmosDb -o tsv 2>$null
if ($dbExists -eq 'true') {
    $raw = az cosmosdb sql container list --account-name $cosmosAccount --resource-group $rg --database-name $cosmosDb -o json | ConvertFrom-Json
    foreach ($c in $raw) {
        $cosmosContainers += [pscustomobject]@{
            name    = $c.name
            owner   = Resolve-Owner $c.name
            runtime = if ($c.name -match '-(agent-definitions-v1|run-state-v1)$') { 'modern' } else { 'classic' }
        }
    }
}
else {
    Write-Warning "Database '$cosmosDb' does not exist yet. Capability hosts may still be provisioning."
}

$cosmosContainers | Sort-Object owner, name | Format-Table -AutoSize

# ---------------------------------------------------------------------------
# Blob containers
# ---------------------------------------------------------------------------
Write-Host "Blob containers in $storageAccount" -ForegroundColor Cyan

$blobContainers = @()
$rawBlob = az storage container list --account-name $storageAccount --auth-mode login -o json 2>$null | ConvertFrom-Json
foreach ($c in $rawBlob) {
    $blobContainers += [pscustomobject]@{
        name  = $c.name
        owner = Resolve-Owner $c.name
    }
}
$blobContainers | Sort-Object owner, name | Format-Table -AutoSize

# ---------------------------------------------------------------------------
# Cosmos data-plane role assignments
#
# This is where the documented-vs-hardened difference becomes visible: look at
# whether 'scope' ends at /dbs/enterprise_memory or continues to /colls/<name>.
# ---------------------------------------------------------------------------
Write-Host 'Cosmos data-plane (SQL) role assignments' -ForegroundColor Cyan

$cosmosRoles = @()
$rawRoles = az cosmosdb sql role assignment list --account-name $cosmosAccount --resource-group $rg -o json 2>$null | ConvertFrom-Json
foreach ($r in $rawRoles) {
    $scopeSuffix = $r.scope -replace '^.*/databaseAccounts/[^/]+', ''
    if ([string]::IsNullOrWhiteSpace($scopeSuffix)) { $scopeSuffix = '<account>' }

    $granularity = if ($scopeSuffix -match '/colls/') { 'container' }
    elseif ($scopeSuffix -match '/dbs/') { 'DATABASE (spans all projects)' }
    else { 'ACCOUNT (spans all projects)' }

    $cosmosRoles += [pscustomobject]@{
        principalId = $r.principalId
        scope       = $scopeSuffix
        granularity = $granularity
        container   = if ($scopeSuffix -match '/colls/(.+)$') { $Matches[1] } else { '' }
    }
}

# Attribute each principal to a project, probe or the deployer.
$principalLabels = @{}
foreach ($p in $tf.projects.PSObject.Properties) {
    $principalLabels[$p.Value.principal_id] = "project:$($p.Name)"
}
$probes = terraform -chdir="$terraformDir" output -json probe_identities 2>$null | ConvertFrom-Json
if ($probes) {
    foreach ($p in $probes.PSObject.Properties) { $principalLabels[$p.Value.object_id] = "probe:$($p.Name)" }
}

$cosmosRoles | ForEach-Object {
    $label = if ($principalLabels.ContainsKey($_.principalId)) { $principalLabels[$_.principalId] } else { 'other/deployer' }
    $_ | Add-Member -NotePropertyName principal -NotePropertyValue $label -PassThru
} | Sort-Object principal, container | Format-Table principal, granularity, container -AutoSize

# ---------------------------------------------------------------------------
# ARM role assignments on the shared data resources
# ---------------------------------------------------------------------------
Write-Host 'ARM role assignments on Cosmos / Storage / Search' -ForegroundColor Cyan

$armRoles = @()
$resourceScopes = [ordered]@{
    cosmos = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.DocumentDB/databaseAccounts/$cosmosAccount"
    storage = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Storage/storageAccounts/$storageAccount"
    search = "/subscriptions/$subId/resourceGroups/$rg/providers/Microsoft.Search/searchServices/$searchService"
}
$allArmAssignmentsJson = az role assignment list --all -o json --only-show-errors
if ($LASTEXITCODE -ne 0 -or -not $allArmAssignmentsJson) {
    throw 'Failed to list Azure role assignments for the authorization inventory.'
}
$allArmAssignments = @($allArmAssignmentsJson | ConvertFrom-Json)

foreach ($resourceName in $resourceScopes.Keys) {
    $scopeId = $resourceScopes[$resourceName]
    $raw = @($allArmAssignments | Where-Object {
            $assignmentScope = "$($_.scope)".TrimEnd('/')
            $resourceScope = $scopeId.TrimEnd('/')
            $assignmentScope -eq $resourceScope -or
            $assignmentScope.StartsWith("$resourceScope/", [System.StringComparison]::OrdinalIgnoreCase) -or
            $resourceScope.StartsWith("$assignmentScope/", [System.StringComparison]::OrdinalIgnoreCase)
        })
    foreach ($r in $raw) {
        $label = if ($principalLabels.ContainsKey($r.principalId)) { $principalLabels[$r.principalId] } else { 'other/deployer' }
        $shortScope = $r.scope -replace "^/subscriptions/$subId/resourceGroups/$rg/providers/", ''
        $isDirect = $r.scope.TrimEnd('/') -eq $scopeId.TrimEnd('/')
        $isInherited = $scopeId.TrimEnd('/').StartsWith("$($r.scope.TrimEnd('/'))/", [System.StringComparison]::OrdinalIgnoreCase)
        $armRoles += [pscustomobject]@{
            principal           = $label
            resource            = $resourceName
            role                = $r.roleDefinitionName
            scope               = $shortScope
            granularity         = if ($isInherited) { 'INHERITED (spans resource)' } elseif ($shortScope -match '/containers/|/indexes/') { 'child resource' } else { 'ACCOUNT (spans all projects)' }
            is_direct           = $isDirect
            is_inherited        = $isInherited
            condition           = if ($r.condition) { 'yes' } else { 'no' }
            condition_version   = $r.conditionVersion
            condition_expression = $r.condition
        }
    }
}
$armRoles | Sort-Object principal, role | Format-Table principal, role, granularity, scope -AutoSize

# ---------------------------------------------------------------------------
# Persist
# ---------------------------------------------------------------------------
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null

$report = [ordered]@{
    schema_version     = $EvidenceSchemaVersion
    run_id             = $runId
    generated_utc      = (Get-Date).ToUniversalTime().ToString('o')
    isolation_mode     = $tf.isolation_mode
    cosmos_account     = $cosmosAccount
    cosmos_database    = $cosmosDb
    storage_account    = $storageAccount
    projects           = $tf.projects
    cosmos_containers  = $cosmosContainers
    blob_containers    = $blobContainers
    cosmos_data_roles  = $cosmosRoles
    arm_roles          = $armRoles
}

$outPath = Join-Path $EvidenceDir 'isolation-inventory.json'
$report | ConvertTo-Json -Depth 8 | Set-Content -Path $outPath -Encoding utf8
Write-Host "`nWrote $outPath" -ForegroundColor Green

$unattributed = $cosmosContainers | Where-Object { $_.owner -eq '<unattributed>' }
if ($unattributed) {
    Write-Warning "Containers not attributable to any project - the naming convention may have changed:"
    $unattributed | Format-Table -AutoSize
}

$modern = $cosmosContainers | Where-Object { $_.runtime -eq 'modern' }
if (-not $modern) {
    Write-Warning "No *-agent-definitions-v1 / *-run-state-v1 containers found. Run scripts/02-run-agents.ps1 first - those containers only appear after a project's first Responses API call."
}
