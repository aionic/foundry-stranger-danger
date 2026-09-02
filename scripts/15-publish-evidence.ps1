<#
.SYNOPSIS
    Produces a sanitized customer evidence bundle from a validated raw run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$SourceEvidenceDir,

    [string]$OutputRoot = (Join-Path $PSScriptRoot '..\evidence\published')
)

$ErrorActionPreference = 'Stop'
$sourceDir = Resolve-Path $SourceEvidenceDir
$root = Resolve-Path (Join-Path $PSScriptRoot '..')

& (Join-Path $PSScriptRoot '14-validate-evidence.ps1') -EvidenceDir $sourceDir
if ($LASTEXITCODE -ne 0) { throw 'Source evidence failed validation; publication is blocked.' }

$sourceManifestPath = Join-Path $sourceDir 'manifest.json'
$sourceManifest = Get-Content $sourceManifestPath -Raw | ConvertFrom-Json
$agents = Get-Content (Join-Path $sourceDir 'agents.json') -Raw | ConvertFrom-Json
$inventory = Get-Content (Join-Path $sourceDir 'isolation-inventory.json') -Raw | ConvertFrom-Json
$matrix = Get-Content (Join-Path $sourceDir 'cross-access-matrix.json') -Raw | ConvertFrom-Json
$search = Get-Content (Join-Path $sourceDir 'search-isolation.json') -Raw | ConvertFrom-Json

$outputDir = Join-Path $OutputRoot $sourceManifest.run_id
if (Test-Path $outputDir) { throw "Published evidence already exists: $outputDir" }
New-Item -ItemType Directory -Path $outputDir -Force | Out-Null

$containerSummary = [ordered]@{}
foreach ($projectName in $inventory.projects.PSObject.Properties.Name) {
    $containerSummary[$projectName] = [ordered]@{
        cosmos_total   = @($inventory.cosmos_containers | Where-Object { $_.owner -eq $projectName }).Count
        cosmos_classic = @($inventory.cosmos_containers | Where-Object { $_.owner -eq $projectName -and $_.runtime -eq 'classic' }).Count
        cosmos_modern  = @($inventory.cosmos_containers | Where-Object { $_.owner -eq $projectName -and $_.runtime -eq 'modern' }).Count
        blob_total     = @($inventory.blob_containers | Where-Object { $_.owner -eq $projectName }).Count
    }
}

$cosmosGrantSummary = @(
    $inventory.cosmos_data_roles |
        Where-Object { $_.principal -like 'project:*' -or $_.principal -like 'probe:*' } |
        Group-Object principal, granularity |
        Sort-Object Name |
        ForEach-Object {
            [ordered]@{
                principal   = $_.Group[0].principal
                granularity = $_.Group[0].granularity
                count       = $_.Count
            }
        }
)

$projectArmRoleSummary = @(
    $inventory.arm_roles |
        Where-Object { $_.principal -like 'project:*' } |
        Sort-Object principal, resource, role |
        ForEach-Object {
            [ordered]@{
                principal         = $_.principal
                resource          = $_.resource
                role              = $_.role
                granularity       = $_.granularity
                direct            = $_.is_direct
                condition_present = $_.condition -eq 'yes'
                condition_version = $_.condition_version
            }
        }
)

$matrixSummary = [ordered]@{}
foreach ($probeProperty in $matrix.matrix.PSObject.Properties) {
    $projectResults = [ordered]@{}
    foreach ($projectProperty in $probeProperty.Value.results.PSObject.Properties) {
        $projectResults[$projectProperty.Name] = [ordered]@{
            cosmos = $projectProperty.Value.cosmos.outcome
            blob   = $projectProperty.Value.blob.outcome
            verdict = $projectProperty.Value.verdict
        }
    }
    $matrixSummary[$probeProperty.Name] = [ordered]@{
        permission_shape = $probeProperty.Value.models
        results          = $projectResults
    }
}

$agentSummary = [ordered]@{}
foreach ($projectProperty in $agents.projects.PSObject.Properties) {
    $agentSummary[$projectProperty.Name] = [ordered]@{
        status           = $projectProperty.Value.status
        api_version      = $agents.api_version
        canary_confirmed = "$($projectProperty.Value.reply)".StartsWith("$($projectProperty.Value.canary_token)", [System.StringComparison]::Ordinal)
    }
}

$summary = [ordered]@{
    schema_version  = '1.0'
    source_run_id   = $sourceManifest.run_id
    collected_utc   = $sourceManifest.generated_utc
    status          = $sourceManifest.status
    assessment_scope = $sourceManifest.assessment_scope
    isolation_mode  = $sourceManifest.isolation_mode
    source          = [ordered]@{
        git_commit = $sourceManifest.source.git_commit
        git_dirty  = $sourceManifest.source.git_dirty
        producer_hashes = $sourceManifest.source.producers
        deployment_source_hashes = $sourceManifest.source.deployment
        tool_versions = $sourceManifest.source.tools
        artifact_hashes = $sourceManifest.artifacts | ForEach-Object {
            [ordered]@{ path = $_.path; sha256 = $_.sha256 }
        }
    }
    assertions      = $sourceManifest.assertions
    projects        = @($inventory.projects.PSObject.Properties.Name)
    agents          = $agentSummary
    containers      = $containerSummary
    cosmos_grants   = $cosmosGrantSummary
    project_arm_roles = $projectArmRoleSummary
    access_matrix   = $matrixSummary
    search          = [ordered]@{
        project_count          = @($search.tested_indexes.PSObject.Properties).Count
        exact_indexes_recorded_in_source = $true
        index_names_redacted   = $true
        index_name_attributable = $search.index_name_attributable
        index_scoped           = $search.results.index_scoped
        service_scoped         = $search.results.service_scoped
    }
    redactions      = @(
        'Azure subscription and tenant identifiers',
        'Azure resource group and resource names',
        'Project and probe principal identifiers',
        'Project endpoints and response identifiers',
        'Vector-store identifiers and Search index names',
        'Role condition expressions containing project GUIDs'
    )
}

$summaryPath = Join-Path $outputDir 'evidence-summary.json'
$summary | ConvertTo-Json -Depth 12 | Set-Content $summaryPath -Encoding utf8

$lines = @(
    '# Microsoft Foundry cross-project isolation - customer evidence summary',
    '',
    "- Source run: ``$($sourceManifest.run_id)``",
    "- Collected: $($sourceManifest.generated_utc.ToUniversalTime().ToString('o'))",
    "- Status: **$($sourceManifest.status)**",
    "- Scope: ``$($sourceManifest.assessment_scope)``",
    "- Configuration: ``$($sourceManifest.isolation_mode)``",
    '',
    '## Validated assertions',
    '',
    "- Deployment configuration passed: **$($sourceManifest.assertions.deployment_configuration_passed)**",
    "- Cosmos and Blob access matrix passed: **$($sourceManifest.assertions.access_matrix_passed)**",
    "- Expected Search findings observed: **$($sourceManifest.assertions.search_expected_results_observed)**",
    '',
    '## Resource attribution',
    '',
    '| Project | Cosmos containers | Classic | Modern | Blob containers |',
    '|---|---:|---:|---:|---:|'
)
foreach ($projectName in $containerSummary.Keys) {
    $item = $containerSummary[$projectName]
    $lines += "| $projectName | $($item.cosmos_total) | $($item.cosmos_classic) | $($item.cosmos_modern) | $($item.blob_total) |"
}

$lines += @(
    '',
    '## Direct data-plane matrix',
    '',
    '| Probe | Alpha Cosmos | Alpha Blob | Bravo Cosmos | Bravo Blob |',
    '|---|---|---|---|---|'
)
foreach ($probeName in $matrixSummary.Keys) {
    $item = $matrixSummary[$probeName]
    $lines += "| ``$probeName`` | $($item.results.alpha.cosmos) | $($item.results.alpha.blob) | $($item.results.bravo.cosmos) | $($item.results.bravo.blob) |"
}

$lines += @(
    '',
    '## AI Search',
    '',
    "- Single-index role: selected index **$($search.results.index_scoped.own)**; other project index **$($search.results.index_scoped.other)**",
    "- Service-scoped role: project A **$($search.results.service_scoped.projectA)**; project B **$($search.results.service_scoped.projectB)**",
    "- Index-scoped enforcement observed: **$($search.results.index_scoped.enforced)**",
    "- Service-scoped reach across projects observed: **$($search.results.service_scoped.spans_projects)**",
    "- Generated index name attributable to a project: **$($search.index_name_attributable)**",
    '',
    '## Evidence handling',
    '',
    'This bundle is a sanitized derivative. The source manifest and artifact SHA-256 hashes are retained in `evidence-summary.json` so the assessment owner can trace this summary to the internally retained raw run. Operational identifiers and raw request details are intentionally omitted.',
    '',
    'The source manifest recorded a dirty Git working tree. Each evidence producer and raw artifact is nevertheless bound by its own SHA-256 hash; those hashes are included in the JSON summary.'
)
$reportPath = Join-Path $outputDir 'REPORT.md'
$lines -join "`n" | Set-Content $reportPath -Encoding utf8

$forbiddenValues = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($value in @(
        $sourceManifest.deployment.resource_group,
        $sourceManifest.deployment.foundry_account,
        $sourceManifest.deployment.cosmos_account,
        $sourceManifest.deployment.storage_account,
        $sourceManifest.deployment.search_service
    )) { if ("$value".Length -ge 6) { [void]$forbiddenValues.Add("$value") } }
foreach ($project in $inventory.projects.PSObject.Properties.Value) {
    foreach ($value in @($project.principal_id, $project.guid, $project.internal_id, $project.endpoint, $project.resource_id)) {
        if ("$value".Length -ge 6) { [void]$forbiddenValues.Add("$value") }
    }
}
foreach ($probe in $matrix.matrix.PSObject.Properties.Value) {
    foreach ($value in @($probe.client_id, $probe.object_id)) { if ("$value".Length -ge 6) { [void]$forbiddenValues.Add("$value") } }
}
foreach ($value in @($search.vector_stores.PSObject.Properties.Value) + @($search.indexes)) {
    if ("$value".Length -ge 6) { [void]$forbiddenValues.Add("$value") }
}

$publishedText = (Get-Content $summaryPath -Raw) + (Get-Content $reportPath -Raw)
$leaks = @($forbiddenValues | Where-Object { $publishedText.Contains($_, [System.StringComparison]::OrdinalIgnoreCase) })
if ($leaks) {
    Remove-Item $outputDir -Recurse -Force
    throw "Sanitization failed; $($leaks.Count) operational identifier(s) remain."
}

$publishedArtifacts = @(
    foreach ($path in @($summaryPath, $reportPath)) {
        [ordered]@{
            path   = Split-Path $path -Leaf
            bytes  = (Get-Item $path).Length
            sha256 = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }
)
$publicationManifest = [ordered]@{
    schema_version       = '1.0'
    source_run_id        = $sourceManifest.run_id
    source_manifest_sha256 = (Get-FileHash $sourceManifestPath -Algorithm SHA256).Hash.ToLowerInvariant()
    generated_utc        = (Get-Date).ToUniversalTime().ToString('o')
    status               = 'sanitized'
    forbidden_value_count_checked = $forbiddenValues.Count
    forbidden_value_matches = 0
    artifacts            = $publishedArtifacts
}
$publicationManifest | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $outputDir 'manifest.json') -Encoding utf8

& (Join-Path $PSScriptRoot 'Test-PublishedEvidence.ps1') -PublishedEvidenceDir $outputDir
if ($LASTEXITCODE -ne 0) { throw 'Published evidence validation failed.' }

Write-Host "Published sanitized evidence: $outputDir" -ForegroundColor Green