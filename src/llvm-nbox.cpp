#include "llvm/ADT/ArrayRef.h"
#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/FileSystem.h"
#include "llvm/ADT/StringRef.h"
#include "llvm/Support/Path.h"
#include "llvm/Support/Process.h"

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <string>

#ifdef _WIN32
#  include <windows.h>
#  include <direct.h>
#  define getcwd _getcwd
#else
#  include <unistd.h>
#endif

namespace llvm {
struct ToolContext {
  const char *Path;
  const char *PrependArg;
  bool NeedsPrependArg;
};
}

extern int clang_main(int argc, char **argv, const llvm::ToolContext &);
extern int lld_main  (int argc, char **argv, const llvm::ToolContext &);

extern int llvm_ar_main     (int argc, char **argv, const llvm::ToolContext &);
extern int llvm_objcopy_main(int argc, char **argv, const llvm::ToolContext &);

#define VLOG(...) do { \
  const char *_v = ::getenv("LLVM_NBOX_VERBOSE"); \
  if (_v && ::strcmp(_v, "1") == 0) { \
    ::fprintf(stderr, "[llvm-nbox] "); \
    ::fprintf(stderr, __VA_ARGS__); \
    ::fprintf(stderr, "\n"); \
  } \
} while (0)

// 功能：获取当前可执行文件所在的目录绝对路径
// 参数：argv0 为 main 函数传入的 argv[0]（程序名或路径）
// 返回：成功返回目录路径字符串（不含末尾分隔符），失败返回空串
static std::string get_own_dir(const char *argv0) {
  char buf[8192];
  std::string exe_path;

#ifdef _WIN32
  DWORD len = ::GetModuleFileNameA(NULL, buf, _countof(buf));
  if (len == 0 || len >= _countof(buf)) {
    VLOG("GetModuleFileNameA failed or buffer too small");
    return std::string();
  }
  buf[len] = '\0';
  exe_path = buf;
#else
  ssize_t len = ::readlink("/proc/self/exe", buf, sizeof(buf) - 1);
  if (len > 0) {
    buf[len] = '\0';
    exe_path = buf;
  } else {
    if (argv0 && argv0[0] == '/') {
      exe_path = argv0;
    } else if (argv0 && ::strchr(argv0, '/') != nullptr) {
      char cwd[4096];
      if (::getcwd(cwd, sizeof(cwd)) != nullptr) {
        exe_path = std::string(cwd) + "/" + argv0;
      }
    } else if (argv0) {
      const char *path_env = ::getenv("PATH");
      if (path_env) {
        std::string path_copy = path_env;
        size_t pos = 0;
        while (pos < path_copy.size()) {
          size_t colon = path_copy.find(':', pos);
          std::string dir;
          if (colon == std::string::npos) {
            dir = path_copy.substr(pos);
            pos = path_copy.size();
          } else {
            dir = path_copy.substr(pos, colon - pos);
            pos = colon + 1;
          }
          if (!dir.empty()) {
            std::string candidate = dir + "/" + argv0;
            if (::access(candidate.c_str(), F_OK) == 0) {
              exe_path = candidate;
              break;
            }
          }
        }
      }
    }
  }
  if (exe_path.empty()) {
    VLOG("cannot resolve own exe path from argv0=%s", argv0 ? argv0 : "(null)");
    return std::string();
  }
#endif

  llvm::StringRef dir_ref = llvm::sys::path::parent_path(exe_path);
  return dir_ref.str();
}

// 功能：将给定目录追加到动态库搜索路径环境变量（PATH 或 LD_LIBRARY_PATH），未包含则追加
// 参数：new_dir 为非空绝对路径目录
// 返回：成功返回 true；仅当底层 SetEnvironmentVariableA/setenv 调用失败时返回 false
static bool set_library_path(const std::string &new_dir) {
  if (new_dir.empty()) {
    return true;
  }

#ifdef _WIN32
  const char *var_name = "PATH";
  const char sep = ';';
#else
  const char *var_name = "LD_LIBRARY_PATH";
  const char sep = ':';
#endif

  const char *old_val = ::getenv(var_name);
  std::string old_str = old_val ? old_val : "";

  std::string needle;
  needle.reserve(new_dir.size() + 3);
  needle.push_back(sep);
  needle.append(new_dir);
  needle.push_back(sep);

  std::string padded;
  padded.reserve(old_str.size() + 2);
  padded.push_back(sep);
  padded.append(old_str);
  padded.push_back(sep);

  if (padded.find(needle) != std::string::npos) {
    VLOG("%s already contains %s, skip", var_name, new_dir.c_str());
    return true;
  }

  std::string new_val;
  if (old_str.empty()) {
    new_val = new_dir;
  } else {
    new_val = old_str;
    new_val.push_back(sep);
    new_val.append(new_dir);
  }

  VLOG("set %s=%s", var_name, new_val.c_str());

#ifdef _WIN32
  BOOL ok = ::SetEnvironmentVariableA(var_name, new_val.c_str());
  return ok != FALSE;
#else
  int rc = ::setenv(var_name, new_val.c_str(), 1);
  return rc == 0;
#endif
}

struct ToolMapEntry {
  const char *ToolName;
  int (*MainFn)(int, char**, const llvm::ToolContext&);
  const char *Argv0Override;
};

static const ToolMapEntry ToolMap[] = {
  {"clang",          clang_main,       nullptr},
  {"clang++",        clang_main,       nullptr},
  {"clang-cl",       clang_main,       nullptr},
  {"clang-cpp",      clang_main,       nullptr},

  {"lld",            lld_main,         nullptr},
  {"ld.lld",         lld_main,         nullptr},
  {"ld64.lld",       lld_main,         nullptr},
  {"lld-link",       lld_main,         nullptr},
  {"wasm-ld",        lld_main,         nullptr},

  {"llvm-ar",        llvm_ar_main,     nullptr},
  {"llvm-ranlib",    llvm_ar_main,     "llvm-ranlib"},
  {"llvm-dlltool",   llvm_ar_main,     "llvm-dlltool"},
  {"llvm-lib",       llvm_ar_main,     "llvm-lib"},

  {"llvm-objcopy",   llvm_objcopy_main, nullptr},
  {"llvm-strip",     llvm_objcopy_main, "llvm-strip"},
  {"llvm-install-name-tool", llvm_objcopy_main, "llvm-install-name-tool"},
  {"llvm-bitcode-strip",   llvm_objcopy_main, "llvm-bitcode-strip"},
};

// 功能：按工具名在 ToolMap 中精确查找对应的工具条目
// 参数：name 为工具名称字符串（symlink basename 或显式子命令名）
// 返回：命中返回对应 ToolMapEntry 指针；未找到返回 nullptr
static const ToolMapEntry *find_tool_by_name(llvm::StringRef name) {
  for (size_t i = 0; i < sizeof(ToolMap) / sizeof(ToolMap[0]); ++i) {
    if (name == ToolMap[i].ToolName) {
      return &ToolMap[i];
    }
  }
  return nullptr;
}

// 功能：打印 llvm-nbox 用法说明，包括 symlink 与显式子命令两种模式，并列出所有受支持子命令
// 参数：argv0 为当前程序名，用于 Usage 行展示
// 返回：无
static void print_usage(const char *argv0) {
  const char *prog = argv0 ? argv0 : "llvm-nbox";
  ::fprintf(stderr, "Usage: %s <subcommand|symlink-name> [args...]\n", prog);
  ::fprintf(stderr, "       ln -s %s clang; ./clang [args...]\n", prog);
  ::fprintf(stderr, "\n");
  ::fprintf(stderr, "Supported subcommands:\n");
  ::fprintf(stderr, "  Clang family:\n");
  ::fprintf(stderr, "    clang  clang++  clang-cl  clang-cpp\n");
  ::fprintf(stderr, "  LLD family:\n");
  ::fprintf(stderr, "    lld  ld.lld  ld64.lld  lld-link  wasm-ld\n");
  ::fprintf(stderr, "  LLVM AR family:\n");
  ::fprintf(stderr, "    llvm-ar  llvm-ranlib  llvm-dlltool  llvm-lib\n");
  ::fprintf(stderr, "  LLVM objcopy family:\n");
  ::fprintf(stderr, "    llvm-objcopy  llvm-strip  llvm-install-name-tool  llvm-bitcode-strip\n");
}

// 功能：llvm-nbox 单二进制分发入口，根据 symlink basename 或显式子命令名查找并调用对应 LLVM 工具 *_main
//   - 区分 symlink/显式两种模式，便于 Android 上无需创建多个真实文件即可调用所有工具
//   - set_library_path 必须在 InitLLVM 之前做：InitLLVM 的信号处理/UTF-8 参数处理可能早于任何用户代码，
//     而自身所在目录加入 LD_LIBRARY_PATH 能保证后续 dlopen 自举（如 libLLVM.so 同目录）时可解析
//   - Argv0Override 作用：llvm_ar_main / llvm_objcopy_main 内部按 ToolName(argv[0]) 二次分发 ranlib/strip 等，
//     故 symlink 名与实际期望的 basename 不一致时（如显式子命令模式）需覆盖 argv[0] 与 ToolContext.Path
// 参数：argc 为命令行参数个数；argv 为命令行参数数组；envp 为环境变量数组（本函数不直接使用）
// 返回：子工具 *_main 的返回值（退出码）
int main(int argc, const char **argv, char *const *envp) {
  (void)envp;
  VLOG("start, argc=%d, argv[0]=%s", argc, argv ? (argv[0] ? argv[0] : "(null)") : "(null)");

  std::string own_dir = get_own_dir(argv ? argv[0] : nullptr);
  if (!own_dir.empty()) {
    VLOG("own_dir=%s", own_dir.c_str());
    if (!set_library_path(own_dir)) {
      VLOG("WARNING: set_library_path failed for %s", own_dir.c_str());
    }
  } else {
    VLOG("WARNING: cannot determine own_dir");
  }

  llvm::StringRef argv0_ref = argv && argv[0] ? argv[0] : "";
  llvm::StringRef basename = llvm::sys::path::filename(argv0_ref);

#ifdef _WIN32
  if (basename.ends_with_insensitive(".exe")) {
    basename = basename.drop_back(4);
  }
#endif

  VLOG("basename=%s", basename.str().c_str());

  const ToolMapEntry *entry = nullptr;
  bool explicit_mode = false;

  if (!(basename == "llvm-nbox")) {
    entry = find_tool_by_name(basename);
    if (entry) {
      VLOG("symlink mode: matched %s", entry->ToolName);
    } else {
      VLOG("basename %s not in ToolMap, fallback to explicit mode", basename.str().c_str());
      explicit_mode = true;
    }
  } else {
    explicit_mode = true;
  }

  if (explicit_mode) {
    if (argc < 2) {
      print_usage(argv ? argv[0] : nullptr);
      return 1;
    }
    llvm::StringRef subcmd = argv[1];
    entry = find_tool_by_name(subcmd);
    if (!entry) {
      print_usage(argv ? argv[0] : nullptr);
      ::fprintf(stderr, "\nUnknown subcommand: %s\n", subcmd.str().c_str());
      return 1;
    }
    VLOG("explicit mode: matched %s", entry->ToolName);
    --argc;
    ++argv;
  }

  if (entry->Argv0Override != nullptr) {
    VLOG("argv[0] override: %s -> %s", argv[0], entry->Argv0Override);
    argv[0] = entry->Argv0Override;
  }

  llvm::ToolContext tool_ctx;
  tool_ctx.Path = argv[0];
  tool_ctx.PrependArg = nullptr;
  tool_ctx.NeedsPrependArg = false;

  VLOG("dispatch to %s with argv[0]=%s, argc=%d", entry->ToolName, argv[0], argc);

  llvm::InitLLVM X(argc, argv);
  return entry->MainFn(argc, const_cast<char**>(argv), tool_ctx);
}
