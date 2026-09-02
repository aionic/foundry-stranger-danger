<#
.SYNOPSIS
    Runs the evidence contract against sanitized fixtures and failure mutations.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$fixtureSource = Join-Path $PSScriptRoot 'fixtures\evidence-valid'
$validator = Join-Path $root 'scripts\14-validate-evidence.ps1'
$contract = Join-Path $root 'scripts\EvidenceContract.ps1'
$tempRoot = Join-Path $env:TEMP "foundry-evidence-tests-$([guid]::NewGuid())"
$artifactNames = @(
    'agents.json',
    'isolation-inventory.json',
    'cross-access-matrix.json',
    'cross-access-matrix.md',
    'search-isolation.json',
    'REPORT.md'
)

. $contract

function Write-FixtureManifest {
    param([string]$CaseDirectory)

    $fixtureProducerPath = Join-Path $CaseDirectory 'source\scripts\EvidenceContract.ps1'
    $fixtureDeploymentPath = Join-Path $CaseDirectory 'source\terraform\main.tf'
    New-Item -ItemType Directory -Force -Path (Split-Path $fixtureProducerPath) | Out-Null
    New-Item -ItemType Directory -Force -Path (Split-Path $fixtureDeploymentPath) | Out-Null
    Copy-Item $contract $fixtureProducerPath -Force
    'terraform {}' | Set-Content $fixtureDeploymentPath -Encoding utf8

    $manifest = [ordered]@{
        schema_version  = '1.0'
        run_id          = 'fixture-run-1'
        generated_utc   = '2026-09-03T01:08:00Z'
        status          = 'passed'
        assessment_scope = 'cosmos-storage-search'
        isolation_mode  = 'hardened'
        search_included = $true
        agent_source    = [ordered]@{
            run_id         = 'fixture-agent-1'
            generated_utc  = '2026-09-03T01:00:00Z'
            isolation_mode = 'documented'
            api_version    = 'v1'
            reused         = $true
        }
        source          = [ordered]@{
            git_commit = 'fixture-commit'
            git_dirty  = $false
            producers  = @(
                [ordered]@{
                    path   = 'scripts/EvidenceContract.ps1'
                    sha256 = (Get-FileHash $fixtureProducerPath -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            )
            deployment = @(
                [ordered]@{
                    path   = 'terraform/main.tf'
                    sha256 = (Get-FileHash $fixtureDeploymentPath -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            )
            tools       = [ordered]@{
                terraform = 'fixture'
                azure_cli = 'fixture'
                powershell = $PSVersionTable.PSVersion.ToString()
            }
        }
        assertions      = [ordered]@{
            deployment_configuration_passed = $true
            deployment_configuration_failures = @()
            access_matrix_passed = $true
            access_matrix_failures = @()
            search_expected_results_observed = $true
        }
        artifacts       = @(
            foreach ($name in $artifactNames) {
                $path = Join-Path $CaseDirectory $name
                [ordered]@{
                    path   = $name
                    bytes  = (Get-Item $path).Length
                    sha256 = (Get-FileHash $path -Algorithm SHA256).Hash.ToLowerInvariant()
                }
            }
        )
    }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $CaseDirectory 'manifest.json') -Encoding utf8
}

function New-FixtureCase {
    param([string]$Name)

    $caseDirectory = Join-Path $tempRoot $Name
    New-Item -ItemType Directory -Force -Path $caseDirectory | Out-Null
    Copy-Item (Join-Path $fixtureSource '*') -Destination $caseDirectory -Recurse -Force
    return $caseDirectory
}

function Invoke-FixtureValidator {
    param([string]$CaseDirectory)

    $output = & pwsh -NoProfile -File $validator -EvidenceDir $CaseDirectory 2>&1 | Out-String
    return [pscustomobject]@{ exit_code = $LASTEXITCODE; output = $output }
}

function Assert-InvalidFixture {
    param(
        [string]$Name,
        [scriptblock]$Mutate,
        [string]$ExpectedMessage,
        [switch]$TamperAfterManifest
    )

    $caseDirectory = New-FixtureCase -Name $Name
    & $Mutate $caseDirectory
    Write-FixtureManifest -CaseDirectory $caseDirectory
    if ($TamperAfterManifest) {
        Add-Content (Join-Path $caseDirectory 'cross-access-matrix.md') 'tampered'
    }
    $result = Invoke-FixtureValidator -CaseDirectory $caseDirectory
    if ($result.exit_code -eq 0 -or $result.output -notmatch [regex]::Escape($ExpectedMessage)) {
        throw "Case '$Name' did not fail as expected. Output: $($result.output)"
    }
    Write-Host "PASS  $Name" -ForegroundColor Green
}

try {
    New-Item -ItemType Directory -Force -Path $tempRoot | Out-Null

    $validDirectory = New-FixtureCase -Name 'valid'
    Write-FixtureManifest -CaseDirectory $validDirectory
    $valid = Invoke-FixtureValidator -CaseDirectory $validDirectory
    if ($valid.exit_code -ne 0) { throw "Valid fixture failed: $($valid.output)" }
    Write-Host 'PASS  valid hardened evidence' -ForegroundColor Green

    Assert-InvalidFixture -Name 'own-blob-denied' -ExpectedMessage 'blob scoped-alpha -> alpha was DENY; expected ALLOW.' -Mutate {
        param($caseDirectory)
        $matrix = Get-Content (Join-Path $caseDirectory 'cross-access-matrix.json') -Raw | ConvertFrom-Json
        $matrix.matrix.'scoped-alpha'.results.alpha.blob.outcome = 'DENY'
        $matrix.matrix.'scoped-alpha'.results.alpha.verdict = 'UNEXPECTED'
        $matrix | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $caseDirectory 'cross-access-matrix.json') -Encoding utf8
    }

    Assert-InvalidFixture -Name 'cross-blob-allowed' -ExpectedMessage 'blob scoped-alpha -> bravo was ALLOW; expected DENY.' -Mutate {
        param($caseDirectory)
        $matrix = Get-Content (Join-Path $caseDirectory 'cross-access-matrix.json') -Raw | ConvertFrom-Json
        $matrix.matrix.'scoped-alpha'.results.bravo.blob.outcome = 'ALLOW'
        $matrix.matrix.'scoped-alpha'.results.bravo.verdict = 'UNEXPECTED'
        $matrix | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $caseDirectory 'cross-access-matrix.json') -Encoding utf8
    }

    Assert-InvalidFixture -Name 'network-blocked' -ExpectedMessage 'cosmos scoped-alpha -> bravo was BLOCKED; expected DENY.' -Mutate {
        param($caseDirectory)
        $matrix = Get-Content (Join-Path $caseDirectory 'cross-access-matrix.json') -Raw | ConvertFrom-Json
        $matrix.matrix.'scoped-alpha'.results.bravo.cosmos.outcome = 'BLOCKED'
        $matrix.matrix.'scoped-alpha'.results.bravo.verdict = 'INVALID'
        $matrix | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $caseDirectory 'cross-access-matrix.json') -Encoding utf8
    }

    Assert-InvalidFixture -Name 'run-mismatch' -ExpectedMessage "Artifact run_id 'other-run' does not match 'fixture-run-1'." -Mutate {
        param($caseDirectory)
        $inventory = Get-Content (Join-Path $caseDirectory 'isolation-inventory.json') -Raw | ConvertFrom-Json
        $inventory.run_id = 'other-run'
        $inventory | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $caseDirectory 'isolation-inventory.json') -Encoding utf8
    }

    Assert-InvalidFixture -Name 'hash-tamper' -ExpectedMessage "Hash mismatch for 'cross-access-matrix.md'." -TamperAfterManifest -Mutate { param($caseDirectory) }

    Assert-InvalidFixture -Name 'search-attribution-missing' -ExpectedMessage "No tested Search index recorded for 'bravo'." -Mutate {
        param($caseDirectory)
        $search = Get-Content (Join-Path $caseDirectory 'search-isolation.json') -Raw | ConvertFrom-Json
        $search.tested_indexes.PSObject.Properties.Remove('bravo')
        $search | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $caseDirectory 'search-isolation.json') -Encoding utf8
    }

    Assert-InvalidFixture -Name 'bad-canary' -ExpectedMessage "Agent reply for 'alpha' does not begin with its canary token." -Mutate {
        param($caseDirectory)
        $agents = Get-Content (Join-Path $caseDirectory 'agents.json') -Raw | ConvertFrom-Json
        $agents.projects.alpha.reply = 'wrong response'
        $agents | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $caseDirectory 'agents.json') -Encoding utf8
    }

    Assert-InvalidFixture -Name 'broad-project-grant' -ExpectedMessage 'project:alpha must have exactly five container-scoped Cosmos grants in hardened mode.' -Mutate {
        param($caseDirectory)
        $inventory = Get-Content (Join-Path $caseDirectory 'isolation-inventory.json') -Raw | ConvertFrom-Json
        $inventory.cosmos_data_roles = @($inventory.cosmos_data_roles | Where-Object { $_.principal -ne 'project:alpha' }) + @(
            [pscustomobject]@{ principal = 'project:alpha'; granularity = 'DATABASE (spans all projects)'; container = '' }
        )
        $inventory | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $caseDirectory 'isolation-inventory.json') -Encoding utf8
    }

    Assert-InvalidFixture -Name 'unconditioned-project-blob' -ExpectedMessage 'project:alpha must have exactly one direct account-scoped, conditioned Storage Blob Data Owner grant.' -Mutate {
        param($caseDirectory)
        $inventory = Get-Content (Join-Path $caseDirectory 'isolation-inventory.json') -Raw | ConvertFrom-Json
        ($inventory.arm_roles | Where-Object { $_.principal -eq 'project:alpha' }).condition = 'no'
        $inventory | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $caseDirectory 'isolation-inventory.json') -Encoding utf8
    }

    Assert-InvalidFixture -Name 'wrong-project-blob-condition' -ExpectedMessage 'project:alpha Blob condition does not match the Terraform-generated project-prefix condition.' -Mutate {
        param($caseDirectory)
        $inventory = Get-Content (Join-Path $caseDirectory 'isolation-inventory.json') -Raw | ConvertFrom-Json
        ($inventory.arm_roles | Where-Object { $_.principal -eq 'project:alpha' }).condition_expression = "(@Resource[Microsoft.Storage/storageAccounts/blobServices/containers:name] StringStartsWithIgnoreCase 'wrong-prefix')"
        $inventory | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $caseDirectory 'isolation-inventory.json') -Encoding utf8
    }

    Assert-InvalidFixture -Name 'inherited-project-blob-role' -ExpectedMessage 'project:alpha must have exactly one direct account-scoped, conditioned Storage Blob Data Owner grant.' -Mutate {
        param($caseDirectory)
        $inventory = Get-Content (Join-Path $caseDirectory 'isolation-inventory.json') -Raw | ConvertFrom-Json
        $inventory.arm_roles = @($inventory.arm_roles) + @(
            [pscustomobject]@{ principal = 'project:alpha'; resource = 'storage'; role = 'Storage Blob Data Reader'; granularity = 'INHERITED (spans resource)'; is_direct = $false; is_inherited = $true; condition = 'no'; condition_version = $null; condition_expression = $null }
        )
        $inventory | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $caseDirectory 'isolation-inventory.json') -Encoding utf8
    }

    Assert-InvalidFixture -Name 'partial-container-access' -ExpectedMessage 'cosmos scoped-alpha -> alpha was PARTIAL; expected ALLOW.' -Mutate {
        param($caseDirectory)
        $matrix = Get-Content (Join-Path $caseDirectory 'cross-access-matrix.json') -Raw | ConvertFrom-Json
        $matrix.matrix.'scoped-alpha'.results.alpha.cosmos.outcome = 'PARTIAL'
        $matrix.matrix.'scoped-alpha'.results.alpha.verdict = 'UNEXPECTED'
        $matrix | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $caseDirectory 'cross-access-matrix.json') -Encoding utf8
    }

    $ambiguousFailed = $false
    try {
        Wait-ForSingleNewValue -Baseline @('base') -GetValues { @('base', 'new-a', 'new-b') } -TimeoutSeconds 0 -PollSeconds 0 -Description 'fixture index' | Out-Null
    }
    catch {
        $ambiguousFailed = $_.Exception.Message -like 'Expected exactly one new*'
    }
    if (-not $ambiguousFailed) { throw 'Ambiguous Search discovery did not fail closed.' }
    Write-Host 'PASS  ambiguous Search discovery' -ForegroundColor Green

    $authFailure = Resolve-AccessFailure -Status 401 -Body 'unauthorized'
    if ($authFailure.outcome -ne 'ERROR') { throw 'HTTP 401 was incorrectly accepted as an authorization denial.' }
    $networkFailure = Resolve-AccessFailure -Status 403 -Body 'Request blocked by public network access settings.'
    if ($networkFailure.outcome -ne 'BLOCKED') { throw 'Network-origin HTTP 403 was not classified as BLOCKED.' }
    $rbacFailure = Resolve-AccessFailure -Status 403 -Body 'AuthorizationPermissionMismatch'
    if ($rbacFailure.outcome -ne 'DENY') { throw 'Authorization HTTP 403 was not classified as DENY.' }
    Write-Host 'PASS  authentication, network, and authorization classification' -ForegroundColor Green
}
finally {
    Remove-Item $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host 'Evidence contract tests passed.' -ForegroundColor Green