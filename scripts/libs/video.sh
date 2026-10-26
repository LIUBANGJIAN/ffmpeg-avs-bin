#!/usr/bin/env bash
# ==============================================================================
# 视频编解码依赖
#   x264 / x265 / dav1d / libvpx        —— 默认构建
#   svtav1 / aom / webp                 —— 可选（ENABLE_xxx=1）
#
# 调用方需已 export：CC CXX AR RANLIB STRIP HOST TARGET_OS TARGET_ARCH
# ==============================================================================

# ------------------------------------------------------------------------------
# x264 —— H.264 编码（GPL v2）
# configure 是自研的，不是 autotools，但恰好接受 --prefix/--host/--enable-static，
# 所以能复用 autotools_build。
# ------------------------------------------------------------------------------
build_x264() {
  dep_needed x264 || return 0
  local dir; dir="$(fetch x264)"

  autotools_build "$dir" x264 \
    --enable-pic \
    --enable-strip \
    --disable-cli \
    --disable-opencl \
    --disable-avs \
    --disable-swscale \
    --disable-lavf \
    --disable-ffms \
    --disable-gpac \
    --disable-lsmash

  require_pc x264
}

# ------------------------------------------------------------------------------
# x265 —— HEVC 编码（GPL v2）
#
# 注意位深：x265 一个构建只出**一个**位深（8 或 10），和 davs2 是同一类限制。
#   -DHIGH_BIT_DEPTH=ON  -> 10bit only
#   默认（不加）          -> 8bit main
# gyan 那种「一个库同时支持 8/10/12bit」是 make multi-lib 把三份对象合并，
# 依赖 x265 自己的 multilib.mak，跨平台可用性差，v1 不做。
# 这里选 8bit main：覆盖面最广；10bit HEVC 需要另编一份，README 里已注明。
# ------------------------------------------------------------------------------
build_x265() {
  dep_needed x265 || return 0
  local dir; dir="$(fetch x265)"

  # 源码在 source/ 子目录，顶层没有 CMakeLists
  cmake_build "$dir/source" x265 \
    -DENABLE_SHARED=OFF \
    -DENABLE_CLI=OFF \
    -DENABLE_PIC=ON \
    -DENABLE_ASSEMBLY=ON \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

  require_pc x265
}

# ------------------------------------------------------------------------------
# dav1d —— AV1 解码（BSD，纯汇编优化，比 aom 快得多）
# 只有 meson 构建。
# ------------------------------------------------------------------------------
build_dav1d() {
  dep_needed dav1d || return 0
  local dir; dir="$(fetch dav1d)"

  meson_build "$dir" dav1d \
    -Denable_tools=false \
    -Denable_tests=false \
    -Denable_examples=false

  require_pc dav1d
}

# ------------------------------------------------------------------------------
# libvpx —— VP8/VP9 编解码
# configure 用的是 --target= 而不是 --host=，且不接受 --enable-static 那套，
# 所以必须走 custom_configure。
# ------------------------------------------------------------------------------
vpx_target() {
  case "${TARGET_OS:-linux}/${TARGET_ARCH:-x86_64}" in
    windows/x86_64)        echo "x86_64-win64-gcc" ;;
    linux/x86_64)          echo "x86_64-linux-gcc" ;;
    android/armv7*|android/arm) echo "armv7-android-gcc" ;;
    android/aarch64)       echo "arm64-android-gcc" ;;
    *) die "libvpx: 未支持的 target ${TARGET_OS:-?}/${TARGET_ARCH:-?}" ;;
  esac
}

build_libvpx() {
  dep_needed libvpx || return 0
  local dir; dir="$(fetch libvpx)"

  local args=(
    "--prefix=$PREFIX"
    "--target=$(vpx_target)"
    --disable-shared --enable-static
    --disable-examples --disable-tools --disable-docs --disable-unit-tests
    --enable-vp9-highbitdepth
    --enable-pic
  )
  # Android 的 libvpx 构建脚本靠 --sdk-path 自己找 clang，不吃 CC 环境变量
  if [ "${TARGET_OS:-}" = "android" ]; then
    [ -n "${ANDROID_NDK_HOME:-}" ] || die "libvpx(android): 缺少 ANDROID_NDK_HOME"
    args+=("--sdk-path=$ANDROID_NDK_HOME")
  fi

  custom_configure "$dir" libvpx configure "${args[@]}"
  require_pc vpx
}

# ------------------------------------------------------------------------------
# SVT-AV1 —— AV1 编码（可选）
# ------------------------------------------------------------------------------
build_svtav1() {
  dep_needed svtav1 || return 0
  local dir; dir="$(fetch svtav1)"

  cmake_build "$dir" svtav1 \
    -DBUILD_APPS=OFF \
    -DBUILD_DEC=ON \
    -DBUILD_ENC=ON \
    -DCOMPILE_10BIT=1 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

  require_pc SvtAv1Enc
}

# ------------------------------------------------------------------------------
# aom —— AV1 编解码（可选）
# ------------------------------------------------------------------------------
build_aom() {
  dep_needed aom || return 0
  local dir; dir="$(fetch aom)"

  local extra=()
  case "${TARGET_ARCH:-x86_64}" in
    arm*|aarch64) extra+=(-DAOM_TARGET_CPU=arm64) ;;
    *)            extra+=(-DAOM_TARGET_CPU=x86_64) ;;
  esac

  cmake_build "$dir" aom \
    -DENABLE_CCACHE=0 \
    -DENABLE_TESTS=0 \
    -DENABLE_EXAMPLES=0 \
    -DENABLE_TOOLS=0 \
    -DENABLE_DOCS=0 \
    -DCONFIG_AV1_HIGHBITDEPTH=1 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
    "${extra[@]}"

  require_pc aom
}

# ------------------------------------------------------------------------------
# libwebp —— WebP 编解码（可选）
# ------------------------------------------------------------------------------
build_webp() {
  dep_needed webp || return 0
  local dir; dir="$(fetch webp)"

  autotools_build "$dir" webp \
    --disable-shared --enable-static \
    --disable-everything \
    --enable-libwebpdecoder \
    --enable-libwebpdemux \
    --enable-libwebpmux

  require_pc libwebp
}

# ------------------------------------------------------------------------------
build_video_all() {
  build_x264
  build_x265
  build_dav1d
  build_libvpx
  build_svtav1
  build_aom
  build_webp
}
