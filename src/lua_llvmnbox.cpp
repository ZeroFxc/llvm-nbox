// ==========================================================================================
// 功能：lxclua 对 llvm-nbox 的 C 模块绑定实现（require("llvm_nbox") 入口）
//   导出模块方法（同之前版本）：init / set_dirs / compile / link / ar / objcopy / strip /
//                               version / clang_version
//   常量字段：target_triple / abi / min_sdk / llvm_version（模块表直接字段）
//
// **关键区别于前一版：彻底不直接链接任何 lxclua / Lua C API 符号**
//   原因：Android 动态加载器 dlopen 默认 RTLD_LOCAL | RTLD_NOW，宿主进程内的 lua_* /
//         luaL_* 全局符号不会暴露给 RTLD_LOCAL 子 so，会立即报
//           "dlopen failed: cannot locate symbol 'luaL_checkversion_' ..."
//   解决：本文件不 #include lua.h / lauxlib.h / lualib.h，所有对 Lua 状态机的
//         操作均通过 dlsym(RTLD_DEFAULT, 符号名) 拿到宿主 lxclua 进程的函数指针，
//         以函数指针调用；因此本 so 的 .dynsym 里不会再出现任何 lua_* / luaL_*
//         UND 未定义符号，Android 加载器不会在 dlopen 阶段报错。
//         只有当 luaopen_llvm_nbox(L) 真正被 lxclua 的 loadlib 调用时，才会通过
//         dlsym(RTLD_DEFAULT, ...) 从整个进程符号表中搜索（即便 RTLD_LOCAL 子 so
//         不可见宿主全局，dlsym(RTLD_DEFAULT) 仍能查到宿主可执行本身的符号）。
//
// 参数 / 返回值：
//   所有 Lua 包装子命令（compile/link/...）接受 1 个 table 参数，即 argv 数组（不含 ToolName 本身）
//   init/set_dirs 接受 2 个 string 参数（nil 视为空串）
//   luaopen_llvm_nbox(L)：返回 1 个模块表，供 lxclua loadlib 的 require("llvm_nbox") 载入
//
// Lua require 名称注意：
//   必须写 require("llvm_nbox")（**下划线**），不要写 require("llvm-nbox")（减号），
//   因为 Lua C 模块搜索函数名会 luaopen_<module> 拼接，减号不是合法 C 标识符；
//   本实现同时通过 alias 额外导出 luaopen_llvm_minus_nbox 作为兼容兜底（但仍建议用下划线名）。
// ==========================================================================================

#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>
#include <cstdint>
#include <cstdarg>
#include <cstdio>

#include <dlfcn.h>  // dlsym, RTLD_DEFAULT

#include "jni/llvm_nbox_jni.h"  // llvm_nbox::jni::dispatch_tool / set_dirs

namespace {

// ------------------------------------------------------------
//  把 Lua C API 需要用到的函数全部建模成函数指针类型 + 全局缓存结构
//  命名严格对应 Lua 5.4 / 5.5 官方原型（lxclua 5.5 完全兼容）
// ------------------------------------------------------------

// —— 基本类型（用不透明别名即可，内部全是指针）
using lua_State = void;
using lua_Integer = std::int64_t;
using lua_Number  = double;
using lua_CFunction = int (*)(lua_State *L);

struct luaL_Reg {
  const char *name;
  lua_CFunction func;
};

enum LuaBasicType_ : int {
  LUA_TNONE_          = -1,
  LUA_TNIL_           = 0,
  LUA_TBOOLEAN_       = 1,
  LUA_TLIGHTUSERDATA_ = 2,
  LUA_TNUMBER_        = 3,
  LUA_TSTRING_        = 4,
  LUA_TTABLE_         = 5,
  LUA_TFUNCTION_      = 6,
  LUA_TUSERDATA_      = 7,
  LUA_TTHREAD_        = 8,
};
constexpr int LUA_VERSION_NUM_ = 505;
constexpr size_t LUAL_NUMSIZES_ = sizeof(lua_Integer)*16 + sizeof(lua_Number);

// —— 函数指针类型，完全对齐 Lua 原型
using T_lua_len       = void      (*)(lua_State *L, int idx);
using T_lua_geti      = void      (*)(lua_State *L, int idx, lua_Integer i);
using T_lua_type      = int       (*)(lua_State *L, int idx);
using T_lua_tointegerx = lua_Integer (*)(lua_State *L, int idx, int *isnum);
using T_lua_tonumberx = lua_Number  (*)(lua_State *L, int idx, int *isnum);
using T_lua_tolstring = const char* (*)(lua_State *L, int idx, size_t *len);
using T_lua_rawlen    = size_t    (*)(lua_State *L, int idx);
using T_lua_pop       = void      (*)(lua_State *L, int n);
using T_lua_settop    = void      (*)(lua_State *L, int idx);
using T_lua_pushcclosure = void   (*)(lua_State *L, lua_CFunction fn, int n);
using T_lua_pushinteger = void    (*)(lua_State *L, lua_Integer n);
using T_lua_pushnumber  = void    (*)(lua_State *L, lua_Number n);
using T_lua_pushlstring = void    (*)(lua_State *L, const char *s, size_t l);
using T_lua_pushstring  = void    (*)(lua_State *L, const char *s);
using T_lua_pushliteral = void    (*)(lua_State *L, const char *s);
using T_lua_pushboolean = void    (*)(lua_State *L, int b);
using T_lua_createtable = void    (*)(lua_State *L, int narr, int nrec);
using T_lua_setfield    = void    (*)(lua_State *L, int idx, const char *k);
using T_lua_getfield    = void    (*)(lua_State *L, int idx, const char *k);

using T_luaL_checkversion_ = void (*)(lua_State *L, lua_Number ver, size_t sz);
using T_luaL_checktype   = void     (*)(lua_State *L, int arg, int t);
using T_luaL_checkinteger = lua_Integer(*)(lua_State *L, int arg);
using T_luaL_checknumber  = lua_Number (*)(lua_State *L, int arg);
using T_luaL_checklstring = const char* (*)(lua_State *L, int arg, size_t *l);
using T_luaL_optlstring   = const char* (*)(lua_State *L, int arg, const char *d, size_t *l);
using T_luaL_argerror     = int      (*)(lua_State *L, int arg, const char *extramsg);
using T_luaL_error        = int      (*)(lua_State *L, const char *fmt, ...);
using T_luaL_newlib       = void     (*)(lua_State *L, const luaL_Reg *l);
using T_luaL_setfuncs     = void     (*)(lua_State *L, const luaL_Reg *l, int nup);
using T_luaL_ref          = int      (*)(lua_State *L, int t);
using T_luaL_unref        = void     (*)(lua_State *L, int t, int ref);

// —— 函数指针全局缓存（线程不安全，但 JNI / luaopen 均按模型串行调）
struct LuaApiTable {
  bool ok = false;
  std::string errmsg;

  T_lua_len       f_lua_len       = nullptr;
  T_lua_geti      f_lua_geti      = nullptr;
  T_lua_type      f_lua_type      = nullptr;
  T_lua_tointegerx f_lua_tointegerx = nullptr;
  T_lua_tonumberx f_lua_tonumberx = nullptr;
  T_lua_tolstring f_lua_tolstring = nullptr;
  T_lua_rawlen    f_lua_rawlen    = nullptr;
  T_lua_pop       f_lua_pop       = nullptr;
  T_lua_settop    f_lua_settop    = nullptr;
  T_lua_pushcclosure f_lua_pushcclosure = nullptr;
  T_lua_pushinteger f_lua_pushinteger = nullptr;
  T_lua_pushnumber  f_lua_pushnumber = nullptr;
  T_lua_pushlstring f_lua_pushlstring = nullptr;
  T_lua_pushliteral f_lua_pushliteral = nullptr;
  T_lua_pushboolean f_lua_pushboolean = nullptr;
  T_lua_createtable f_lua_createtable = nullptr;
  T_lua_setfield    f_lua_setfield = nullptr;

  T_luaL_checkversion_ f_luaL_checkversion_ = nullptr;
  T_luaL_checktype   f_luaL_checktype   = nullptr;
  T_luaL_checkinteger f_luaL_checkinteger = nullptr;
  T_luaL_checknumber  f_luaL_checknumber  = nullptr;
  T_luaL_checklstring f_luaL_checklstring = nullptr;
  T_luaL_optlstring   f_luaL_optlstring   = nullptr;
  T_luaL_argerror     f_luaL_argerror     = nullptr;
  T_luaL_error        f_luaL_error        = nullptr;
  T_luaL_newlib       f_luaL_newlib       = nullptr;
};

// 辅助：从 RTLD_DEFAULT 取函数指针，失败就累积 errmsg
template<class Fn>
static bool load_sym(const char* name, Fn &out, std::string &err) {
  void *p = dlsym(RTLD_DEFAULT, name);
  if (!p) {
    if (!err.empty()) err += "; ";
    err += "dlsym("; err += name; err += ") FAIL: ";
    const char *e = dlerror();
    err += e ? e : "unknown";
    return false;
  }
  reinterpret_cast<void*&>(out) = p;
  return true;
}

// 一次性加载全部所需 Lua API 函数指针
static bool load_lua_api(lua_State *L, LuaApiTable &api) {
  (void)L;
  api.ok = false;
  api.errmsg.clear();
#define L(sym)    load_sym(#sym, api.f_##sym, api.errmsg)
#define LA(sym)   load_sym(#sym, api.f_##sym, api.errmsg)
  bool ok = true;
  ok &= L(lua_len);
  ok &= L(lua_geti);
  ok &= L(lua_type);
  ok &= L(lua_tointegerx);
  ok &= L(lua_tonumberx);
  ok &= L(lua_tolstring);
  ok &= L(lua_rawlen);
  ok &= L(lua_pop);
  ok &= L(lua_settop);
  ok &= L(lua_pushcclosure);
  ok &= L(lua_pushinteger);
  ok &= L(lua_pushnumber);
  ok &= L(lua_pushlstring);
  ok &= L(lua_pushliteral);
  ok &= L(lua_pushboolean);
  ok &= L(lua_createtable);
  ok &= L(lua_setfield);
  ok &= LA(luaL_checkversion_);
  ok &= LA(luaL_checktype);
  ok &= LA(luaL_checkinteger);
  ok &= LA(luaL_checknumber);
  ok &= LA(luaL_checklstring);
  ok &= LA(luaL_optlstring);
  ok &= LA(luaL_argerror);
  ok &= LA(luaL_error);
  ok &= LA(luaL_newlib);
#undef L
#undef LA
  api.ok = ok;
  return ok;
}

// —— 单例 API 表（首次 luaopen 初始化，后续复用）
static LuaApiTable &g_api() {
  static LuaApiTable s;
  return s;
}

// —— 内联小工具：用函数指针形式调用 Lua/LuaL 函数（省掉每次 api.f_xxx 前缀）
#define L_LEN(idx)                 g_api().f_lua_len(L, (idx))
#define L_GETI(idx,i)              g_api().f_lua_geti(L, (idx), (lua_Integer)(i))
#define L_TYPE(idx)                g_api().f_lua_type(L, (idx))
#define L_TOINTEGERX(idx,p)        g_api().f_lua_tointegerx(L, (idx), (p))
#define L_TOLSTRING(idx,plen)      g_api().f_lua_tolstring(L, (idx), (plen))
#define L_POP(n)                   g_api().f_lua_pop(L, (n))
#define L_SETTOP(idx)              g_api().f_lua_settop(L, (idx))
#define L_PUSHINTEGER(v)           g_api().f_lua_pushinteger(L, (lua_Integer)(v))
#define L_PUSHLSTRING(s,l)         g_api().f_lua_pushlstring(L, (s), (size_t)(l))
#define L_PUSHLITERAL(s)           g_api().f_lua_pushliteral(L, ("" s))
#define L_PUSHBOOLEAN(b)           g_api().f_lua_pushboolean(L, (int)((b) ? 1 : 0))
#define L_CREATETABLE(na, nr)      g_api().f_lua_createtable(L, (int)(na), (int)(nr))
#define L_SETFIELD(idx, k)         g_api().f_lua_setfield(L, (idx), (k))

#define LL_CHECKTYPE(arg,t)        g_api().f_luaL_checktype(L, (int)(arg), (int)(t))
#define LL_CHECKINTEGER(arg)       g_api().f_luaL_checkinteger(L, (int)(arg))
#define LL_OPTLSTRING(arg,d,plen)  g_api().f_luaL_optlstring(L, (int)(arg), (d), (plen))
#define LL_ARGERROR(arg, extra)    return g_api().f_luaL_argerror(L, (int)(arg), (extra))
#define LL_ERROR(fmt, ...)         return g_api().f_luaL_error(L, (fmt), ##__VA_ARGS__)

// ------------------------------------------------------------
// trim（和旧版本一致）
// ------------------------------------------------------------
static std::string &trim(std::string &s) {
  const char *ws = " \t\n\r\f\v";
  s.erase(0, s.find_first_not_of(ws));
  auto pos = s.find_last_not_of(ws);
  if (pos == std::string::npos) s.clear(); else s.erase(pos + 1);
  return s;
}

// ------------------------------------------------------------
// Lua 栈 idx 处字符串数组 table → argv
// ------------------------------------------------------------
static bool tbl_to_argv(lua_State *L, int idx,
                        std::vector<std::string> *storage,
                        std::vector<const char*> *argv) {
  storage->clear(); argv->clear();
  if (L_TYPE(idx) != LUA_TTABLE_) return false;
  L_LEN(idx);
  int isn = 0;
  lua_Integer N = L_TOINTEGERX(-1, &isn);
  L_POP(1);
  if (!isn || N < 0) N = 0;
  storage->reserve((size_t)N);
  argv->reserve((size_t)N);
  for (lua_Integer i = 1; i <= N; ++i) {
    L_GETI(idx, i);
    size_t len = 0;
    const char *s = L_TOLSTRING(-1, &len);
    storage->push_back(s ? std::string(s, len) : std::string());
    L_POP(2); // tolstring pushed string + original value
    argv->push_back(storage->back().c_str());
  }
  return true;
}

// ------------------------------------------------------------
// { code, out, err } 压栈
// ------------------------------------------------------------
static void push_result(lua_State *L, int code, const std::string &out, const std::string &err) {
  L_CREATETABLE(0, 3);
  L_PUSHINTEGER(code);
  L_SETFIELD(-2, "code");
  L_PUSHLSTRING(out.data(), out.size());
  L_SETFIELD(-2, "out");
  L_PUSHLSTRING(err.data(), err.size());
  L_SETFIELD(-2, "err");
}

// ------------------------------------------------------------
// 通用分发模板（用全局模板参数常量字符串，避免一次 heap 分配）
// ------------------------------------------------------------
template<const char ToolNameCStr[]>
static int l_dispatch(lua_State *L) {
  // 功能：把栈第 1 个字符串数组 table 作为 argv，调用 llvm-nbox 对应工具
  // 返回：压入 1 个 {code,out,err} 表
  LL_CHECKTYPE(1, LUA_TTABLE_);
  std::vector<std::string> storage;
  std::vector<const char*> argv;
  if (!tbl_to_argv(L, 1, &storage, &argv)) {
    LL_ARGERROR(1, "expected table of strings");
  }
  std::string out, err;
  const std::string tn(ToolNameCStr);
  int code = llvm_nbox::jni::dispatch_tool(tn, argv, &out, &err);
  push_result(L, code, out, err);
  return 1;
}

constexpr char kTool_clang[]    = "clang";
constexpr char kTool_ldlld[]    = "ld.lld";
constexpr char kTool_ar[]       = "llvm-ar";
constexpr char kTool_objcopy[]  = "llvm-objcopy";
constexpr char kTool_strip[]    = "llvm-strip";

// Lua CFunction 必须 extern "C"（声明在下面）
extern "C" {
  int lxclua_llvmnbox_l_clang(lua_State *L)   { return l_dispatch<kTool_clang>  (L); }
  int lxclua_llvmnbox_l_link (lua_State *L)   { return l_dispatch<kTool_ldlld>  (L); }
  int lxclua_llvmnbox_l_ar   (lua_State *L)   { return l_dispatch<kTool_ar>     (L); }
  int lxclua_llvmnbox_l_objcopy(lua_State *L){ return l_dispatch<kTool_objcopy>(L); }
  int lxclua_llvmnbox_l_strip(lua_State *L)   { return l_dispatch<kTool_strip>  (L); }

  // init / set_dirs
  int lxclua_llvmnbox_l_init(lua_State *L) {
    const char *libDir = LL_OPTLSTRING(1, "", nullptr);
    const char *resDir = LL_OPTLSTRING(2, "", nullptr);
    llvm_nbox::jni::set_dirs(libDir ? libDir : "", resDir ? resDir : "");
    return 0;
  }

  // version() / clang_version()：clang --version stdout trim
  int lxclua_llvmnbox_l_version(lua_State *L) {
    std::vector<const char*> argv = { "--version" };
    std::string out, err;
    int code = llvm_nbox::jni::dispatch_tool("clang", argv, &out, &err);
    if (code != 0) LL_ERROR("clang --version failed code=%d err=%s", code, err.c_str());
    std::string v(out); trim(v);
    L_PUSHLSTRING(v.data(), v.size());
    return 1;
  }
  int lxclua_llvmnbox_l_clang_version(lua_State *L) { return lxclua_llvmnbox_l_version(L); }
}

} // namespace


// ==========================================================================================
//  luaopen_llvm_nbox：lxclua require("llvm_nbox") 的入口（extern "C" + default visibility）
//  同时导出 luaopen_llvm_minus_nbox 别名，兼容 require("llvm-nbox") 这种常见写法失误
// ==========================================================================================

#define LUA_LLVM_NBOX_EXPORT __attribute__((visibility("default"))) extern "C"

LUA_LLVM_NBOX_EXPORT int luaopen_llvm_nbox(lua_State *L) {
  // 1) 一次性加载所有 Lua API 函数指针（通过 dlsym(RTLD_DEFAULT, ...) 搜索宿主 lxclua）
  if (!g_api().ok) {
    if (!load_lua_api(L, g_api())) {
      // 错误处理：用 luaL_error 优先，fallback 到 NULL return 让 lua 抛默认错误
      if (g_api().f_luaL_error) {
        return g_api().f_luaL_error(L, "llvm_nbox: 加载宿主 Lua C API 失败: %s", g_api().errmsg.c_str());
      }
      // 最后兜底：让 loadlib 看到 nil + 错误字符串（手写压栈格式）
      if (g_api().f_lua_pushliteral) {
        g_api().f_lua_pushliteral(L, "llvm_nbox: load_lua_api FAIL");
        return 0;
      }
      return 0;
    }
  }
  auto &api = g_api();

  // 2) luaL_checkversion（以函数指针调用）
  if (api.f_luaL_checkversion_) {
    api.f_luaL_checkversion_(L, (lua_Number)LUA_VERSION_NUM_, LUAL_NUMSIZES_);
  }

  // 3) 构造 luaL_Reg 数组（指向上面 extern "C" 的那些包装函数）
  //    lxclua 5.5 的 luaL_newlib 内部会 push 新表 + 调用 luaL_setfuncs(L, l, 0)
  static const luaL_Reg regs[] = {
    {"init",           lxclua_llvmnbox_l_init},
    {"set_dirs",       lxclua_llvmnbox_l_init},
    {"compile",        lxclua_llvmnbox_l_clang},
    {"link",           lxclua_llvmnbox_l_link},
    {"ar",             lxclua_llvmnbox_l_ar},
    {"objcopy",        lxclua_llvmnbox_l_objcopy},
    {"strip",          lxclua_llvmnbox_l_strip},
    {"version",        lxclua_llvmnbox_l_version},
    {"clang_version",  lxclua_llvmnbox_l_clang_version},
    {NULL, NULL}
  };
  api.f_luaL_newlib(L, regs);

  // 4) 追加 4 个常量字段到模块表（栈顶就是新表，idx=-2 不对是 -1；setfield idx=-2 是"把新表作为被设置者"）
  //    写法顺序：先 push v，再 lua_setfield(table_idx, k) → 注意 newlib 后表在 -1
  api.f_lua_pushliteral(L, "aarch64-linux-android24");
  api.f_lua_setfield(L, -2, "target_triple");
  api.f_lua_pushliteral(L, "arm64-v8a");
  api.f_lua_setfield(L, -2, "abi");
  api.f_lua_pushinteger(L, 24);
  api.f_lua_setfield(L, -2, "min_sdk");
  api.f_lua_pushliteral(L, "22.1.0");
  api.f_lua_setfield(L, -2, "llvm_version");

  return 1;  // 模块表一个返回值
}

// 兼容别名：require("llvm-nbox")(带减号) / require("llvm_nbox")(下划线) 都能找到入口
//   Lua C 模块搜索器默认把 module 名直接拼到 luaopen_ 后面，不会自动替换 "-" → "_"，
//   因此必须用内联汇编强行在 .dynsym 放符号名 luaopen_llvm-nbox（含减号）指向同一实现。
asm(
  ".globl luaopen_llvm_minus_nbox\n"
  ".set   luaopen_llvm_minus_nbox, luaopen_llvm_nbox\n"
  ".globl luaopen_llvm_2dnbox\n"
  ".set   luaopen_llvm_2dnbox, luaopen_llvm_nbox\n"
  // 强制导出带减号的符号名（C 标识符不能写减号，用汇编命名）
  ".globl luaopen_llvm-nbox\n"
  ".set   luaopen_llvm-nbox, luaopen_llvm_nbox\n"
);

