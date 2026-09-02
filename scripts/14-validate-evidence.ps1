<#
.SYNOPSIS
    Validates a generated evidence run without contacting Azure.

.DESCRIPTION
    Checks schema and run identity, artifact hashes, per-store positive and
    negative controls, inventory attribution, and Search test provenance.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$EvidenceDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'EvidenceContract.ps1')
$failures = @()

function Add-Failure {
    param([string]$Message)
    $script:failures += $Message
}

$manifestPath = Join-Path $EvidenceDir 'manifest.json'
if (-not (Test-Path $manifestPath)) { throw "Missing evidence manifest: $manifestPath" }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json

if ($manifest.schema_version -ne '1.0') { Add-Failure "Unsupported manifest schema '$($manifest.schema_version)'." }
if (-not $manifest.run_id) { Add-Failure 'Manifest has no run_id.' }
if (-not $manifest.source.producers -or -not $manifest.source.deployment) {
    Add-Failure 'Manifest does not include both evidence-producer and deployment-source inventories.'
}
if (-not $manifest.source.tools.terraform -or -not $manifest.source.tools.azure_cli -or -not $manifest.source.tools.powershell) {
    Add-Failure 'Manifest does not include the required tool versions.'
}
if ($manifest.status -ne 'passed') { Add-Failure "Manifest status is '$($manifest.status)', expected 'passed'." }
if (-not $manifest.assertions.deployment_configuration_passed) { Add-Failure 'Manifest says deployment configuration did not pass.' }
if (-not $manifest.assertions.access_matrix_passed) { Add-Failure 'Manifest says the access matrix did not pass.' }
if ($manifest.search_included -and -not $manifest.assertions.search_expected_results_observed) {
    Add-Failure 'Manifest says the expected Search results were not observed.'
}
if ($manifest.search_included -and $manifest.assessment_scope -ne 'cosmos-storage-search') {
    Add-Failure "Search is included but assessment_scope is '$($manifest.assessment_scope)'."
}
if (-not $manifest.search_included -and $manifest.assessment_scope -ne 'cosmos-storage') {
    Add-Failure "Search is omitted but assessment_scope is '$($manifest.assessment_scope)'."
}

foreach ($artifact in $manifest.artifacts) {
    $path = Join-Path $EvidenceDir $artifact.path
    if (-not (Test-Path $path)) {
        Add-Failure "Missing artifact '$($artifact.path)'."
        continue
    }
    if ((Get-Item $path).Length -ne $artifact.bytes) { Add-Failure "Byte count mismatch for '$($artifact.path)'." }
    $actualHash = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $artifact.sha256) { Add-Failure "Hash mismatch for '$($artifact.path)'." }
}

foreach ($sourceFile in @($manifest.source.producers) + @($manifest.source.deployment)) {
    $path = Join-Path (Join-Path $EvidenceDir 'source') $sourceFile.path
    if (-not (Test-Path $path)) {
        Add-Failure "Missing source snapshot '$($sourceFile.path)'."
        continue
    }
    $actualHash = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actualHash -ne $sourceFile.sha256) { Add-Failure "Source snapshot hash mismatch for '$($sourceFile.path)'." }
}

$inventory = Get-Content (Join-Path $EvidenceDir 'isolation-inventory.json') -Raw | ConvertFrom-Json
$matrix = Get-Content (Join-Path $EvidenceDir 'cross-access-matrix.json') -Raw | ConvertFrom-Json
$agents = Get-Content (Join-Path $EvidenceDir 'agents.json') -Raw | ConvertFrom-Json
foreach ($artifact in @($inventory, $matrix)) {
    if ($artifact.schema_version -ne $manifest.schema_version) { Add-Failure 'Artifact schema does not match manifest.' }
    if ($artifact.run_id -ne $manifest.run_id) { Add-Failure "Artifact run_id '$($artifact.run_id)' does not match '$($manifest.run_id)'." }
    if ($artifact.isolation_mode -ne $manifest.isolation_mode) { Add-Failure 'Artifact isolation_mode does not match manifest.' }
}

if (-not $manifest.agent_source.run_id) {
    Add-Failure 'Manifest has no agent_source run_id.'
}
else {
    $agentFailures = @(Test-AgentEvidence `
            -Evidence $agents `
            -ExpectedProjects $inventory.projects `
            -ExpectedRunId $manifest.agent_source.run_id)
    foreach ($failure in $agentFailures) { Add-Failure $failure }

    if ($agents.generated_utc -ne $manifest.agent_source.generated_utc) { Add-Failure 'Agent generated_utc does not match manifest agent_source.' }
    if ($agents.isolation_mode -ne $manifest.agent_source.isolation_mode) { Add-Failure 'Agent isolation_mode does not match manifest agent_source.' }
    if ($agents.api_version -ne $manifest.agent_source.api_version) { Add-Failure 'Agent api_version does not match manifest agent_source.' }

    if (-not $manifest.agent_source.reused -and $agents.run_id -ne $manifest.run_id) {
        Add-Failure 'Fresh agent evidence does not share the collection run_id.'
    }
}

$projectNames = @($inventory.projects.PSObject.Properties.Name)
foreach ($projectName in $projectNames) {
    $cosmosCount = @($inventory.cosmos_containers | Where-Object { $_.owner -eq $projectName }).Count
    $blobCount = @($inventory.blob_containers | Where-Object { $_.owner -eq $projectName }).Count
    if ($cosmosCount -ne 5) { Add-Failure "Project '$projectName' has $cosmosCount Cosmos containers; expected 5." }
    if ($blobCount -ne 2) { Add-Failure "Project '$projectName' has $blobCount Blob containers; expected 2." }
}
if ($inventory.cosmos_containers.owner -contains '<unattributed>') { Add-Failure 'One or more Cosmos containers are unattributed.' }
if ($inventory.blob_containers.owner -contains '<unattributed>') { Add-Failure 'One or more Blob containers are unattributed.' }

$configurationFailures = @(Test-DeploymentConfiguration -Inventory $inventory)
foreach ($failure in $configurationFailures) { Add-Failure $failure }

foreach ($probeProperty in $matrix.matrix.PSObject.Properties) {
    $probe = $probeProperty.Value
    foreach ($projectProperty in $probe.results.PSObject.Properties) {
        $expected = if (-not $probe.own_project -or $projectProperty.Name -eq $probe.own_project) { 'ALLOW' } else { 'DENY' }
        foreach ($store in @('cosmos', 'blob')) {
            $result = $projectProperty.Value.$store
            if ($result.outcome -ne $expected) {
                Add-Failure "$store $($probeProperty.Name) -> $($projectProperty.Name) was $($result.outcome); expected $expected."
            }
        }
        if ($projectProperty.Value.verdict -ne 'PASS') {
            Add-Failure "Combined verdict $($probeProperty.Name) -> $($projectProperty.Name) was $($projectProperty.Value.verdict)."
        }
    }
}

if ($manifest.search_included) {
    $searchPath = Join-Path $EvidenceDir 'search-isolation.json'
    if (-not (Test-Path $searchPath)) {
        Add-Failure 'Manifest says Search is included, but search-isolation.json is missing.'
    }
    else {
        $search = Get-Content $searchPath -Raw | ConvertFrom-Json
        if ($search.run_id -ne $manifest.run_id) { Add-Failure 'Search run_id does not match manifest.' }
        if (-not $search.results.index_scoped.enforced) { Add-Failure 'Index-scoped Search RBAC was not enforced.' }
        if (-not $search.results.service_scoped.spans_projects) { Add-Failure 'Service-scoped Search access did not reproduce the expected span.' }
        if ($search.index_name_attributable) { Add-Failure 'Search index names unexpectedly became project-attributable; reassess the finding.' }
        foreach ($projectName in $projectNames) {
            $testedIndex = $search.tested_indexes.$projectName
            if (-not $testedIndex) { Add-Failure "No tested Search index recorded for '$projectName'."; continue }
            if ($search.index_owner.$testedIndex -ne $projectName) {
                Add-Failure "Tested Search index '$testedIndex' is not attributed to '$projectName'."
            }
        }
    }
}

if ($failures) {
    Write-Host 'Evidence validation failed:' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host "Evidence contract valid: $($manifest.run_id)" -ForegroundColor Green
