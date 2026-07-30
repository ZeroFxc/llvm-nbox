# 功能：Windows 侧引导脚本，检测 WSL 是否可用，若可用则自动映射路径并调用 WSL 内的 build.sh
#       若 WSL 不可用，则报错提示用户安装 WSL 或手动在 WSL 中执行 scripts/build.sh
# 参数：与 build.sh --help 一致（将被透传到 WSL bash 脚本）
# 返回值：0 成功、非 0 失败

param(
    [string]$Ndk = "",
    [string]$LlvmSrc = "",
    [string]$BuildDir = "",
    [string]$OutDir = "",
    [string]$Jobs = "",
    [switch]$SkipPatches,
    [switch]$SkipLlvmBuild,
    [Alias("h")]
    [switch]$Help
)

$ErrorActionPreference = "Stop"

# 函数：打印帮助信息
function Usage {
    Write-Host "用法: .\build.ps1 [选项]"
    Write-Host ""
    Write-Host "说明：这是 Windows 侧引导脚本，优先自动调用 WSL 执行 scripts/build.sh"
    Write-Host "      若 WSL 不可用，请手动进入 WSL 后执行： bash scripts/build.sh"
    Write-Host ""
    Write-Host "选项（将透传到 WSL build.sh）："
    Write-Host "  -Ndk <path>          显式指定 Android NDK 根目录（Windows 或 WSL 路径均可）"
    Write-Host "  -LlvmSrc <path>      LLVM 源码目录（默认: 项目根目录下的 llvm-project-llvmorg-22.1.0）"
    Write-Host "  -BuildDir <path>     构建目录（默认: <project-root>/build-android-aarch64）"
    Write-Host "  -OutDir <path>       输出目录（默认: <project-root>/out/android-aarch64）"
    Write-Host "  -Jobs <N>            并行编译数（默认: nproc）"
    Write-Host "  -SkipPatches         不重新 apply patches（若上次已应用）"
    Write-Host "  -SkipLlvmBuild       跳过 cmake + ninja，直接写 lib-exports.txt"
    Write-Host "  -Help, -h            显示此帮助信息"
}

# 函数：将 Windows 路径转换为 WSL 路径（例如 E:\llvmbox -> /mnt/e/llvmbox）
function Convert-ToWslPath {
    param([string]$WinPath)
    if ([string]::IsNullOrWhiteSpace($WinPath)) {
        return ""
    }
    # 若已经是 WSL 路径（/mnt/... 或 /...），直接返回
    if ($WinPath -match '^/') {
        return $WinPath
    }
    # 规范化：去掉引号，替换 \ 为 /
    $WinPath = $WinPath.Trim('"').Replace('\', '/')
    # 处理盘符：E:/foo -> /mnt/e/foo
    if ($WinPath -match '^([A-Za-z]):/(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = $Matches[2]
        return "/mnt/$drive/$rest"
    }
    # 相对路径：保持原样（WSL 端会处理）
    return $WinPath
}

# 函数：检测 WSL 是否可用
function Test-WslAvailable {
    try {
        $wsl = Get-Command wsl.exe -ErrorAction SilentlyContinue
        if (-not $wsl) {
            return $false
        }
        # 尝试 wsl --version（WSL 2 才有；WSL 1 可能没有，但 bash.exe 可用）
        $out = & wsl.exe --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[WSL 检测] wsl.exe 可用: $($out -join ', ')"
            return $true
        }
        # 再试 wsl -e true（兼容性检查）
        $null = & wsl.exe -e true 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Host "[WSL 检测] wsl.exe 可用（WSL1 兼容模式）"
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
}

# ========== 主入口 ==========
if ($Help) {
    Usage
    exit 0
}

Write-Host "=========================================="
Write-Host "  llvm-nbox / build.ps1 (Windows -> WSL 引导)"
Write-Host "=========================================="

# 获取脚本自身所在目录
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRootWin = Resolve-Path (Join-Path $ScriptDir "..")
Write-Host "PROJECT_ROOT (Win) = $ProjectRootWin"

# 映射到 WSL 路径
$ProjectRootWsl = Convert-ToWslPath $ProjectRootWin
$BuildShWsl = "$ProjectRootWsl/scripts/build.sh"
Write-Host "PROJECT_ROOT (WSL) = $ProjectRootWsl"
Write-Host "build.sh (WSL 路径) = $BuildShWsl"

# --- 检查 WSL ---
Write-Host ""
Write-Host "[WSL 检测] 正在检测 WSL 环境..."
if (-not (Test-WslAvailable)) {
    Write-Host ""
    Write-Host "[错误] 未检测到可用的 WSL 环境。" -ForegroundColor Red
    Write-Host ""
    Write-Host "解决方案（二选一）："
    Write-Host "  1. 安装 WSL：以管理员身份打开 PowerShell，执行"
    Write-Host "     wsl --install"
    Write-Host "     然后重启电脑，再运行本脚本。"
    Write-Host ""
    Write-Host "  2. 手动进入 WSL，在 WSL 内直接执行："
    Write-Host "     cd $ProjectRootWsl"
    Write-Host "     bash scripts/build.sh --help"
    Write-Host ""
    exit 1
}

# --- 组装参数（透传到 WSL build.sh） ---
$wslArgs = @()

# 先把 wsl.exe 的执行参数准备好（wsl bash <path> <args...>）
if (-not [string]::IsNullOrWhiteSpace($Ndk)) {
    $wslArgs += "--ndk"
    $wslArgs += (Convert-ToWslPath $Ndk)
}
if (-not [string]::IsNullOrWhiteSpace($LlvmSrc)) {
    $wslArgs += "--llvm-src"
    $wslArgs += (Convert-ToWslPath $LlvmSrc)
}
if (-not [string]::IsNullOrWhiteSpace($BuildDir)) {
    $wslArgs += "--build-dir"
    $wslArgs += (Convert-ToWslPath $BuildDir)
}
if (-not [string]::IsNullOrWhiteSpace($OutDir)) {
    $wslArgs += "--out-dir"
    $wslArgs += (Convert-ToWslPath $OutDir)
}
if (-not [string]::IsNullOrWhiteSpace($Jobs)) {
    $wslArgs += "--jobs"
    $wslArgs += $Jobs
}
if ($SkipPatches) { $wslArgs += "--skip-patches" }
if ($SkipLlvmBuild) { $wslArgs += "--skip-llvm-build" }

Write-Host ""
Write-Host "[参数透传] WSL build.sh 参数:"
if ($wslArgs.Count -eq 0) {
    Write-Host "  (无额外参数，将启用 WSL NDK 自动探测)"
}
else {
    Write-Host "  $($wslArgs -join ' ')"
}

# --- 执行 wsl bash ---
Write-Host ""
Write-Host "[执行] wsl.exe bash $BuildShWsl $($wslArgs -join ' ')"
Write-Host "-----------------------------------------"

$allArgs = @("bash", $BuildShWsl) + $wslArgs
& wsl.exe @allArgs
$exitCode = $LASTEXITCODE

Write-Host "-----------------------------------------"
Write-Host "[完成] WSL build.sh 退出码 = $exitCode"
exit $exitCode
