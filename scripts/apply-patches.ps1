# 功能：按文件名顺序应用 patches/ 目录下的所有 .patch 文件到 LLVM 源码目录
# 参数：无（内部硬编码源码路径为 e:/llvmbox/llvm-project-llvmorg-22.1.0/）
# 返回值：0=成功，非0=失败（失败时已对已应用的 patch 进行反向回滚）

param()

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptDir
$PatchesDir = Join-Path $ProjectRoot "patches"
$SrcDir = "e:/llvmbox/llvm-project-llvmorg-22.1.0"

$appliedPatches = New-Object System.Collections.Generic.List[string]

function Rollback-Patches {
    Write-Host "发生错误，开始回滚已应用的 patch..." -ForegroundColor Red
    for ($i = $appliedPatches.Count - 1; $i -ge 0; $i--) {
        $patchFile = $appliedPatches[$i]
        $patchName = Split-Path $patchFile -Leaf
        Write-Host "回滚: $patchName" -ForegroundColor Yellow
        try {
            $process = Start-Process -FilePath "patch" -ArgumentList @("-d", "`"$SrcDir`"", "-p1", "-R", "-s") `
                -RedirectStandardInput $patchFile -NoNewWindow -Wait -PassThru
        } catch {
        }
    }
}

try {
    if (-not (Test-Path $PatchesDir -PathType Container)) {
        Write-Host "patches 目录不存在: $PatchesDir" -ForegroundColor Red
        exit 1
    }

    $patchFiles = Get-ChildItem -Path $PatchesDir -Filter "*.patch" -File | Sort-Object Name

    if ($patchFiles.Count -eq 0) {
        Write-Host "patches 目录为空，无需应用。"
        exit 0
    }

    if (-not (Test-Path $SrcDir -PathType Container)) {
        Write-Host "LLVM 源码目录不存在: $SrcDir" -ForegroundColor Red
        exit 1
    }

    foreach ($patchFile in $patchFiles) {
        $patchName = $patchFile.Name
        Write-Host "应用 patch: $patchName"

        $process = Start-Process -FilePath "patch" -ArgumentList @("-d", "`"$SrcDir`"", "-p1", "-s") `
            -RedirectStandardInput $patchFile.FullName -NoNewWindow -Wait -PassThru

        if ($process.ExitCode -ne 0) {
            Write-Host "patch 失败: $patchName (exit code: $($process.ExitCode))" -ForegroundColor Red
            Rollback-Patches
            exit 1
        }

        $appliedPatches.Add($patchFile.FullName)
    }

    Write-Host "所有 patch 应用成功。" -ForegroundColor Green
    exit 0
} catch {
    Write-Host "执行出错: $_" -ForegroundColor Red
    Rollback-Patches
    exit 1
}
