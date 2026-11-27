[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repositoryRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$nativeDir = Join-Path $repositoryRoot 'Scripts\Native'
$outDir = Join-Path $repositoryRoot 'Scripts\Include'

$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) {
    throw 'vswhere.exe not found. The native DLLs build with the MSVC x64 tools.'
}
$installation = (& $vswhere -latest -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
if (-not $installation) {
    throw 'MSVC x64 tools not found. Install the Desktop development with C++ workload.'
}
$vcvars = Join-Path $installation 'VC\Auxiliary\Build\vcvars64.bat'
if (-not (Test-Path -LiteralPath $vcvars -PathType Leaf)) {
    throw "vcvars64.bat not found at $vcvars"
}

$jobs = @(
    @{
        Source = 'RegionCap.cpp'
        Output = 'RegionCap.dll'
        Libs = @('d3d11.lib', 'dxgi.lib', 'user32.lib')
    }
    @{
        Source = 'MaskMatch.c'
        Output = 'MaskMatch.dll'
        Libs = @()
    }
)

$built = 0
foreach ($job in $jobs) {
    $source = Join-Path $nativeDir $job.Source
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        continue
    }

    $work = Join-Path ([IO.Path]::GetTempPath()) ('ptcgpb-native-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        $object = Join-Path $work 'obj.obj'
        $output = Join-Path $work $job.Output
        $command = "cl /nologo /MT /O2 /W3 /LD /EHsc `"$source`" /Fo`"$object`" /Fe`"$output`""
        if ($job.Libs.Count -gt 0) {
            $command += ' /link ' + ($job.Libs -join ' ')
        }
        & cmd.exe /d /s /c "`"$vcvars`" >nul && $command"
        if ($LASTEXITCODE -ne 0) {
            throw "cl failed for $($job.Source) (exit $LASTEXITCODE)"
        }
        if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
            throw "cl did not produce $($job.Output)"
        }
        New-Item -ItemType Directory -Path $outDir -Force | Out-Null
        Copy-Item -LiteralPath $output -Destination (Join-Path $outDir $job.Output) -Force
        Write-Host "Built Scripts/Include/$($job.Output)"
        $built++
    }
    finally {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

if ($built -eq 0) {
    throw 'No sources found under Scripts/Native.'
}
