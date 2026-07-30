# 功能：llvm-nbox 构建入口脚本（当前阶段：参数解析 + 环境检查）
# 参数：
#   -Ndk <path>       Android NDK 路径（默认：环境变量 ANDROID_NDK_HOME 或 ANDROID_NDK_ROOT）
#   -LlvmSrc <path>   LLVM 源码路径（默认：e:/llvmbox/llvm-project-llvmorg-22.1.0）
#   -BuildDir <path>  构建目录（默认：./build）
#   -OutDir <path>    输出目录（默认：./out）
#   -Jobs <num>       并行编译数（默认：CPU 核心数）
#   -SkipLlvm         跳过 LLVM 构建
#   -NoCcache         禁用 ccache
#   -Help             显示帮助
# 返回值：0=环境检查通过，非0=参数或环境检查失败

param(
    [string]$Ndk = "",
    [string]$LlvmSrc = "",
    [string]$BuildDir = "",
    [string]$OutDir = "",
    [int]$Jobs = 0,
    [switch]$SkipLlvm,
    [switch]$NoCcache,
    [Alias("h")]
    [switch]$Help
)

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DefaultLlvmSrc = "e:/llvmbox/llvm-project-llvmorg-22.1.0"
$DefaultBuildDir = Join-Path $ScriptDir "build"
$DefaultOutDir = Join-Path $ScriptDir "out"

function Usage {
    Write-Host @"
用法: .\build.ps1 [选项]

选项:
  -Ndk <path>       Android NDK 路径（默认: `$env:ANDROID_NDK_HOME 或 `$env:ANDROID_NDK_ROOT）
  -LlvmSrc <path>   LLVM 源码路径（默认: $DefaultLlvmSrc）
  -BuildDir <path>  构建目录（默认: $DefaultBuildDir）
  -OutDir <path>    输出目录（默认: $DefaultOutDir）
  -Jobs <num>       并行编译数（默认: CPU 核心数）
  -SkipLlvm         跳过 LLVM 构建
  -NoCcache         禁用 ccache
  -Help, -h         显示此帮助信息

环境安装建议:
  WSL / Linux: apt install cmake ninja-build ccache build-essential
  macOS:       brew install cmake ninja ccache
  Windows:     scoop install cmake ninja ccache
"@
}

function Print-ErrorAndHelp {
    param([string]$Message)
    Write-Host "错误: $Message" -ForegroundColor Red
    Write-Host ""
    Usage
    Write-Host ""
    Write-Host "环境安装建议:" -ForegroundColor Yellow
    Write-Host "  WSL / Linux: apt install cmake ninja-build ccache build-essential"
    Write-Host "  Windows:     scoop install cmake ninja ccache"
    exit 1
}

if ($Help) {
    Usage
    exit 0
}

if ([string]::IsNullOrEmpty($Ndk)) {
    if (-not [string]::IsNullOrEmpty($env:ANDROID_NDK_HOME)) {
        $Ndk = $env:ANDROID_NDK_HOME
    } elseif (-not [string]::IsNullOrEmpty($env:ANDROID_NDK_ROOT)) {
        $Ndk = $env:ANDROID_NDK_ROOT
    }
}

if ([string]::IsNullOrEmpty($LlvmSrc)) {
    $LlvmSrc = $DefaultLlvmSrc
}

if ([string]::IsNullOrEmpty($BuildDir)) {
    $BuildDir = $DefaultBuildDir
}

if ([string]::IsNullOrEmpty($OutDir)) {
    $OutDir = $DefaultOutDir
}

if ($Jobs -eq 0) {
    $cpuCount = (Get-CimInstance -ClassName Win32_Processor | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum
    if ($cpuCount -and $cpuCount -gt 0) {
        $Jobs = $cpuCount
    } else {
        $Jobs = 4
    }
}

$errors = New-Object System.Collections.Generic.List[string]

if ([string]::IsNullOrEmpty($Ndk) -or -not (Test-Path $Ndk -PathType Container)) {
    $errors.Add("NDK 路径无效或未设置: $(if ([string]::IsNullOrEmpty($Ndk)) { "<未设置>" } else { $Ndk })")
}

if (-not (Test-Path $LlvmSrc -PathType Container)) {
    $errors.Add("LLVM 源码目录不存在: $LlvmSrc")
}

function Test-CommandExists {
    param([string]$Command)
    try {
        $null = Get-Command $Command -ErrorAction Stop
        return $true
    } catch {
        return $false
    }
}

if (-not (Test-CommandExists "cmake")) {
    $errors.Add("cmake 未安装或不在 PATH 中")
}

if (-not (Test-CommandExists "ninja")) {
    $errors.Add("ninja 未安装或不在 PATH 中")
}

if (-not $NoCcache -and -not (Test-CommandExists "ccache")) {
    $errors.Add("ccache 未安装或不在 PATH 中（可用 -NoCcache 禁用）")
}

if ($errors.Count -gt 0) {
    Write-Host "环境检查失败:" -ForegroundColor Red
    foreach ($err in $errors) {
        Write-Host "  - $err" -ForegroundColor Red
    }
    Write-Host ""
    Usage
    Write-Host ""
    Write-Host "环境安装建议:" -ForegroundColor Yellow
    Write-Host "  WSL / Linux: apt install cmake ninja-build ccache build-essential"
    Write-Host "  Windows:     scoop install cmake ninja ccache"
    exit 1
}

Write-Host "环境检查通过，后续阶段待实现。"
exit 0
