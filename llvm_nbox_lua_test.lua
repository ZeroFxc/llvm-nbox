-- =========================================================================================
-- 功能：lxclua 宿主环境下 require("llvm_nbox") 的烟雾测试脚本
--
-- 【模块名说明】只支持 require("llvm_nbox")（下划线），不要用减号写法。
--   Lua C 模块搜索器会把 require("llvm-nbox") 拼成 luaopen_llvm-nbox，
--   但减号不是合法 C / 汇编符号名，无法导出该符号。
--   内部通过 dlsym(RTLD_DEFAULT, ...) 动态获取宿主 lxclua 的 Lua C API 函数指针，
--   libllvm_nbox.so 的 .dynsym 中 lua_* / luaL_* UND 计数为 0。
--
-- 【Android dlopen 修复】所有 lua_* / luaL_* 调用都走 dlsym(RTLD_DEFAULT, xxx) 函数指针，
--   libllvm_nbox.so 动态符号表中不再有 lua_* UND 引用，解决 RTLD_LOCAL 下：
--     dlopen failed: cannot locate symbol "luaL_checkversion_"
--   的问题。
--
-- 【测试项】
--   1) 基本：require 成功 + 模块表字段 4 常量正确
--   2) clang_version/version() 含 clang 关键字 且非空
--   3) compile{"--version"} 退出码 0 + stderr/out 有内容
--   4) ar rc + objcopy --help 无崩溃（code=0/1 均可）
--   5) 目录初始化：init("/tmp/llvmbox-lib", "/tmp/llvmbox-res") 不报错
-- 参数：无（或 arg[1]=libDir arg[2]=resDir 覆盖默认）
-- 返回值：0 全 OK；os.exit 非 0 某项 FAILED
-- =========================================================================================

local llvm_nbox = require("llvm_nbox")
print("[TEST_0] require(\"llvm_nbox\") OK")
assert(type(llvm_nbox) == "table", "require 返回不是 table")
assert(llvm_nbox.abi            == "arm64-v8a",              "abi 常量错")
assert(llvm_nbox.min_sdk        == 24,                       "min_sdk 常量错")
assert(llvm_nbox.llvm_version   == "22.1.0",                 "llvm_version 常量错")
assert(string.find(llvm_nbox.target_triple, "aarch64%-linux%-android") ~= nil, "target_triple 常量错")
print("[TEST_0] 模块 4 常量 OK")

local libDir = arg[1] or (os.getenv("LLVM_NBOX_LIB_DIR") or "")
local resDir = arg[2] or (os.getenv("LLVM_NBOX_RES_DIR") or "")
llvm_nbox.init(libDir, resDir)
llvm_nbox.set_dirs(libDir, resDir)
print("[TEST_INIT] init/set_dirs(" .. tostring(libDir) .. "," .. tostring(resDir) .. ") OK")

do -- version() 快捷方式
  local v = llvm_nbox.version()
  assert(type(v) == "string" and #v > 0, "version() 空")
  assert(string.find(v, "clang") ~= nil, "version() 不含 clang："..v)
  print("[TEST_VERSION] len="..#v)
  print("    head=", v:sub(1,100):gsub("\n","\\n"))
  assert(llvm_nbox.clang_version() == v, "clang_version 别名不相等")
end

local function dump_result(tag, r)
  assert(type(r) == "table", tag .. " 返回不是 table")
  print(("    [RESULT %s] code=%s out_len=%s err_len=%s"):format(tag, tostring(r.code), #r.out, #r.err))
  if #r.out > 0 then print("    out-head=".. r.out:sub(1,120):gsub("\n","\\n")) end
  if #r.err > 0 then print("    err-head=".. r.err:sub(1,120):gsub("\n","\\n")) end
end

do -- compile
  local r = llvm_nbox.compile{"--version"}
  dump_result("compile--version", r)
  assert(r.code == 0, "clang --version 非 0 code=" .. r.code)
  assert(#r.out + #r.err > 0, "clang --version out/err 都空")
end

do -- link（ld.lld --version 通常返回 0）
  local r = llvm_nbox.link{"--version"}
  dump_result("ld.lld--version", r)
  assert(r.code == 0, "ld.lld --version 非 0 code="..r.code)
end

do -- ar 帮助（llvm-ar --help 返回 0）
  local r = llvm_nbox.ar{"--help"}
  dump_result("ar--help", r)
end

do -- objcopy 帮助
  local r = llvm_nbox.objcopy{"--help"}
  dump_result("objcopy--help", r)
end

do -- strip 帮助
  local r = llvm_nbox.strip{"--help"}
  dump_result("strip--help", r)
end

print("\nALL_LLVM_NBOX_TESTS_OK")
os.exit(0)
