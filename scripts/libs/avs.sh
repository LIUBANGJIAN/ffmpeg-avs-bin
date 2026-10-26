#!/usr/bin/env bash
# ==============================================================================
# AVS 四件套
#   davs2  —— AVS2 解码（10bit，xatabhk fork）
#   xavs2  —— AVS2 编码（上游仅 8bit，这是硬限制）
#   uavs3d —— AVS3 解码（10bit）
#   uavs3e —— AVS3 编码（10bit）★ 需要配合 scripts/patch-ffmpeg.sh 才有 FFmpeg 接口
#
# 调用方需已 export：
#   CC CXX AR RANLIB STRIP HOST TARGET_ARCH IS_ANDROID CMAKE_TOOLCHAIN
# ==============================================================================

# ------------------------------------------------------------------------------
# davs2 —— AVS2 解码
# 四个坑（全部已踩过并核实）：
#   1) 源码是 C++（.cc），configure 默认 CC=g++；交叉编译时必须把 CC 指到 C++ 编译器
#   2) configure 把 --bit-depth=10 写死成 exit 1 —— fork 改了源码却没改构建脚本
#   3) 没有 install 目标，只有 install-lib-static / install-lib-dev
#   4) 静态链进 FFmpeg 需要 C++ 运行库（由平台脚本 --extra-libs 补）
# ------------------------------------------------------------------------------
build_davs2() {
  local dir bdir logf
  dir="$(fetch davs2)"
  bdir="$dir/build/linux"
  logf="$LOGS/davs2.log"

  # 只保留对 9bit 的拒绝，放开 10bit
  edit_exact "$bdir/configure" \
    'elif [[ "$bit_depth" = "9" || "$bit_depth" = "10" ]]; then' \
    'elif [[ "$bit_depth" = "9" ]]; then'

  # 10bit 的 SIMD 例程里用了未限定的 min/max，而文件只 include 了 intrinsics
  # 头、没有 <algorithm>。MSVC 下靠 windows.h 带的 min/max 宏能过，MinGW 的
  # GCC 直接报 "'min' was not declared in this scope; did you mean 'sin'?"。
  # 换成三元表达式：不依赖头文件，也不受命名空间影响。
  edit_exact "$dir/source/common/vec/intrinsic_intra-pred.cc" \
    '    int ishift = min(ishift_x, ishift_y);' \
    '    int ishift = (ishift_x < ishift_y) ? ishift_x : ishift_y;'
  edit_exact "$dir/source/common/vec/intrinsic_pixel_avx.cc" \
    '    start = max(start, 0);' \
    '    start = (start > 0) ? start : 0;' 4

  local arch_opts=()
  case "${TARGET_ARCH:-x86_64}" in
    arm*|aarch64)
      # davs2 仓库里没有任何 ARM 汇编（source/common 下只有 x86 与 vec 两个目录），
      # 用 --disable-asm 绕开 configure 里的 gas-preprocessor 分支，走纯 C。
      # 代价：没有 SIMD 加速；收益：不会因为汇编而编不过。
      arch_opts+=(--disable-asm)
      ;;
  esac
  if [ "${IS_ANDROID:-0}" = "1" ]; then
    arch_opts+=(--enable-pic)
  fi

  log "configure davs2 (10bit, arch=${TARGET_ARCH:-x86_64})"
  (
    cd "$bdir"
    # davs2 是 C++ 源码：强制用 C++ 编译器，否则 gcc 会把 .cc 当 C 编
    CC="$CXX" \
    ./configure \
      --prefix="$PREFIX" \
      ${HOST:+--host="$HOST"} \
      --bit-depth=10 \
      --enable-static --disable-shared \
      --disable-cli --disable-opencl \
      "${arch_opts[@]}"
  ) > "$logf" 2>&1 || { dump_log "$logf"; die "davs2: configure 失败"; }

  log "build/install davs2"
  make -C "$bdir" -j"$JOBS" install-lib-static install-lib-dev >> "$logf" 2>&1 \
    || { dump_log "$logf"; die "davs2: 构建或安装失败"; }

  require_pc davs2
  # FFmpeg 6.1 的 configure 写死 "davs2 >= 1.6.0"，而 fork 自己生成的 .pc
  # 版本串未必达得到（它长期没更新 version 宏）。库能力是够的，只改声明。
  pc_ensure_version davs2 1.6.0
}

# ------------------------------------------------------------------------------
# xavs2 —— AVS2 编码（只能 8bit）
# ------------------------------------------------------------------------------
build_xavs2() {
  local dir bdir logf
  dir="$(fetch xavs2)"
  bdir="$dir/build/linux"
  logf="$LOGS/xavs2.log"

  # GCC 14 起 -Wincompatible-pointer-types 从「警告」升级成「错误」，
  # xavs2 1.4（2018 年的代码）在这个函数上踩中：
  #   static void *encoder_aec_encode_one_frame(xavs2_t *h)
  #   被当成 void *(*)(void *) 传给 xavs2_threadpool_run
  # 两个指针只是类型标签不同、二进制布局完全一致，本可以安全转换；
  # 但 xavs2 的源码是 CRLF 行尾，多行锚点会匹配失败（edit_exact 用 \n 比对），
  # 所以不改造源码，直接在 configure 里关掉这条诊断 —— 效果等价，且不动上游文件。
  # -Wno-error= 是第二道保险：万一某些 GCC 把它当 permerror，这条能降回警告。
  local gcc14_opts='-Wno-incompatible-pointer-types -Wno-error=incompatible-pointer-types'

  local arch_opts=()
  case "${TARGET_ARCH:-x86_64}" in
    arm*|aarch64)
      arch_opts+=(--disable-asm)
      ;;
  esac
  if [ "${IS_ANDROID:-0}" = "1" ]; then
    arch_opts+=(--enable-pic)
  fi

  log "configure xavs2 (8bit)"
  (
    cd "$bdir"
    # 注意：这里**不能**像 davs2 那样把 CC 强制成 CXX。
    # xavs2 是纯 C 项目（source 下 70 个 .c、0 个 .cc）；用 g++ 编 .c 会按 C++
    # 规则做 narrowing 检查，cpu.c 里的 `static const char cache32_ids[] = {0x82,...}`
    # 直接报 "narrowing conversion of '130' from 'int' to 'char'"。
    # CC 由平台脚本导出（gcc / NDK clang），configure 会自己用。
    ./configure \
      --prefix="$PREFIX" \
      ${HOST:+--host="$HOST"} \
      --bit-depth=8 \
      --enable-static --disable-shared \
      --disable-cli --disable-opencl \
      --disable-avs --disable-swscale --disable-lavf \
      --disable-ffms --disable-gpac --disable-lsmash \
      --extra-cflags="$gcc14_opts" \
      "${arch_opts[@]}"
  ) > "$logf" 2>&1 || { dump_log "$logf"; die "xavs2: configure 失败"; }

  log "build/install xavs2"
  make -C "$bdir" -j"$JOBS" install-lib-static install-lib-dev >> "$logf" 2>&1 \
    || { dump_log "$logf"; die "xavs2: 构建或安装失败"; }

  require_pc xavs2
}

# ------------------------------------------------------------------------------
# uavs3d —— AVS3 解码（10bit）
# 自带 CMakeLists（cmake_minimum_required 3.1，CMake 4.x 需要 CMAKE_POLICY_VERSION_MINIMUM）
#
# 三个必改点（都是「上游没做」而不是「上游做错了」）：
#   1) 位深是**编译期**的：com_def.h 的 BIT_DEPTH 决定 pel 是 u8 还是 s16，
#      README 明写「要解 10bit 就把 BIT_DEPTH 改成 10」。
#      （原来传的 -DCOMPILE_10BIT=ON 是个无人引用的变量，cmake 只会警告 unused，
#        对产物零影响 —— 也就是说之前编出来的其实是 8bit-only。）
#      10bit 构建是超集：bit_depth_internal 由码流决定（8 或 10），
#      C / SSE / AVX2 的例程都吃运行期 bit_depth 参数，所以一个二进制 8/10bit 都能解。
#   2) source/CMakeLists.txt 把 x86 的 sse/avx2 目录**无条件**加进目标，
#      ARM 上就会拿 x86 intrinsics 去编 ARM（NDK clang 直接 20 个 error）。
#   3) 但 ARM 的 NEON 汇编不能拿来做「通用 10bit 解码」：def_arm64.S / def_armv7.S
#      里写死 `#define COMPILE_10BIT 0`，8bit 分支用 .16b/u8 指令、另一分支用 .8h/s16，
#      是编译期二选一 —— 一个二进制不可能同时对 8bit 和 10bit 正确。
#      所以 ARM 上关掉 NEON 汇编、走纯 C（C 实现是运行期位深的），
#      代价是 ARM 解码慢 2~4 倍；x86 上 SSE/AVX2 完全不受影响。
# ------------------------------------------------------------------------------
build_uavs3d() {
  local dir
  dir="$(fetch uavs3d)"

  edit_exact "$dir/source/decore/com_def.h" \
    '#define BIT_DEPTH 8' \
    '#define BIT_DEPTH 10'

  edit_exact "$dir/source/CMakeLists.txt" \
'aux_source_directory(./decore/sse DIR_X86_SRC)
aux_source_directory(./decore/avx2 DIR_X86_256_SRC)' \
'if(CMAKE_SYSTEM_PROCESSOR MATCHES "x86_64|AMD64|amd64|i.86")
  aux_source_directory(./decore/sse DIR_X86_SRC)
  aux_source_directory(./decore/avx2 DIR_X86_256_SRC)
else()
  message("-- ${CMAKE_SYSTEM_PROCESSOR}: 不启用 x86 SIMD（ARM 走纯 C，原因见 scripts/libs/avs.sh）")
endif()'

  # 空列表传给 set_source_files_properties 会被 CMake 当成参数个数错误，
  # 所以再包一层存在性判断（ARM 上这两个变量是空的）。
  edit_exact "$dir/source/CMakeLists.txt" \
'set_source_files_properties(${DIR_X86_SRC} PROPERTIES COMPILE_FLAGS "${CMAKE_C_FLAGS} -fPIC -std=c99 -O3 -msse4.2")
set_source_files_properties(${DIR_X86_256_SRC} PROPERTIES COMPILE_FLAGS "${CMAKE_C_FLAGS} -fPIC -std=c99 -O3 -mavx2")' \
'if(DIR_X86_SRC)
  set_source_files_properties(${DIR_X86_SRC} PROPERTIES COMPILE_FLAGS "${CMAKE_C_FLAGS} -fPIC -std=c99 -O3 -msse4.2")
endif()
if(DIR_X86_256_SRC)
  set_source_files_properties(${DIR_X86_256_SRC} PROPERTIES COMPILE_FLAGS "${CMAKE_C_FLAGS} -fPIC -std=c99 -O3 -mavx2")
endif()'

  # com_util.h 会按 __ANDROID__+__aarch64__ 自动打开 ENABLE_FUNCTION_ARM64/ARM32，
  # 而这两个宏指向的实现在 decore/arm64|armv7（我们不再编译）→ 链接期 undefined。
  # 注意 uavs3d.c 用的是 `#if defined(...)`，所以「定义成 0」没用，必须整条不定义。
  edit_exact "$dir/source/decore/com_util.h" \
'#define ENABLE_FUNCTION_C 1
#define ENABLE_FUNCTION_ARM64 1' \
'#define ENABLE_FUNCTION_C 1'
  edit_exact "$dir/source/decore/com_util.h" \
'#define ENABLE_FUNCTION_C 1
#define ENABLE_FUNCTION_ARM32 1' \
'#define ENABLE_FUNCTION_C 1'

  log "cmake build uavs3d (10bit)"
  # 只编库目标：test/uavs3dec 会 target_link_libraries(… pthread)，
  # 而 Android 的 bionic 把 pthread 并进了 libc，没有独立 -lpthread，
  # 链接期直接 "ld: error: unable to find library -lpthread"。
  # 我们只要 libuavs3d.a，命令行程序一次也用不到。
  local CMAKE_BUILD_TARGET=uavs3d
  cmake_build "$dir" uavs3d \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

  require_pc uavs3d
  # FFmpeg 6.0 的 configure 写死要求 "uavs3d >= 1.1.41"，
  # 而上游 version.sh 用 git describe 生成，可能只有 "1.1" 这种串。
  # 版本不达标时 configure 会直接拒绝，但库的功能是够用的。
  pc_ensure_version uavs3d 1.1.41
}

# ------------------------------------------------------------------------------
# uavs3e —— AVS3 编码（8bit，原因见函数内注释）
# 需要改的地方：
#   1) cmake_minimum_required(VERSION 2.8) —— CMake 4.x 已移除对 <3.5 的兼容
#   2) src/CMakeLists.txt 的 else() 分支会拉 x86 的 sse/avx2 源文件，
#      ARMv7 上会掉进去（CMAKE_SYSTEM_PROCESSOR=armv7-a 既不匹配 aarch64 也不匹配
#      loongarch64），结果拿 x86 intrinsics 编 ARM，必然失败
#   3) 同一个文件里 set_source_files_properties 的空列表地雷
#   4) inc/com_api.h 在非 Linux 分支把 COMPILE_10BIT 强行归零（MinGW 上踩）
#   5) test/utest.c 缺 <unistd.h> + 用 lseek64（musl 上没有这个符号）
# ------------------------------------------------------------------------------
build_uavs3e() {
  local dir
  dir="$(fetch uavs3e)"

  edit_exact "$dir/CMakeLists.txt" \
    'cmake_minimum_required(VERSION 2.8)' \
    'cmake_minimum_required(VERSION 3.5)'

  edit_exact "$dir/src/CMakeLists.txt" \
'else()
  aux_source_directory(./sse DIR_X86_SRC)' \
'elseif("${CMAKE_SYSTEM_PROCESSOR}" MATCHES "arm")
  message("-- arm: 仅 C 实现，不使用 x86 SIMD")
else()
  aux_source_directory(./sse DIR_X86_SRC)'

  # 3) src/CMakeLists.txt 还有一处同样的地雷：`set_source_files_properties(${DIR_X86_SRC} ...)`
  #    在上面那条分支把 x86 目录排除后，这两个变量是**空的**，
  #    而 set_source_files_properties 拿到空文件列表会直接报
  #    "called with incorrect number of arguments" → ARM 上 configure 就挂了。
  edit_exact "$dir/src/CMakeLists.txt" \
'set_source_files_properties(${DIR_X86_SRC} PROPERTIES COMPILE_FLAGS "${CMAKE_C_FLAGS} -fPIC -std=c99 -O3 -msse4.2")
set_source_files_properties(${DIR_X86_256_SRC} PROPERTIES COMPILE_FLAGS "${CMAKE_C_FLAGS} -fPIC -std=c99 -O3 -mavx2")' \
'if(DIR_X86_SRC)
  set_source_files_properties(${DIR_X86_SRC} PROPERTIES COMPILE_FLAGS "${CMAKE_C_FLAGS} -fPIC -std=c99 -O3 -msse4.2")
endif()
if(DIR_X86_256_SRC)
  set_source_files_properties(${DIR_X86_256_SRC} PROPERTIES COMPILE_FLAGS "${CMAKE_C_FLAGS} -fPIC -std=c99 -O3 -mavx2")
endif()'

  # 4) inc/com_api.h 用 #if defined(__linux__) 门控 10bit，
  #    非 Linux 分支里有一句无条件的 #define COMPILE_10BIT 0，
  #    会把 -DCOMPILE_10BIT=1 直接抹掉 —— MinGW(Windows) 上因此永远只有 8bit。
  #    改成 #ifndef 保护后，命令行定义优先。
  edit_exact "$dir/inc/com_api.h" \
'#else
#define COMPILE_10BIT 0' \
'#else
#ifndef COMPILE_10BIT
#define COMPILE_10BIT 0
#endif'

  # 5) test/utest.c 的平台分支有两个坑，一起补：
  #      #if defined(__APPLE__) || defined(__loongarch__)
  #      #include <unistd.h>          <- 只有 Apple/loongarch 包含
  #      #define _lseeki64 lseek
  #      #else
  #      #define _lseeki64 lseek64     <- Linux/Android 走这条，但没有 unistd.h
  #    结果：Linux 下 read/write/close/lseek64 全是隐式声明；glibc 恰好有 lseek64 符号
  #    所以能链上，musl（Alpine 全静态）没有 → "undefined reference to `lseek64'"。
  #    隐式声明还有个隐患：被当成 int 返回，大文件下偏移会被截断。
  #    统一改成「无条件 include <unistd.h> + 用 POSIX 的 lseek」，
  #    配合下面 -D_FILE_OFFSET_BITS=64 让 32 位（armv7）上也是 64 位偏移。
  edit_exact "$dir/test/utest.c" \
'#if defined(__APPLE__) || defined(__loongarch__)
#include <unistd.h>
#define _lseeki64 lseek
#else
#define _lseeki64 lseek64
#endif' \
'#include <unistd.h>
#define _lseeki64 lseek'

  log "cmake build uavs3e (8bit)"
  # 位深显式锁 8bit，不是偷懒，是因为「10bit 编码」这条路现在走不通：
  #   - uavs3e 的开关是顶层 CMakeLists 里的 add_definitions(-DCOMPILE_10BIT=1)，
  #     而它写在 add_subdirectory(./src) **之后**；CMake 的 add_definitions
  #     只对「之后创建的目标」生效，于是库目标永远拿不到这个宏 —— 也就是说
  #     传 -DCOMPILE_10BIT=ON 的真实效果是：库还是 8bit，只有 test/uavs3enc
  #     这个命令行被编成 10bit（pel 从 u8 变 s16），两者 ABI 直接打架。
  #   - 想真正打开，得同时把 FFmpeg 侧的 patches/libuavs3e.c 改成
  #     bit_depth_internal=10 并做 8→10 的样本搬移，是另一个独立改动。
  # 所以这里显式 OFF：C 库、ARM 汇编、CLI 三者一致都是 8bit。
  # 同样只编库目标，跳过 uavs3enc 命令行（原因见 build_uavs3d）
  local CMAKE_BUILD_TARGET=uavs3e
  cmake_build "$dir" uavs3e \
    -DCOMPILE_10BIT=OFF \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    -DCMAKE_C_FLAGS=-D_FILE_OFFSET_BITS=64

  require_pc uavs3e
}

# ------------------------------------------------------------------------------
# 一次性构建全部 AVS 库
# ------------------------------------------------------------------------------
build_avs_all() {
  build_davs2
  build_xavs2
  build_uavs3d
  build_uavs3e
}
