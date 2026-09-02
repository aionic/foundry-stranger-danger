<#
.SYNOPSIS
    Pre-deployment checks.

.DESCRIPTION
    Verifies the things that, if missing, cause a failure late and expensively -
    particularly a failed capability host, which cannot be repaired in place and
    forces the project to be deleted and recreated.
#>
[CmdletBinding()]
param(
    [string]$Location = 'eastus2',
    [string]$ModelName = 'gpt-4o'
)

$ErrorActionPreference = 'Stop'
$problems = @()

function Test-Item {
    param([string]$Name, [scriptblock]$Check)
    Write-Host -NoNewline ("  {0,-46}" -f $Name)
    try {
        $result = & $Check
        if ($result.ok) { Write-Host "OK  $($result.detail)" -ForegroundColor Green }
        else { Write-Host "FAIL  $($result.detail)" -ForegroundColor Red; $script:problems += $Name }
    }
    catch {
        Write-Host "FAIL  $_" -ForegroundColor Red
        $script:problems += $Name
    }
}

Write-Host "`nTooling" -ForegroundColor Cyan
Test-Item 'terraform on PATH' { @{ ok = [bool](Get-Command terraform -EA SilentlyContinue); detail = (terraform version | Select-Object -First 1) } }
Test-Item 'az on PATH' { @{ ok = [bool](Get-Command az -EA SilentlyContinue); detail = '' } }

Write-Host "`nAzure context" -ForegroundColor Cyan
$account = az account show -o json 2>$null | ConvertFrom-Json
Test-Item 'signed in' { @{ ok = $null -ne $account; detail = "$($account.name)" } }

Write-Host "`nPrivilege" -ForegroundColor Cyan
Test-Item 'can write role assignments (Owner / RBAC Admin)' {
    $me = az ad signed-in-user show --query id -o tsv
    $assignments = az role assignment list --assignee $me --include-inherited --all -o json | ConvertFrom-Json
    $roles = $assignments.roleDefinitionName | Sort-Object -Unique
    $ok = $roles -contains 'Owner' -or $roles -contains 'User Access Administrator' -or $roles -contains 'Role Based Access Control Administrator'
    @{ ok = $ok; detail = ($roles -join ', ') }
}

Write-Host "`nResource providers" -ForegroundColor Cyan
foreach ($ns in @('Microsoft.CognitiveServices', 'Microsoft.DocumentDB', 'Microsoft.Storage', 'Microsoft.Search', 'Microsoft.KeyVault', 'Microsoft.MachineLearningServices', 'Microsoft.App', 'Microsoft.ContainerService')) {
    Test-Item $ns { $s = az provider show -n $ns --query registrationState -o tsv 2>$null; @{ ok = ($s -eq 'Registered'); detail = $s } }
}

Write-Host "`nModel capacity in $Location" -ForegroundColor Cyan
Test-Item "$ModelName GlobalStandard quota" {
    $usage = az cognitiveservices usage list -l $Location -o json | ConvertFrom-Json
    $q = $usage | Where-Object { $_.name.value -eq "OpenAI.GlobalStandard.$ModelName" }
    $free = if ($q) { $q.limit - $q.currentValue } else { 0 }
    @{ ok = ($free -ge 50); detail = "$free free of $($q.limit)" }
}

Write-Host "`nEntra" -ForegroundColor Cyan
Test-Item 'can create app registrations (probe identities)' {
    $app = az ad app create --display-name 'zz-foundry-isolation-preflight' -o json 2>$null | ConvertFrom-Json
    if ($app.appId) { az ad app delete --id $app.appId 2>$null | Out-Null; @{ ok = $true; detail = 'verified and cleaned up' } }
    else { @{ ok = $false; detail = 'blocked - set enable_probe_identities = false' } }
}

Write-Host ''
if ($problems) {
    Write-Host "Preflight failed:" -ForegroundColor Red
    $problems | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
Write-Host 'Preflight passed.' -ForegroundColor Green
