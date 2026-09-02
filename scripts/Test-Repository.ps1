<#
.SYNOPSIS
    Runs all local quality gates for the repository.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$terraformDir = Join-Path $root 'terraform'

function Invoke-Gate {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    Write-Host "`n=== $Name ===" -ForegroundColor Cyan
    $global:LASTEXITCODE = 0
    & $Action
    if ($LASTEXITCODE -ne 0) { throw "$Name failed with exit code $LASTEXITCODE." }
}

Invoke-Gate -Name 'PowerShell syntax' -Action {
    $failures = @()
    foreach ($script in Get-ChildItem (Join-Path $root 'scripts') -Filter '*.ps1') {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $script.FullName,
            [ref]$tokens,
            [ref]$errors
        )
        foreach ($error in $errors) { $failures += "$($script.Name): $($error.Message)" }
    }
    foreach ($script in Get-ChildItem (Join-Path $root 'tests') -Filter '*.ps1' -Recurse) {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile(
            $script.FullName,
            [ref]$tokens,
            [ref]$errors
        )
        foreach ($error in $errors) { $failures += "$($script.Name): $($error.Message)" }
    }
    if ($failures) { throw ($failures -join "`n") }
    Write-Host 'PowerShell syntax valid.' -ForegroundColor Green
}

Invoke-Gate -Name 'Terraform formatting' -Action {
    & terraform "-chdir=$terraformDir" fmt -check -no-color
}

Invoke-Gate -Name 'Terraform validation' -Action {
    & terraform "-chdir=$terraformDir" validate -no-color
}

Invoke-Gate -Name 'Evidence contract tests' -Action {
    & pwsh -NoProfile -File (Join-Path $root 'tests\Test-EvidenceContract.ps1')
}

$publishedEvidenceRoot = Join-Path $root 'evidence\published'
if (Test-Path $publishedEvidenceRoot) {
    foreach ($publishedDirectory in Get-ChildItem $publishedEvidenceRoot -Directory) {
        Invoke-Gate -Name "Published evidence $($publishedDirectory.Name)" -Action {
            & pwsh -NoProfile -File (Join-Path $root 'scripts\Test-PublishedEvidence.ps1') -PublishedEvidenceDir $publishedDirectory.FullName
        }
    }
}

Invoke-Gate -Name 'Markdown links' -Action {
    & pwsh -NoProfile -File (Join-Path $root 'scripts\Test-MarkdownLinks.ps1')
}

Invoke-Gate -Name 'Mermaid contracts' -Action {
    & pwsh -NoProfile -File (Join-Path $root 'scripts\Test-MermaidDiagrams.ps1')
}

$renderManifest = Join-Path $root 'docs\diagrams\rendered\render-manifest.json'
if (Test-Path $renderManifest) {
    Invoke-Gate -Name 'Rendered diagrams' -Action {
        & pwsh -NoProfile -File (Join-Path $root 'scripts\Test-RenderedDiagrams.ps1')
    }
}

Invoke-Gate -Name 'Git diff hygiene' -Action {
    & git -C $root diff --check
}

Write-Host "`nAll repository quality gates passed." -ForegroundColor Green