<#
.SYNOPSIS
    Verifies approved contract, icon, output, and PNG integrity after rendering.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$diagramDir = Join-Path $root 'docs\diagrams'
$renderDir = Join-Path $diagramDir 'rendered'
$lock = Get-Content (Join-Path $diagramDir 'approved-contract-lock.json') -Raw | ConvertFrom-Json
$manifestPath = Join-Path $renderDir 'render-manifest.json'
if (-not (Test-Path $manifestPath)) { throw "Missing render manifest: $manifestPath" }
$manifest = Get-Content $manifestPath -Raw | ConvertFrom-Json
$failures = @()

if ($manifest.approval_lock -ne 'approved-contract-lock.json') {
    $failures += "Unexpected approval lock '$($manifest.approval_lock)'."
}
$rendererPath = Join-Path $root $manifest.renderer
if (-not (Test-Path $rendererPath)) {
    $failures += "Missing renderer '$($manifest.renderer)'."
}
else {
    $rendererHash = (Get-FileHash $rendererPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($rendererHash -ne $manifest.renderer_sha256) { $failures += 'Renderer hash does not match the render manifest.' }
}

function Get-PngDimensions {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $signature = [byte[]](137, 80, 78, 71, 13, 10, 26, 10)
    $validSignature = $bytes.Length -ge 24
    if ($validSignature) {
        for ($index = 0; $index -lt $signature.Length; $index++) {
            if ($bytes[$index] -ne $signature[$index]) { $validSignature = $false; break }
        }
    }
    if (-not $validSignature) { throw "Not a valid PNG: $Path" }

    $width = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($bytes, 16))
    $height = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($bytes, 20))
    return [pscustomobject]@{ width = $width; height = $height }
}

$contractCount = @($lock.contracts.PSObject.Properties).Count
if ($manifest.outputs.Count -ne $contractCount) {
    $failures += "Render manifest contains $($manifest.outputs.Count) outputs; expected $contractCount."
}

foreach ($contractProperty in $lock.contracts.PSObject.Properties) {
    $contract = $contractProperty.Value
    $sourcePath = Join-Path $diagramDir $contract.source
    $sourceHash = (Get-FileHash $sourcePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($sourceHash -ne $contract.sha256) { $failures += "Approved contract changed: $($contract.source)." }

    $output = $manifest.outputs | Where-Object { $_.contract -eq $contract.source }
    if (-not $output) { $failures += "No rendered output for $($contract.source)."; continue }
    $outputPath = Join-Path $renderDir $output.output
    if (-not (Test-Path $outputPath)) { $failures += "Missing PNG $($output.output)."; continue }
    $outputHash = (Get-FileHash $outputPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($outputHash -ne $output.output_sha256) { $failures += "Output hash mismatch for $($output.output)." }
    if ((Get-Item $outputPath).Length -ne $output.bytes) { $failures += "Byte count mismatch for $($output.output)." }
    $dimensions = Get-PngDimensions -Path $outputPath
    if ($dimensions.width -ne 3840 -or $dimensions.height -ne 2160) {
        $failures += "$($output.output) is $($dimensions.width)x$($dimensions.height), expected 3840x2160."
    }
    if ($output.node_count -ne $contract.nodes.Count -or $output.edge_count -ne $contract.edges.Count -or $output.boundary_count -ne $contract.boundaries.Count) {
        $failures += "Fidelity inventory counts differ for $($contract.source)."
    }
}

foreach ($icon in $manifest.icons) {
    $iconPath = Join-Path $diagramDir $icon.file
    if (-not (Test-Path $iconPath)) { $failures += "Missing official icon $($icon.file)."; continue }
    $iconHash = (Get-FileHash $iconPath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($iconHash -ne $icon.sha256) { $failures += "Official icon hash mismatch for $($icon.file)." }
    if ((Get-Item $iconPath).Length -ne $icon.bytes) { $failures += "Official icon byte count mismatch for $($icon.file)." }
}

if ($failures) {
    Write-Host 'Rendered diagram validation failed:' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host "Rendered diagrams valid: $($manifest.outputs.Count) PNGs at 3840x2160." -ForegroundColor Green
