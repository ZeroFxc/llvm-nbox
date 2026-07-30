# llvm-nbox

基于 LLVM 22.1.0 + Android NDK r29 的单二进制 + JNI 共享库工具集。将 LLVM 工具链（clang、lld、llvm-ar、llvm-objcopy、llvm-strip 等）打包为单二进制 `llvm-nbox`，通过 argv[0] 或显式子命令调度，同时提供 JNI 接口供 Java/Android 调用。

## 目录结构

```
llvm-nbox/
├── patches/              # LLVM 源码补丁（按文件名顺序应用）
├── scripts/              # 辅助脚本（补丁应用等）
│   ├── apply-patches.sh
│   └── apply-patches.ps1
├── src/                  # 项目源码
│   └── jni/              # JNI 接口实现
├── include/              # 对外头文件
├── resource/             # 资源文件
├── .github/              # GitHub Actions 等 CI 配置
│   └── workflows/
├── build.sh              # Bash 构建入口
├── build.ps1             # PowerShell 构建入口
└── README.md
```

## 子命令用法

`llvm-nbox` 可通过 **symlink 方式**（以工具名作为文件名）或 **显式子命令** 方式调用各 LLVM 工具：

```bash
# 1. symlink clang 方式：将 clang 链接到 llvm-nbox，直接调用 clang
ln -s llvm-nbox clang
./clang --target=aarch64-linux-android29 -c test.c -o test.o

# 2. 显式 llvm-nbox clang 方式
./llvm-nbox clang --target=aarch64-linux-android29 -c test.c -o test.o

# 3. 显式 llvm-nbox lld 方式（链接 ELF 共享库）
./llvm-nbox lld -flavor gnu --sysroot=$NDK/sysroot -shared test.o -o libtest.so

# 4. 显式 llvm-nbox llvm-ar 方式（归档静态库）
./llvm-nbox llvm-ar rcs libtest.a test1.o test2.o

# 5. 显式 llvm-nbox llvm-objcopy 方式（复制/转换目标文件）
./llvm-nbox llvm-objcopy --strip-all test.o stripped.o

# 6. 显式 llvm-nbox llvm-strip 方式（剥离符号）
./llvm-nbox llvm-strip libtest.so
```

## 构建

### Bash（WSL / Linux / macOS）

```bash
./build.sh --ndk /path/to/android-ndk-r29
```

可选参数：

| 参数 | 说明 |
|------|------|
| `--ndk <path>` | Android NDK 路径 |
| `--llvm-src <path>` | LLVM 源码目录（默认 `e:/llvmbox/llvm-project-llvmorg-22.1.0`） |
| `--build-dir <path>` | 构建目录（默认 `./build`） |
| `--out-dir <path>` | 输出目录（默认 `./out`） |
| `--jobs <num>` | 并行编译数 |
| `--skip-llvm` | 跳过 LLVM 构建 |
| `--no-ccache` | 禁用 ccache |
| `-h, --help` | 显示帮助 |

### PowerShell（Windows）

```powershell
.\build.ps1 -Ndk D:\path\to\android-ndk-r29
```

可选参数：

| 参数 | 说明 |
|------|------|
| `-Ndk <path>` | Android NDK 路径 |
| `-LlvmSrc <path>` | LLVM 源码目录 |
| `-BuildDir <path>` | 构建目录 |
| `-OutDir <path>` | 输出目录 |
| `-Jobs <num>` | 并行编译数 |
| `-SkipLlvm` | 跳过 LLVM 构建 |
| `-NoCcache` | 禁用 ccache |
| `-Help, -h` | 显示帮助 |

环境依赖（构建前安装）：

- **WSL / Linux**: `apt install cmake ninja-build ccache build-essential`
- **Windows**: `scoop install cmake ninja ccache`

## JNI 最小示例

以下为 Java 侧声明的 `LlvmNbox` 类，包含 5 个 native 方法与库加载：

```java
package com.llvmbox;

public class LlvmNbox {

    static {
        System.loadLibrary("llvmbox");
    }

    /**
     * 初始化 llvm-nbox 运行时环境
     * @return 0=成功，非0=失败
     */
    public static native int init();

    /**
     * 调用 clang 编译指定源文件
     * @param args clang 参数数组（等效于命令行 argv）
     * @return clang 进程退出码
     */
    public static native int clang(String[] args);

    /**
     * 调用 lld 链接指定目标文件
     * @param args lld 参数数组（等效于命令行 argv）
     * @return lld 进程退出码
     */
    public static native int lld(String[] args);

    /**
     * 调用 llvm-ar 进行归档操作
     * @param args llvm-ar 参数数组（等效于命令行 argv）
     * @return llvm-ar 进程退出码
     */
    public static native int llvmAr(String[] args);

    /**
     * 调用通用 LLVM 工具（根据子命令分发到 llvm-objcopy / llvm-strip 等）
     * @param toolName 工具名称，如 "llvm-objcopy"、"llvm-strip"
     * @param args 工具参数数组
     * @return 进程退出码
     */
    public static native int runTool(String toolName, String[] args);
}
```
