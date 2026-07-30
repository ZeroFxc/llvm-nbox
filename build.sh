#!/usr/bin/env bash
# 功能：llvm-nbox 生产级构建脚本（WSL/Linux），对齐 Task 1~7 所有阶段
# 阶段：apply-patches → cmake/ninja LLVM → 重编 driver .o 为 -fPIC →
#       编译 llvm-nbox.cpp.o + jni.o → 链接 elf/so → strip → 资源拷贝 → zip
# 参数：见 --help
# 返回值：0=成功，非0=失败
set -euo pipefail

declare -g T_START=$SECONDS

# ========== 基础路径 ==========
# 功能：获取脚本所在目录与项目根目录
# 参数：无
# 返回值：无（写入全局 ROOT / SCRIPT_DIR）
get_project_root() {
    local script_dir
    script_dir="$(cd "$(dirname "$0")" && pwd)"
    ROOT="$(cd "$script_dir" && pwd)"
    SCRIPT_DIR="$script_dir"
    PATCHES_SCRIPT="${ROOT}/scripts/apply-patches.sh"
}

get_project_root

# ========== 参数默认值 ==========
DEFAULT_LLVM_SRC="${ROOT}/llvm-project-llvmorg-22.1.0"
DEFAULT_BUILD_DIR="${ROOT}/build-android-aarch64"
DEFAULT_OUT_DIR="${ROOT}/out/android-aarch64"
DEFAULT_TARGET_TRIPLE="aarch64-linux-android"
DEFAULT_ABI="arm64-v8a"
DEFAULT_ANDROID_PLATFORM="24"

# ========== 参数变量 ==========
NDK=""
LLVM_SRC="$DEFAULT_LLVM_SRC"
BUILD_DIR="$DEFAULT_BUILD_DIR"
OUT_DIR="$DEFAULT_OUT_DIR"
JOBS=""
SKIP_LLVM=0
SKIP_ZIP=0
TARGET_TRIPLE="$DEFAULT_TARGET_TRIPLE"
ABI="$DEFAULT_ABI"
ANDROID_PLATFORM="$DEFAULT_ANDROID_PLATFORM"
CLANG_VERSION=""

# ========== 工具链变量（detect_paths 后填充） ==========
TOOLCHAIN=""
CLANGXX=""
STRIP=""
API_LEVEL=""
TARGET_WITH_API=""
COMMON_FLAGS=""
INC_FLAGS=""

# ========== 日志辅助 ==========
# 功能：打印阶段标题，记录开始时间
# 参数：$1=阶段名
# 返回值：无
log_stage() {
    local stage="$1"
    echo ""
    echo "============================================================"
    echo "  STAGE: $stage"
    echo "============================================================"
    echo "[$stage] start: $(date '+%H:%M:%S')"
    STAGE_START=$SECONDS
}

# 功能：打印阶段结束时间与耗时
# 参数：$1=阶段名
# 返回值：无
log_stage_end() {
    local stage="$1"
    local elapsed=$((SECONDS - STAGE_START))
    echo "[$stage] end:   $(date '+%H:%M:%S')  elapsed: ${elapsed}s ($((elapsed/60))m$((elapsed%60))s)"
    echo "============================================================"
}

# ========== 帮助信息 ==========
# 功能：打印帮助信息
# 参数：无
# 返回值：无
usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

选项:
  --ndk <path>          显式指定 Android NDK 根目录（优先级最高，跳过自动探测）
  --llvm-src <path>     LLVM 源码目录（默认: ${DEFAULT_LLVM_SRC}）
  --build-dir <path>    构建目录（默认: ${DEFAULT_BUILD_DIR}）
  --out-dir <path>      输出目录（默认: ${DEFAULT_OUT_DIR}）
  --jobs <N>            并行编译数（默认: nproc）
  --skip-llvm           跳过 apply-patches + cmake/ninja，直接进入重编 driver.o → 链接 → 资源
  --skip-zip            不生成最终 zip 包
  --target <TRIPLE>     目标三元组（默认: ${DEFAULT_TARGET_TRIPLE}）
  --abi <ABI>           Android ABI（默认: ${DEFAULT_ABI}）
  --android-platform <N> Android API level（默认: ${DEFAULT_ANDROID_PLATFORM}）
  --clang-version <DIR> clang 版本目录名（默认: 自动探测 build/lib/clang/ 下首项，失败退为 22）
  -h, --help            显示此帮助信息
EOF
}

# ========== 参数解析 ==========
# 功能：解析命令行参数
# 参数：$@ 命令行参数列表
# 返回值：无（写入全局参数变量）
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
            --skip-llvm)
                SKIP_LLVM=1
                shift
                ;;
            --skip-zip)
                SKIP_ZIP=1
                shift
                ;;
            --target)
                [[ $# -lt 2 ]] && { echo "错误: --target 需要参数" >&2; exit 1; }
                TARGET_TRIPLE="$2"
                shift 2
                ;;
            --abi)
                [[ $# -lt 2 ]] && { echo "错误: --abi 需要参数" >&2; exit 1; }
                ABI="$2"
                shift 2
                ;;
            --android-platform)
                [[ $# -lt 2 ]] && { echo "错误: --android-platform 需要参数" >&2; exit 1; }
                ANDROID_PLATFORM="$2"
                shift 2
                ;;
            --clang-version)
                [[ $# -lt 2 ]] && { echo "错误: --clang-version 需要参数" >&2; exit 1; }
                CLANG_VERSION="$2"
                shift 2
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
# 功能：判断当前环境是否为 WSL（Windows Subsystem for Linux）
# 参数：无
# 返回值：0=是 WSL，1=不是 WSL
is_wsl() {
    if grep -qEi "(microsoft|wsl)" /proc/version 2>/dev/null; then
        return 0
    fi
    if [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
        return 0
    fi
    return 1
}

# ========== NDK 自动探测 ==========
# 功能：按指定顺序自动探测 Android NDK 路径
# 参数：无（写入全局 NDK）
# 返回值：无
detect_ndk() {
    local ndk_candidate=""

    # 1. $HOME/android-ndk-r29
    if [[ -d "$HOME/android-ndk-r29" ]]; then
        ndk_candidate="$HOME/android-ndk-r29"
    fi

    # 2. $ANDROID_NDK_HOME
    if [[ -z "$ndk_candidate" && -n "${ANDROID_NDK_HOME:-}" && -d "$ANDROID_NDK_HOME" ]]; then
        ndk_candidate="$ANDROID_NDK_HOME"
    fi

    # 3. $ANDROID_NDK_ROOT
    if [[ -z "$ndk_candidate" && -n "${ANDROID_NDK_ROOT:-}" && -d "$ANDROID_NDK_ROOT" ]]; then
        ndk_candidate="$ANDROID_NDK_ROOT"
    fi

    if [[ -z "$ndk_candidate" ]]; then
        echo "错误: 未检测到 Android NDK，查找路径：" >&2
        echo "  1) \$HOME/android-ndk-r29" >&2
        echo "  2) \$ANDROID_NDK_HOME=${ANDROID_NDK_HOME:-<未设置>}" >&2
        echo "  3) \$ANDROID_NDK_ROOT=${ANDROID_NDK_ROOT:-<未设置>}" >&2
        echo "请用 --ndk <path> 显式指定" >&2
        exit 1
    fi

    NDK="$ndk_candidate"
}

# ========== 阶段 1：detect_paths ==========
# 功能：探测 NDK、工具链、ccache、cmake/ninja/python3 路径，计算 COMMON_FLAGS / INC_FLAGS
# 参数：无
# 返回值：无
detect_paths() {
    log_stage "detect_paths"

    # --- JOBS 默认值 ---
    if [[ -z "$JOBS" ]]; then
        if command -v nproc >/dev/null 2>&1; then
            JOBS="$(nproc)"
        else
            JOBS="4"
        fi
    fi

    # --- NDK ---
    if [[ -z "$NDK" ]]; then
        detect_ndk
    else
        if [[ ! -d "$NDK" ]]; then
            echo "错误: 显式指定的 NDK 目录不存在: $NDK" >&2
            exit 1
        fi
    fi
    echo "NDK = $NDK"

    # --- 工具链 ---
    TOOLCHAIN="$NDK/toolchains/llvm/prebuilt/linux-x86_64"
    if [[ ! -d "$TOOLCHAIN" ]]; then
        echo "错误: 工具链目录不存在: $TOOLCHAIN" >&2
        exit 1
    fi
    CLANGXX="$TOOLCHAIN/bin/clang++"
    STRIP="$TOOLCHAIN/bin/llvm-strip"
    for bin in "$CLANGXX" "$STRIP"; do
        if [[ ! -x "$bin" ]]; then
            echo "错误: 工具链二进制不存在或不可执行: $bin" >&2
            exit 1
        fi
    done
    echo "TOOLCHAIN = $TOOLCHAIN"

    # --- API level ---
    API_LEVEL="$ANDROID_PLATFORM"
    TARGET_WITH_API="${TARGET_TRIPLE}${API_LEVEL}"
    echo "TARGET = $TARGET_WITH_API"

    # --- 公共编译选项 ---
    COMMON_FLAGS="--target=$TARGET_WITH_API --sysroot=$TOOLCHAIN/sysroot -std=c++17 -fPIC -fno-exceptions -fno-rtti -ffunction-sections -fdata-sections -Oz -g0 -Wall -Wno-unused-parameter"
    INC_FLAGS="-I$LLVM_SRC/llvm/include -I$BUILD_DIR/include -I$LLVM_SRC/clang/include -I$BUILD_DIR/tools/clang/include -I$LLVM_SRC/lld/include -I$BUILD_DIR/tools/lld/include -I$BUILD_DIR/tools/llvm-objcopy"

    # --- ccache ---
    if command -v ccache >/dev/null 2>&1; then
        echo "ccache: yes ($(command -v ccache))"
        ccache -V 2>&1 | head -n1 || true
    else
        echo "ccache: no"
    fi

    # --- cmake/ninja/python3 ---
    local dep_ok=1
    for dep in cmake ninja python3; do
        if command -v "$dep" >/dev/null 2>&1; then
            echo "$dep: yes ($(command -v $dep))"
        else
            echo "$dep: MISSING" >&2
            dep_ok=0
        fi
    done
    if [[ $dep_ok -ne 1 ]]; then
        echo "错误: 缺少依赖命令，请先安装 cmake ninja-build python3" >&2
        exit 1
    fi

    # --- LLVM_SRC 检查 ---
    if [[ ! -d "$LLVM_SRC" ]]; then
        echo "错误: LLVM 源码目录不存在: $LLVM_SRC" >&2
        exit 1
    fi
    if [[ ! -f "$LLVM_SRC/llvm/CMakeLists.txt" ]]; then
        echo "错误: LLVM 源码不合法 (llvm/CMakeLists.txt 不存在): $LLVM_SRC" >&2
        exit 1
    fi
    echo "LLVM_SRC = $LLVM_SRC"

    # --- BUILD_DIR 检查（--skip-llvm 时必须已存在）---
    if [[ $SKIP_LLVM -eq 1 && ! -d "$BUILD_DIR" ]]; then
        echo "错误: --skip-llvm 时构建目录必须已存在: $BUILD_DIR" >&2
        exit 1
    fi
    echo "BUILD_DIR = $BUILD_DIR"
    echo "OUT_DIR   = $OUT_DIR"

    log_stage_end "detect_paths"
}

# ========== 阶段 2：apply_patches_stage ==========
# 功能：调用 scripts/apply-patches.sh 应用 LLVM 源码补丁
# 参数：无（--skip-llvm 时跳过）
# 返回值：无
apply_patches_stage() {
    if [[ $SKIP_LLVM -eq 1 ]]; then
        echo "STAGE apply_patches_stage: --skip-llvm → SKIP"
        return 0
    fi
    log_stage "apply_patches_stage"
    if [[ ! -f "$PATCHES_SCRIPT" ]]; then
        echo "错误: apply-patches.sh 不存在: $PATCHES_SCRIPT" >&2
        exit 1
    fi
    bash "$PATCHES_SCRIPT" --src "$LLVM_SRC"
    log_stage_end "apply_patches_stage"
}

# ========== 阶段 3：cmake_configure_stage ==========
# 功能：使用 NDK toolchain 配置 cmake，生成 build.ninja
# 参数：无（--skip-llvm 时跳过，复用已有 BUILD_DIR）
# 返回值：无
cmake_configure_stage() {
    if [[ $SKIP_LLVM -eq 1 ]]; then
        echo "STAGE cmake_configure_stage: --skip-llvm → SKIP (reuse $BUILD_DIR)"
        return 0
    fi
    log_stage "cmake_configure_stage"
    local toolchain="${NDK}/build/cmake/android.toolchain.cmake"
    if [[ ! -f "$toolchain" ]]; then
        echo "错误: NDK toolchain 文件不存在: $toolchain" >&2
        exit 1
    fi
    mkdir -p "$BUILD_DIR"
    cmake -S "$LLVM_SRC/llvm" -B "$BUILD_DIR" -G Ninja \
        -DCMAKE_TOOLCHAIN_FILE="$toolchain" \
        -DANDROID_ABI="$ABI" \
        -DANDROID_PLATFORM="android-${ANDROID_PLATFORM}" \
        -DANDROID_STL=c++_static \
        -DLLVM_ENABLE_PROJECTS="clang;lld" \
        -DLLVM_ENABLE_RUNTIMES="" \
        -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_INSTALL_PREFIX="$OUT_DIR/staging" \
        -DLLVM_HOST_TRIPLE="$TARGET_TRIPLE" \
        -DLLVM_DEFAULT_TARGET_TRIPLE="$TARGET_TRIPLE" \
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
        -DCLANG_ENABLE_ARCMT=OFF
    echo "cmake 配置成功"
    log_stage_end "cmake_configure_stage"
}

# ========== 阶段 4：ninja_llvm_stage ==========
# 功能：ninja 构建 clang/lld 及相关 binutil 工具（静态库 + 驱动 .o）
# 参数：无（--skip-llvm 时跳过）
# 返回值：无
ninja_llvm_stage() {
    if [[ $SKIP_LLVM -eq 1 ]]; then
        echo "STAGE ninja_llvm_stage: --skip-llvm → SKIP"
        return 0
    fi
    log_stage "ninja_llvm_stage"
    echo "构建目标: clang lld llvm-ar llvm-objcopy llvm-ranlib llvm-dlltool llvm-lib llvm-strip llvm-install-name-tool llvm-bitcode-strip"
    cmake --build "$BUILD_DIR" -j "$JOBS" \
        --target clang lld llvm-ar llvm-objcopy llvm-strip llvm-ranlib \
                 llvm-dlltool llvm-lib llvm-install-name-tool llvm-bitcode-strip
    local lib_count
    lib_count=$(ls -1 "$BUILD_DIR/lib"/*.a 2>/dev/null | wc -l | tr -d ' ')
    echo "构建完成，共 $lib_count 个 .a 文件"
    log_stage_end "ninja_llvm_stage"
}

# ========== 阶段 5：rebuild_driver_objs_fpic_stage ==========
# 功能：重新编译 9 个 driver .o 为 -fPIC（原 cmake 构建的 driver 非 -fPIC 会导致 -shared 重定位失败）
#       即使 --skip-llvm 也必须执行，因为每次 driver .o 可能非 -fPIC
# 参数：无
# 返回值：无
rebuild_driver_objs_fpic_stage() {
    log_stage "rebuild_driver_objs_fpic_stage"

    # 定义 9 个 driver 对象：[0]=源文件 [1]=输出 .o 路径
    declare -a DRIVER_SRCS=(
        "$LLVM_SRC/clang/tools/driver/driver.cpp"
        "$LLVM_SRC/clang/tools/driver/cc1_main.cpp"
        "$LLVM_SRC/clang/tools/driver/cc1as_main.cpp"
        "$LLVM_SRC/clang/tools/driver/cc1gen_reproducer_main.cpp"
        "$LLVM_SRC/lld/tools/lld/lld.cpp"
        "$LLVM_SRC/llvm/tools/llvm-ar/llvm-ar.cpp"
        "$LLVM_SRC/llvm/tools/llvm-objcopy/llvm-objcopy.cpp"
        "$LLVM_SRC/llvm/tools/llvm-objcopy/ObjcopyOptions.cpp"
    )
    declare -a DRIVER_OBJS=(
        "$BUILD_DIR/tools/clang/tools/driver/CMakeFiles/clang.dir/driver.cpp.o"
        "$BUILD_DIR/tools/clang/tools/driver/CMakeFiles/clang.dir/cc1_main.cpp.o"
        "$BUILD_DIR/tools/clang/tools/driver/CMakeFiles/clang.dir/cc1as_main.cpp.o"
        "$BUILD_DIR/tools/clang/tools/driver/CMakeFiles/clang.dir/cc1gen_reproducer_main.cpp.o"
        "$BUILD_DIR/tools/lld/tools/lld/CMakeFiles/lld.dir/lld.cpp.o"
        "$BUILD_DIR/tools/llvm-ar/CMakeFiles/llvm-ar.dir/llvm-ar.cpp.o"
        "$BUILD_DIR/tools/llvm-objcopy/CMakeFiles/llvm-objcopy.dir/llvm-objcopy.cpp.o"
        "$BUILD_DIR/tools/llvm-objcopy/CMakeFiles/llvm-objcopy.dir/ObjcopyOptions.cpp.o"
    )

    local count=${#DRIVER_SRCS[@]}
    echo "需要重编 $count 个 driver .o（带 -fPIC）"

    for (( i=0; i<count; i++ )); do
        local src="${DRIVER_SRCS[$i]}"
        local obj="${DRIVER_OBJS[$i]}"
        local objdir
        objdir="$(dirname "$obj")"
        mkdir -p "$objdir"
        local name
        name="$(basename "$src")"
        echo "  [$((i+1))/$count] $name"
        time -p $CLANGXX -c "$src" -o "$obj" $COMMON_FLAGS $INC_FLAGS
        local sz
        sz=$(stat -c%s "$obj" 2>/dev/null || echo 0)
        echo "     → OK ($sz bytes)"
    done

    echo "9 个 driver .o 全部重编成功"
    log_stage_end "rebuild_driver_objs_fpic_stage"
}

# ========== 阶段 6：compile_entry_objs_stage ==========
# 功能：编译本项目入口 llvm-nbox.cpp + JNI llvm_nbox_jni.cpp 为 .o
# 参数：无
# 返回值：无
compile_entry_objs_stage() {
    log_stage "compile_entry_objs_stage"

    local entry_src="${ROOT}/src/llvm-nbox.cpp"
    local entry_obj="${BUILD_DIR}/llvm-nbox.cpp.o"
    local jni_src="${ROOT}/src/jni/llvm_nbox_jni.cpp"
    local jni_obj="${BUILD_DIR}/llvm_nbox_jni.cpp.o"

    echo "  [1/2] llvm-nbox.cpp"
    time -p $CLANGXX -c "$entry_src" -o "$entry_obj" $COMMON_FLAGS $INC_FLAGS
    echo "     → OK ($(stat -c%s "$entry_obj") bytes)"

    echo "  [2/2] llvm_nbox_jni.cpp"
    time -p $CLANGXX -c "$jni_src" -o "$jni_obj" $COMMON_FLAGS $INC_FLAGS
    echo "     → OK ($(stat -c%s "$jni_obj") bytes)"

    log_stage_end "compile_entry_objs_stage"
}

# ========== 阶段 7：link_elf_stage ==========
# 功能：链接 PIE 可执行文件 llvm-nbox（unstripped → strip-debug → strip-all）
# 参数：无
# 返回值：无
link_elf_stage() {
    log_stage "link_elf_stage"

    local bin_unstripped_dir="$OUT_DIR/bin/unstripped"
    local bin_dir="$OUT_DIR/bin"
    mkdir -p "$bin_unstripped_dir" "$bin_dir"

    # DRIVER_OBJS
    local DRIVER_OBJS=(
        "$BUILD_DIR/llvm-nbox.cpp.o"
        "$BUILD_DIR/llvm_nbox_jni.cpp.o"
        "$BUILD_DIR/tools/clang/tools/driver/CMakeFiles/clang.dir/driver.cpp.o"
        "$BUILD_DIR/tools/clang/tools/driver/CMakeFiles/clang.dir/cc1_main.cpp.o"
        "$BUILD_DIR/tools/clang/tools/driver/CMakeFiles/clang.dir/cc1as_main.cpp.o"
        "$BUILD_DIR/tools/clang/tools/driver/CMakeFiles/clang.dir/cc1gen_reproducer_main.cpp.o"
        "$BUILD_DIR/tools/lld/tools/lld/CMakeFiles/lld.dir/lld.cpp.o"
        "$BUILD_DIR/tools/llvm-ar/CMakeFiles/llvm-ar.dir/llvm-ar.cpp.o"
        "$BUILD_DIR/tools/llvm-objcopy/CMakeFiles/llvm-objcopy.dir/llvm-objcopy.cpp.o"
        "$BUILD_DIR/tools/llvm-objcopy/CMakeFiles/llvm-objcopy.dir/ObjcopyOptions.cpp.o"
    )

    # ALL_LIBS
    local ALL_LIBS
    ALL_LIBS=$(ls -1 "$BUILD_DIR/lib/libclang"*.a "$BUILD_DIR/lib/liblld"*.a "$BUILD_DIR/lib/libLLVM"*.a 2>/dev/null | tr '\n' ' ')
    local lib_count
    lib_count=$(echo "$ALL_LIBS" | wc -w)
    echo "ALL_LIBS count = $lib_count"

    local elf_unstripped="$bin_unstripped_dir/llvm-nbox"
    local elf_debug="$bin_dir/llvm-nbox.debug"
    local elf_final="$bin_dir/llvm-nbox"

    echo "--- link unstripped ELF ---"
    time -p $CLANGXX \
        --target="$TARGET_WITH_API" \
        --sysroot="$TOOLCHAIN/sysroot" \
        -pie \
        -fPIC \
        -fuse-ld=lld \
        -Wl,--gc-sections \
        -Wl,-z,muldefs \
        -Wl,--exclude-libs,ALL \
        -Wl,--hash-style=gnu \
        -Wl,--build-id=sha1 \
        -Oz \
        -o "$elf_unstripped" \
        "${DRIVER_OBJS[@]}" \
        -Wl,--start-group \
        $ALL_LIBS \
        -Wl,--end-group \
        -lm -lz -ldl -llog -latomic \
        -static-libstdc++ -static-libgcc
    echo "link unstripped OK ($(stat -c%s "$elf_unstripped") bytes)"

    echo "--- strip-debug → llvm-nbox.debug ---"
    time -p $STRIP --strip-debug -o "$elf_debug" "$elf_unstripped"
    echo "strip-debug OK ($(stat -c%s "$elf_debug") bytes)"

    echo "--- strip-all → llvm-nbox ---"
    time -p $STRIP --strip-all -o "$elf_final" "$elf_debug"
    echo "strip-all OK ($(stat -c%s "$elf_final") bytes)"

    log_stage_end "link_elf_stage"
}

# ========== 阶段 8：link_so_stage ==========
# 功能：链接 JNI 共享库 libllvm-nbox.so（unstripped → strip-debug → strip-all）
# 参数：无
# 返回值：无
link_so_stage() {
    log_stage "link_so_stage"

    local lib_unstripped_dir="$OUT_DIR/lib/$ABI/unstripped"
    local lib_dir="$OUT_DIR/lib/$ABI"
    mkdir -p "$lib_unstripped_dir" "$lib_dir"

    local DRIVER_OBJS=(
        "$BUILD_DIR/llvm-nbox.cpp.o"
        "$BUILD_DIR/llvm_nbox_jni.cpp.o"
        "$BUILD_DIR/tools/clang/tools/driver/CMakeFiles/clang.dir/driver.cpp.o"
        "$BUILD_DIR/tools/clang/tools/driver/CMakeFiles/clang.dir/cc1_main.cpp.o"
        "$BUILD_DIR/tools/clang/tools/driver/CMakeFiles/clang.dir/cc1as_main.cpp.o"
        "$BUILD_DIR/tools/clang/tools/driver/CMakeFiles/clang.dir/cc1gen_reproducer_main.cpp.o"
        "$BUILD_DIR/tools/lld/tools/lld/CMakeFiles/lld.dir/lld.cpp.o"
        "$BUILD_DIR/tools/llvm-ar/CMakeFiles/llvm-ar.dir/llvm-ar.cpp.o"
        "$BUILD_DIR/tools/llvm-objcopy/CMakeFiles/llvm-objcopy.dir/llvm-objcopy.cpp.o"
        "$BUILD_DIR/tools/llvm-objcopy/CMakeFiles/llvm-objcopy.dir/ObjcopyOptions.cpp.o"
    )

    local ALL_LIBS
    ALL_LIBS=$(ls -1 "$BUILD_DIR/lib/libclang"*.a "$BUILD_DIR/lib/liblld"*.a "$BUILD_DIR/lib/libLLVM"*.a 2>/dev/null | tr '\n' ' ')

    local so_unstripped="$lib_unstripped_dir/libllvm-nbox.so"
    local so_debug="$lib_dir/libllvm-nbox.debug"
    local so_final="$lib_dir/libllvm-nbox.so"

    echo "--- link unstripped SO ---"
    time -p $CLANGXX \
        --target="$TARGET_WITH_API" \
        --sysroot="$TOOLCHAIN/sysroot" \
        -shared \
        -fPIC \
        -fuse-ld=lld \
        -Wl,--gc-sections \
        -Wl,-z,muldefs \
        -Wl,--exclude-libs,ALL \
        -Wl,--hash-style=gnu \
        -Wl,--build-id=sha1 \
        -Wl,-soname,libllvm-nbox.so \
        -O2 \
        -o "$so_unstripped" \
        "${DRIVER_OBJS[@]}" \
        -Wl,--start-group \
        $ALL_LIBS \
        -Wl,--end-group \
        -lm -lz -ldl -llog -latomic \
        -static-libstdc++ -static-libgcc
    echo "link unstripped OK ($(stat -c%s "$so_unstripped") bytes)"

    echo "--- strip-debug → libllvm-nbox.debug ---"
    time -p $STRIP --strip-debug -o "$so_debug" "$so_unstripped"
    echo "strip-debug OK ($(stat -c%s "$so_debug") bytes)"

    echo "--- strip-all → libllvm-nbox.so ---"
    time -p $STRIP --strip-all -o "$so_final" "$so_debug"
    echo "strip-all OK ($(stat -c%s "$so_final") bytes)"

    log_stage_end "link_so_stage"
}

# ========== 阶段 9：copy_resource_stage ==========
# 功能：拷贝 clang 内置 include、sysroot 指南 + 示例、JNI 头文件、顶层 README
# 参数：无
# 返回值：无
copy_resource_stage() {
    log_stage "copy_resource_stage"

    # --- 9.1 探测 clang 版本目录 ---
    local clang_ver="$CLANG_VERSION"
    if [[ -z "$clang_ver" ]]; then
        clang_ver=$(ls -1 "$BUILD_DIR/lib/clang" 2>/dev/null | head -n1 || true)
    fi
    if [[ -z "$clang_ver" ]]; then
        clang_ver="22"
        echo "警告: 自动探测 clang 版本失败，回退为 $clang_ver"
    fi
    echo "CLANG_VERSION = $clang_ver"

    # --- 9.2 拷贝 clang 内置 resource include ---
    local clang_res_src="$BUILD_DIR/lib/clang/$clang_ver/include"
    local clang_res_dst="$OUT_DIR/resource/lib/clang/$clang_ver/include"
    mkdir -p "$(dirname "$clang_res_dst")"
    if [[ ! -d "$clang_res_src" ]]; then
        echo "错误: clang resource include 目录不存在: $clang_res_src" >&2
        exit 1
    fi
    cp -a "$clang_res_src" "$clang_res_dst"
    local fcount
    fcount=$(ls -1 "$clang_res_dst" | wc -l | tr -d ' ')
    echo "clang resource include: $fcount 个文件已拷贝"

    # --- 9.3 sysroot README.md + compile.example.sh ---
    local sysroot_dir="$OUT_DIR/resource/sysroot"
    mkdir -p "$sysroot_dir"

    cat > "$sysroot_dir/README.md" <<'SYSROOT_README_EOF'
# sysroot 放置指南

Android 端编译（`clang --target=aarch64-linux-android24 ...`）必须指定一个 bionic sysroot：头文件（stdio.h/stdlib.h/pthread.h ...）和库（libc.so/libm.so/...）。
本项目不直接打包 NDK 文件，请在 Android 设备上按以下方式准备 sysroot：

## 方式 A（推荐，体积最小）：从本设备拷贝
  1. 你的 Android 设备出厂已带 `/system/lib64/libc.so` 等运行时库；头文件从 NDK 拷一次即可：

     # 从 PC 端 NDK push 到设备（假设已 adb root 或有权限）：
     adb push $NDK/toolchains/llvm/prebuilt/linux-x86_64/sysroot /data/local/tmp/llvm-nbox/sysroot/

  2. 运行时：`--sysroot=/data/local/tmp/llvm-nbox/sysroot`

## 方式 B（纯运行时，APP filesDir）：
  解压 zip 到你的 `context.getFilesDir() + "/llvm-nbox"`，sysroot 对应目录为：
    `filesDir/llvm-nbox/resource/sysroot`
  首次启动把 NDK sysroot 用 Java File.copy 解压到上述位置即可。

## 验证 clang 用的头/库都来自该 sysroot：
  运行 `llvm-nbox clang --target=aarch64-linux-android24 --sysroot=<SYSROOT_PATH> -resource-dir=<RES>/lib/clang/<VER> -v -E -x c /dev/null 2>&1 | grep -E '^\s*/'`
  输出的 `#include <...> search starts here` 列表里必须包含 `<SYSROOT_PATH>/usr/include`。
SYSROOT_README_EOF
    echo "sysroot/README.md 已写入"

    cat > "$sysroot_dir/compile.example.sh" <<COMPILE_SH_EOF
#!/system/bin/sh
# Android 设备上真实的编译+链接示例（确保 llvm-nbox 有可执行权限：chmod 755 llvm-nbox）
HERE=\$(cd "\$(dirname "\$0")" && pwd)
NBOX=\$HERE/../../bin/llvm-nbox
RES=\$HERE/..
SYSROOT=\$HERE

cd /data/local/tmp
echo 'int puts(const char*); int main(){puts("hello from llvm-nbox aarch64"); return 0;}' > hello.c
\$NBOX clang --target=aarch64-linux-android24 \\
  --sysroot=\$SYSROOT \\
  -resource-dir=\$RES/lib/clang/$clang_ver \\
  -pie -fPIC -Oz hello.c -o hello
echo "exit=\$?"
file hello
COMPILE_SH_EOF
    chmod +x "$sysroot_dir/compile.example.sh"
    echo "sysroot/compile.example.sh 已写入 (chmod +x)"

    # --- 9.4 JNI 头文件 ---
    local inc_dir="$OUT_DIR/include"
    mkdir -p "$inc_dir"
    cp -a "${ROOT}/src/jni/llvm_nbox_jni.h" "$inc_dir/"
    echo "include/llvm_nbox_jni.h 已拷贝 ($(stat -c%s "$inc_dir/llvm_nbox_jni.h") bytes)"

    # --- 9.5 顶层 README.md ---
    cat > "$OUT_DIR/README.md" <<TOP_README_EOF
# llvm-nbox-android-aarch64 交付结构

\`\`\`
llvm-nbox-android-aarch64/
  ├─ bin/
  │   ├─ llvm-nbox              # strip-all 主程序，单一二进制，symlink 模式或显式子命令模式
  │   └─ llvm-nbox.debug        # strip-debug 调试版
  ├─ lib/
  │   └─ arm64-v8a/
  │       ├─ libllvm-nbox.so    # JNI 共享库 strip-all，APP 放在 jniLibs/arm64-v8a/
  │       ├─ libllvm-nbox.debug # strip-debug 版
  │       └─ unstripped/
  ├─ include/
  │   └─ llvm_nbox_jni.h        # JNI 绑定 C 辅助函数声明（APP 自定义 C++ JNI 扩展时 include）
  ├─ resource/
  │   ├─ lib/clang/$clang_ver/include/   # clang 内置头（stdarg.h/stddef.h/emmintrin.h/xmmintrin.h 等）
  │   └─ sysroot/                     # sysroot 放置指南与示例脚本（不包含 NDK 版权文件，需自行准备）
  └─ README.md
\`\`\`

## 模式 1：Android CLI（adb shell），无 APP
\`\`\`
adb push llvm-nbox-android-aarch64 /data/local/tmp/llvm-nbox
adb shell
cd /data/local/tmp/llvm-nbox
chmod 755 bin/llvm-nbox

# 1) 通过 symlink 调用（让 argv[0] 识别）：
cd bin
ln -s llvm-nbox clang
ln -s llvm-nbox ld.lld
ln -s llvm-nbox llvm-ar
ln -s llvm-nbox llvm-objcopy
ln -s llvm-nbox llvm-strip
cd ..

# 首次：准备 sysroot（从本机 NDK push，见 resource/sysroot/README.md）。
# 2) 编译 hello.c → hello（aarch64 PIE）：
cd /data/local/tmp
cat > hello.c <<'C'
#include <stdio.h>
int main(){puts("llvm-nbox ok"); return 0;}
C
/data/local/tmp/llvm-nbox/bin/clang \\
  --target=aarch64-linux-android24 \\
  --sysroot=/data/local/tmp/llvm-nbox/resource/sysroot \\
  -resource-dir=/data/local/tmp/llvm-nbox/resource/lib/clang/$clang_ver \\
  -pie -fPIC -Oz hello.c -o hello
./hello   # 输出 "llvm-nbox ok"

# 3) 归档：
/data/local/tmp/llvm-nbox/bin/llvm-ar rc libhello.a hello.o
# 4) strip：
/data/local/tmp/llvm-nbox/bin/llvm-strip --strip-all -o hello.stripped hello
\`\`\`

## 模式 2：Android APP（JNI）
\`\`\`
// java/cn/zero/llvmnbox/LlvmNbox.java 已包含在源码树 java/ 目录
// 1) jniLibs：把 lib/arm64-v8a/libllvm-nbox.so 拷贝到 app/src/main/jniLibs/arm64-v8a/
// 2) assets：把 resource/ 整体放到 app/src/main/assets/llvm-nbox-res/
// 3) 启动时解压 assets 到 getFilesDir()/llvm-nbox-res/ 并调用 init()
static { System.loadLibrary("llvm-nbox"); }
...
String resDir = getFilesDir() + "/llvm-nbox-res";
String libDir = getApplicationInfo().nativeLibraryDir;
LlvmNbox.init(libDir, resDir);
LlvmNbox.Result r = LlvmNbox.compile(new String[]{"--version"});
Log.d("NBOX", "code=" + r.code + " out=" + r.outUtf8());  // code=0, out contains "clang version"
\`\`\`

## 显式子命令模式（不用 symlink）
  \`llvm-nbox <子命令名> <参数...>\`
  子命令名支持：\`clang clang++ clang-cl clang-cpp lld ld.lld ld64.lld lld-link wasm-ld llvm-ar llvm-ranlib llvm-dlltool llvm-lib llvm-objcopy llvm-strip llvm-install-name-tool llvm-bitcode-strip\`
  示例：
  \`llvm-nbox clang --version\`
  \`llvm-nbox llvm-ar --version\`
  \`llvm-nbox ld.lld --version\`

## 关键说明
- minSdkVersion：**24**（与 \`--target=aarch64-linux-android24\` 一致；对应 Android 7.0 Nougat）
- ABI：仅 **arm64-v8a**
- \`-resource-dir\` 默认值：本项目 JNI 层缓存的 \`resourceDir\`；CLI 不传则 clang 会尝试按 \`clang\` 可执行文件相对路径找 \`../lib/clang/$clang_ver/\`，若不是默认安装布局请务必显式传该参数
- JNI 的 \`LlvmNbox.init(libDir, resourceDir)\` 为可选，但推荐调用（保证 LD_LIBRARY_PATH 兜底 + -resource-dir 能自动注入）
TOP_README_EOF
    echo "README.md 已写入顶层"

    log_stage_end "copy_resource_stage"
}

# ========== 阶段 10：pack_zip_stage ==========
# 功能：将 OUT_DIR 打包为 zip，输出到 PROJECT 根目录
# 参数：无（--skip-zip 时跳过）
# 返回值：无
pack_zip_stage() {
    if [[ $SKIP_ZIP -eq 1 ]]; then
        echo "STAGE pack_zip_stage: --skip-zip → SKIP"
        return 0
    fi
    log_stage "pack_zip_stage"
    local out_parent
    out_parent="$(dirname "$OUT_DIR")"
    local out_basename
    out_basename="$(basename "$OUT_DIR")"
    local zip_path="${ROOT}/llvm-nbox-android-aarch64.zip"
    cd "$out_parent"
    rm -f "$zip_path"
    echo "zip -9rq $zip_path $out_basename"
    time -p zip -9rq "$zip_path" "$out_basename"
    cd "$ROOT"
    echo "zip 完成: $zip_path ($(stat -c%s "$zip_path") bytes)"
    log_stage_end "pack_zip_stage"
}

# ========== 主入口 ==========
# 功能：按顺序执行 10 个阶段
# 参数：$@ 命令行参数
# 返回值：无
main() {
    parse_args "$@"

    echo "=========================================="
    echo "  llvm-nbox / build.sh (WSL/Linux Android aarch64)"
    echo "=========================================="
    echo "PROJECT_ROOT = $ROOT"
    echo "SKIP_LLVM    = $SKIP_LLVM"
    echo "SKIP_ZIP     = $SKIP_ZIP"

    detect_paths
    apply_patches_stage
    cmake_configure_stage
    ninja_llvm_stage
    rebuild_driver_objs_fpic_stage
    compile_entry_objs_stage
    link_elf_stage
    link_so_stage
    copy_resource_stage
    pack_zip_stage

    echo ""
    echo "=========================================="
    echo "  build.sh 全部完成"
    echo "  TOTAL_MIN=$(((SECONDS-T_START)/60))"
    echo "=========================================="
    exit 0
}

main "$@"
