// ==========================================================================================
// 功能：lxclua 对 llvm-nbox 的 C 模块绑定实现（require("llvm_nbox") 入口）
//   导出如下模块方法（全部返回 Lua 表 { code:int, out:string, err:string }，除 init/set_dirs 返回 nil）：
//     init(libDir, resourceDir)          同 JNI LlvmNbox.init，缓存目录并追加 LD_LIBRARY_PATH
//     set_dirs(libDir, resourceDir)      init 的别名
//     compile({...})                     clang_main 分发
//     link({...})                        lld_main ld.lld flavor 分发
//     ar({...})                          llvm_ar_main 分发
//     objcopy({...})                     llvm_objcopy_main 分发
//     strip({...})                       llvm_objcopy_main(ToolName="llvm-strip")
//     version()                          返回 clang --version 输出字符串（快捷方式，失败则 luaL_error）
//     clang_version()                    version 的别名
//   常量字段：target_triple / abi / min_sdk / llvm_version（模块表直接字段）
// 参数：
//   所有 Lua 包装子命令（compile/link/...）接受 1 个 table 参数，即 argv 数组（不含 ToolName 本身）
//   init/set_dirs 接受 2 个 string 参数（nil 视为空串）
// 返回值：
//   luaopen_llvm_nbox(L)：返回 1 个模块表，供 lxclua loadlib 的 require("llvm_nbox") 载入
// 设计约束：
//   1) 不 #include 任何 lxclua 子目录头文件：lua.h/lauxlib.h/lualib.h/luaconf.h/lprefix.h
//      由调用方通过 -I<lua>/src/core -I<lua>/src/stdlib 传入，或用户自行在 lxclua 工程里集成
//   2) 与 JNI 层共用 llvm_nbox::jni::dispatch_tool / set_dirs（C++ 命名空间），最终和 JNI 6 个 Java_*
//      导出一起打包进 libllvm-nbox.so 99MB arm64-v8a 共享库中
//   3) 对外符号：luaopen_llvm_nbox（extern "C" + default visibility，ld 必须导出到 .dynsym）
// ==========================================================================================

#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

// —— lxclua C API 头（extern "C" 包裹，防止 C++ name mangling）
extern "C" {
#include "lprefix.h"
#include "lua.h"
#include "lauxlib.h"
#include "lualib.h"
}

// —— 确保 LUAMOD_API 具备 extern "C" + visibility + 返回类型 int
//    lxclua 的 luaconf.h 可能将 LUAMOD_API 定义为裸 extern，需统一覆盖。
#ifdef LUAMOD_API
#undef LUAMOD_API
#endif
#define LUAMOD_API extern "C" __attribute__((visibility("default"))) int

// —— JNI 辅助函数声明（C++ namespace llvm_nbox::jni），最终链接单元来自 llvm_nbox_jni.cpp.o
#include "jni/llvm_nbox_jni.h"

namespace {

// ------------------------------------------------------------
// 功能：trim 首尾空白（in-place 返回相同 std::string&，链式调用友好）
// 参数：s 待修剪字符串
// 返回值：修剪后的 s 引用
std::string &trim(std::string &s) {
  const char *ws = " \t\n\r\f\v";
  s.erase(0, s.find_first_not_of(ws));
  s.erase(s.find_last_not_of(ws)+1);
  return s;
}

// ------------------------------------------------------------
// 功能：把 Lua 栈上索引 idx 处的字符串数组 table 转成 vector<const char*> argv
// 参数：L Lua 状态；idx 栈索引（应为 table，元素为 string/可转 string）
// 参数：storage 输出，保存转换后的 std::string 内存（生命期 ≥ dispatch_tool 返回）
// 参数：argv 输出，指向 storage[i].c_str() 的指针数组
// 返回值：true 成功；false idx 不是 table
bool tbl_to_argv(lua_State *L, int idx,
                 std::vector<std::string> *storage,
                 std::vector<const char*> *argv) {
  storage->clear(); argv->clear();
  if (lua_type(L, idx) != LUA_TTABLE) return false;
  lua_len(L, idx);
  lua_Integer N = luaL_checkinteger(L, -1); lua_pop(L, 1);
  storage->reserve((size_t)N);
  argv->reserve((size_t)N);
  for (lua_Integer i = 1; i <= N; ++i) {
    lua_geti(L, idx, i);
    size_t len = 0;
    const char *s = luaL_tolstring(L, -1, &len);
    storage->push_back(s ? std::string(s, len) : std::string());
    lua_pop(L, 2); // tolstring + table[i]
    argv->push_back(storage->back().c_str());
  }
  return true;
}

// ------------------------------------------------------------
// 功能：向栈顶压入结果表 { code = int, out = string, err = string }
// 参数：L Lua 状态；code exitcode；out stdout 捕获；err stderr 捕获
// 返回值：无（栈 +1）
void push_result(lua_State *L, int code, const std::string &out, const std::string &err) {
  lua_createtable(L, 0, 3);
  lua_pushinteger(L, (lua_Integer)code);
  lua_setfield(L, -2, "code");
  lua_pushlstring(L, out.data(), out.size());
  lua_setfield(L, -2, "out");
  lua_pushlstring(L, err.data(), err.size());
  lua_setfield(L, -2, "err");
}

// ------------------------------------------------------------
// 通用分发模板：以编译期 const char[] ToolNameCStr 作为 llvm-nbox 的分发子命令名，
//   读栈 idx=1 的字符串数组 table，调用 llvm_nbox::jni::dispatch_tool，把结果压成 {code,out,err}。
template<const char ToolNameCStr[]>
int l_dispatch(lua_State *L) {
  // 功能：通用工具分发（compile/link/ar/objcopy/strip 共用）
  // 参数：L Lua 状态；栈顶 idx=1 = {string,string,...} 即 argv 数组（不含 ToolName）
  // 返回值：1（压入 {code,out,err}）
  luaL_checktype(L, 1, LUA_TTABLE);
  std::vector<std::string> storage;
  std::vector<const char*> argv;
  if (!tbl_to_argv(L, 1, &storage, &argv)) {
    return luaL_argerror(L, 1, "expected table of strings");
  }
  std::string out, err;
  const std::string tn(ToolNameCStr);
  int code = llvm_nbox::jni::dispatch_tool(tn, argv, &out, &err);
  push_result(L, code, out, err);
  return 1;
}

// ToolName 常量链接实体（ODR 需要实际 storage；必须是 constexpr char[]，不做字符串字面量临时）
constexpr char kTool_clang[]    = "clang";
constexpr char kTool_ldlld[]    = "ld.lld";
constexpr char kTool_ar[]       = "llvm-ar";
constexpr char kTool_objcopy[]  = "llvm-objcopy";
constexpr char kTool_strip[]    = "llvm-strip";

// —— Lua CFunction（必须 extern "C" linkage，因为 luaL_Reg 里存的是函数指针）
extern "C" {
  static int l_clang   (lua_State *L) { return l_dispatch<kTool_clang>  (L); }
  static int l_link    (lua_State *L) { return l_dispatch<kTool_ldlld>  (L); }
  static int l_ar      (lua_State *L) { return l_dispatch<kTool_ar>     (L); }
  static int l_objcopy (lua_State *L) { return l_dispatch<kTool_objcopy>(L); }
  static int l_strip   (lua_State *L) { return l_dispatch<kTool_strip>  (L); }
}

// ------------------------------------------------------------
// init(libDir, resourceDir) / set_dirs(libDir, resourceDir)
// version() / clang_version() —— 全部放入 extern "C" 块避免 duplicate specifier
extern "C" {
  static int l_init(lua_State *L) {
    const char *libDir = luaL_optstring(L, 1, "");
    const char *resDir = luaL_optstring(L, 2, "");
    llvm_nbox::jni::set_dirs(libDir ? libDir : "", resDir ? resDir : "");
    return 0;
  }

  static int l_version(lua_State *L) {
    std::vector<const char*> argv = { "--version" };
    std::string out, err;
    int code = llvm_nbox::jni::dispatch_tool("clang", argv, &out, &err);
    if (code != 0) {
      return luaL_error(L, "clang --version failed code=%d err=%s", code, err.c_str());
    }
    std::string v(out); trim(v);
    lua_pushlstring(L, v.data(), v.size());
    return 1;
  }
  static int l_clang_version(lua_State *L) { return l_version(L); }
}

} // namespace

// ------------------------------------------------------------
// 模块函数注册表（luaL_Reg sentinel {NULL,NULL} 结束）
extern "C" {
  static const luaL_Reg l_llvmnbox_funcs[] = {
    {"init",           l_init},
    {"set_dirs",       l_init},
    {"compile",        l_clang},
    {"link",           l_link},
    {"ar",             l_ar},
    {"objcopy",        l_objcopy},
    {"strip",          l_strip},
    {"version",        l_version},
    {"clang_version",  l_clang_version},
    {NULL, NULL}
  };
}

// ==========================================================================================
// 功能：lxclua loadlib 通过 dlopen(path_to_so) + dlsym("luaopen_llvm_nbox") 调用的入口
//       必须 extern "C" + default visibility，否则 .dynsym 不会导出，dlsym 返回 NULL
// 参数：L Lua 状态
// 返回值：压入 1 个模块表（返回值数 = 1）
// ==========================================================================================
LUAMOD_API luaopen_llvm_nbox(lua_State *L) {
  luaL_checkversion(L);
  luaL_newlib(L, l_llvmnbox_funcs);

  // 常量字段直接写到模块表，Lua 侧调试方便：
  lua_pushliteral(L, "aarch64-linux-android24");
  lua_setfield(L, -2, "target_triple");
  lua_pushliteral(L, "arm64-v8a");
  lua_setfield(L, -2, "abi");
  lua_pushinteger(L, 24);
  lua_setfield(L, -2, "min_sdk");
  lua_pushliteral(L, "22.1.0");
  lua_setfield(L, -2, "llvm_version");
  return 1;
}
