# 功能：llvm-nbox Windows 侧构建入口脚本
#       策略：检测环境条件，不满足则友好报错提示用 WSL；
#             满足条件则把参数翻译为 WSL 路径，转发调用 WSL 内的 bash build.sh
# 参数：与 build.sh CLI 参数对齐（透传映射）
# 返回值：0=成功，非0=失败

param(
    [string]$Ndk = "",
    [string]$LlvmSrc = "",
    [string]$BuildDir = "",
    [string]$OutDir = "",
    [int]$Jobs = 0,
    [switch]$SkipLlvm,
    [switch]$SkipZip,
    [string]$TargetTriple = "",
    [string]$Abi = "",
    [int]$AndroidPlatform = 0,
    [string]$ClangVersion = "",
    [Alias("h")]
    [switch]$Help
)

$ErrorActionPreference = "Stop"

# ========== 函数：打印帮助信息 ==========
function Usage {
    Write-Host "用法: .\build.ps1 [选项]"
    Write-Host ""
    Write-Host "说明：这是 Windows 侧入口脚本。本项目实际构建依赖 WSL Ubuntu + Android NDK。"
    Write-Host "      若环境满足，本脚本自动翻译路径并转发到 WSL 内 bash ./build.sh <args>"
    Write-Host ""
    Write-Host "选项："
    Write-Host "  -Ndk <path>           Android NDK 根目录（Windows 或 WSL 路径；建议在 WSL ~ 下）"
    Write-Host "  -LlvmSrc <path>       LLVM 源码目录（默认: <项目根>\llvm-project-llvmorg-22.1.0）"
    Write-Host "  -BuildDir <path>      构建目录（默认: <项目根>\build-android-aarch64）"
    Write-Host "  -OutDir <path>        输出目录（默认: <项目根>\out\android-aarch64）"
    Write-Host "  -Jobs <N>             并行编译数（默认: nproc）"
    Write-Host "  -SkipLlvm             跳过 apply-patches + cmake/ninja 全量 LLVM，"
    Write-Host "                        直接进入重编 driver.o → 链接 → 资源拷贝（5 分钟内完成）"
    Write-Host "  -SkipZip              不生成最终 zip 包"
    Write-Host "  -TargetTriple <str>   目标三元组（默认: aarch64-linux-android）"
    Write-Host "  -Abi <str>            Android ABI（默认: arm64-v8a）"
    Write-Host "  -AndroidPlatform <N>  Android API level（默认: 24）"
    Write-Host "  -ClangVersion <str>   clang 版本目录名（默认: 自动探测）"
    Write-Host "  -Help, -h             显示此帮助信息"
    Write-Host ""
    Write-Host "环境要求（Windows 侧只作为转发入口；实际编译在 WSL 内发生）："
    Write-Host "  1. 必须安装 WSL（推荐 Ubuntu 22.04）"
    Write-Host "  2. Android NDK 建议放在 WSL ~/android-ndk-r29"
    Write-Host "     （放在 Windows 盘会因 9p 文件系统严重变慢）"
    Write-Host ""
    Write-Host "推荐用法：直接在 WSL 内手动执行："
    Write-Host "  wsl -d Ubuntu -- bash -lc 'cd /mnt/e/llvmbox && ./build.sh --ndk `$HOME/android-ndk-r29 --skip-llvm --skip-zip -j16'"
}

# ========== 函数：将 Windows 路径转换为 WSL 路径 ==========
# 功能：把形如 E:\llvmbox\foo → /mnt/e/llvmbox/foo
#       已经是 /... 开头的 WSL/UNIX 路径原样返回
# 参数：WinPath 原始路径字符串
# 返回值：WSL 路径字符串
function Convert-ToWslPath {
    param([string]$WinPath)
    if ([string]::IsNullOrWhiteSpace($WinPath)) {
        return ""
    }
    # 已是 WSL/Unix 路径：/mnt/... 或 /home/...
    if ($WinPath -match '^/') {
        return $WinPath
    }
    # 规范化：去掉首尾引号，反斜杠 → 正斜杠
    $WinPath = $WinPath.Trim('"').Trim("'").Replace('\', '/')
    # 盘符模式：E:/foo/bar → /mnt/e/foo/bar
    if ($WinPath -match '^([A-Za-z]):/?(.*)$') {
        $drive = $Matches[1].ToLower()
        $rest = $Matches[2]
        return "/mnt/$drive/$rest"
    }
    # 相对路径原样返回（WSL 端 cd 后可解析）
    return $WinPath
}

# ========== 函数：检查某命令是否存在于 PATH ==========
function Test-CommandExists {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    return [bool]$cmd
}

# ========== 主入口 ==========
if ($Help) {
    Usage
    exit 0
}

Write-Host "=========================================="
Write-Host "  llvm-nbox / build.ps1 (Windows -> WSL)"
Write-Host "=========================================="

# 获取脚本所在目录 → 项目根目录（脚本本身就在项目根）
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRootWin = (Resolve-Path $ScriptDir).Path
Write-Host "PROJECT_ROOT (Win) = $ProjectRootWin"

# 映射项目根到 WSL 路径
$ProjectRootWsl = Convert-ToWslPath $ProjectRootWin
$BuildShWsl = "$ProjectRootWsl/build.sh"
Write-Host "PROJECT_ROOT (WSL) = $ProjectRootWsl"
Write-Host "build.sh (WSL 路径) = $BuildShWsl"

# ========== 2.1 环境探测规则 1：Linux/macOS PowerShell ==========
if (($IsLinux -eq $true) -or ($IsMacOS -eq $true)) {
    Write-Warning "当前在 Linux/macOS PowerShell 环境运行，建议直接执行 bash ./build.sh"
    # 仍然尝试用 bash 执行（可能是 CI）
}

# ========== 2.1 环境探测规则 2：WSL_DISTRO_NAME 存在 + NDK 是 Windows 路径 ==========
# 当用户在用 wsl 终端里的 powershell 但把 NDK 放在 C:\... 时，报错提示
if (-not [string]::IsNullOrWhiteSpace($env:WSL_DISTRO_NAME)) {
    # 在 WSL 内部的 powershell
    Write-Host "[WSL 检测] 当前在 WSL 内运行 PowerShell (distro=$env:WSL_DISTRO_NAME)"
    # 检测 NDK 是否是 Windows 路径（盘符 C:\...）
    if (-not [string]::IsNullOrWhiteSpace($Ndk)) {
        if ($Ndk -match '^[A-Za-z]:\\') {
            Write-Host ""
            Write-Host "[错误] 检测到 NDK 使用 Windows 路径：$Ndk" -ForegroundColor Red
            Write-Host "在 WSL 内构建时，NDK 必须放在 WSL 文件系统下（例如 ~/android-ndk-r29），"
            Write-Host "Windows 盘 (/mnt/c /mnt/d ...) 走 9p 文件系统会严重拖慢编译速度且可能失败。"
            Write-Host ""
            Write-Host "请将 NDK 拷贝到 WSL 家目录，并在 WSL bash 中执行："
            Write-Host "  cd $ProjectRootWsl"
            Write-Host "  bash build.sh --ndk `$HOME/android-ndk-r29 <其他参数>"
            exit 1
        }
    }
}

# ========== 2.1 环境探测规则 3：纯 Windows → 检查 cmake/ninja/clang++ ==========
$isPureWindows = (-not $IsLinux) -and (-not $IsMacOS) -and [string]::IsNullOrWhiteSpace($env:WSL_DISTRO_NAME)
if ($isPureWindows) {
    Write-Host ""
    Write-Host "[环境检测] 当前为纯 Windows 环境，检查基础工具..."
    $missing = @()
    if (-not (Test-CommandExists "cmake")) { $missing += "cmake" }
    if (-not (Test-CommandExists "ninja")) { $missing += "ninja" }
    if (-not (Test-CommandExists "clang++")) { $missing += "clang++" }
    if (-not (Test-CommandExists "wsl")) { $missing += "wsl.exe (WSL)" }

    if ($missing.Count -gt 0) {
        Write-Host ""
        Write-Host "[错误] 未在 PATH 中检测到以下命令： $($missing -join ', ')" -ForegroundColor Red
        Write-Host ""
        Write-Host "本项目构建依赖 WSL Ubuntu + Android NDK，推荐方案："
        Write-Host ""
        Write-Host "  1. 安装 WSL（若未安装）：以管理员身份打开 PowerShell 执行"
        Write-Host "     wsl --install -d Ubuntu"
        Write-Host "     重启电脑后完成 Ubuntu 初始化用户密码设置。"
        Write-Host ""
        Write-Host "  2. 在 WSL Ubuntu 中安装 Android NDK r29 到 ~/android-ndk-r29"
        Write-Host ""
        Write-Host "  3. 在 WSL bash 中直接执行："
        Write-Host "     wsl -d Ubuntu -- bash -lc 'cd $ProjectRootWsl && ./build.sh --ndk `$HOME/android-ndk-r29 --skip-llvm --skip-zip -j16'"
        Write-Host ""
        exit 1
    }

    Write-Host "  cmake / ninja / clang++ / wsl.exe 均已在 PATH（但实际编译仍在 WSL 内进行）"

    # NDK 路径格式检查（纯 Windows 端传 Windows NDK 路径 → 报错提示移到 WSL）
    if (-not [string]::IsNullOrWhiteSpace($Ndk)) {
        if ($Ndk -match '^[A-Za-z]:\\') {
            Write-Host ""
            Write-Host "[错误] NDK 指定为 Windows 路径：$Ndk" -ForegroundColor Red
            Write-Host ""
            Write-Host "Android NDK 必须放置在 WSL 文件系统下（例如 ~/android-ndk-r29），"
            Write-Host "Windows 盘在 WSL 中走 9p 协议会导致编译极慢且 cmake 配置可能失败。"
            Write-Host ""
            Write-Host "请先将 NDK 拷到 WSL 家目录："
            Write-Host "  wsl -d Ubuntu -- bash -lc 'cp -a <NDK.zip 或目录> `$HOME/android-ndk-r29'"
            Write-Host ""
            Write-Host "然后在 WSL bash 中执行："
            Write-Host "  cd $ProjectRootWsl && ./build.sh --ndk `$HOME/android-ndk-r29 --skip-llvm --skip-zip -j16"
            exit 1
        }
    }
}

# ========== 组装 WSL build.sh 参数 ==========
$wslArgs = @()

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
if ($Jobs -gt 0) {
    $wslArgs += "--jobs"
    $wslArgs += "$Jobs"
}
if ($SkipLlvm) { $wslArgs += "--skip-llvm" }
if ($SkipZip)  { $wslArgs += "--skip-zip" }
if (-not [string]::IsNullOrWhiteSpace($TargetTriple)) {
    $wslArgs += "--target"
    $wslArgs += $TargetTriple
}
if (-not [string]::IsNullOrWhiteSpace($Abi)) {
    $wslArgs += "--abi"
    $wslArgs += $Abi
}
if ($AndroidPlatform -gt 0) {
    $wslArgs += "--android-platform"
    $wslArgs += "$AndroidPlatform"
}
if (-not [string]::IsNullOrWhiteSpace($ClangVersion)) {
    $wslArgs += "--clang-version"
    $wslArgs += $ClangVersion
}

Write-Host ""
Write-Host "[参数透传] WSL 内执行的 bash 命令参数："
if ($wslArgs.Count -eq 0) {
    Write-Host "  (无额外参数，将启用 WSL 端 NDK 自动探测)"
} else {
    Write-Host "  $($wslArgs -join ' ')"
}

# ========== 最终调用：wsl.exe bash -lc "cd PROJECT && ./build.sh args..." ==========
# 使用 bash -lc 加载 WSL 用户 profile 让 PATH/NDK 环境变量生效
$innerBashCmd = "cd `"$ProjectRootWsl`" && bash `"$BuildShWsl`" $($wslArgs -join ' ')"

Write-Host ""
Write-Host "[执行] wsl.exe -- bash -lc `"$innerBashCmd`""
Write-Host "-----------------------------------------"

& wsl.exe -- bash -lc $innerBashCmd
$exitCode = $LASTEXITCODE

Write-Host "-----------------------------------------"
Write-Host "[完成] WSL build.sh 退出码 = $exitCode"
exit $exitCode
