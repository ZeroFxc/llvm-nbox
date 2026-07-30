package cn.zero.llvmnbox;

/**
 * llvm-nbox JNI 前端。
 * 用法：
 *   static { System.loadLibrary("llvm-nbox"); }
 *   LlvmNbox.init("/data/app/.../lib/arm64-v8a", "/sdcard/llvm-nbox/resource");
 *   Result r = LlvmNbox.compile(new String[]{"--version"});
 *   if (r.code != 0) { ... }
 */
public final class LlvmNbox {
    static {
        System.loadLibrary("llvm-nbox");
    }

    public static class Result {
        public final int code;
        public final byte[] out;
        public final byte[] err;
        public Result(int code, byte[] out, byte[] err) {
            this.code = code;
            this.out = out;
            this.err = err;
        }
        public String outUtf8() { return out == null ? "" : new String(out); }
        public String errUtf8() { return err == null ? "" : new String(err); }
    }

    /**
     * 初始化（可选但推荐）。
     * @param libDir 本 libllvm-nbox.so 所在的绝对目录。
     * @param resourceDir 资源根目录（其下应有 lib/clang/22.1.0/include/...）。
     */
    public static native void init(String libDir, String resourceDir);

    /** 等价 clang <args> */
    public static native Result compile(String[] args);
    /** 等价 ld.lld <args> */
    public static native Result link   (String[] args);
    /** 等价 llvm-ar <args> */
    public static native Result ar     (String[] args);
    /** 等价 llvm-objcopy <args> */
    public static native Result objcopy(String[] args);
    /** 等价 llvm-strip <args> */
    public static native Result strip  (String[] args);
}
