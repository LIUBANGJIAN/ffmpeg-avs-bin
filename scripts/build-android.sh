#!/usr/bin/env bash
# ==============================================================================
# Android —— NDK r25c，单文件可执行 ffmpeg
#
# 叫「单文件」而不是「全静态」，是因为 Android 的 libc 是 bionic：
#   - 可以把除 libc 以外的所有东西静态链进去（x264/x265/AVS 全套/openssl…）
#   - 但绝不能把 bionic 静态链进去（Android 上静态 bionic 会丢 TLS/atfork，
#     运行时随机崩，官方也不支持）
#   所以产物是「一个二进制 + 依赖系统自带的 libc/libm/libdl」，
#   在 4.4 及以上任何一台机器上都能直接跑，无需 root（放 /data/local/tmp 即可执行）。
#
# API level 为什么这么定：
#   - armv7 -> API 19：NDK r26 起官方不再支持 KitKat，最后一个支持 4.4.2 的是 r25c
#   - arm64 -> API 21：Android 5.0 才开始有 64 位
#
# 用法：
#   ANDROID_NDK_HOME=/opt/ndk/25.2.9519653 ./scripts/build-android.sh armv7
#   ANDROID_NDK_HOME=/opt/ndk/25.2.9519653 ./scripts/build-android.sh arm64
# ==============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT

ABI_IN="${1:-${ABI_IN:-armv7}}"
: "${ANDROID_NDK_HOME:?必须指定 ANDROID_NDK_HOME（NDK r25c）}"

case "$ABI_IN" in
  armv7|armeabi-v7a)
    export ANDROID_ABI="armeabi-v7a"
    export ANDROID_API="${ANDROID_API:-19}"
    export TARGET_ARCH="arm"
    export HOST="arm-linux-androideabi"
    CLANG_TRIPLE="armv7a-linux-androideabi"
    FF_ARCH="arm"
    FF_CPU="armv7-a"
    MESON_CPU_FAMILY="arm"
    MESON_CPU="armv7-a"
    PKG_ABI_NAME="armv7"
    ;;
  arm64|arm64-v8a|aarch64)
    export ANDROID_ABI="arm64-v8a"
    export ANDROID_API="${ANDROID_API:-21}"
    export TARGET_ARCH="aarch64"
    export HOST="aarch64-linux-android"
    CLANG_TRIPLE="aarch64-linux-android"
    FF_ARCH="aarch64"
    FF_CPU="armv8-a"
    MESON_CPU_FAMILY="aarch64"
    MESON_CPU="armv8-a"
    PKG_ABI_NAME="arm64"
    ;;
  *) echo "未知 ABI: $ABI_IN（可用 armv7 / arm64）" >&2; exit 1 ;;
esac

export TARGET_OS=android
export EXE=

TC="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64"
if [ ! -d "$TC" ]; then
  echo "找不到 NDK 工具链：$TC" >&2
  echo "确认 ANDROID_NDK_HOME 指向 NDK 根目录（不是 toolchains 目录）" >&2
  exit 1
fi

# openssl 3.x 的 Configurations/15-android.conf 只认 ANDROID_NDK_ROOT / ANDROID_NDK，
# 而且必须靠 `which clang` 解析出 $ndk/.../prebuilt/.../clang，才会走 NDK clang 分支。
# GitHub 的 ubuntu runner 预装了别的 NDK 并已设好 ANDROID_NDK_ROOT，不覆盖的话
# openssl 会去 r25c 里找早已被移除的 arm-linux-androideabi-gcc，报
#   "no NDK arm-linux-androideabi-gcc on $PATH"
export ANDROID_NDK_ROOT="$ANDROID_NDK_HOME"
export ANDROID_NDK="$ANDROID_NDK_HOME"
case ":$PATH:" in
  *":$TC/bin:"*) ;;
  *) export PATH="$TC/bin:$PATH" ;;
esac

export CC="$TC/bin/${CLANG_TRIPLE}${ANDROID_API}-clang"
export CXX="$TC/bin/${CLANG_TRIPLE}${ANDROID_API}-clang++"
export AR="$TC/bin/llvm-ar"
export RANLIB="$TC/bin/llvm-ranlib"
export STRIP="$TC/bin/llvm-strip"
export NM="$TC/bin/llvm-nm"
[ -x "$CC" ] || { echo "编译器不存在：$CC" >&2; exit 1; }

export CFLAGS="-O2 -fPIC -D__ANDROID_API__=${ANDROID_API}"
export CXXFLAGS="$CFLAGS"
export LDFLAGS=""
# davs2 / xavs2 / zimg 是 C++，用 clang 驱动链接时必须显式带 NDK 的静态 C++ 运行库
export EXTRA_LIBS="-lc++_static -lc++abi"

# 防止跨平台污染：ubuntu runner 上装了 libssl-dev/zlib1g-dev 时，
# pkg-config 会找到 **x86 主机版** .pc，然后把 x86 的库链进 ARM 产物。
# 限定 LIBDIR 是唯一可靠的做法（只改 PATH 不够）。真正的值在 source lib.sh 后设置。
unset PKG_CONFIG_PATH || true

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

# lib.sh 定义了 PREFIX，现在才能设 pkg-config 搜索路径
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig:$PREFIX/share/pkgconfig"

# meson 没有 --host 那套，跨平台必须给 cross file
export MESON_CROSS_FILE="$WORK/meson-${PKG_ABI_NAME}.ini"
cat > "$MESON_CROSS_FILE" <<EOF
[binaries]
c = '$CC'
cpp = '$CXX'
ar = '$AR'
strip = '$STRIP'
pkgconfig = 'pkg-config'

[host_machine]
system = 'android'
cpu_family = '$MESON_CPU_FAMILY'
cpu = '$MESON_CPU'
endian = 'little'

[properties]
needs_exe_wrapper = true
sys_root = '$TC/sysroot'

# 交叉编译时 meson 会忽略环境里的 CFLAGS，必须在这里显式给，
# 否则 -fPIC / -D__ANDROID_API__ 全丢，dav1d 这类库会按 host 默认值编。
[built-in options]
c_args = ['-O2', '-fPIC', '-D__ANDROID_API__=$ANDROID_API']
c_link_args = ['-D__ANDROID_API__=$ANDROID_API']
cpp_args = ['-O2', '-fPIC', '-D__ANDROID_API__=$ANDROID_API']
cpp_link_args = ['-D__ANDROID_API__=$ANDROID_API']
EOF

# cmake 必须显式给 NDK 的 toolchain 文件。
# 只传 -DANDROID_ABI 而不给 toolchain 时 cmake 不会进入交叉编译模式，
# 结果是**按 host 编出 x86_64 的 .a**，直到链接 ffmpeg 才报架构不匹配，
# 错误信息离真正原因很远，所以必须在这里堵住。
export CMAKE_TOOLCHAIN="$ANDROID_NDK_HOME/build/cmake/android.toolchain.cmake"
export ANDROID_PLATFORM="android-${ANDROID_API}"
[ -f "$CMAKE_TOOLCHAIN" ] || { echo "找不到 NDK cmake toolchain：$CMAKE_TOOLCHAIN" >&2; exit 1; }

# libvpx 不吃 CC 环境变量，只认 --sdk-path
export ANDROID_NDK_HOME

# ---------------- FFmpeg 专属参数 ----------------
# 注意是**字符串**而不是数组：bash 无法导出数组，build-ffmpeg.sh 按空格拆
FF_EXTRA_ARGS="--target-os=android --arch=${FF_ARCH} --cpu=${FF_CPU} --enable-cross-compile --sysroot=${TC}/sysroot"
# API 19 的 bionic 没有 iconv，留着会让 configure 探测出一堆假阳性
if [ "$ANDROID_API" -lt 21 ]; then
  FF_EXTRA_ARGS+=" --disable-iconv"
fi
export FF_EXTRA_ARGS

# ---------------- 干活 ----------------
build_everything

# 交叉编译出的 ARM 二进制无法在 x86 runner 上执行，
# 所以这里做「结构验证」而不是「运行验证」：ELF 架构、动态依赖、AVS 符号都在
verify_cross_binary "$PREFIX/bin/ffmpeg" "$TARGET_ARCH"

package_output "ffmpeg-${FFMPEG_VERSION}-avs-android-${PKG_ABI_NAME}-api${ANDROID_API}"
