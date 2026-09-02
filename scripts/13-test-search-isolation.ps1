<#
.SYNOPSIS
    Tests whether two Foundry projects sharing one Azure AI Search service are
    isolated from each other.

.DESCRIPTION
    Establishes three things empirically:

      1. What Foundry actually creates in Search when a project uses a vector
         store, and whether the index name identifies the owning project.

        2. Whether index-scoped RBAC is ENFORCED. Current Azure AI Search guidance
            supports this scope; the probe confirms it for the tested service.

        3. Whether a service-scoped grant spans other projects' indexes. It does.

    The conclusion is not that Search cannot be scoped - it can. It is that the
    scoping cannot be TARGETED: index names carry no project identifier and the
    vector store API exposes no mapping, so there is no durable way to express
    "this project's indexes" in a role assignment.

    Creates temporary role assignments and removes them. Creates one vector
    store per project, which is left in place - delete it or tear down the
    environment afterwards.

.NOTES
    Read-mostly. The only writes are two temporary role assignments and one
    vector store per project.
#>
[CmdletBinding()]
param(
    [string]$EvidenceDir = (Join-Path $PSScriptRoot '..\evidence'),
    [int]$PropagationSeconds = 60,
    [int]$IndexDiscoveryTimeoutSeconds = 120,
    [int]$IndexDiscoveryPollSeconds = 5
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

$svc = $tf.search_service_name
$searchUrl = "https://$svc.search.windows.net"
$apiVersion = '2024-07-01'
$svcId = az search service show -n $svc -g $tf.resource_group_name --query id -o tsv

function Get-SearchToken {
    param([string]$ClientId, [string]$ClientSecret)
    if (-not $ClientId) { return az account get-access-token --scope https://search.azure.com/.default --query accessToken -o tsv }
    (Invoke-RestMethod -Method Post -Uri "https://login.microsoftonline.com/$($tf.tenant_id)/oauth2/v2.0/token" -Body @{
            client_id = $ClientId; client_secret = $ClientSecret
            scope     = 'https://search.azure.com/.default'; grant_type = 'client_credentials'
        }).access_token
}

function Get-Indexes {
    param([string]$Token)
    @((Invoke-RestMethod -Uri "$searchUrl/indexes?api-version=$apiVersion" -Headers @{ Authorization = "Bearer $Token" }).value.name) | Sort-Object
}

function Test-IndexRead {
    param([string]$Token, [string]$Index)
    try {
        $null = Invoke-RestMethod -Uri "$searchUrl/indexes/$Index/docs?api-version=$apiVersion&search=*&`$top=1" -Headers @{ Authorization = "Bearer $Token" }
        return 'ALLOW'
    }
    catch {
        $s = if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { 0 }
        $text = "$($_.ErrorDetails.Message) $($_.Exception.Message)"
        return (Resolve-AccessFailure -Status $s -Body $text).outcome
    }
}

# ---------------------------------------------------------------------------
# 1. Make each project create an index
# ---------------------------------------------------------------------------
Write-Host "`n=== 1/4  Creating a vector store per project ===" -ForegroundColor Cyan
$aiToken = az account get-access-token --scope 'https://ai.azure.com/.default' --query accessToken -o tsv
$projectKeys = @($tf.projects.PSObject.Properties.Name)

$adminSearchToken = Get-SearchToken
$before = Get-Indexes -Token $adminSearchToken
$indexOwner = @{}
$vectorStores = [ordered]@{}

foreach ($pk in $projectKeys) {
    $ep = $tf.projects.$pk.endpoint
    $vs = Invoke-RestMethod -Method Post -Uri "$ep/openai/v1/vector_stores" `
        -Headers @{ Authorization = "Bearer $aiToken"; 'Content-Type' = 'application/json' } `
        -Body (@{ name = "$pk-isolation-probe-vs" } | ConvertTo-Json)
    Write-Host "  $pk : vector store $($vs.id)"
    $vectorStores[$pk] = $vs.id

    # Ownership is only discoverable by observation - the API never returns the
    # index name, and the name itself contains no project identifier. Poll for
    # exactly one new index; concurrent or delayed additions invalidate the run.
    $discovery = Wait-ForSingleNewValue `
        -Baseline $before `
        -GetValues { Get-Indexes -Token $adminSearchToken } `
        -TimeoutSeconds $IndexDiscoveryTimeoutSeconds `
        -PollSeconds $IndexDiscoveryPollSeconds `
        -Description "Search index for project '$pk'"
    $indexOwner[$discovery.value] = $pk
    $before = $discovery.all_values
}

$indexes = Get-Indexes -Token $adminSearchToken
Write-Host "`n  Indexes now present:" -ForegroundColor Cyan
foreach ($i in $indexes) {
    $owner = if ($indexOwner.ContainsKey($i)) { $indexOwner[$i] } else { '<unknown>' }
    Write-Host ("    {0}  owner={1}" -f $i, $owner)
}

$attributable = @($indexOwner.GetEnumerator() | Where-Object {
        $_.Key -match [regex]::Escape($tf.projects.$($_.Value).guid)
    }).Count -eq $indexOwner.Count
Write-Host ("`n  Index name contains the project GUID: {0}" -f $(if ($attributable) { 'YES' } else { 'NO - not attributable from the name alone' })) -ForegroundColor $(if ($attributable) { 'Green' } else { 'Red' })

if ($indexes.Count -lt 2) { throw "Need at least two indexes to test cross-project access; found $($indexes.Count)." }

$ownA = ($indexOwner.GetEnumerator() | Where-Object { $_.Value -eq $projectKeys[0] } | Select-Object -First 1).Key
$ownB = ($indexOwner.GetEnumerator() | Where-Object { $_.Value -eq $projectKeys[1] } | Select-Object -First 1).Key
if (-not $ownA -or -not $ownB) {
    throw 'Could not attribute one tested Search index to each project; refusing to guess.'
}

$probe = $tf.probe_identities."scoped-$($projectKeys[0])"
$broad = $tf.probe_identities.broad
$results = [ordered]@{}

# ---------------------------------------------------------------------------
# 2. Index-scoped grant
# ---------------------------------------------------------------------------
Write-Host "`n=== 2/4  Index-scoped grant ===" -ForegroundColor Cyan
Write-Host "  Granting Search Index Data Reader on ONE index only..."
$indexRoleCreated = $false
try {
    az role assignment create --scope "$svcId/indexes/$ownA" --role 'Search Index Data Reader' `
        --assignee-object-id $probe.object_id --assignee-principal-type ServicePrincipal -o none
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create the temporary index-scoped Search role assignment.' }
    $indexRoleCreated = $true
    Start-Sleep -Seconds $PropagationSeconds

    $pt = Get-SearchToken -ClientId $probe.client_id -ClientSecret $probe.client_secret
    $r1 = Test-IndexRead -Token $pt -Index $ownA
    $r2 = Test-IndexRead -Token $pt -Index $ownB
    Write-Host ("    granted index   -> {0}" -f $r1) -ForegroundColor $(if ($r1 -eq 'ALLOW') { 'Green' } else { 'Red' })
    Write-Host ("    other project   -> {0}" -f $r2) -ForegroundColor $(if ($r2 -eq 'DENY') { 'Green' } else { 'Red' })
    $results['index_scoped'] = @{ own = $r1; other = $r2; enforced = ($r1 -eq 'ALLOW' -and $r2 -eq 'DENY') }
}
finally {
    if ($indexRoleCreated) {
        az role assignment delete --scope "$svcId/indexes/$ownA" --role 'Search Index Data Reader' --assignee $probe.object_id -o none 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Failed to remove the temporary index-scoped Search role assignment.' }
    }
}

# ---------------------------------------------------------------------------
# 3. Service-scoped connectivity control
# ---------------------------------------------------------------------------
Write-Host "`n=== 3/4  Service-scoped connectivity control ===" -ForegroundColor Cyan
$serviceRoleCreated = $false
try {
    az role assignment create --scope $svcId --role 'Search Index Data Reader' `
        --assignee-object-id $broad.object_id --assignee-principal-type ServicePrincipal -o none
    if ($LASTEXITCODE -ne 0) { throw 'Failed to create the temporary service-scoped Search role assignment.' }
    $serviceRoleCreated = $true
    Start-Sleep -Seconds $PropagationSeconds

    $bt = Get-SearchToken -ClientId $broad.client_id -ClientSecret $broad.client_secret
    $s1 = Test-IndexRead -Token $bt -Index $ownA
    $s2 = Test-IndexRead -Token $bt -Index $ownB
    Write-Host ("    project A index -> {0}" -f $s1) -ForegroundColor $(if ($s1 -eq 'ALLOW') { 'Red' } else { 'Green' })
    Write-Host ("    project B index -> {0}" -f $s2) -ForegroundColor $(if ($s2 -eq 'ALLOW') { 'Red' } else { 'Green' })
    $results['service_scoped'] = @{ projectA = $s1; projectB = $s2; spans_projects = ($s1 -eq 'ALLOW' -and $s2 -eq 'ALLOW') }
}
finally {
    if ($serviceRoleCreated) {
        az role assignment delete --scope $svcId --role 'Search Index Data Reader' --assignee $broad.object_id -o none 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'Failed to remove the temporary service-scoped Search role assignment.' }
    }
}
Write-Host "`n  Temporary role assignments removed." -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# 4. Conclusion
# ---------------------------------------------------------------------------
Write-Host "`n=== 4/4  Conclusion ===" -ForegroundColor Cyan

if ($results.index_scoped.enforced) {
    Write-Host '  Index-scoped RBAC IS enforced - per-index isolation is technically possible.' -ForegroundColor Green
}
else {
    Write-Host '  Index-scoped RBAC was NOT enforced as expected - investigate before relying on it.' -ForegroundColor Yellow
}

if ($results.service_scoped.spans_projects) {
    Write-Host '  Service-scoped grants reach EVERY project index on the shared service.' -ForegroundColor Red
    Write-Host '  Treat service scope as a shared boundary, not a project boundary.' -ForegroundColor Red
}

if (-not $attributable) {
    Write-Host ''
    Write-Host '  Index names carry no project identifier, and the vector store API exposes no' -ForegroundColor Red
    Write-Host '  index name. Ownership above was derived by create-and-diff, which is not a' -ForegroundColor Red
    Write-Host '  control you can operate.' -ForegroundColor Red
    Write-Host ''
    Write-Host '  => Give each project its own AI Search service. It is the only durable' -ForegroundColor Yellow
    Write-Host '     isolation for vector data. See docs/05-hardening-guide.md section 2.3.' -ForegroundColor Yellow
}

New-Item -ItemType Directory -Force -Path $EvidenceDir | Out-Null
$report = [ordered]@{
    schema_version        = $EvidenceSchemaVersion
    run_id               = $runId
    generated_utc          = (Get-Date).ToUniversalTime().ToString('o')
    search_service         = $svc
    vector_stores          = $vectorStores
    indexes                = $indexes
    index_owner            = $indexOwner
    tested_indexes         = [ordered]@{
        $projectKeys[0] = $ownA
        $projectKeys[1] = $ownB
    }
    index_name_attributable = $attributable
    results                = $results
}
$out = Join-Path $EvidenceDir 'search-isolation.json'
$report | ConvertTo-Json -Depth 8 | Set-Content $out -Encoding utf8
Write-Host "`nWrote $out" -ForegroundColor Green
