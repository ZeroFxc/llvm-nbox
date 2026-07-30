#!/usr/bin/env bash
# 功能：探测 NDK → 打 patches → cmake + ninja 构建 LLVM/Clang/LLD 静态库（aarch64-android）
# 参数：见 --help
# 返回值：0 成功、非 0 失败

set -euo pipefail

# ========== 基础路径 ==========
# 函数：获取脚本所在目录与项目根目录
get_project_root() {
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    echo "$(cd "$script_dir/.." && pwd)"
}

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(get_project_root)"
PATCHES_SCRIPT="${SCRIPT_DIR}/apply-patches.sh"

# ========== 参数默认值 ==========
DEFAULT_LLVM_SRC="${ROOT}/llvm-project-llvmorg-22.1.0"
DEFAULT_BUILD_DIR="${ROOT}/build-android-aarch64"
DEFAULT_OUT_DIR="${ROOT}/out/android-aarch64"

# ========== 参数变量 ==========
NDK=""
LLVM_SRC="$DEFAULT_LLVM_SRC"
BUILD_DIR="$DEFAULT_BUILD_DIR"
OUT_DIR="$DEFAULT_OUT_DIR"
JOBS=""
SKIP_PATCHES=0
SKIP_LLVM_BUILD=0

# ========== 帮助信息 ==========
# 函数：打印帮助信息
usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

选项:
  --ndk <path>          显式指定 Android NDK 根目录（优先级最高，跳过自动探测）
  --llvm-src <path>     LLVM 源码目录（默认: ${DEFAULT_LLVM_SRC}）
  --build-dir <path>    构建目录（默认: <project-root>/build-android-aarch64）
  --out-dir <path>      输出目录（默认: <project-root>/out/android-aarch64）
  --jobs <N>            并行编译数（默认: nproc）
  --skip-patches        不重新 apply patches（若上次已应用）
  --skip-llvm-build     跳过 cmake + ninja，直接写 lib-exports.txt
  -h, --help            显示此帮助信息
EOF
}

# ========== 参数解析 ==========
# 函数：getopts 风格的长参数解析
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ndk)
                [[ $# -lt 2 ]] && { echo "错误: --ndk 需要参数" >&2; exit 1; }
                NDK="$2"
                shift 2
                ;;
            --llvm-src)
                [[ $# -lt 2 ]] && { echo "错误: --llvm-src 需要参数" >&2; exit 1; }
                LLVM_SRC="$2"
                shift 2
                ;;
            --build-dir)
                [[ $# -lt 2 ]] && { echo "错误: --build-dir 需要参数" >&2; exit 1; }
                BUILD_DIR="$2"
                shift 2
                ;;
            --out-dir)
                [[ $# -lt 2 ]] && { echo "错误: --out-dir 需要参数" >&2; exit 1; }
                OUT_DIR="$2"
                shift 2
                ;;
            --jobs)
                [[ $# -lt 2 ]] && { echo "错误: --jobs 需要参数" >&2; exit 1; }
                JOBS="$2"
                shift 2
                ;;
            --skip-patches)
                SKIP_PATCHES=1
                shift
                ;;
            --skip-llvm-build)
                SKIP_LLVM_BUILD=1
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                echo "错误: 未知参数 $1" >&2
                echo "" >&2
                usage >&2
                exit 1
                ;;
        esac
    done
}

# ========== 检测是否在 WSL 下运行 ==========
# 函数：判断当前环境是否为 WSL（Windows Subsystem for Linux）
is_wsl() {
    if grep -qEi "(microsoft|wsl)" /proc/version 2>/dev/null; then
        return 0
    fi
    if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        return 0
    fi
    return 1
}

# ========== NDK 自动探测（仅 WSL 且未显式 --ndk 时） ==========
# 函数：按指定顺序自动探测 WSL 用户目录下的 Android NDK
detect_ndk_wsl() {
    local ndk_candidate=""
    local search_log=()

    echo "[NDK 探测] 开始在 WSL ~ 用户目录下自动探测 Android NDK..."

    # 1. $ANDROID_NDK_HOME
    search_log+=("  1) \$ANDROID_NDK_HOME = ${ANDROID_NDK_HOME:-<未设置>}")
    if [[ -n "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_NDK_HOME" ]]; then
        ndk_candidate="$ANDROID_NDK_HOME"
        search_log+=("     → 匹配成功!")
    else
        search_log+=("     → 跳过（不存在或未设置）")
    fi

    # 2. $ANDROID_NDK_ROOT
    if [[ -z "$ndk_candidate" ]]; then
        search_log+=("  2) \$ANDROID_NDK_ROOT = ${ANDROID_NDK_ROOT:-<未设置>}")
        if [[ -n "${ANDROID_NDK_ROOT:-}" && -d "$ANDROID_NDK_ROOT" ]]; then
            ndk_candidate="$ANDROID_NDK_ROOT"
            search_log+=("     → 匹配成功!")
        else
            search_log+=("     → 跳过（不存在或未设置）")
        fi
    fi

    # 3. $ANDROID_HOME/ndk/*（最大版本号）
    if [[ -z "$ndk_candidate" ]]; then
        local android_home="${ANDROID_HOME:-}"
        search_log+=("  3) \$ANDROID_HOME/ndk/* = ${android_home:-<未设置>}/ndk/*")
        if [[ -n "$android_home" && -d "${android_home}/ndk" ]]; then
            local latest
            latest="$(ls -d "${android_home}/ndk"/*/ 2>/dev/null | sort | tail -1 || true)"
            if [[ -n "$latest" && -d "$latest" ]]; then
                ndk_candidate="${latest%/}"
                search_log+=("     → 找到最大版本: $(basename "$ndk_candidate")")
            else
                search_log+=("     → ndk 目录为空或无匹配")
            fi
        else
            search_log+=("     → 跳过（ANDROID_HOME 不存在或无 ndk 子目录）")
        fi
    fi

    # 4. $HOME/Android/Sdk/ndk/*（最大版本号）
    if [[ -z "$ndk_candidate" ]]; then
        local sdk_ndk_home="${HOME}/Android/Sdk/ndk"
        search_log+=("  4) \$HOME/Android/Sdk/ndk/* = ${sdk_ndk_home}/*")
        if [[ -d "$sdk_ndk_home" ]]; then
            local latest
            latest="$(ls -d "${sdk_ndk_home}"/*/ 2>/dev/null | sort | tail -1 || true)"
            if [[ -n "$latest" && -d "$latest" ]]; then
                ndk_candidate="${latest%/}"
                search_log+=("     → 找到最大版本: $(basename "$ndk_candidate")")
            else
                search_log+=("     → ndk 目录为空或无匹配")
            fi
        else
            search_log+=("     → 跳过（目录不存在）")
        fi
    fi

    # 5. $HOME/ndk/*
    if [[ -z "$ndk_candidate" ]]; then
        local home_ndk="${HOME}/ndk"
        search_log+=("  5) \$HOME/ndk/* = ${home_ndk}/*")
        if [[ -d "$home_ndk" ]]; then
            local latest
            latest="$(ls -d "${home_ndk}"/*/ 2>/dev/null | sort | tail -1 || true)"
            if [[ -n "$latest" && -d "$latest" ]]; then
                ndk_candidate="${latest%/}"
                search_log+=("     → 找到最大版本: $(basename "$ndk_candidate")")
            else
                search_log+=("     → ndk 目录为空或无匹配")
            fi
        else
            search_log+=("     → 跳过（目录不存在）")
        fi
    fi

    # 打印探测日志
    for line in "${search_log[@]}"; do
        echo "$line"
    done

    # 若都没找到，报错并指引
    if [[ -z "$ndk_candidate" ]]; then
        echo "" >&2
        echo "[NDK 探测] 失败! 未在 WSL ~ 目录下找到 Android NDK。" >&2
        echo "查找了以下路径（按顺序）：" >&2
        for line in "${search_log[@]}"; do
            echo "  $line" >&2
        done
        echo "" >&2
        echo "请用 --ndk 传入，或在 ~/ 下放 NDK（例如 ~/Android/Sdk/ndk/29.0.13004108）" >&2
        exit 1
    fi

    NDK="$ndk_candidate"
}

# ========== 获取 NDK 版本号 ==========
# 函数：从 NDK 目录下的 source.properties 中读取版本号
get_ndk_version() {
    local ndk_path="$1"
    local props_file="${ndk_path}/source.properties"
    if [[ -f "$props_file" ]]; then
        grep -E "^Pkg.Revision\s*=" "$props_file" 2>/dev/null | head -1 | sed -E 's/.*=\s*//' || echo "unknown"
    else
        echo "unknown"
    fi
}

# ========== ccache 接入 ==========
# 函数：检测并配置 ccache，输出 cmake 参数数组
setup_ccache() {
    CCACHE_CMAKE_ARGS=()
    CCACHE_ENABLED=0

    if command -v ccache >/dev/null 2>&1 && ccache --version >/dev/null 2>&1; then
        export CCACHE_SLOPPINESS="pch_defines,time_macros,include_file_mtime,include_file_ctime,file_stat_matches"
        export CCACHE_COMPILERCHECK="content"
        CCACHE_CMAKE_ARGS=("-DCMAKE_C_COMPILER_LAUNCHER=ccache" "-DCMAKE_CXX_COMPILER_LAUNCHER=ccache")
        CCACHE_ENABLED=1
        echo "[ccache] 已启用: $(command -v ccache)"
        echo "  CCACHE_SLOPPINESS   = $CCACHE_SLOPPINESS"
        echo "  CCACHE_COMPILERCHECK = $CCACHE_COMPILERCHECK"
        echo "  --- ccache -s（构建前） ---"
        ccache -s 2>&1 || true
    else
        echo "[ccache] 未检测到可用 ccache，跳过。"
    fi
}

# ========== apply patches ==========
# 函数：调用 apply-patches.sh 应用补丁
apply_patches_step() {
    if [[ $SKIP_PATCHES -eq 1 ]]; then
        echo "[patches] --skip-patches 设置，跳过 patch 应用。"
        return 0
    fi

    echo "[patches] 调用 apply-patches.sh 应用补丁..."
    if [[ ! -f "$PATCHES_SCRIPT" ]]; then
        echo "错误: apply-patches.sh 不存在: $PATCHES_SCRIPT" >&2
        exit 1
    fi
    bash "$PATCHES_SCRIPT" --src "$LLVM_SRC"
}

# ========== cmake 配置 ==========
# 函数：执行 cmake 配置，使用 NDK 自带 toolchain 文件
run_cmake_configure() {
    local toolchain="${NDK}/build/cmake/android.toolchain.cmake"

    if [[ ! -f "$toolchain" ]]; then
        echo "错误: NDK toolchain 文件不存在: $toolchain" >&2
        exit 1
    fi

    echo "[cmake] 开始配置 (BUILD_DIR=$BUILD_DIR)..."
    echo "  toolchain = $toolchain"
    echo "  ANDROID_ABI = arm64-v8a"
    echo "  ANDROID_PLATFORM = android-24"

    cmake -S "$LLVM_SRC/llvm" -B "$BUILD_DIR" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
        -DANDROID_ABI=arm64-v8a \
        -DANDROID_PLATFORM=android-24 \
        -DANDROID_STL=c++_static \
        -DLLVM_ENABLE_PROJECTS="clang;lld" \
        -DLLVM_ENABLE_RUNTIMES="" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$OUT_DIR/staging" \
        -DLLVM_HOST_TRIPLE=aarch64-linux-android \
        -DLLVM_DEFAULT_TARGET_TRIPLE=aarch64-linux-android \
        -DLLVM_TARGETS_TO_BUILD="ARM;AArch64;X86;RISCV;WebAssembly" \
        -DLLVM_BUILD_TOOLS=ON \
        -DLLVM_BUILD_STATIC=ON \
        -DLLVM_INCLUDE_TESTS=OFF \
        -DLLVM_INCLUDE_BENCHMARKS=OFF \
        -DLLVM_INCLUDE_EXAMPLES=OFF \
        -DLLVM_ENABLE_BINDINGS=OFF \
        -DLLVM_ENABLE_OCAMLDOC=OFF \
        -DLLVM_ENABLE_LIBXML2=OFF \
        -DLLVM_ENABLE_ZLIB=ON \
        -DLLVM_ENABLE_ZSTD=OFF \
        -DLLVM_ENABLE_TERMINFO=OFF \
        -DLLVM_ENABLE_THREADS=ON \
        -DLLVM_ENABLE_PIC=ON \
        -DCLANG_ENABLE_STATIC_ANALYZER=OFF \
        -DCLANG_ENABLE_ARCMT=OFF \
        "${CCACHE_CMAKE_ARGS[@]}"

    echo "[cmake] 配置成功。"
}

# ========== ninja 构建 ==========
# 函数：执行 ninja 构建指定目标
run_ninja_build() {
    echo "[ninja] 开始构建 (jobs=$JOBS)..."
    echo "  目标: clang lld llvm-ar llvm-objcopy llvm-strip llvm-ranlib llvm-dlltool llvm-lib llvm-install-name-tool llvm-bitcode-strip"

    local start_ts
    start_ts=$(date +%s)

    cmake --build "$BUILD_DIR" -j "$JOBS" \
        --target clang lld llvm-ar llvm-objcopy llvm-strip llvm-ranlib \
                 llvm-dlltool llvm-lib llvm-install-name-tool llvm-bitcode-strip

    local end_ts
    end_ts=$(date +%s)
    local elapsed=$((end_ts - start_ts))
    echo "[ninja] 构建完成，耗时 $((elapsed / 60)) 分 $((elapsed % 60)) 秒。"
}

# ========== 产出 lib-exports.txt ==========
# 函数：列出 build/lib/*.a 并导出到 lib-exports.txt
export_lib_list() {
    local lib_dir="${BUILD_DIR}/lib"
    local exports_file="${BUILD_DIR}/lib-exports.txt"

    echo "[lib-exports] 导出静态库清单到 $exports_file ..."

    if [[ ! -d "$lib_dir" ]]; then
        echo "警告: lib 目录不存在: $lib_dir" >&2
        mkdir -p "$lib_dir"
    fi

    ls -1 "$lib_dir"/*.a 2>/dev/null | sort > "$exports_file" || true
    local count
    count=$(wc -l < "$exports_file" | tr -d ' ')
    echo "$count static libs in lib/"
    echo "[lib-exports] 共 $count 个 .a 文件已写入 lib-exports.txt"

    # 若有，打印 ccache 构建后统计
    if [[ $CCACHE_ENABLED -eq 1 ]]; then
        echo "  --- ccache -s（构建后） ---"
        ccache -s 2>&1 || true
    fi
}

# ========== 主流程 ==========
# 函数：主入口函数
main() {
    parse_args "$@"

    echo "=========================================="
    echo "  llvm-nbox / build.sh (WSL Android aarch64)"
    echo "=========================================="
    echo "PROJECT_ROOT  = $ROOT"
    echo "SCRIPT_DIR    = $SCRIPT_DIR"

    # --- JOBS 默认值 ---
    if [[ -z "$JOBS" ]]; then
        if command -v nproc >/dev/null 2>&1; then
            JOBS="$(nproc)"
        else
            JOBS="4"
        fi
    fi

    # --- NDK 处理：若未显式指定且是 WSL 则自动探测 ---
    if [[ -z "$NDK" ]]; then
        if is_wsl; then
            detect_ndk_wsl
        else
            echo "错误: 非 WSL 环境且未显式指定 --ndk，请传入 --ndk <path>" >&2
            exit 1
        fi
    else
        # 显式指定了 --ndk，检查是否存在
        if [[ ! -d "$NDK" ]]; then
            echo "错误: 显式指定的 NDK 目录不存在: $NDK" >&2
            exit 1
        fi
        echo "[NDK] 使用显式指定路径: $NDK"
    fi

    # 打印 NDK 版本
    NDK_VERSION="$(get_ndk_version "$NDK")"
    echo "Found NDK at $NDK (version: $NDK_VERSION)"

    # --- 目录创建 ---
    mkdir -p "$BUILD_DIR"
    mkdir -p "$OUT_DIR"

    # --- 环境检查 ---
    echo ""
    echo "[环境检查]"
    local env_ok=1
    command -v cmake >/dev/null 2>&1 || { echo "  ✗ cmake 未安装"; env_ok=0; }
    command -v ninja >/dev/null 2>&1 || { echo "  ✗ ninja 未安装"; env_ok=0; }
    [[ -d "$LLVM_SRC" ]] || { echo "  ✗ LLVM 源码目录不存在: $LLVM_SRC"; env_ok=0; }
    [[ -f "$LLVM_SRC/llvm/CMakeLists.txt" ]] || { echo "  ✗ LLVM 源码不合法 (llvm/CMakeLists.txt 不存在)"; env_ok=0; }
    if [[ $env_ok -ne 1 ]]; then
        echo "环境检查失败，退出。" >&2
        exit 1
    fi
    echo "  ✓ cmake: $(command -v cmake)"
    echo "  ✓ ninja: $(command -v ninja)"
    echo "  ✓ LLVM_SRC: $LLVM_SRC"

    echo ""
    echo "[参数汇总]"
    echo "  NDK          = $NDK (v$NDK_VERSION)"
    echo "  LLVM_SRC     = $LLVM_SRC"
    echo "  BUILD_DIR    = $BUILD_DIR"
    echo "  OUT_DIR      = $OUT_DIR"
    echo "  JOBS         = $JOBS"
    echo "  SKIP_PATCHES = $SKIP_PATCHES"
    echo "  SKIP_LLVM    = $SKIP_LLVM_BUILD"

    # --- ccache 接入 ---
    echo ""
    setup_ccache

    # --- apply patches ---
    echo ""
    apply_patches_step

    # --- cmake + ninja ---
    if [[ $SKIP_LLVM_BUILD -eq 0 ]]; then
        echo ""
        run_cmake_configure

        echo ""
        run_ninja_build
    else
        echo ""
        echo "[构建] --skip-llvm-build 设置，跳过 cmake + ninja。"
    fi

    # --- 导出 lib-exports.txt ---
    echo ""
    export_lib_list

    # --- 关键 .a 抽查 ---
    echo ""
    echo "[关键 .a 抽查]"
    for lib in libLLVMCore.a libLLVMSupport.a libclangBasic.a; do
        local libpath="${BUILD_DIR}/lib/${lib}"
        if [[ -f "$libpath" ]]; then
            local fsize
            fsize=$(stat -c%s "$libpath" 2>/dev/null || stat -f%z "$libpath" 2>/dev/null || echo 0)
            local fsize_kb=$((fsize / 1024))
            local check="OK"
            [[ $fsize -lt 1048576 ]] && check="WARN(size<1MB)"
            if command -v file >/dev/null 2>&1; then
                local ftype
                ftype=$(file "$libpath" 2>/dev/null | cut -d: -f2- || echo "")
                echo "  ✓ $lib: ${fsize_kb} KB [$check] $ftype"
            else
                echo "  ✓ $lib: ${fsize_kb} KB [$check]"
            fi
        else
            echo "  - $lib: 不存在（若 ninja 仍在运行属正常）"
        fi
    done

    echo ""
    echo "=========================================="
    echo "  build.sh 执行结束"
    echo "=========================================="
    exit 0
}

main "$@"
