#!/usr/bin/env bash
# ==============================================================================
# 基础 / 字幕 / 网络依赖
#   zlib / openssl / expat / fontconfig / freetype / fribidi / harfbuzz
#   libass / zimg / srt / sdl2(Windows)
#
# 字幕这条链是有顺序的，不能乱：
#   freetype ─┬─> fontconfig ─┐
#   expat ────┘               ├─> libass
#   fribidi ──────────────────┤
#   harfbuzz(freetype) ───────┘
# libass 的字体提供者二选一：Windows 用 directwrite（零额外依赖），
# 其他平台必须 fontconfig，否则 configure 直接报「no font provider」。
# ==============================================================================

# ------------------------------------------------------------------------------
# zlib —— 压缩（mkv/png/字幕都靠它）
# zlib 的 configure 既不认 --host 也不认 --enable-static，必须走 custom_configure
# ------------------------------------------------------------------------------
build_zlib() {
  dep_needed zlib || return 0
  local dir; dir="$(fetch zlib)"

  # --static 必须加。Linux 那条线为了 musl 全静态产物给 LDFLAGS 塞了 -static，
  # 而 zlib 默认同时产出 libz.so，ld 在 -static 下建共享库会直接报
  #   relocation R_X86_64_32 against hidden symbol `__TMC_END__'
  #   can not be used when making a shared object
  # 我们只需要 libz.a，所以只建静态库，从根上避开这个组合。
  custom_configure "$dir" zlib configure "--prefix=$PREFIX" --static

  # zlib 的 .pc 依赖安装方式，缺了就自己补一个，
  # 否则 FFmpeg 的 --enable-zlib 会静默失效（configure 不报错，能力直接没有）。
  if ! pkg-config --exists zlib 2>/dev/null; then
    gen_pc zlib 1.3.1 "zlib compression library" "-lz"
  fi
  require_pc zlib
}

# ------------------------------------------------------------------------------
# openssl —— TLS（https / rtmps / srt 都依赖）
#
# 选 openssl 而不是 gnutls：musl 全静态下 gnutls 要拖 nettle + gmp + libidn2
# 一长串，失败面大；openssl 静态链接在 musl 上表现稳定。
# ------------------------------------------------------------------------------
openssl_target() {
  case "${TARGET_OS:-linux}/${TARGET_ARCH:-x86_64}" in
    windows/x86_64)              echo "mingw64" ;;
    linux/x86_64)                echo "linux-x86_64" ;;
    android/arm|android/armv7*)  echo "android-arm" ;;
    android/aarch64)             echo "android-arm64" ;;
    *) die "openssl: 未支持的 target ${TARGET_OS:-?}/${TARGET_ARCH:-?}" ;;
  esac
}

build_openssl() {
  dep_needed openssl || return 0
  local dir; dir="$(fetch openssl)"

  local args=(
    "--prefix=$PREFIX"
    # 必须显式 --libdir=lib。openssl 3.x 在 linux-x86_64 上默认装到
    # $PREFIX/lib64/pkgconfig，而我们的 PKG_CONFIG_PATH 只含 $PREFIX/lib/pkgconfig，
    # 结果 openssl 明明编好了却 pkg-config 找不到，--enable-openssl 会被静默关掉。
    "--libdir=lib"
    "--openssldir=$PREFIX/ssl"
    "$(openssl_target)"
    no-shared no-tests no-async no-ssl3 no-comp
  )
  if [ "${TARGET_OS:-}" = "android" ]; then
    # NDK 的 clang 需要显式 API level，否则默认按最低版本编
    args+=("-D__ANDROID_API__=${ANDROID_API:-19}")
  fi

  # openssl 用的是大写 Configure（perl 脚本）
  custom_configure "$dir" openssl Configure "${args[@]}"
  require_pc openssl
}

# ------------------------------------------------------------------------------
# expat —— fontconfig 的 XML 解析器
# ------------------------------------------------------------------------------
build_expat() {
  dep_needed expat || return 0
  local dir; dir="$(fetch expat)"

  autotools_build "$dir" expat \
    --disable-shared --enable-static \
    --disable-dependency-tracking \
    --without-docbook \
    --without-xmlwf

  require_pc expat
}

# ------------------------------------------------------------------------------
# fontconfig —— libass 在非 Windows 平台的字体提供者
# 注意：它需要的字体目录在运行时确定，静态链接时把默认值写死进二进制
# ------------------------------------------------------------------------------
build_fontconfig() {
  dep_needed fontconfig || return 0
  local dir; dir="$(fetch fontconfig)"

  require_pc expat
  require_pc freetype2

  local fontdir="/usr/share/fonts"
  [ "${TARGET_OS:-}" = "android" ] && fontdir="/system/fonts"

  autotools_build "$dir" fontconfig \
    --disable-shared --enable-static \
    --disable-dependency-tracking \
    --disable-docs \
    --disable-nls \
    --sysconfdir="$PREFIX/etc" \
    --localstatedir="$PREFIX/var" \
    --with-default-fonts="$fontdir" \
    --with-cache-dir="$PREFIX/var/cache/fontconfig"

  require_pc fontconfig
}

# ------------------------------------------------------------------------------
# freetype —— 字体渲染
# GitHub 归档只有 CMakeLists，用 cmake（不依赖 autoreconf）
# harfbuzz / brotli / png / bzip2 全关：这些交给 libass 自己链 harfbuzz，
# 让 freetype 再依赖一遍只会增加失败面
# ------------------------------------------------------------------------------
build_freetype() {
  dep_needed freetype || return 0
  local dir; dir="$(fetch freetype)"

  cmake_build "$dir" freetype \
    -DFT_DISABLE_HARFBUZZ=TRUE \
    -DFT_DISABLE_BROTLI=TRUE \
    -DFT_DISABLE_PNG=TRUE \
    -DFT_DISABLE_BZIP2=TRUE \
    -DFT_DISABLE_ZLIB=FALSE \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

  require_pc freetype2
}

# ------------------------------------------------------------------------------
# fribidi —— 双向文本（阿拉伯语/希伯来语字幕排版）
# ------------------------------------------------------------------------------
build_fribidi() {
  dep_needed fribidi || return 0
  local dir; dir="$(fetch fribidi)"

  autotools_build "$dir" fribidi \
    --disable-shared --enable-static \
    --disable-dependency-tracking \
    --disable-docs

  require_pc fribidi
}

# ------------------------------------------------------------------------------
# harfbuzz —— 复杂文本整形（字幕排版质量的关键）
# 依赖 freetype；glib/gobject/icu/cairo 全关，避免拖进一整套 GNOME 依赖
# ------------------------------------------------------------------------------
build_harfbuzz() {
  dep_needed harfbuzz || return 0
  local dir; dir="$(fetch harfbuzz)"

  require_pc freetype2

  meson_build "$dir" harfbuzz \
    -Dglib=disabled \
    -Dgobject=disabled \
    -Dicu=disabled \
    -Dcairo=disabled \
    -Dfreetype=enabled \
    -Dtests=disabled \
    -Ddocs=disabled \
    -Dintrospection=disabled

  require_pc harfbuzz
}

# ------------------------------------------------------------------------------
# libass —— ASS/SSA 字幕渲染
# Windows 用 directwrite 当字体提供者（系统自带，零额外依赖）
# 其他平台必须有 fontconfig
# ------------------------------------------------------------------------------
build_libass() {
  dep_needed libass || return 0
  local dir; dir="$(fetch libass)"

  require_pc freetype2
  require_pc fribidi
  require_pc harfbuzz

  local args=(
    --disable-shared --enable-static
    --disable-dependency-tracking
    --disable-test
  )
  if [ "${TARGET_OS:-}" = "windows" ]; then
    args+=(--enable-directwrite --disable-fontconfig)
  else
    require_pc fontconfig
    args+=(--enable-fontconfig)
  fi

  autotools_build "$dir" libass "${args[@]}"
  require_pc libass
}

# ------------------------------------------------------------------------------
# zimg —— 高质量色彩空间/缩放（FFmpeg 的 zscale 滤镜）
# 纯 C++，GitHub 归档没有 configure，靠 autoreconf 生成
# ------------------------------------------------------------------------------
build_zimg() {
  dep_needed zimg || return 0
  local dir; dir="$(fetch zimg)"

  local extra=()
  case "${TARGET_ARCH:-x86_64}" in
    x86_64|i?86) extra+=(--enable-x86simd) ;;
  esac

  autotools_build "$dir" zimg \
    --disable-shared --enable-static \
    --disable-dependency-tracking \
    "${extra[@]}"

  require_pc zimg
}

# ------------------------------------------------------------------------------
# srt —— SRT 传输协议（低延迟直播/回传）
# 加密库指定 openssl，否则它会去找 mbedtls 然后失败
# ------------------------------------------------------------------------------
build_srt() {
  dep_needed srt || return 0
  local dir; dir="$(fetch srt)"

  require_pc openssl

  cmake_build "$dir" srt \
    -DENABLE_APPS=OFF \
    -DENABLE_SHARED=OFF \
    -DENABLE_STATIC=ON \
    -DUSE_ENCLIB=openssl \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5

  require_pc srt
}

# ------------------------------------------------------------------------------
# SDL2 —— 只给 ffplay 用（Windows 专属）
# ------------------------------------------------------------------------------
build_sdl2() {
  dep_needed sdl2 || return 0
  local dir; dir="$(fetch sdl2)"

  autotools_build "$dir" sdl2 \
    --disable-shared --enable-static \
    --disable-dependency-tracking

  require_pc sdl2
}

# ------------------------------------------------------------------------------
build_misc_all() {
  build_zlib
  build_openssl
  build_freetype
  build_expat
  build_fontconfig
  build_fribidi
  build_harfbuzz
  build_libass
  build_zimg
  build_srt
  build_sdl2
}
