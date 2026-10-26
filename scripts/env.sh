#!/usr/bin/env bash
# ==============================================================================
# 版本锁 —— 所有外部依赖的版本集中在这里，升级只改这一个文件
#
# DEPS 每行格式：  name|kind|url_or_repo|ref
#   kind = tar | git
#   ref  = tar 忽略（留空）；git 填分支 / 标签 / commit
#
# 想单独覆盖某个版本又不想改文件：
#   FFMPEG_VERSION=6.1.6 ./scripts/build-linux.sh
# ==============================================================================

# ------------------------------------------------------------------
# FFmpeg 本体
# ------------------------------------------------------------------
# 为什么锁 6.x —— 这不是"6.x 更好"，是"6.x 是补丁的宿主"：
#
#   AVS3 编码器 libuavs3e 从未进入 FFmpeg 主线（master 的 EXTERNAL_LIBRARY_LIST 里
#   只有 libdavs2 / libuavs3d / libxavs / libxavs2，没有任何 uavs3e 字样）。
#   现成的封装补丁最新只到 v6.0（LuoZijun/FFmpeg 的 patch-avs3/v4.4、v5.1、v6.0）。
#
#   本项目已逐条核对（见 README「为什么是 6.1.6」）：
#     - n6.0 / n6.0.1 / n6.1.6 三个 tag 上，6 个补丁锚点都精确匹配 1 次
#     - matroska.c 第 81-82 行已自带 V_AVS2 / V_AVS3，旧补丁那两行是多余的
#     - allcodecs.c 里没有 REGISTER_* 宏，注册表是 configure 生成的 codec_list.c，
#       所以只要补上 libuavs3e_encoder_deps 就会自动注册
#     - 真正需要的只有 5 处接线 + 1 个新文件 libavcodec/libuavs3e.c
#
#   选 6.1.6 而不是 6.0：锚点同样可用，且带 6.1 分支的安全修复。
#   若哪天要上 7.x/8.x/9.x，必须先把 libuavs3e.c 的 API 移植过去
#   （7.0 起 AVCodec 字段全面搬进 .p.*，还有 FF_CODEC_ENCODE_CB 等），
#   那是另一个独立任务，不是改个版本号的事。
FFMPEG_VERSION="${FFMPEG_VERSION:-6.1.6}"
FFMPEG_TAG="n${FFMPEG_VERSION}"
FFMPEG_URL="https://github.com/FFmpeg/FFmpeg/archive/refs/tags/${FFMPEG_TAG}.tar.gz"

# ------------------------------------------------------------------
# 许可证
# ------------------------------------------------------------------
# GPL v2（不带 nonfree）：
#   x264 / x265 / xavs2 / davs2 都是 GPL v2，不 --enable-gpl 就用不了。
#   fdk-aac 的许可与 GPL 不兼容，必须 --enable-nonfree 才能编，
#   而 nonfree 产物不可再分发 —— 所以这里不引入 fdk-aac，AAC 用 FFmpeg 自带编码器。
LICENSE_GPL="${LICENSE_GPL:-1}"

# ------------------------------------------------------------------
# 依赖清单
# ------------------------------------------------------------------
# shellcheck disable=SC2034
DEPS=(
  # ========== FFmpeg 本体 ==========
  "ffmpeg|tar|${FFMPEG_URL}|"

  # ========== AVS 家族（本项目核心） ==========
  # davs2 上游（pkuvcl）是「编译期单一位深」，build/linux/configure 里
  #   --bit-depth=9 或 10  ->  echo "not supported currently"; exit 1
  # xatabhk/davs2-10bit 把源码改成了 10bit 可用（补了 x86 的 10bit SSE/AVX 例程），
  # 但没改 build/linux/configure —— 所以 avs.sh 里用 edit_exact 放开那个限制。
  # ARM 平台没有 10bit 汇编（整个仓库 source/common 下只有 x86 和 vec），走纯 C：
  # 结果正确，只是没有 SIMD 加速，慢 3~5 倍。
  "davs2|git|https://github.com/xatabhk/davs2-10bit.git|master"
  # xavs2 只有 8bit 编码能力，这是上游硬限制，不是我们的选择
  "xavs2|tar|https://github.com/pkuvcl/xavs2/archive/refs/tags/1.4.tar.gz|"
  "uavs3d|git|https://github.com/uavs3/uavs3d.git|v1.1"
  # AVS3 编码器。三个必改点（见 scripts/libs/avs.sh）：
  #   1) cmake_minimum_required(VERSION 2.8) —— CMake 4.x 移除 <3.5 兼容，直接报错
  #   2) src/CMakeLists.txt 的 else() 会给 ARM 拉 x86 sse/avx2 源文件
  #   3) inc/com_api.h 用 #if defined(__linux__) 门控 10bit，MinGW 上把
  #      COMPILE_10BIT 强制归零 —— Windows 不打这个补丁就只有 8bit
  "uavs3e|git|https://github.com/uavs3/uavs3e.git|master"

  # ========== 视频编码 / 解码 ==========
  "x264|git|https://code.videolan.org/videolan/x264.git|stable"
  "x265|tar|https://github.com/videolan/x265/archive/refs/tags/3.4.tar.gz|"
  "dav1d|tar|https://github.com/videolan/dav1d/archive/refs/tags/1.5.4.tar.gz|"
  "libvpx|tar|https://github.com/webmproject/libvpx/archive/refs/tags/v1.15.0.tar.gz|"

  # ========== 音频 ==========
  "lame|tar|https://downloads.sourceforge.net/project/lame/lame/3.100/lame-3.100.tar.gz|"
  # xiph 官方站从国内常常极慢；用 GitHub 归档 + autoreconf（lib.sh 自动处理）
  "ogg|tar|https://github.com/xiph/ogg/archive/refs/tags/v1.3.5.tar.gz|"
  "vorbis|tar|https://github.com/xiph/vorbis/archive/refs/tags/v1.3.7.tar.gz|"
  "opus|tar|https://github.com/xiph/opus/archive/refs/tags/v1.5.2.tar.gz|"

  # ========== 基础 / 字幕 / 网络 ==========
  "zlib|tar|https://github.com/madler/zlib/archive/refs/tags/v1.3.1.tar.gz|"
  "freetype|tar|https://github.com/freetype/freetype/archive/refs/tags/VER-2-13-3.tar.gz|"
  "fribidi|tar|https://github.com/fribidi/fribidi/releases/download/v1.0.15/fribidi-1.0.15.tar.xz|"
  "harfbuzz|tar|https://github.com/harfbuzz/harfbuzz/releases/download/10.1.0/harfbuzz-10.1.0.tar.xz|"
  "libass|tar|https://github.com/libass/libass/releases/download/0.17.5/libass-0.17.5.tar.xz|"
  "zimg|tar|https://github.com/sekrit-twc/zimg/archive/refs/tags/release-3.0.5.tar.gz|"
  "srt|tar|https://github.com/Haivision/srt/archive/refs/tags/v1.5.4.tar.gz|"
  "openssl|tar|https://github.com/openssl/openssl/releases/download/openssl-3.0.15/openssl-3.0.15.tar.gz|"
  # libass 在非 Windows 平台必须有字体提供者，fontconfig 依赖 expat
  "expat|tar|https://github.com/libexpat/libexpat/releases/download/R_2_6_2/expat-2.6.2.tar.gz|"
  # fontconfig 的 GitHub Releases 没有资产（只有 tag），必须走官方发行目录；
  # 这个 tarball 自带 configure，正好省掉 autoreconf
  "fontconfig|tar|https://www.freedesktop.org/software/fontconfig/release/fontconfig-2.14.2.tar.xz|"

  # ========== Windows 专属 ==========
  # 硬件编码器头文件：只要头文件，不需要 CUDA / 运行库
  "nvcodec|tar|https://github.com/FFmpeg/nv-codec-headers/archive/refs/tags/n12.2.72.0.tar.gz|"
  "amf|tar|https://github.com/GPUOpen-LibrariesAndSDKs/AMF/archive/refs/tags/v1.4.33.tar.gz|"
  "libvpl|tar|https://github.com/intel/libvpl/archive/refs/tags/v2.13.0.tar.gz|"
  # ffplay 需要 SDL2
  "sdl2|tar|https://github.com/libsdl-org/SDL/archive/refs/tags/release-2.30.9.tar.gz|"

  # ========== 可选（默认关，用 ENABLE_xxx=1 打开） ==========
  "svtav1|tar|https://github.com/AOMediaCodec/SVT-AV1/archive/refs/tags/v2.3.0.tar.gz|"
  # aom 走 git：googlesource 的 +archive 包没有单一顶层目录，tar 解包不便。
  # 官方源在中国大陆经常不可达（本机实测 curl 失败），但 GitHub runner 是境外节点，
  # 正常可达。它是可选库（默认关），真编不过就保持关闭，不影响 AVS 能力。
  "aom|git|https://aomedia.googlesource.com/aom|v3.10.0"
  "webp|tar|https://storage.googleapis.com/downloads.webmproject.org/releases/webp/libwebp-1.4.0.tar.gz|"
)

# ------------------------------------------------------------------
# 可选库开关（默认全关）
# ------------------------------------------------------------------
ENABLE_SVTAV1="${ENABLE_SVTAV1:-0}"
ENABLE_AOM="${ENABLE_AOM:-0}"
ENABLE_WEBP="${ENABLE_WEBP:-0}"

# ------------------------------------------------------------------
# 平台裁剪：某些依赖只在特定平台有意义
# ------------------------------------------------------------------
# 这些库只在 Windows 编（Linux/Android 上编了也用不到，白等）
WINDOWS_ONLY_DEPS="nvcodec amf libvpl sdl2"

# 判定某个依赖是否要装：libs_needed <name>
dep_needed() {
  local n="$1"
  case " $WINDOWS_ONLY_DEPS " in
    *" $n "*) [ "${TARGET_OS:-}" = "windows" ] || return 1 ;;
  esac
  case "$n" in
    svtav1) [ "$ENABLE_SVTAV1" = "1" ] || return 1 ;;
    aom)    [ "$ENABLE_AOM"    = "1" ] || return 1 ;;
    webp)   [ "$ENABLE_WEBP"   = "1" ] || return 1 ;;
  esac
  return 0
}
