[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^v\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$')]
    [string]$Version,

    [string]$OutputDirectory = (Join-Path $PSScriptRoot '..\dist'),

    [switch]$SkipVersionCheck
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$outputRoot = [IO.Path]::GetFullPath($OutputDirectory)
$includeFile = Join-Path $PSScriptRoot 'package-include.txt'
$entryPoint = Join-Path $repositoryRoot 'PTCGPB.ahk'
$bundleName = "PTCGPB-$Version"
$stagingParent = Join-Path ([IO.Path]::GetTempPath()) ("ptcgpb-release-" + [guid]::NewGuid().ToString('N'))
$stagingRoot = Join-Path $stagingParent $bundleName

if (-not $SkipVersionCheck) {
    $entryPointText = Get-Content -LiteralPath $entryPoint -Raw
    $match = [regex]::Match($entryPointText, '(?m)^\s*,?localVersion\s*:=\s*"([^"]+)"')
    if (-not $match.Success) {
        throw 'Could not find localVersion in PTCGPB.ahk.'
    }
    if ($match.Groups[1].Value -ne $Version) {
        throw "PTCGPB.ahk declares $($match.Groups[1].Value), but the requested release is $Version."
    }
}

$trackedFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$generatedPackageFiles = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$null = $generatedPackageFiles.Add('Helper/carddb.exe')
$null = $generatedPackageFiles.Add('Helper/cardimage.exe')
$gitPaths = @(& git -C $repositoryRoot ls-files)
if ($LASTEXITCODE -ne 0) {
    throw 'Could not enumerate Git-tracked files for release packaging.'
}
foreach ($gitPath in $gitPaths) {
    $null = $trackedFiles.Add($gitPath.Replace('\', '/'))
}

function Get-RelativePath {
    param([Parameter(Mandatory = $true)][string]$Path)
    $fullPath = [IO.Path]::GetFullPath($Path)
    $rootWithSeparator = $repositoryRoot.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar
    if (-not $fullPath.StartsWith($rootWithSeparator, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Package path escapes the repository: $fullPath"
    }
    return $fullPath.Substring($rootWithSeparator.Length).Replace('\', '/')
}

function Add-PackageFile {
    param(
        [Parameter(Mandatory = $true)][Collections.Generic.Dictionary[string, string]]$Files,
        [Parameter(Mandatory = $true)][string]$Path
    )
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required package file does not exist: $Path"
    }
    $relativePath = Get-RelativePath -Path $Path
    if (-not $trackedFiles.Contains($relativePath) -and -not $generatedPackageFiles.Contains($relativePath)) {
        return $false
    }
    $Files[$relativePath] = [IO.Path]::GetFullPath($Path)
    return $true
}

$packageFiles = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
$patterns = Get-Content -LiteralPath $includeFile | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('#') }

foreach ($pattern in $patterns) {
    $normalizedPattern = $pattern.Replace('/', [IO.Path]::DirectorySeparatorChar)
    if ($normalizedPattern.EndsWith("$([IO.Path]::DirectorySeparatorChar)**")) {
        $directoryPart = $normalizedPattern.Substring(0, $normalizedPattern.Length - 3)
        $directoryPath = Join-Path $repositoryRoot $directoryPart
        if (-not (Test-Path -LiteralPath $directoryPath -PathType Container)) {
            throw "Required package directory does not exist: $pattern"
        }
        $addedTrackedFile = $false
        Get-ChildItem -LiteralPath $directoryPath -File -Recurse | ForEach-Object {
            if (Add-PackageFile -Files $packageFiles -Path $_.FullName) {
                $addedTrackedFile = $true
            }
        }
        if (-not $addedTrackedFile) {
            throw "Package directory did not contain tracked files: $pattern"
        }
        continue
    }

    if ($normalizedPattern.IndexOfAny([char[]]'*?') -ge 0) {
        $parent = Split-Path -Parent $normalizedPattern
        $leaf = Split-Path -Leaf $normalizedPattern
        $searchRoot = Join-Path $repositoryRoot $parent
        $matches = @(Get-ChildItem -LiteralPath $searchRoot -File -Filter $leaf)
        if ($matches.Count -eq 0) {
            throw "Package pattern did not match any files: $pattern"
        }
        $addedTrackedFile = $false
        $matches | ForEach-Object {
            if (Add-PackageFile -Files $packageFiles -Path $_.FullName) {
                $addedTrackedFile = $true
            }
        }
        if (-not $addedTrackedFile) {
            throw "Package pattern did not match tracked files: $pattern"
        }
        continue
    }

    if (-not (Add-PackageFile -Files $packageFiles -Path (Join-Path $repositoryRoot $normalizedPattern))) {
        throw "Required package file is neither Git-tracked nor an approved generated file: $pattern"
    }
}

try {
    New-Item -ItemType Directory -Path $stagingRoot -Force | Out-Null
    New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

    $managedPaths = @($packageFiles.Keys | Sort-Object)
    foreach ($relativePath in $managedPaths) {
        $destination = Join-Path $stagingRoot $relativePath
        New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null
        Copy-Item -LiteralPath $packageFiles[$relativePath] -Destination $destination -Force
    }

    $managedFileName = '.ptcgpb-managed-files.txt'
    $managedFilePath = Join-Path $stagingRoot $managedFileName
    $managedInstallPaths = @($managedPaths + $managedFileName + 'update-manifest.json' | Sort-Object -Unique)
    [IO.File]::WriteAllLines($managedFilePath, $managedInstallPaths, [Text.UTF8Encoding]::new($false))

    $manifestEntries = foreach ($relativePath in $managedPaths) {
        $packagedPath = Join-Path $stagingRoot $relativePath
        [ordered]@{
            path = $relativePath
            size = (Get-Item -LiteralPath $packagedPath).Length
            sha256 = (Get-FileHash -LiteralPath $packagedPath -Algorithm SHA256).Hash.ToLowerInvariant()
        }
    }

    $manifest = [ordered]@{
        schemaVersion = 1
        product = 'PTCGPB'
        version = $Version
        repository = 'Leanny/PTCGPB'
        generatedAt = [DateTime]::UtcNow.ToString('o')
        managedFileList = $managedFileName
        files = @($manifestEntries)
    }

    $manifestJson = $manifest | ConvertTo-Json -Depth 5
    $stagedManifestPath = Join-Path $stagingRoot 'update-manifest.json'
    [IO.File]::WriteAllText($stagedManifestPath, $manifestJson + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))

    $zipPath = Join-Path $outputRoot "$bundleName.zip"
    $checksumPath = "$zipPath.sha256"
    $publishedManifestPath = Join-Path $outputRoot 'update-manifest.json'
    Remove-Item -LiteralPath $zipPath, $checksumPath, $publishedManifestPath -Force -ErrorAction SilentlyContinue

    Compress-Archive -LiteralPath $stagingRoot -DestinationPath $zipPath -CompressionLevel Optimal
    Copy-Item -LiteralPath $stagedManifestPath -Destination $publishedManifestPath -Force

    $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
    [IO.File]::WriteAllText($checksumPath, "$zipHash  $([IO.Path]::GetFileName($zipPath))`n", [Text.UTF8Encoding]::new($false))

    Write-Host "Created $zipPath"
    Write-Host "Created $checksumPath"
    Write-Host "Created $publishedManifestPath"
    Write-Host "Packaged $($managedPaths.Count) application files."
}
finally {
    if (Test-Path -LiteralPath $stagingParent) {
        Remove-Item -LiteralPath $stagingParent -Recurse -Force
    }
}
