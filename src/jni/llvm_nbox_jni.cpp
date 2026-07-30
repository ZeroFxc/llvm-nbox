// ==========================================================================================
// 功能：llvm-nbox JNI 封装实现（对外导出 6 个 Java_* 方法）
//   1) init(String libDir, String resourceDir)            缓存库/资源目录，set_library_path(libDir)
//   2) compile(String[] args): Result                     调用 clang_main
//   3) link   (String[] args): Result                     调用 lld_main(ld.lld flavor)
//   4) ar     (String[] args): Result                     调用 llvm_ar_main
//   5) objcopy(String[] args): Result                     调用 llvm_objcopy_main
//   6) strip  (String[] args): Result                     调用 llvm_objcopy_main(ToolName=llvm-strip)
// 说明：
//   - stdout/stderr 通过 ::pipe() + dup2 捕获（Android JNI 默认无 TTY），调用前后恢复原 fd
//   - InitLLVM 生命周期：每个 JNI 调用新建局部对象 → 调用结束自动析构（避免多次 InitLLVM 冲突）
//   - 本文件不 #include "src/llvm-nbox.cpp"：所有辅助符号（get_own_dir/set_library_path/find_tool_by_name/clang_main 等）
//     来自同一个最终链接单元（llvm-nbox.cpp.o + driver .o + *.a），链接器会解析
// ==========================================================================================
#include "llvm_nbox_jni.h"
#include <jni.h>

#include <cstring>
#include <cstdlib>
#include <cstdio>
#include <string>
#include <vector>
#include <mutex>
#include <unistd.h>
#include <fcntl.h>

// —— 与 src/llvm-nbox.cpp 中导出的符号保持一致（extern 声明，避免 include 带来的 InitLLVM 重名）
namespace llvm { struct ToolContext { const char *Path; const char *PrependArg; bool NeedsPrependArg; }; }
extern int clang_main(int argc, char **argv, const llvm::ToolContext &);
extern int lld_main  (int argc, char **argv, const llvm::ToolContext &);
extern int llvm_ar_main(int argc, char **argv, const llvm::ToolContext &);
extern int llvm_objcopy_main(int argc, char **argv, const llvm::ToolContext &);
// set_library_path 与 find_tool_by_name 在 llvm-nbox.cpp 中为 static → 故本文件不再调用它们，
// init() 里直接用 setenv/SetEnvironmentVariable 做同等效果；llvm-nbox.cpp.o 的静态 set_library_path
// 仅在 llvm-nbox 主入口 main 里使用，JNI 层无需可见。

// —— 从 llvm/Support/InitLLVM.h 获取完整类型（LLVM 源码已构建头文件可用，编译时 -I include）
#include "llvm/Support/InitLLVM.h"

namespace llvm_nbox { namespace jni {

static std::mutex gMutex;
static std::string gLibDir;
static std::string gResourceDir;

// ------------------------------------------------------------
// 功能：JNI String[] → argc/argv（不透明 const char* 数组）
// 参数：env JNI 环境；javaArgs Java 字符串数组；storage 输出，持有转换后的 std::string 内存
// 返回值：vector<const char*>，大小等于 javaArgs 的 length；元素指向 storage[i].c_str()
// 说明：调用者保证 storage 的生命期 ≥ dispatch_tool 返回
std::vector<const char*> jstrings_to_argv(JNIEnv *env, jobjectArray javaArgs,
                                          std::vector<std::string> *storage) {
  std::vector<const char*> out;
  if (!env || !javaArgs) return out;
  jsize N = env->GetArrayLength(javaArgs);
  storage->reserve(N);
  out.reserve(N);
  for (jsize i = 0; i < N; ++i) {
    jstring s = (jstring)env->GetObjectArrayElement(javaArgs, i);
    if (!s) { storage->push_back(""); out.push_back(storage->back().c_str()); continue; }
    const char *utf = env->GetStringUTFChars(s, nullptr);
    storage->push_back(utf ? utf : "");
    env->ReleaseStringUTFChars(s, utf);
    env->DeleteLocalRef(s);
    out.push_back(storage->back().c_str());
  }
  return out;
}

// ------------------------------------------------------------
// 功能：缓存 libDir/resourceDir，并把 libDir 追加到 LD_LIBRARY_PATH（Android so 搜索路径）
// 参数：libDir 本机 so 所在绝对目录；resourceDir clang 资源根目录（<resource>/lib/clang/22.1.0 的上层）
// 返回值：无
// 说明：Android 纯 JNI 调用场景下用 setenv("LD_LIBRARY_PATH", ...) 追加；不保证后续 dlopen 生效，
//       此处仅作为兜底，业务方 APP 侧通常已经通过 System.loadLibrary 加载成功
void set_dirs(const std::string &libDir, const std::string &resourceDir) {
  std::lock_guard<std::mutex> l(gMutex);
  gLibDir = libDir;
  gResourceDir = resourceDir;
  if (!libDir.empty()) {
    const char *old = getenv("LD_LIBRARY_PATH");
    std::string val;
    if (old && std::strstr(old, libDir.c_str()) == nullptr) {
      val = std::string(old) + ":" + libDir;
      setenv("LD_LIBRARY_PATH", val.c_str(), 1);
    } else if (!old) {
      setenv("LD_LIBRARY_PATH", libDir.c_str(), 1);
    }
  }
}

// ------------------------------------------------------------
// 功能：返回上次缓存的 resourceDir（供 compile() 默认 -resource-dir 注入）
// 参数：无
// 返回值：resourceDir，未初始化返回空串
std::string get_resource_dir() {
  std::lock_guard<std::mutex> l(gMutex);
  return gResourceDir;
}

// ------------------------------------------------------------
// 功能：管道 fd 捕获 + 调度对应 *_main；内部按 Android 可接受方式模拟 argc/argv
// 参数：ToolName 分发子命令；argvNoTool 用户传入的后续 args（不含 ToolName 自身）；
//       capturedStdout 输出捕获的 stdout 字节流；capturedStderr 输出捕获的 stderr 字节流
// 返回值：*_main 的退出码（0 成功）
// 说明：
//   - 构造最终 argv = [0]=ToolName  [1..N]=argvNoTool  [N+1]=nullptr
//   - ToolContext.Path = ToolName（与 symlink 模式一致，让 ar/objcopy 内部分发配到 ranlib/strip）
//   - 每调用开启一次 pipe+dup2，结束后恢复原 stdout/stderr
int dispatch_tool(const std::string &ToolName,
                  const std::vector<const char*> &argvNoTool,
                  std::string *capturedStdout,
                  std::string *capturedStderr) {
  // —— 1. 捕获 stdout/stderr ——
  int pipeOut[2] = {-1, -1}, pipeErr[2] = {-1, -1};
  int savedOut = -1, savedErr = -1;
  auto readAll = [](int fd, std::string *out) {
    char buf[4096]; ssize_t n;
    while ((n = ::read(fd, buf, sizeof(buf))) > 0) out->append(buf, (size_t)n);
  };
  auto scopedPipe = [](int (&p)[2]) -> bool { return ::pipe(p) == 0; };
  if (capturedStdout && !scopedPipe(pipeOut)) { /* skip capture */ capturedStdout = nullptr; }
  if (capturedStderr && !scopedPipe(pipeErr)) { capturedStderr = nullptr; }
  if (capturedStdout) { savedOut = ::dup(STDOUT_FILENO); ::dup2(pipeOut[1], STDOUT_FILENO); ::close(pipeOut[1]); }
  if (capturedStderr) { savedErr = ::dup(STDERR_FILENO); ::dup2(pipeErr[1], STDERR_FILENO); ::close(pipeErr[1]); }

  // —— 2. 组装 argc/argv ——
  std::vector<const char*> argv;
  argv.reserve(1 + argvNoTool.size() + 1);
  argv.push_back(ToolName.c_str());
  for (auto p : argvNoTool) argv.push_back(p ? p : "");
  argv.push_back(nullptr);
  int argc = (int)argvNoTool.size() + 1;   // 不计末尾 nullptr
  char **cargv = const_cast<char**>(argv.data());

  // —— 3. 选择 main 并执行（同 llvm-nbox symlink 模式，argv[0] basename=ToolName）
  int rc = -1;
  llvm::ToolContext ctx{argv[0], nullptr, false};
  {
    // InitLLVM 需要引用 argc 与 const char** argv：
    // 注意：InitLLVM(int& argc, const char**& argv, InstallPipeSignalExitHandler=true)
    const char **cppArgv = const_cast<const char**>(argv.data());
    llvm::InitLLVM X(argc, cppArgv, /*InstallPipeSignalExitHandler*/ false);

    if      (ToolName == "clang"       ) rc = clang_main      (argc, cargv, ctx);
    else if (ToolName == "ld.lld"      ) rc = lld_main        (argc, cargv, ctx);
    else if (ToolName == "llvm-ar"     ) rc = llvm_ar_main    (argc, cargv, ctx);
    else if (ToolName == "llvm-objcopy") rc = llvm_objcopy_main(argc, cargv, ctx);
    else if (ToolName == "llvm-strip"  ) rc = llvm_objcopy_main(argc, cargv, ctx); // objcopy_main 按 ToolName "llvm-strip" 再分发
    else {
      // 未知 ToolName：向 stderr 写错误并返回 2
      fprintf(stderr, "llvm-nbox JNI: unknown tool '%s'\n", ToolName.c_str());
      rc = 2;
    }
    // X 析构发生在此作用域结束
  }
  // —— 4. 恢复 stdout/stderr，读管道 ——
  ::fflush(stdout); ::fflush(stderr);
  if (capturedStdout) { ::dup2(savedOut, STDOUT_FILENO); ::close(savedOut); ::close(pipeOut[1]); readAll(pipeOut[0], capturedStdout); ::close(pipeOut[0]); }
  if (capturedStderr) { ::dup2(savedErr, STDERR_FILENO); ::close(savedErr); ::close(pipeErr[1]); readAll(pipeErr[0], capturedStderr); ::close(pipeErr[0]); }
  return rc;
}

// ------------------------------------------------------------
// 功能：std::string 转 jbyteArray（逐字节拷贝，无编码转换）
// 参数：env JNI；s 源字符串（可空）
// 返回值：jbyteArray，env 本地引用；不抛异常
jbyteArray bytes_to_jbytearray(JNIEnv *env, const std::string &s) {
  jsize n = (jsize)s.size();
  jbyteArray arr = env->NewByteArray(n);
  if (arr && n > 0) {
    env->SetByteArrayRegion(arr, 0, n, reinterpret_cast<const jbyte*>(s.data()));
  }
  return arr;
}

}} // namespace llvm_nbox::jni

using namespace llvm_nbox::jni;

// ============================================================
//  对外 JNI 导出（包名：cn.zero.llvmnbox，类：LlvmNbox）
//  Java 方法签名与这里的名字严格一致：
//    Java_cn_zero_llvmnbox_LlvmNbox_<methodName>
//  Result 对象类：cn/zero/llvmnbox/LlvmNbox$Result（int code; byte[] out; byte[] err）
// ============================================================
static jobject make_result(JNIEnv *env, int code, const std::string &out, const std::string &err) {
  jclass cls = env->FindClass("cn/zero/llvmnbox/LlvmNbox$Result");
  if (!cls) return nullptr;
  jmethodID ctor = env->GetMethodID(cls, "<init>", "(I[B[B)V");
  if (!ctor) return nullptr;
  jbyteArray oa = bytes_to_jbytearray(env, out);
  jbyteArray ea = bytes_to_jbytearray(env, err);
  return env->NewObject(cls, ctor, (jint)code, oa, ea);
}

extern "C" JNIEXPORT void JNICALL
Java_cn_zero_llvmnbox_LlvmNbox_init(JNIEnv *env, jclass /*clazz*/, jstring libDir, jstring resourceDir) {
  // 功能：缓存 so 所在目录与 clang 资源目录，并把 libDir 追加到 LD_LIBRARY_PATH（兜底）
  // 参数：libDir 如 /data/app/.../lib/arm64；resourceDir 如 /sdcard/llvm-nbox/resource
  // 返回值：void
  auto j2s = [&](jstring s) -> std::string {
    if (!s) return "";
    const char *u = env->GetStringUTFChars(s, nullptr);
    std::string r(u ? u : "");
    if (u) env->ReleaseStringUTFChars(s, u);
    return r;
  };
  set_dirs(j2s(libDir), j2s(resourceDir));
}

// 通用包装：传入 ToolName + javaArgs，返回 LlvmNbox.Result
static jobject dispatch0(JNIEnv *env, jobjectArray javaArgs, const std::string &ToolName) {
  std::vector<std::string> storage;
  auto argv = jstrings_to_argv(env, javaArgs, &storage);
  std::string out, err;
  int rc = dispatch_tool(ToolName, argv, &out, &err);
  return make_result(env, rc, out, err);
}

extern "C" JNIEXPORT jobject JNICALL
Java_cn_zero_llvmnbox_LlvmNbox_compile(JNIEnv *env, jclass, jobjectArray args) {
  // 功能：clang 分发；args 等价 "clang <args>..."，无需带 "clang" 前缀
  // 参数：args java String[]，例如 ["--version"]、["-c","foo.c","-o","foo.o"]
  // 返回值：LlvmNbox.Result {code, out, err}
  return dispatch0(env, args, "clang");
}

extern "C" JNIEXPORT jobject JNICALL
Java_cn_zero_llvmnbox_LlvmNbox_link(JNIEnv *env, jclass, jobjectArray args) {
  // 功能：lld(ld.lld) 链接分发；等价 "ld.lld <args>..."
  // 参数：args java String[]，如 ["--version"]、["-pie","-o","app","app.o","-lc"]
  // 返回值：Result
  return dispatch0(env, args, "ld.lld");
}

extern "C" JNIEXPORT jobject JNICALL
Java_cn_zero_llvmnbox_LlvmNbox_ar(JNIEnv *env, jclass, jobjectArray args) {
  // 功能：llvm-ar 分发（内部会再按 argv[0]=llvm-ar 分发到 rc/t/x... 子命令）
  // 参数：args java String[]，如 ["--version"]、["rc","libfoo.a","foo.o","bar.o"]
  // 返回值：Result
  return dispatch0(env, args, "llvm-ar");
}

extern "C" JNIEXPORT jobject JNICALL
Java_cn_zero_llvmnbox_LlvmNbox_objcopy(JNIEnv *env, jclass, jobjectArray args) {
  // 功能：llvm-objcopy 分发；args 即 llvm-objcopy 子命令参数
  return dispatch0(env, args, "llvm-objcopy");
}

extern "C" JNIEXPORT jobject JNICALL
Java_cn_zero_llvmnbox_LlvmNbox_strip(JNIEnv *env, jclass, jobjectArray args) {
  // 功能：llvm-strip 分发（实际由 llvm_objcopy_main 根据 ToolName=llvm-strip 执行 strip 路径）
  return dispatch0(env, args, "llvm-strip");
}
