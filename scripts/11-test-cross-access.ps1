<#
.SYNOPSIS
    Cross-project access matrix.

.DESCRIPTION
    For every probe service principal, attempts to read every project's Cosmos
    containers and blob containers, and records allow / deny.

    Probes exist because a project's system-assigned managed identity cannot be
    impersonated. Each probe holds a CLONE of a specific permission shape:

        probe-scoped-<project>  container-scoped   -> hardened project identity
        probe-broad             database + account -> the documented config

    A 403 IS NOT AUTOMATICALLY A DENIAL.

    Cosmos returns 403 both for "RBAC denied" and for "blocked by your Cosmos DB
    account firewall settings". This environment's tenant automation disables
    public network access on data resources, and if that happens mid-run every
    probe fails 403. Recording those as DENY would fabricate a passing isolation
    result. Network-origin 403s are therefore classified BLOCKED and treated as
    an invalid test, not as evidence.

    PowerShell rather than Python because PyPI is not reachable from this
    environment; this needs nothing beyond the Azure CLI.
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

$tf = @{}
(terraform -chdir="$terraformDir" output -json | ConvertFrom-Json).PSObject.Properties |
    ForEach-Object { $tf[$_.Name] = $_.Value.value }

$probes = $tf.probe_identities
if (-not $probes) { throw 'No probe identities in state. Set enable_probe_identities = true and re-apply.' }

$tenantId = $tf.tenant_id
# The documentEndpoint output carries an explicit :443, which is valid in a URL
# but produces an invalid token resource. Strip it.
$cosmosEndpoint = ($tf.cosmos_endpoint -replace ':443', '').TrimEnd('/')
$cosmosDb = $tf.cosmos_database_name
$blobEndpoint = $tf.storage_blob_endpoint.TrimEnd('/')

# Generic Cosmos data-plane audience. Works for any account and avoids the
# per-account resource having to be registered in the tenant.
$cosmosScope = 'https://cosmos.azure.com/.default'
$blobScope = 'https://storage.azure.com/.default'

function Get-SpToken {
    param([string]$ClientId, [string]$ClientSecret, [string]$Scope)
    $body = @{
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = $Scope
        grant_type    = 'client_credentials'
    }
    try {
        $response = Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" -Body $body
        if (-not $response.access_token) { throw 'The token response did not contain access_token.' }
        return $response.access_token
    }
    catch {
        throw "Failed to acquire a probe token for '$Scope' using client '$ClientId': $($_.Exception.Message)"
    }
}

function Test-CosmosRead {
    <#
        Point read of a document that will not exist.

        A cross-partition query is not usable here: the REST gateway rejects it
        with 400 before authorization is even reflected in the result, which is
        indistinguishable from a probe bug. A point read is evaluated against
        RBAC first, so:
            404 -> authorized (the document simply is not there)
            403 -> denied
    #>
    param([string]$Token, [string]$Container)
    $auth = [uri]::EscapeDataString("type=aad&ver=1.0&sig=$Token")
    $probeId = 'isolation-probe-nonexistent'
    $headers = @{
        Authorization                    = $auth
        'x-ms-date'                      = (Get-Date).ToUniversalTime().ToString('r').ToLower()
        'x-ms-version'                   = '2018-12-31'
        'x-ms-documentdb-partitionkey'   = "[`"$probeId`"]"
    }
    $uri = "$cosmosEndpoint/dbs/$cosmosDb/colls/$Container/docs/$probeId"
    try {
        $null = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
        return @{ outcome = 'ALLOW'; status = 200 }
    }
    catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        if ($status -eq 404) {
            return @{ outcome = 'ALLOW'; status = 404; note = 'authorized; document absent as expected' }
        }
        $text = "$($_.ErrorDetails.Message) $($_.Exception.Message)"
        $v = Resolve-AccessFailure -Status $status -Body $text
        return @{ outcome = $v.outcome; status = $status; note = $v.note; detail = $text.Substring(0, [Math]::Min(240, $text.Length)) }
    }
}

function Test-BlobList {
    param([string]$Token, [string]$Container)
    $headers = @{
        Authorization  = "Bearer $Token"
        'x-ms-version' = '2021-08-06'
    }
    $uri = "$blobEndpoint/$Container`?restype=container&comp=list&maxresults=1"
    try {
        $null = Invoke-RestMethod -Method Get -Uri $uri -Headers $headers
        return @{ outcome = 'ALLOW'; status = 200 }
    }
    catch {
        $status = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $text = "$($_.ErrorDetails.Message) $($_.Exception.Message)"
        $v = Resolve-AccessFailure -Status $status -Body $text
        return @{ outcome = $v.outcome; status = $status; note = $v.note; detail = $text.Substring(0, [Math]::Min(240, $text.Length)) }
    }
}

# ---------------------------------------------------------------------------
# Discover the real blob containers.
#
# The documented convention (<workspaceId>-azureml-blobstore and
# <workspaceId>-agents-blobstore, no-dash prefix) does not match reality. Actual
# names use the DASHED guid, and the second container is
# <guid>-<12 hex>-azureml-agent - the hex segment is not predictable, so these
# names cannot be constructed and must be enumerated.
# ---------------------------------------------------------------------------
$deployerBlobToken = az account get-access-token --scope $blobScope --query accessToken -o tsv
$listRaw = Invoke-RestMethod -Method Get -Uri "$blobEndpoint/?comp=list" -Headers @{
    Authorization  = "Bearer $deployerBlobToken"
    'x-ms-version' = '2021-08-06'
}
# The response carries a BOM, which blocks the cast to XmlDocument.
$listXml = [xml]($listRaw.ToString().Substring($listRaw.ToString().IndexOf('<')))
$allBlobContainers = @($listXml.EnumerationResults.Containers.Container.Name)

$blobContainersByProject = @{}
foreach ($pk in $tf.projects.PSObject.Properties.Name) {
    $guid = $tf.projects.$pk.guid
    $blobContainersByProject[$pk] = @($allBlobContainers | Where-Object { $_ -like "$guid-*" })
}

Write-Host 'Discovered blob containers:' -ForegroundColor DarkGray
foreach ($pk in $blobContainersByProject.Keys) {
    foreach ($c in $blobContainersByProject[$pk]) { Write-Host "  $pk : $c" -ForegroundColor DarkGray }
}

$matrix = [ordered]@{}
$projectKeys = @($tf.projects.PSObject.Properties.Name)

foreach ($pp in $probes.PSObject.Properties) {
    $probeKey = $pp.Name
    $probe = $pp.Value

    Write-Host "`n=== probe: $probeKey ===" -ForegroundColor Cyan
    Write-Host "    models: $($probe.models)" -ForegroundColor DarkGray

    $cosmosToken = Get-SpToken -ClientId $probe.client_id -ClientSecret $probe.client_secret -Scope $cosmosScope
    $blobToken = Get-SpToken -ClientId $probe.client_id -ClientSecret $probe.client_secret -Scope $blobScope

    $perProject = [ordered]@{}

    foreach ($projectKey in $projectKeys) {
        $project = $tf.projects.$projectKey

        $cosmosResults = @(foreach ($c in $project.expected_cosmos_containers) {
                $r = Test-CosmosRead -Token $cosmosToken -Container $c
                [pscustomobject]($r + @{ container = $c })
            })
        $blobResults = @(foreach ($c in $blobContainersByProject[$projectKey]) {
                $r = Test-BlobList -Token $blobToken -Container $c
                [pscustomobject]($r + @{ container = $c })
            })

        $cosmosOutcome = Merge-AccessOutcome $cosmosResults
        $blobOutcome = Merge-AccessOutcome $blobResults

        # Container-scoped probes should reach only their own project. The broad
        # probe is the database/account connectivity control and should reach both.
        $expected = if ($null -eq $probe.project -or $probe.project -eq $projectKey) { 'ALLOW' } else { 'DENY' }
        $cosmosVerdict = Get-AccessVerdict -Outcome $cosmosOutcome -Expected $expected
        $blobVerdict = Get-AccessVerdict -Outcome $blobOutcome -Expected $expected
        $verdict = if ('INVALID' -in @($cosmosVerdict, $blobVerdict)) { 'INVALID' }
        elseif ('UNEXPECTED' -in @($cosmosVerdict, $blobVerdict)) { 'UNEXPECTED' }
        else { 'PASS' }

        $colour = switch ($verdict) { 'PASS' { 'Green' } 'INVALID' { 'Yellow' } default { 'Red' } }
        Write-Host ("    {0,-8} cosmos={1,-7} blob={2,-7} expected={3,-5} {4}" -f $projectKey, $cosmosOutcome, $blobOutcome, $expected, $verdict) -ForegroundColor $colour

        $perProject[$projectKey] = [ordered]@{
            cosmos          = @{ outcome = $cosmosOutcome; containers = $cosmosResults }
            blob            = @{ outcome = $blobOutcome; containers = $blobResults }
            expected_cosmos = $expected
            expected_blob   = $expected
            cosmos_verdict  = $cosmosVerdict
            blob_verdict    = $blobVerdict
            verdict         = $verdict
        }
    }

    $matrix[$probeKey] = [ordered]@{
        display_name = $probe.display_name
        client_id    = $probe.client_id
        object_id    = $probe.object_id
        models       = $probe.models
        own_project  = $probe.project
        results      = $perProject
    }
}

New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null

$report = [ordered]@{
    schema_version  = $EvidenceSchemaVersion
    run_id          = $runId
    generated_utc   = (Get-Date).ToUniversalTime().ToString('o')
    isolation_mode  = $tf.isolation_mode
    cosmos_account  = $tf.cosmos_account_name
    cosmos_database = $cosmosDb
    storage_account = $tf.storage_account_name
    matrix          = $matrix
}
$report | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $EvidenceDir 'cross-access-matrix.json') -Encoding utf8

$lines = @(
    '# Cross-project access matrix',
    '',
    "- Isolation mode: ``$($tf.isolation_mode)``",
    "- Cosmos: ``$($tf.cosmos_account_name)`` / ``$cosmosDb``",
    "- Storage: ``$($tf.storage_account_name)``",
    '',
    ('| Probe | Models | ' + (($projectKeys | ForEach-Object { "$_ cosmos | $_ blob" }) -join ' | ') + ' |'),
    ('|---|---|' + ('---|' * (2 * $projectKeys.Count)))
)
foreach ($k in $matrix.Keys) {
    $cells = foreach ($pk in $projectKeys) {
        $matrix[$k].results[$pk].cosmos.outcome
        $matrix[$k].results[$pk].blob.outcome
    }
    $lines += "| ``$k`` | $($matrix[$k].models) | " + ($cells -join ' | ') + ' |'
}
$lines -join "`n" | Set-Content (Join-Path $EvidenceDir 'cross-access-matrix.md') -Encoding utf8

Write-Host "`nWrote $EvidenceDir\cross-access-matrix.{json,md}" -ForegroundColor Green

$invalid = foreach ($k in $matrix.Keys) { foreach ($pk in $projectKeys) { if ($matrix[$k].results[$pk].verdict -eq 'INVALID') { "$k -> $pk" } } }
if ($invalid) {
    Write-Warning 'Network-origin refusals detected. These are NOT denials and this run is not valid evidence:'
    $invalid | ForEach-Object { Write-Warning "  $_" }
    Write-Warning 'Check public network access on the Cosmos account and confirm the control-bypass tags are present.'
    exit 2
}

$unexpected = foreach ($k in $matrix.Keys) { foreach ($pk in $projectKeys) { if ($matrix[$k].results[$pk].verdict -eq 'UNEXPECTED') { "$k -> $pk" } } }
if ($unexpected) {
    Write-Host "`nOutcomes that did not match expectation:" -ForegroundColor Yellow
    $unexpected | ForEach-Object { Write-Host "  $_" -ForegroundColor Yellow }
    exit 1
}
