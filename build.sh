#!/usr/bin/env bash
# 功能：llvm-nbox 构建入口脚本（当前阶段：参数解析 + 环境检查）
# 参数：
#   --ndk <path>       Android NDK 路径（默认：环境变量 ANDROID_NDK_HOME 或 ANDROID_NDK_ROOT）
#   --llvm-src <path>  LLVM 源码路径（默认：e:/llvmbox/llvm-project-llvmorg-22.1.0）
#   --build-dir <path> 构建目录（默认：./build）
#   --out-dir <path>   输出目录（默认：./out）
#   --jobs <num>       并行编译数（默认：CPU 核心数）
#   --skip-llvm        跳过 LLVM 构建
#   --no-ccache        禁用 ccache
#   -h, --help         显示帮助
# 返回值：0=环境检查通过，非0=参数或环境检查失败

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DEFAULT_LLVM_SRC="e:/llvmbox/llvm-project-llvmorg-22.1.0"
DEFAULT_BUILD_DIR="${SCRIPT_DIR}/build"
DEFAULT_OUT_DIR="${SCRIPT_DIR}/out"

NDK_DIR=""
LLVM_SRC=""
BUILD_DIR=""
OUT_DIR=""
JOBS=""
SKIP_LLVM=0
NO_CCACHE=0

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

选项:
  --ndk <path>       Android NDK 路径（默认: \$ANDROID_NDK_HOME 或 \$ANDROID_NDK_ROOT）
  --llvm-src <path>  LLVM 源码路径（默认: ${DEFAULT_LLVM_SRC}）
  --build-dir <path> 构建目录（默认: ${DEFAULT_BUILD_DIR}）
  --out-dir <path>   输出目录（默认: ${DEFAULT_OUT_DIR}）
  --jobs <num>       并行编译数（默认: CPU 核心数）
  --skip-llvm        跳过 LLVM 构建
  --no-ccache        禁用 ccache
  -h, --help         显示此帮助信息

环境安装建议:
  WSL / Linux: apt install cmake ninja-build ccache build-essential
  macOS:       brew install cmake ninja ccache
  Windows:     scoop install cmake ninja ccache
EOF
}

print_error_and_help() {
    echo "错误: $1" >&2
    echo "" >&2
    usage >&2
    echo "" >&2
    echo "环境安装建议:" >&2
    echo "  WSL / Linux: apt install cmake ninja-build ccache build-essential" >&2
    echo "  Windows:     scoop install cmake ninja ccache" >&2
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ndk)
            [[ $# -lt 2 ]] && print_error_and_help "--ndk 需要参数"
            NDK_DIR="$2"
            shift 2
            ;;
        --llvm-src)
            [[ $# -lt 2 ]] && print_error_and_help "--llvm-src 需要参数"
            LLVM_SRC="$2"
            shift 2
            ;;
        --build-dir)
            [[ $# -lt 2 ]] && print_error_and_help "--build-dir 需要参数"
            BUILD_DIR="$2"
            shift 2
            ;;
        --out-dir)
            [[ $# -lt 2 ]] && print_error_and_help "--out-dir 需要参数"
            OUT_DIR="$2"
            shift 2
            ;;
        --jobs)
            [[ $# -lt 2 ]] && print_error_and_help "--jobs 需要参数"
            JOBS="$2"
            shift 2
            ;;
        --skip-llvm)
            SKIP_LLVM=1
            shift
            ;;
        --no-ccache)
            NO_CCACHE=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            print_error_and_help "未知参数: $1"
            ;;
    esac
done

[[ -z "$NDK_DIR" ]] && NDK_DIR="${ANDROID_NDK_HOME:-${ANDROID_NDK_ROOT:-}}"
[[ -z "$LLVM_SRC" ]] && LLVM_SRC="$DEFAULT_LLVM_SRC"
[[ -z "$BUILD_DIR" ]] && BUILD_DIR="$DEFAULT_BUILD_DIR"
[[ -z "$OUT_DIR" ]] && OUT_DIR="$DEFAULT_OUT_DIR"
if [[ -z "$JOBS" ]]; then
    if command -v nproc >/dev/null 2>&1; then
        JOBS="$(nproc)"
    elif command -v sysctl >/dev/null 2>&1; then
        JOBS="$(sysctl -n hw.ncpu)"
    else
        JOBS="4"
    fi
fi

errors=()

if [[ -z "$NDK_DIR" || ! -d "$NDK_DIR" ]]; then
    errors+=("NDK 路径无效或未设置: ${NDK_DIR:-<未设置>}")
fi

if [[ ! -d "$LLVM_SRC" ]]; then
    errors+=("LLVM 源码目录不存在: $LLVM_SRC")
fi

if ! command -v cmake >/dev/null 2>&1; then
    errors+=("cmake 未安装或不在 PATH 中")
fi

if ! command -v ninja >/dev/null 2>&1; then
    errors+=("ninja 未安装或不在 PATH 中")
fi

if [[ $NO_CCACHE -eq 0 ]] && ! command -v ccache >/dev/null 2>&1; then
    errors+=("ccache 未安装或不在 PATH 中（可用 --no-ccache 禁用）")
fi

if [[ ${#errors[@]} -gt 0 ]]; then
    echo "环境检查失败:" >&2
    for err in "${errors[@]}"; do
        echo "  - $err" >&2
    done
    echo "" >&2
    usage >&2
    echo "" >&2
    echo "环境安装建议:" >&2
    echo "  WSL / Linux: apt install cmake ninja-build ccache build-essential" >&2
    echo "  Windows:     scoop install cmake ninja ccache" >&2
    exit 1
fi

echo "环境检查通过，后续阶段待实现。"
exit 0
