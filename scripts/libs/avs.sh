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
    CC="$CXX" \
    ./configure \
      --prefix="$PREFIX" \
      ${HOST:+--host="$HOST"} \
      --bit-depth=8 \
      --enable-static --disable-shared \
      --disable-cli --disable-opencl \
      --disable-avs --disable-swscale --disable-lavf \
      --disable-ffms --disable-gpac --disable-lsmash \
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
# ------------------------------------------------------------------------------
build_uavs3d() {
  local dir
  dir="$(fetch uavs3d)"

  log "cmake build uavs3d (10bit)"
  cmake_build "$dir" uavs3d \
    -DCOMPILE_10BIT=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

  require_pc uavs3d
  # FFmpeg 6.0 的 configure 写死要求 "uavs3d >= 1.1.41"，
  # 而上游 version.sh 用 git describe 生成，可能只有 "1.1" 这种串。
  # 版本不达标时 configure 会直接拒绝，但库的功能是够用的。
  pc_ensure_version uavs3d 1.1.41
}

# ------------------------------------------------------------------------------
# uavs3e —— AVS3 编码（10bit）
# 两个必改点：
#   1) cmake_minimum_required(VERSION 2.8) —— CMake 4.x 已移除对 <3.5 的兼容
#   2) src/CMakeLists.txt 的 else() 分支会拉 x86 的 sse/avx2 源文件，
#      ARMv7 上会掉进去（CMAKE_SYSTEM_PROCESSOR=armv7-a 既不匹配 aarch64 也不匹配
#      loongarch64），结果拿 x86 intrinsics 编 ARM，必然失败
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

  # 3) inc/com_api.h 用 #if defined(__linux__) 门控 10bit，
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

  log "cmake build uavs3e (10bit)"
  cmake_build "$dir" uavs3e \
    -DCOMPILE_10BIT=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

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
