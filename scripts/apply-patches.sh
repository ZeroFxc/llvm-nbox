#!/usr/bin/env bash
# 功能：按文件名顺序应用 patches/ 目录下的所有 .patch 文件到 LLVM 源码目录
# 参数：无（内部硬编码源码路径为 e:/llvmbox/llvm-project-llvmorg-22.1.0/）
# 返回值：0=成功，非0=失败（失败时已对已应用的 patch 进行反向回滚）

set -euo pipefail

PATCHES_DIR="$(cd "$(dirname "$0")/.." && pwd)/patches"
SRC_DIR="e:/llvmbox/llvm-project-llvmorg-22.1.0"

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

for patch_file in "${sorted_patches[@]}"; do
    patch_name="$(basename "$patch_file")"
    echo "应用 patch: $patch_name"
    patch -d "$SRC_DIR" -p1 -s < "$patch_file"
    applied_patches+=("$patch_file")
done

echo "所有 patch 应用成功。"
exit 0
