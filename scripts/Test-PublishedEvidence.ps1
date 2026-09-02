<#
.SYNOPSIS
    Validates a sanitized customer evidence bundle without raw Azure access.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PublishedEvidenceDir
)

$ErrorActionPreference = 'Stop'
$directory = Resolve-Path $PublishedEvidenceDir
$manifest = Get-Content (Join-Path $directory 'manifest.json') -Raw | ConvertFrom-Json
$summary = Get-Content (Join-Path $directory 'evidence-summary.json') -Raw | ConvertFrom-Json
$failures = @()

if ($manifest.schema_version -ne '1.0' -or $manifest.status -ne 'sanitized') { $failures += 'Publication manifest schema or status is invalid.' }
if ($summary.source_run_id -ne $manifest.source_run_id) { $failures += 'Published summary run ID does not match its manifest.' }
if ($summary.status -ne 'passed') { $failures += "Source evidence status is '$($summary.status)', expected 'passed'." }
if (-not $summary.assertions.deployment_configuration_passed -or -not $summary.assertions.access_matrix_passed -or -not $summary.assertions.search_expected_results_observed) {
    $failures += 'One or more source assertions are not true.'
}
if ($manifest.forbidden_value_matches -ne 0) { $failures += 'Publication manifest records an identifier leak.' }

foreach ($artifact in $manifest.artifacts) {
    $path = Join-Path $directory $artifact.path
    if (-not (Test-Path $path)) { $failures += "Missing published artifact '$($artifact.path)'."; continue }
    if ((Get-Item $path).Length -ne $artifact.bytes) { $failures += "Byte count mismatch for '$($artifact.path)'." }
    $hash = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($hash -ne $artifact.sha256) { $failures += "Hash mismatch for '$($artifact.path)'." }
}

$publishedText = (Get-Content (Join-Path $directory 'evidence-summary.json') -Raw) + (Get-Content (Join-Path $directory 'REPORT.md') -Raw)
$forbiddenPatterns = @(
    '/subscriptions/',
    'https://[^\s"/]+\.services\.ai\.azure\.com',
    'vs_[A-Za-z0-9]+',
    'document_chunks_hnsw_',
    '(?i)client_secret',
    '(?i)AccountKey='
)
foreach ($pattern in $forbiddenPatterns) {
    if ($publishedText -match $pattern) { $failures += "Published evidence matches forbidden pattern '$pattern'." }
}

if ($failures) {
    Write-Host 'Published evidence validation failed:' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host "Published evidence valid: $($manifest.source_run_id)" -ForegroundColor Green