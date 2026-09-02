<#
.SYNOPSIS
    Deploys, bootstraps and hardens the environment in one run, then proves the
    hardening took effect before declaring it usable.

.DESCRIPTION
    Handles the ordering constraint that makes a single-pass hardened deployment
    impossible, and closes the exposure it creates.

    WHY THERE IS A BOOTSTRAP WINDOW

    Azure Cosmos DB rejects a role assignment scoped to a container that does not
    exist. The modern runtime's <project-id>-agent-definitions-v1 and
    <project-id>-run-state-v1 containers are created lazily, on a project's first
    Responses API invocation - not by the capability host. So on a clean
    deployment those containers cannot be targeted, and the only scope that
    works is the shared 'enterprise_memory' DATABASE.

    That grant spans every project in the account. Between phase 1 and phase 4
    below, each project identity can reach other projects' containers.

    WHY THE WINDOW IS NOT CLOSED BY PRE-CREATING THE CONTAINERS

    It was considered and rejected. The service-created containers carry an
    elaborate service-owned indexing policy - 33 composite indexes on internal
    document paths. Reproducing it in IaC is brittle, drifts silently when the
    service changes, and a mismatch risks degraded queries or a broken runtime.

    HOW THE WINDOW IS MADE SAFE

      - The only data written during the window is the synthetic hello-world
        canary. No real workload is present.
      - The window is bounded by this script; it does not depend on an operator
        remembering to run a second step.
            - Phase 5 VERIFIES Cosmos and Storage hardening and FAILS CLOSED. The
                environment is not reported usable until project grants are scoped as
                intended and live own-project/cross-project reads match expectations.

        SEARCH REMAINS A MEASURED RESIDUAL RISK

        This validation topology intentionally uses one shared AI Search service to
        reproduce the Search finding. It is not made project-isolated by this
        script. Production deployments that use vector stores or file search need
        one Search service per project.

    If you need zero window, give each project its own Cosmos DB account. A
    database-scoped grant is then inherently confined to one project. See
    docs/00-report.md.

.PARAMETER SkipDeploy
    Assume the infrastructure already exists and start at the agent run.

.PARAMETER VerifyOnly
    Run phase 5 only, against whatever is currently deployed.

.PARAMETER PreflightLocation
    Override the model-quota region checked by preflight. Defaults to the
    effective Terraform var.location value.

.PARAMETER PreflightModelName
    Override the model checked by preflight. Defaults to the effective
    Terraform var.model_name value.

.EXAMPLE
    .\scripts\deploy-and-harden.ps1
#>
[CmdletBinding()]
param(
    [switch]$SkipDeploy,
    [switch]$VerifyOnly,
    [switch]$SkipPreflight,
    [string]$PreflightLocation,
    [string]$PreflightModelName
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$terraformDir = Join-Path $root 'terraform'
$evidenceDir = Join-Path $root 'evidence'
$modernContainersMarker = Join-Path $terraformDir 'modern-containers.auto.tfvars.json'
. (Join-Path $PSScriptRoot 'EvidenceContract.ps1')

function Write-Phase {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 74) -ForegroundColor Cyan
    Write-Host "  $Text" -ForegroundColor Cyan
    Write-Host ('=' * 74) -ForegroundColor Cyan
}

function Get-TfOutputs {
    $o = @{}
    (terraform -chdir="$terraformDir" output -json | ConvertFrom-Json).PSObject.Properties |
        ForEach-Object { $o[$_.Name] = $_.Value.value }
    return $o
}

function Get-ConfiguredTerraformValue {
    param([Parameter(Mandatory)][string]$Name)

    $value = "var.$Name" | & terraform "-chdir=$terraformDir" console -no-color 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $value) {
        throw "Could not resolve Terraform variable '$Name'. Run terraform init or provide the corresponding preflight override."
    }
    return "$value".Trim().Trim('"')
}

function Invoke-Terraform {
    param([string[]]$Vars, [string]$LogName)
    $args = @("-chdir=$terraformDir", 'apply', '-input=false', '-auto-approve', '-no-color')
    foreach ($v in $Vars) { $args += "-var=$v" }
    $log = Join-Path $root $LogName
    & terraform @args 2>&1 | Tee-Object -FilePath $log | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Get-Content $log | Select-String -Pattern '^Error:' -Context 0, 8 | Select-Object -First 3
        throw "terraform apply failed. Full log: $log"
    }
    Get-Content $log | Select-String -Pattern 'Apply complete'
}

# ---------------------------------------------------------------------------
# Phase 5 lives in a function because it is also the -VerifyOnly entrypoint.
# ---------------------------------------------------------------------------
function Test-Hardened {
    Write-Phase 'PHASE 5  Verifying the hardening'

    # Two independent checks, and BOTH are load-bearing.
    #
    # The probe matrix uses surrogate principals holding cloned permission
    # shapes, so it proves the enforcement MECHANISM works - it says nothing
    # about what the real project identities currently hold. Verified the hard
    # way: with the environment deliberately reverted to database scope, all six
    # probe verdicts still read PASS while the deployment was leaking. Only the
    # configuration assertion caught it.
    #
    # Conversely the configuration check alone would trust that a container
    # scope is actually enforced by Cosmos rather than merely recorded.
    $failures = @()
    & (Join-Path $PSScriptRoot '10-show-isolation.ps1') -EvidenceDir $evidenceDir *> $null
    $inventory = Get-Content (Join-Path $evidenceDir 'isolation-inventory.json') -Raw | ConvertFrom-Json
    $configurationFailures = @(Test-DeploymentConfiguration -Inventory $inventory)
    $failures += $configurationFailures

    # 1. No project identity may retain a grant broader than a container.
    Write-Host "`nCosmos grant scope per principal:" -ForegroundColor Cyan
    foreach ($g in $inventory.cosmos_data_roles | Group-Object principal, granularity | Sort-Object Name) {
        Write-Host ("  {0,-48} x{1}" -f $g.Name, $g.Count)
    }

    $broadProjectGrants = $inventory.cosmos_data_roles |
        Where-Object { $_.principal -like 'project:*' -and $_.granularity -ne 'container' }

    if ($broadProjectGrants) {
        foreach ($g in $broadProjectGrants) {
            $failures += "Project identity $($g.principal) still holds a '$($g.granularity)' Cosmos grant."
        }
    }
    else {
        Write-Host "`n  PASS  every project identity is container-scoped" -ForegroundColor Green
    }

    # 2. Every container must be attributable to a project.
    $orphans = $inventory.cosmos_containers | Where-Object { $_.owner -eq '<unattributed>' }
    if ($orphans) { $failures += "Containers not attributable to a project: $($orphans.name -join ', ')" }

    # 3. Every project identity must have a conditioned Blob data grant. An
    # unconditioned account-scoped data role would span every project.
    Write-Host "`nStorage data grant scope per project:" -ForegroundColor Cyan
    foreach ($projectName in $inventory.projects.PSObject.Properties.Name) {
        $projectBlobRoles = @($inventory.arm_roles | Where-Object {
                $_.principal -eq "project:$projectName" -and
                $_.resource -eq 'storage' -and
                $_.role -like 'Storage Blob Data *'
            })
        $conditionedOwner = @($projectBlobRoles | Where-Object {
                $_.role -eq 'Storage Blob Data Owner' -and $_.condition -eq 'yes'
            })
        $unbounded = @($projectBlobRoles | Where-Object {
                $_.granularity -like 'ACCOUNT*' -and $_.condition -ne 'yes'
            })

        if ($conditionedOwner.Count -eq 1 -and -not $unbounded -and
            -not ($configurationFailures | Where-Object { $_ -like "project:$projectName*Blob*" })) {
            Write-Host ("  PASS  {0,-16} conditioned by project container prefix" -f "project:$projectName") -ForegroundColor Green
        }
    }

    # 4. Live enforcement check. Configuration review alone is not proof.
    Write-Host "`nRunning live cross-project access matrix..." -ForegroundColor Cyan
    & (Join-Path $PSScriptRoot '11-test-cross-access.ps1') -EvidenceDir $evidenceDir | Out-Null
    $probeExit = $LASTEXITCODE

    $matrix = Get-Content (Join-Path $evidenceDir 'cross-access-matrix.json') -Raw | ConvertFrom-Json

    if ($probeExit -eq 2) {
        $failures += 'Probes hit network-origin refusals. This run proves nothing - a firewall block is not a denial. Check Cosmos public network access and the control-bypass tags.'
    }

    foreach ($probeKey in $matrix.matrix.PSObject.Properties.Name) {
        $probe = $matrix.matrix.$probeKey
        foreach ($pk in $probe.results.PSObject.Properties.Name) {
            $expected = if (-not $probe.own_project -or $pk -eq $probe.own_project) { 'ALLOW' } else { 'DENY' }
            foreach ($store in @('cosmos', 'blob')) {
                $outcome = $probe.results.$pk.$store.outcome
                if ($outcome -ne $expected) {
                    $failures += "$store read $probeKey -> $pk returned $outcome, expected $expected."
                }
            }
        }
    }
    if (-not ($failures | Where-Object { $_ -match '^(cosmos|blob) read ' })) {
        Write-Host '  PASS  Cosmos and Blob positive/negative controls matched' -ForegroundColor Green
    }

    return $failures
}

# ---------------------------------------------------------------------------

if ($VerifyOnly) {
    $failures = Test-Hardened
    if ($failures) {
        Write-Host "`nVERIFICATION FAILED" -ForegroundColor Red
        $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        exit 1
    }
    Write-Host "`nVERIFIED - Cosmos and Storage hardened. Shared Search remains a lab condition." -ForegroundColor Green
    exit 0
}

if (-not $SkipPreflight) {
    Write-Phase 'PHASE 0  Preflight'
    $effectivePreflightLocation = if ($PreflightLocation) { $PreflightLocation } else { Get-ConfiguredTerraformValue -Name 'location' }
    $effectivePreflightModel = if ($PreflightModelName) { $PreflightModelName } else { Get-ConfiguredTerraformValue -Name 'model_name' }
    Write-Host "Checking model quota for $effectivePreflightModel in $effectivePreflightLocation." -ForegroundColor DarkGray
    & (Join-Path $PSScriptRoot '00-preflight.ps1') -Location $effectivePreflightLocation -ModelName $effectivePreflightModel
    if ($LASTEXITCODE -ne 0) { throw 'Preflight failed.' }
}

if (-not $SkipDeploy) {
    Remove-Item $modernContainersMarker -Force -ErrorAction SilentlyContinue
    Write-Phase 'PHASE 1  Deploy and bootstrap'
    Write-Host @'
Deploying with database-scoped Cosmos grants.

This is the only scope that works on a clean deployment: the modern runtime's
containers do not exist yet, and Cosmos rejects a grant scoped to a container
that is absent.

>>> The bootstrap window opens here. Until phase 4 completes, each project
>>> identity can reach other projects containers. Do NOT introduce real data.
'@ -ForegroundColor Yellow

    Invoke-Terraform -Vars @('isolation_mode=documented', 'modern_containers_exist=false') -LogName 'phase1-bootstrap.log'
}

Write-Phase 'PHASE 2  Hello-world agent per project'
Write-Host 'Synthetic canary data only. This call is what creates the modern containers.' -ForegroundColor DarkGray
& (Join-Path $PSScriptRoot '02-run-agents.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Agent run failed. Containers will not exist and hardening cannot proceed.' }

Write-Phase 'PHASE 3  Confirming containers exist'
$tf = Get-TfOutputs
$expectedContainers = @()
foreach ($pk in $tf.projects.PSObject.Properties.Name) {
    $expectedContainers += $tf.projects.$pk.expected_cosmos_containers
}
$existing = Wait-ForExpectedValues `
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
    -Description 'all project Cosmos containers'
Write-Host "  All $($existing.Count) containers present." -ForegroundColor Green

# Persist the lifecycle fact for every subsequent plain terraform plan. Without
# this marker, var.modern_containers_exist falls back to false and Terraform
# would propose removing the modern container grants from a hardened project.
@{ modern_containers_exist = $true } | ConvertTo-Json | Set-Content $modernContainersMarker -Encoding utf8

Write-Phase 'PHASE 4  Hardening'
Write-Host 'Replacing database-scoped grants with per-container grants.' -ForegroundColor DarkGray
Invoke-Terraform -Vars @('isolation_mode=hardened', 'modern_containers_exist=true') -LogName 'phase4-harden.log'

$failures = Test-Hardened

Write-Host ''
if ($failures) {
    Write-Host ('!' * 74) -ForegroundColor Red
    Write-Host '  HARDENING NOT VERIFIED - TREAT THIS ENVIRONMENT AS UNSAFE' -ForegroundColor Red
    Write-Host ('!' * 74) -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    Write-Host "`nThe bootstrap window is still open. Do not introduce real data." -ForegroundColor Red
    Write-Host 'Re-run with -VerifyOnly after investigating.' -ForegroundColor Red
    exit 1
}

Write-Host ('=' * 74) -ForegroundColor Green
Write-Host '  COSMOS AND STORAGE HARDENING VERIFIED' -ForegroundColor Green
Write-Host ('=' * 74) -ForegroundColor Green
Write-Host @"

    Every project identity is scoped to its own Cosmos and Blob containers.
    Live own-project reads succeeded and cross-project reads were denied.

    AI Search is intentionally shared in this validation topology and remains
    reachable across projects. Use one Search service per project in production.

  Evidence: $evidenceDir

  Note: the canary data written during bootstrap is still present. Remove it
  before using this environment for anything real.
"@ -ForegroundColor Green
