<#
.SYNOPSIS
    Validates every authoritative Mermaid contract and creates local previews.

.DESCRIPTION
    Uses the repository-pinned Mermaid CLI and installed Microsoft Edge. Preview
    PNGs are written outside the repository by default. They are validation
    artifacts, not approved customer deliverables.
#>
[CmdletBinding()]
param(
    [string]$PreviewDirectory = (Join-Path $env:TEMP 'foundry-stranger-danger-diagram-previews'),
    [string]$BrowserPath
)

$ErrorActionPreference = 'Stop'
$root = Resolve-Path (Join-Path $PSScriptRoot '..')
$diagramDir = Join-Path $root 'docs\diagrams'
$mmdc = Join-Path $root 'node_modules\.bin\mmdc.cmd'
$config = Join-Path $diagramDir 'mermaid-config.json'

if (-not (Test-Path $mmdc)) {
    throw 'Mermaid CLI is not installed. Run npm install from the repository root.'
}

New-Item -ItemType Directory -Force -Path $PreviewDirectory | Out-Null

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

$puppeteerConfig = Join-Path $PreviewDirectory 'puppeteer-config.json'
@{
    executablePath = $BrowserPath
    headless       = $true
    args           = @('--no-sandbox', '--disable-setuid-sandbox')
} | ConvertTo-Json -Depth 3 | Set-Content -Path $puppeteerConfig -Encoding utf8

$contracts = @(Get-ChildItem $diagramDir -Filter '*.mmd' | Sort-Object Name)
if ($contracts.Count -eq 0) { throw "No Mermaid contracts found in $diagramDir" }

$failures = @()
foreach ($contract in $contracts) {
    $preview = Join-Path $PreviewDirectory "$($contract.BaseName).png"
    Write-Host "Validating $($contract.Name)..." -ForegroundColor Cyan
    & $mmdc `
        --input $contract.FullName `
        --output $preview `
        --configFile $config `
        --puppeteerConfigFile $puppeteerConfig `
        --backgroundColor white `
        --width 1920 `
        --height 1080 `
        --quiet

    if ($LASTEXITCODE -ne 0 -or -not (Test-Path $preview) -or (Get-Item $preview).Length -eq 0) {
        $failures += $contract.Name
    }
}

if ($failures) {
    throw "Mermaid validation failed: $($failures -join ', ')"
}

Write-Host "Validated $($contracts.Count) contracts." -ForegroundColor Green
Write-Host "Browser: $BrowserPath" -ForegroundColor Green
Write-Host "Preview directory: $PreviewDirectory" -ForegroundColor Green
Write-Host 'These previews are not final customer PNGs.' -ForegroundColor Yellow
