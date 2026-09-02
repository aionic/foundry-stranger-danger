<#
.SYNOPSIS
    Runs the full evidence collection and assembles a report.

.DESCRIPTION
    Order matters:
      1. 02-run-agents.ps1      - creates AND invokes an agent per project, which
                                  is what materialises the modern Cosmos
                                  containers. Skipped with -SkipAgents once done.
      2. 10-show-isolation.ps1  - container inventory and RBAC scopes
      3. 11-test-cross-access.ps1 - the allow/deny matrix
      4. 13-test-search-isolation.ps1 - Search scope and attribution

    Output lands in evidence/ (gitignored) and is archived under a timestamped
    run directory with a manifest and hashes. Promote reviewed, sanitized
    conclusions into the customer report rather than committing raw artefacts.
#>
[CmdletBinding()]
param(
    [switch]$SkipAgents,
    [switch]$SkipSearch,
    [string]$EvidenceDir = (Join-Path $PSScriptRoot '..\evidence')
)

$ErrorActionPreference = 'Stop'
$root = Join-Path $PSScriptRoot '..'
. (Join-Path $PSScriptRoot 'EvidenceContract.ps1')
New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null

$tf = @{}
(terraform -chdir="$root\terraform" output -json | ConvertFrom-Json).PSObject.Properties |
    ForEach-Object { $tf[$_.Name] = $_.Value.value }
$runId = New-EvidenceRunId
$previousRunId = $env:FOUNDRY_EVIDENCE_RUN_ID
$env:FOUNDRY_EVIDENCE_RUN_ID = $runId

try {
    if (-not $SkipAgents) {
        Write-Host "`n=== 1/4  Creating and invoking agents ===" -ForegroundColor Cyan
        Write-Host 'The *-agent-definitions-v1 and *-run-state-v1 containers do not exist until this runs.' -ForegroundColor DarkGray
        & (Join-Path $PSScriptRoot '02-run-agents.ps1') -EvidenceDir $EvidenceDir
        if ($LASTEXITCODE -ne 0) { throw 'Agent run failed; the evidence would be incomplete.' }

        Write-Host 'Waiting for every modern Cosmos container to become discoverable...' -ForegroundColor DarkGray
        $expectedContainers = @(
            foreach ($projectProperty in $tf.projects.PSObject.Properties) {
                $projectProperty.Value.expected_cosmos_containers
            }
        )
        $null = Wait-ForExpectedValues `
            -Expected $expectedContainers `
            -GetValues {
                az cosmosdb sql container list `
                    --account-name $tf.cosmos_account_name `
                    --resource-group $tf.resource_group_name `
                    --database-name $tf.cosmos_database_name `
                    --query '[].name' -o tsv
            } `
            -TimeoutSeconds 180 `
            -PollSeconds 5 `
            -Description 'modern Cosmos containers'
    }
    elseif (-not (Test-Path (Join-Path $EvidenceDir 'agents.json'))) {
        throw '-SkipAgents requires an existing evidence/agents.json to preserve agent provenance.'
    }

    if ($SkipAgents) {
        $existingAgents = Get-Content (Join-Path $EvidenceDir 'agents.json') -Raw | ConvertFrom-Json
        $agentFailures = @(Test-AgentEvidence -Evidence $existingAgents -ExpectedProjects $tf.projects)
        if ($agentFailures) {
            throw "Existing agents.json is not valid provenance for -SkipAgents: $($agentFailures -join ' ')"
        }
    }

    Write-Host "`n=== 2/4  Container inventory and RBAC scopes ===" -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot '10-show-isolation.ps1') -EvidenceDir $EvidenceDir

    Write-Host "`n=== 3/4  Cross-project access matrix ===" -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot '11-test-cross-access.ps1') -EvidenceDir $EvidenceDir
    $matrixExitCode = $LASTEXITCODE
    if ($matrixExitCode -eq 2) {
        throw 'Probes hit network-origin refusals, so this run is not valid evidence. Check Cosmos public network access and the control-bypass tags before rerunning.'
    }
    if ($matrixExitCode -ne 0) {
        throw "Cross-project access outcomes did not match expectations (exit $matrixExitCode). Review cross-access-matrix.json."
    }

    if (-not $SkipSearch) {
        Write-Host "`n=== 4/4  AI Search isolation ===" -ForegroundColor Cyan
        & (Join-Path $PSScriptRoot '13-test-search-isolation.ps1') -EvidenceDir $EvidenceDir
        if ($LASTEXITCODE -ne 0) { throw 'AI Search isolation test failed; the evidence package would be incomplete.' }
    }
}
finally {
    $env:FOUNDRY_EVIDENCE_RUN_ID = $previousRunId
}

# ---------------------------------------------------------------------------
# Assemble
# ---------------------------------------------------------------------------
$inventory = Get-Content (Join-Path $EvidenceDir 'isolation-inventory.json') -Raw | ConvertFrom-Json
$matrix = Get-Content (Join-Path $EvidenceDir 'cross-access-matrix.json') -Raw | ConvertFrom-Json
$agents = Get-Content (Join-Path $EvidenceDir 'agents.json') -Raw | ConvertFrom-Json
$searchPath = Join-Path $EvidenceDir 'search-isolation.json'
$search = if (-not $SkipSearch -and (Test-Path $searchPath)) { Get-Content $searchPath -Raw | ConvertFrom-Json } else { $null }
$matrixMd = Get-Content (Join-Path $EvidenceDir 'cross-access-matrix.md') -Raw

$matrixFailures = @(
    foreach ($probeProperty in $matrix.matrix.PSObject.Properties) {
        foreach ($projectProperty in $probeProperty.Value.results.PSObject.Properties) {
            if ($projectProperty.Value.verdict -ne 'PASS') {
                "$($probeProperty.Name) -> $($projectProperty.Name): $($projectProperty.Value.verdict)"
            }
        }
    }
)
$configurationFailures = @(Test-DeploymentConfiguration -Inventory $inventory)
$searchPassed = $SkipSearch -or (
    $search.results.index_scoped.enforced -and
    $search.results.service_scoped.spans_projects -and
    -not $search.index_name_attributable
)
$runStatus = if ($configurationFailures.Count -eq 0 -and $matrixFailures.Count -eq 0 -and $searchPassed) { 'passed' } else { 'failed' }

$lines = @(
    '# Foundry cross-project isolation - evidence',
    '',
    "Run ID: ``$runId``",
    "Generated: $((Get-Date).ToUniversalTime().ToString('u'))",
    "Status: **$runStatus**",
    "Isolation mode: ``$($inventory.isolation_mode)``",
    "Cosmos: ``$($inventory.cosmos_account)`` / ``$($inventory.cosmos_database)``",
    "Storage: ``$($inventory.storage_account)``",
    '',
    '## 1. Container layout',
    '',
    'Container names below were discovered, then correlated back to the owning',
    "project by its ARM ``internalId``.",
    '',
    '| Container | Owner | Runtime |',
    '|---|---|---|'
)
foreach ($c in $inventory.cosmos_containers | Sort-Object owner, name) {
    $lines += "| ``$($c.name)`` | $($c.owner) | $($c.runtime) |"
}
$lines += @('', '| Blob container | Owner |', '|---|---|')
foreach ($c in $inventory.blob_containers | Sort-Object owner, name) {
    $lines += "| ``$($c.name)`` | $($c.owner) |"
}

$lines += @(
    '',
    '## 2. Authorization scope',
    '',
    'Cosmos data-plane grants. Anything marked DATABASE or ACCOUNT reaches every',
    "project's containers, regardless of how the containers are named.",
    '',
    '| Principal | Granularity | Container |',
    '|---|---|---|'
)
foreach ($r in $inventory.cosmos_data_roles | Sort-Object principal, container) {
    $lines += "| $($r.principal) | $($r.granularity) | ``$($r.container)`` |"
}

$lines += @(
    '',
    '## 3. Enforcement',
    '',
    $matrixMd,
    '',
    '## 4. AI Search',
    ''
)
if ($SkipSearch) {
    $lines += 'Search was explicitly skipped for this run.'
}
else {
    $lines += @(
        "- Index-scoped RBAC enforced: **$($search.results.index_scoped.enforced)**",
        "- Service-scoped grant spans projects: **$($search.results.service_scoped.spans_projects)**",
        "- Index names identify their project: **$($search.index_name_attributable)**",
        "- Tested indexes: ``$($search.tested_indexes.PSObject.Properties.Value -join '`` / ``')``"
    )
}
$lines += @(
    '',
    '---',
    '',
    'Raw artefacts and hashes are listed in `manifest.json`.'
)

$reportPath = Join-Path $EvidenceDir 'REPORT.md'
$lines -join "`n" | Set-Content -Path $reportPath -Encoding utf8

$artifactNames = @('agents.json', 'isolation-inventory.json', 'cross-access-matrix.json', 'cross-access-matrix.md', 'REPORT.md')
if (-not $SkipSearch) { $artifactNames += 'search-isolation.json' }

$producerPaths = @(
    'scripts\00-preflight.ps1',
    'scripts\EvidenceContract.ps1',
    'scripts\02-run-agents.ps1',
    'scripts\10-show-isolation.ps1',
    'scripts\11-test-cross-access.ps1',
    'scripts\12-collect-evidence.ps1',
    'scripts\13-test-search-isolation.ps1',
    'scripts\14-validate-evidence.ps1',
    'scripts\deploy-and-harden.ps1'
)
$deploymentSourcePaths = @(
    Get-ChildItem (Join-Path $root 'terraform') -Filter '*.tf' -File |
        Sort-Object Name |
        ForEach-Object { [System.IO.Path]::GetRelativePath($root, $_.FullName) }
)
$deploymentSourcePaths += @(
    'terraform\.terraform.lock.hcl',
    'terraform\terraform.tfvars',
    'terraform\modern-containers.auto.tfvars.json'
)
$terraformVersion = (terraform version -json | ConvertFrom-Json).terraform_version
$azVersion = (az version -o json | ConvertFrom-Json).'azure-cli'
$gitCommit = (& git -C "$root" rev-parse HEAD 2>$null)
$gitDirty = [bool](& git -C "$root" status --porcelain 2>$null)
$manifest = [ordered]@{
    schema_version = $EvidenceSchemaVersion
    run_id         = $runId
    generated_utc  = (Get-Date).ToUniversalTime().ToString('o')
    status         = $runStatus
    assessment_scope = if ($SkipSearch) { 'cosmos-storage' } else { 'cosmos-storage-search' }
    isolation_mode = $inventory.isolation_mode
    search_included = -not $SkipSearch
    agent_source = [ordered]@{
        run_id         = $agents.run_id
        generated_utc  = $agents.generated_utc
        isolation_mode = $agents.isolation_mode
        api_version    = $agents.api_version
        reused         = [bool]$SkipAgents
    }
    source = [ordered]@{
        git_commit = "$gitCommit".Trim()
        git_dirty  = $gitDirty
        producers  = @(
            foreach ($relativePath in $producerPaths) {
                $fullPath = Join-Path $root $relativePath
                [ordered]@{
                    path   = $relativePath -replace '\\', '/'
                    sha256 = (Get-FileHash $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
        )
        deployment = @(
            foreach ($relativePath in $deploymentSourcePaths) {
                $fullPath = Join-Path $root $relativePath
                [ordered]@{
                    path   = $relativePath -replace '\\', '/'
                    sha256 = (Get-FileHash $fullPath -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
        )
        tools = [ordered]@{
            terraform = $terraformVersion
            azure_cli = $azVersion
            powershell = $PSVersionTable.PSVersion.ToString()
        }
    }
    deployment = [ordered]@{
        resource_group  = $tf.resource_group_name
        foundry_account = $tf.foundry_account_name
        cosmos_account  = $tf.cosmos_account_name
        storage_account = $tf.storage_account_name
        search_service  = $tf.search_service_name
        projects        = @($tf.projects.PSObject.Properties.Name)
    }
    assertions = [ordered]@{
        deployment_configuration_passed = $configurationFailures.Count -eq 0
        deployment_configuration_failures = $configurationFailures
        access_matrix_passed = $matrixFailures.Count -eq 0
        access_matrix_failures = $matrixFailures
        search_expected_results_observed = if ($SkipSearch) { $null } else { $searchPassed }
    }
    artifacts = @(
        foreach ($name in $artifactNames) {
            $path = Join-Path $EvidenceDir $name
            [ordered]@{
                path   = $name
                bytes  = (Get-Item $path).Length
                sha256 = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
            }
        }
    )
}
$manifestPath = Join-Path $EvidenceDir 'manifest.json'
$manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $manifestPath -Encoding utf8

$archiveName = "$runId-$($inventory.isolation_mode)"
$archiveDir = Join-Path (Join-Path $EvidenceDir 'runs') $archiveName
New-Item -ItemType Directory -Force -Path (Split-Path $archiveDir) | Out-Null
New-Item -ItemType Directory -Path $archiveDir | Out-Null
foreach ($name in ($artifactNames + 'manifest.json')) {
    Copy-Item -Path (Join-Path $EvidenceDir $name) -Destination (Join-Path $archiveDir $name) -Force
}
$sourceSnapshotDir = Join-Path $archiveDir 'source'
foreach ($relativePath in @($producerPaths + $deploymentSourcePaths)) {
    $sourcePath = Join-Path $root $relativePath
    $destinationPath = Join-Path $sourceSnapshotDir $relativePath
    New-Item -ItemType Directory -Force -Path (Split-Path $destinationPath) | Out-Null
    Copy-Item -Path $sourcePath -Destination $destinationPath -Force
}

& (Join-Path $PSScriptRoot '14-validate-evidence.ps1') -EvidenceDir $archiveDir
if ($LASTEXITCODE -ne 0) { throw "Evidence contract validation failed for $archiveDir" }

Write-Host "`nWrote $reportPath" -ForegroundColor Green
Write-Host "Archived run: $archiveDir" -ForegroundColor Green

if ($runStatus -ne 'passed') {
    throw "Evidence run $runId completed with failed assertions. Review manifest.json before drawing conclusions."
}
