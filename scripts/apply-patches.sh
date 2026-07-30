#!/usr/bin/env bash
# 功能：按文件名顺序应用 patches/ 目录下的所有 .patch 文件到 LLVM 源码目录
# 参数：
#   --src <path>    显式指定 LLVM 源码目录（优先级最高）
#   --patches <dir> 显式指定 patches 目录
#   无参数时：从环境变量 LLVM_SRC 获取源码目录，或推断上级目录下的 llvm-project-llvmorg-22.1.0
# 返回值：0=成功，非0=失败（失败时已对已应用的 patch 进行反向回滚）

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

SRC_DIR=""
PATCHES_DIR=""

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        --src)
            [[ $# -lt 2 ]] && { echo "错误: --src 需要参数" >&2; exit 1; }
            SRC_DIR="$2"
            shift 2
            ;;
        --patches)
            [[ $# -lt 2 ]] && { echo "错误: --patches 需要参数" >&2; exit 1; }
            PATCHES_DIR="$2"
            shift 2
            ;;
        *)
            echo "警告: 未知参数 $1，忽略" >&2
            shift
            ;;
    esac
done

# 默认 SRC_DIR：环境变量 LLVM_SRC > 推断上级目录下的 llvm-project-llvmorg-22.1.0
if [[ -z "$SRC_DIR" ]]; then
    if [[ -n "${LLVM_SRC:-}" ]]; then
        SRC_DIR="$LLVM_SRC"
    else
        SRC_DIR="${PROJECT_ROOT}/llvm-project-llvmorg-22.1.0"
    fi
fi

# 默认 PATCHES_DIR：上级目录下的 patches/
if [[ -z "$PATCHES_DIR" ]]; then
    PATCHES_DIR="${PROJECT_ROOT}/patches"
fi

applied_patches=()

rollback() {
    echo "发生错误，开始回滚已应用的 patch..." >&2
    for (( idx=${#applied_patches[@]}-1 ; idx>=0 ; idx-- )); do
        patch_file="${applied_patches[idx]}"
        echo "回滚: $(basename "$patch_file")" >&2
        patch -d "$SRC_DIR" -p1 -R -s < "$patch_file" || true
    done
}

trap 'rollback; exit 1' ERR

if [ ! -d "$PATCHES_DIR" ]; then
    echo "patches 目录不存在: $PATCHES_DIR" >&2
    exit 1
fi

shopt -s nullglob
patch_files=("$PATCHES_DIR"/*.patch)
shopt -u nullglob

if [ ${#patch_files[@]} -eq 0 ]; then
    echo "patches 目录为空，无需应用。"
    exit 0
fi

if [ ! -d "$SRC_DIR" ]; then
    echo "LLVM 源码目录不存在: $SRC_DIR" >&2
    exit 1
fi

IFS=$'\n' sorted_patches=($(sort <<<"${patch_files[*]}"))
unset IFS

echo "=== apply-patches ==="
echo "LLVM_SRC    = $SRC_DIR"
echo "PATCHES_DIR = $PATCHES_DIR"
echo "patch 数量  = ${#sorted_patches[@]}"

for patch_file in "${sorted_patches[@]}"; do
    patch_name="$(basename "$patch_file")"
    # 幂等检测：--dry-run --forward 若返回非 0 说明已应用或不适用，跳过
    if patch -d "$SRC_DIR" -p1 --forward --silent --dry-run < "$patch_file" >/dev/null 2>&1; then
        echo "应用 patch: $patch_name"
        patch -d "$SRC_DIR" -p1 --forward --silent < "$patch_file"
        applied_patches+=("$patch_file")
    else
        echo "跳过（已应用或不适用）: $patch_name"
    fi
done

echo "所有 patch 应用成功（共 ${#applied_patches[@]} 个新应用）。"
exit 0
