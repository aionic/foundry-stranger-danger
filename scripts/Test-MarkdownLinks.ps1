<#
.SYNOPSIS
    Validates local Markdown file targets and heading anchors.
#>
[CmdletBinding()]
param(
    [string]$Root = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'
$resolvedRoot = Resolve-Path $Root
$excludedSegments = @('\.git\', '\.beads\', '\node_modules\', '\.terraform\')

function ConvertTo-GitHubHeadingAnchor {
    param([Parameter(Mandatory)][string]$Heading)

    $value = $Heading.ToLowerInvariant()
    $value = [regex]::Replace($value, '<[^>]+>', '')
    $value = [regex]::Replace($value, '[`*_~]', '')
    $value = [regex]::Replace($value, '[^\p{L}\p{N}\s_-]', '')
    $value = [regex]::Replace($value.Trim(), '\s+', '-')
    return $value
}

function Get-MarkdownAnchors {
    param([Parameter(Mandatory)][string]$Path)

    $counts = @{}
    $anchors = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($line in Get-Content $Path) {
        if ($line -notmatch '^#{1,6}\s+(.+?)\s*$') { continue }
        $baseAnchor = ConvertTo-GitHubHeadingAnchor -Heading $Matches[1]
        if (-not $baseAnchor) { continue }
        $count = if ($counts.ContainsKey($baseAnchor)) { $counts[$baseAnchor] + 1 } else { 0 }
        $counts[$baseAnchor] = $count
        $anchor = if ($count -eq 0) { $baseAnchor } else { "$baseAnchor-$count" }
        [void]$anchors.Add($anchor)
    }
    return $anchors
}

$markdownFiles = @(
    Get-ChildItem $resolvedRoot -Recurse -File -Filter '*.md' |
        Where-Object {
            $path = $_.FullName
            -not ($excludedSegments | Where-Object { $path -like "*$_*" })
        }
)
$anchorCache = @{}
$failures = @()

foreach ($source in $markdownFiles) {
    $content = Get-Content $source.FullName -Raw
    foreach ($match in [regex]::Matches($content, '!?\[[^\]]*\]\(([^)]+)\)')) {
        $target = $match.Groups[1].Value.Trim()
        if (-not $target -or $target -match '^(https?://|mailto:)') { continue }

        $parts = $target -split '#', 2
        $pathPart = [System.Uri]::UnescapeDataString($parts[0])
        $anchorPart = if ($parts.Count -eq 2) { [System.Uri]::UnescapeDataString($parts[1]) } else { $null }
        $targetPath = if ($pathPart) {
            [System.IO.Path]::GetFullPath((Join-Path $source.DirectoryName $pathPart))
        }
        else {
            $source.FullName
        }
        $lineNumber = 1 + [regex]::Matches($content.Substring(0, $match.Index), "`n").Count
        $relativeSource = [System.IO.Path]::GetRelativePath($resolvedRoot, $source.FullName)

        if (-not (Test-Path $targetPath)) {
            $failures += "$relativeSource`:$lineNumber targets missing '$target'."
            continue
        }
        if ((Get-Item $targetPath).PSIsContainer -or -not $anchorPart) { continue }

        if (-not $anchorCache.ContainsKey($targetPath)) {
            $anchorCache[$targetPath] = Get-MarkdownAnchors -Path $targetPath
        }
        if (-not $anchorCache[$targetPath].Contains($anchorPart)) {
            $failures += "$relativeSource`:$lineNumber targets missing anchor '#$anchorPart' in '$pathPart'."
        }
    }
}

if ($failures) {
    Write-Host 'Markdown link validation failed:' -ForegroundColor Red
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

Write-Host "Markdown links valid: $($markdownFiles.Count) files." -ForegroundColor Green
