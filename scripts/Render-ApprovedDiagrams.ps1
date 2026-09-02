<#
.SYNOPSIS
    Renders the human-approved Mermaid contracts as Azure-native PNGs.

.DESCRIPTION
    Refuses to render if an approved Mermaid source hash differs from
    docs/diagrams/approved-contract-lock.json. Uses official Microsoft Azure
    architecture SVGs and writes a render manifest with source, icon, and output
    hashes plus image QA measurements.
#>
[CmdletBinding()]
param(
    [string]$BrowserPath
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')

if (-not $BrowserPath -and $env:PUPPETEER_EXECUTABLE_PATH) {
    $BrowserPath = $env:PUPPETEER_EXECUTABLE_PATH
}
if (-not $BrowserPath) {
    $cachedBrowsers = @(
        Get-ChildItem (Join-Path $env:USERPROFILE '.cache\puppeteer\chrome-headless-shell') `
            -Recurse -Filter 'chrome-headless-shell.exe' -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTimeUtc -Descending
    )
    if ($cachedBrowsers) { $BrowserPath = $cachedBrowsers[0].FullName }
}
if (-not $BrowserPath) {
    $installedBrowsers = @(
        'C:\Program Files\Google\Chrome\Application\chrome.exe',
        'C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe',
        'C:\Program Files\Microsoft\Edge\Application\msedge.exe'
    ) | Where-Object { Test-Path $_ }
    if ($installedBrowsers) { $BrowserPath = $installedBrowsers[0] }
}
if (-not $BrowserPath -or -not (Test-Path $BrowserPath)) {
    throw 'No Chromium browser found. Run npm run diagrams:browser or pass -BrowserPath.'
}

$renderer = Join-Path $root 'scripts\render-approved-diagrams.mjs'
& node $renderer $BrowserPath
if ($LASTEXITCODE -ne 0) { throw "Approved diagram rendering failed with exit code $LASTEXITCODE." }

& (Join-Path $PSScriptRoot 'Test-RenderedDiagrams.ps1')
if ($LASTEXITCODE -ne 0) { throw 'Rendered diagram validation failed.' }
