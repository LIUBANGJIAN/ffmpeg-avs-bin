#!/usr/bin/env bash
# ==============================================================================
# Linux x86_64 —— Alpine + musl，全静态
#
# 为什么必须是 musl 而不是 glibc：
#   glibc 静态链接后 getaddrinfo / NSS 会在运行时静默失败
#   （dlopen 不了 libnss_*，DNS 直接不工作），
#   http/rtmp/srt 这些协议就全废了 —— 而且报错现场离原因很远。
#   musl 没有这个问题，代价是必须换整个 libc。
#
# 用法（CI 里是 alpine 容器；本地等价命令）：
#   docker run --rm -v "$PWD":/src -w /src alpine:3.20 sh -c '
#     apk add --no-cache build-base linux-headers nasm cmake meson ninja \
#         pkgconf perl autoconf automake libtool git curl python3 zip && \
#     ./scripts/build-linux.sh'
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

export TARGET_OS=linux
export TARGET_ARCH=x86_64
export EXE=

# ---------------- 工具链 ----------------
export CC=gcc
export CXX=g++
export AR=ar
export RANLIB=ranlib
export STRIP=strip
export NM=nm
export PKG_CONFIG=pkg-config

export CFLAGS="-O2 -pipe -fno-ident"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-static"
# -lstdc++：davs2/xavs2/zimg 是 C++ 写的，用 gcc 驱动链接时要显式带
export EXTRA_LIBS="-lstdc++"

# ---------------- 载入构建系统 ----------------
source "$ROOT/scripts/env.sh"
source "$ROOT/scripts/lib.sh"
source "$ROOT/scripts/patch-ffmpeg.sh"
source "$ROOT/scripts/libs/avs.sh"
source "$ROOT/scripts/libs/video.sh"
source "$ROOT/scripts/libs/audio.sh"
source "$ROOT/scripts/libs/misc.sh"
source "$ROOT/scripts/build-ffmpeg.sh"
source "$ROOT/scripts/build-common.sh"

# 依赖全部自建在 $PREFIX 下（Alpine 只装了工具链，没装任何 -dev 包）。
# 带 .pc 的库会把 -L$PREFIX/lib 一起带出来，但 FFmpeg 对 **libmp3lame** 走的是
# 裸 check_lib（lame 3.100 上游不提供 .pc，我们补的 lame.pc 只用于脚本自己
# 判断"要不要 --enable-libmp3lame"），此时链接行只有全局 ldflags：
#   gcc -static ... -o test test.o -lmp3lame -lm -lstdc++
# 缺 -L 就报 cannot find -lmp3lame → ERROR: libmp3lame >= 3.98.3 not found。
# 这条在 android-arm64 上已经实测踩到（run#16），linux 只是还没走到那一步
# （前面先死在 davs2），一并堵掉。
# 必须放在 source lib.sh 之后：PREFIX 定义在那里，提前引用会触发 set -u。
export EXTRA_LDFLAGS="-L$PREFIX/lib"

# ---------------- 干活 ----------------
build_everything

# 静态性必须验证：ldd 说 "not a dynamic executable" 才算过
log "校验静态链接"
if ldd "$PREFIX/bin/ffmpeg" 2>&1 | grep -qi 'not a dynamic\|statically linked'; then
  ok "ffmpeg 是纯静态二进制"
else
  ldd "$PREFIX/bin/ffmpeg" >&2 || true
  die "ffmpeg 仍然依赖动态库 —— musl 静态链接没生效"
fi

smoke_test
package_output "ffmpeg-${FFMPEG_VERSION}-avs-linux64-static"
