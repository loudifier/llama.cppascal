# Build for Pascal (sm_60/61) on Windows with CUDA 12.9.
#
# Usage:
#   .\scripts\build-pascal-win.ps1 [-BuildDir <dir>] [-CudaDir <dir>] [-CudaArch <list>] [-Ninja <path>] [-Jobs N]
#
# -BuildDir : output directory (default: build-pascal)
# -CudaDir  : CUDA toolkit root (default: CUDA v12.9 install path)
# -CudaArch : CMAKE_CUDA_ARCHITECTURES (default: 60;61)
# -Ninja    : path to ninja.exe (default: PATH, then the winget install location)
# -Jobs     : parallel jobs (default: all cores)
#
# Requires:
#   - Visual Studio 2022 (17.x) with the C++ workload. Newer MSVC toolsets
#     (19.5x) are not accepted by CUDA 12.9 nvcc (host_config.h C1189, and
#     cudafe++ crashes with -allow-unsupported-compiler).
#   - CUDA 12.9.x toolkit: the last series that can target Maxwell/Pascal/Volta
#     (CUDA 13.x removed sm60/61).
#   - CMake and Ninja on PATH.

param(
    [string]$BuildDir = "build-pascal",
    [string]$CudaDir = "C:\Program Files\NVIDIA GPU Computing Toolkit\CUDA\v12.9",
    [string]$CudaArch = "60;61",
    [string]$Ninja = "",
    [int]$Jobs = [Environment]::ProcessorCount
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$RootDir = Split-Path -Parent $ScriptDir

if (-not (Test-Path $CudaDir)) {
    Write-Error "CUDA toolkit not found at $CudaDir (use -CudaDir)"
    exit 1
}
if (-not $Ninja) {
    $NinjaCmd = Get-Command ninja -ErrorAction SilentlyContinue
    if ($NinjaCmd) {
        $Ninja = $NinjaCmd.Source
    } else {
        # winget install locations (alias link, then package dir)
        $Candidates = @(
            (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Links\ninja.exe")
        )
        $WingetPkg = Get-ChildItem (Join-Path $env:LOCALAPPDATA "Microsoft\WinGet\Packages") -Filter "ninja.exe" -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($WingetPkg) { $Candidates += $WingetPkg.FullName }
        foreach ($C in $Candidates) {
            if (Test-Path $C) { $Ninja = $C; break }
        }
    }
}
if (-not $Ninja -or -not (Test-Path $Ninja)) {
    Write-Error "ninja not found (install it or pass -Ninja <path to ninja.exe>)"
    exit 1
}

$Vswhere = "C:\Program Files (x86)\Microsoft Visual Studio\Installer\vswhere.exe"
# CUDA 12.9 nvcc only accepts MSVC up to VS 2022 (17.x), so prefer a 17.x install
$VsPath = & $Vswhere -latest -prerelease -products * -version "[17.0,18.0)" `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $VsPath) {
    $VsPath = & $Vswhere -latest -prerelease -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 `
        -property installationPath
    if ($VsPath) {
        Write-Warning "VS 2022 (17.x) not found, using $VsPath - CUDA 12.9 may refuse its MSVC (install VS 2022 Build Tools if the build fails)"
    }
}
if (-not $VsPath) {
    Write-Error "Visual Studio with the C++ workload (x64) not found"
    exit 1
}
$VcVarsAll = Join-Path $VsPath "VC\Auxiliary\Build\vcvarsall.bat"
if (-not (Test-Path $VcVarsAll)) {
    Write-Error "vcvarsall.bat not found at $VcVarsAll"
    exit 1
}

$Bat = @"
@echo off
call "$VcVarsAll" x64
if errorlevel 1 exit /b 1
set "PATH=$CudaDir\bin;%PATH%"
cmake -S "$RootDir" -B "$BuildDir" -G Ninja -DCMAKE_MAKE_PROGRAM="$Ninja" -DCMAKE_BUILD_TYPE=Release -DGGML_CUDA=ON -DCMAKE_CUDA_ARCHITECTURES="$CudaArch"
if errorlevel 1 exit /b 1
cmake --build "$BuildDir" -j $Jobs
"@
$BatFile = Join-Path $env:TEMP "build-pascal-win.bat"
Set-Content -Path $BatFile -Value $Bat -Encoding ascii
# vcvarsall emits harmless stderr; let it pass instead of throwing
$PrevEAP = $ErrorActionPreference
$ErrorActionPreference = "Continue"
cmd /c "`"$BatFile`""
$Code = $LASTEXITCODE
$ErrorActionPreference = $PrevEAP
if ($Code -ne 0) {
    Write-Error "build failed (exit $Code)"
    exit $Code
}
