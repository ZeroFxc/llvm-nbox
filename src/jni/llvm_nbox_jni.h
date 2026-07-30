// llvm_nbox_jni.h —— llvm-nbox JNI 导出层辅助函数声明
// 作用：把 Java 层 String[] args 转换为 argc/argv 并调用 llvm-nbox 的 dispatcher；
//       提供 stdout/stderr 缓冲捕获与库路径初始化缓存。
// 作者要求：每个函数顶部"功能/参数/返回值"三行中文注释（.cpp 实现里写）。
#pragma once

#include <jni.h>
#include <string>
#include <vector>

namespace llvm_nbox {
namespace jni {

// 把 Java String[] args（长度 argc'）转化为 std::vector<const char*>，尾部 nullptr 对齐
// JavaArgs 来自 env->GetObjectArrayElement；返回 vector 内存由调用方持有直到 *_main 调用结束
std::vector<const char*> jstrings_to_argv(JNIEnv *env, jobjectArray javaArgs,
                                          /* out */ std::vector<std::string> *storage);

// 注册全局缓存：libDir（自身 so 所在目录，用于 set_library_path）、resourceDir（clang -resource-dir 默认）
// 首次调用会缓存到静态变量；重复调用视为覆盖（线程不安全但 Android JNI 通常主线程串行）
void set_dirs(const std::string &libDir, const std::string &resourceDir);

// 返回缓存的 resourceDir（未初始化返回空串）
std::string get_resource_dir();

// 通用分发器：按 ToolName（"clang"、"ld.lld"、"llvm-ar"、"llvm-objcopy"、"llvm-strip"）走 llvm-nbox 查表分发
// 等价命令行：$argv[0]=llvm-nbox  $argv[1]=ToolName  rest=args
// 返回 exit code（0 成功，非 0 失败）
int dispatch_tool(const std::string &ToolName,
                  const std::vector<const char*> &argvNoTool,
                  /* out */ std::string *capturedStdout,
                  /* out */ std::string *capturedStderr);

// 把 std::string 转 jbyteArray（非 NULL，空串返回长度 0 的 byteArray，不抛异常）
jbyteArray bytes_to_jbytearray(JNIEnv *env, const std::string &s);

} // namespace jni
} // namespace llvm_nbox

// 注意：真实 JNIEXPORT 方法声明无需此头文件，C++ 源文件直接 extern "C" 写出（Java_* 命名约定）
// 此头仅提供辅助函数复用接口，供 build task 未来扩展 cpp 时 include。
