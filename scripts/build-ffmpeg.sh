#!/usr/bin/env bash
# ==============================================================================
# FFmpeg 本体构建
#
# 两个设计原则：
#   1) 所有外部库都按「pkg-config 里有才开」自动决定，不写死。
#      这样某个库编失败时，构建不会因为 --enable-xxx 找不到而整体崩掉，
#      而是那项能力缺失 —— 但会通过下面的断言把「缺了什么」喊出来。
#   2) configure 之后必须回读 config_components.h。
#      FFmpeg 的 --enable-xxx 找不到库时**不会报错**，只是把它关掉；
#      不检查的话产物看着正常，实际少一半能力。
# ==============================================================================

# 该 .pc 是否存在（供需要判断返回值的调用点使用）
_have_pc() {
  pkg-config --exists "$1" 2>/dev/null
}

# 只在该 .pc 存在时才追加 --enable-xxx
#
# 注意：这里**必须恒返回 0**。平台脚本都带 `set -euo pipefail`，
# 若在「找不到库」的分支 return 1，第一个缺库的点就会把整个脚本杀掉 ——
# 症状是只打出一条「跳过 --enable-libsvtav1」然后 exit 1，
# 后面的参数组装、configure 一个字都看不到（run#7 的 linux 就是这么挂的）。
# 需要判断成败的调用点请用 _have_pc，别依赖本函数的返回值。
_enable_if_pc() {
  local pc="$1" flag="$2"
  if _have_pc "$pc"; then
    FF_ARGS+=("$flag")
    return 0
  fi
  warn "跳过 $flag（pkg-config 找不到 $pc）"
  return 0
}

# 断言某个 CONFIG_xxx 在 configure 产出里为 1
assert_config() {
  local key="$1" desc="$2" hit=""
  local f
  for f in "$FF_DIR/config_components.h" "$FF_DIR/config.h"; do
    [ -f "$f" ] || continue
    if grep -qE "^#define ${key} 1$" "$f"; then hit="$f"; break; fi
  done
  [ -n "$hit" ] || die "断言失败：$desc（$key）没有被启用 —— configure 静默关掉了它，见 config.log"
  ok "断言通过：$desc"
}

build_ffmpeg() {
  dep_needed ffmpeg || return 0

  FF_DIR="$(fetch ffmpeg)"
  export FF_DIR

  # AVS3 编码器补丁必须在 configure 之前打 —— 否则 --enable-libuavs3e 是未知选项
  apply_ffmpeg_avs3_patch "$FF_DIR"

  FF_ARGS=(
    "--prefix=$PREFIX"
    --disable-doc
    --disable-debug
    --enable-static
    --disable-shared
    # 让 pkg-config 把 Libs.private 里的传递依赖也吐出来，
    # 否则静态链接会在最后一步报一堆 undefined reference
    --pkg-config-flags=--static
    --enable-gpl
    --enable-pic
    # 可复现构建：把构建路径信息压掉
    --disable-stripping
  )

  # ---------------- AVS 四件套 ----------------
  _enable_if_pc davs2   --enable-libdavs2
  _enable_if_pc xavs2   --enable-libxavs2
  _enable_if_pc uavs3d  --enable-libuavs3d
  _enable_if_pc uavs3e  --enable-libuavs3e

  # ---------------- 视频 ----------------
  _enable_if_pc x264    --enable-libx264
  _enable_if_pc x265    --enable-libx265
  _enable_if_pc dav1d   --enable-libdav1d
  _enable_if_pc vpx     --enable-libvpx
  _enable_if_pc SvtAv1Enc --enable-libsvtav1
  _enable_if_pc aom     --enable-libaom
  _enable_if_pc libwebp --enable-libwebp

  # ---------------- 音频 ----------------
  _enable_if_pc lame    --enable-libmp3lame
  _enable_if_pc vorbis  --enable-libvorbis
  _enable_if_pc opus    --enable-libopus

  # ---------------- 字幕 / 图像 / 缩放 ----------------
  _enable_if_pc libass   --enable-libass
  _enable_if_pc freetype2 --enable-libfreetype
  _enable_if_pc fribidi  --enable-libfribidi
  _enable_if_pc harfbuzz --enable-libharfbuzz
  _enable_if_pc zimg     --enable-libzimg
  # fontconfig：drawtext / subtitles 的字体选择。Windows 上我们没编它
  # （libass 走 directwrite），所以只在其它平台尝试开启。
  if [ "${TARGET_OS:-}" != "windows" ]; then
    _enable_if_pc fontconfig --enable-libfontconfig
  fi

  # ---------------- 网络 ----------------
  _enable_if_pc srt      --enable-libsrt
  _enable_if_pc openssl  --enable-openssl

  # ---------------- 平台专属 ----------------
  if [ "${TARGET_OS:-}" = "windows" ]; then
    # 硬件编码只装头文件，无运行库依赖；没装到就自动跳过。
    # 注意不要写 --enable-ffnvcodec：那不是文档化的开关，
    # nvenc 的依赖里已经含 ffnvcodec，会自动带上。
    # 注意不能写 `_enable_if_pc ... && FF_ARGS+=(...)`：_enable_if_pc 现在恒返回 0，
    # 那样 --enable-nvdec 会被无条件加上。用 _have_pc 显式判断。
    if _have_pc ffnvcodec; then
      FF_ARGS+=(--enable-nvenc --enable-nvdec)
    else
      warn "跳过 --enable-nvenc（pkg-config 找不到 ffnvcodec）"
    fi
    _enable_if_pc libvpl --enable-libvpl
    # AMF 没有 .pc，只能看头文件
    if [ -d "$PREFIX/include/AMF" ]; then
      FF_ARGS+=(--enable-amf)
    else
      warn "跳过 --enable-amf（$PREFIX/include/AMF 不存在）"
    fi
  fi

  if [ -n "${FF_EXTRA_ARGS:-}" ]; then
    # FF_EXTRA_ARGS 是**空格分隔的字符串**，不是数组。
    # 原因：bash 无法导出数组，而平台脚本需要把它传给被 source 的函数；
    # 一旦某处写成了数组，这里读到的就只剩第一个元素（静默丢参数）。
    read -r -a _ff_extra <<< "${FF_EXTRA_ARGS}"
    FF_ARGS+=("${_ff_extra[@]}")
  fi
  # 静态链接时，C++ 库（davs2/xavs2/zimg）的 libstdc++ 不会被 pkg-config 带出来，
  # 平台脚本通过 EXTRA_LIBS 补；openssl 在 mingw 上还要 ws2_32/crypt32 这类系统库
  if [ -n "${EXTRA_LIBS:-}" ]; then
    FF_ARGS+=("--extra-libs=$EXTRA_LIBS")
  fi
  if [ -n "${EXTRA_LDFLAGS:-}" ]; then
    FF_ARGS+=("--extra-ldflags=$EXTRA_LDFLAGS")
  fi
  if [ -n "${EXTRA_CFLAGS:-}" ]; then
    FF_ARGS+=("--extra-cflags=$EXTRA_CFLAGS")
  fi

  local logf="$LOGS/ffmpeg-configure.log"
  CURRENT_LOGFILE="$logf"

  # 把最终参数串打出来：configure 失败时这是第一手证据
  log "FF_ARGS(${#FF_ARGS[@]} 项): ${FF_ARGS[*]}"
  log "configure FFmpeg ${FFMPEG_VERSION} (${TARGET_OS}/${TARGET_ARCH})"
  (
    cd "$FF_DIR"
    ./configure "${FF_ARGS[@]}"
  ) > "$logf" 2>&1 || { dump_log "$logf"; die "FFmpeg configure 失败"; }

  # ---------------- 防静默失败断言 ----------------
  # 这四项是本项目的存在理由，任何一个没开成，产物就没有意义
  assert_config CONFIG_LIBDAVS2_DECODER   "AVS2 解码 (libdavs2)"
  assert_config CONFIG_LIBUAVS3D_DECODER  "AVS3 解码 (libuavs3d)"
  assert_config CONFIG_LIBUAVS3E_ENCODER  "AVS3 编码 (libuavs3e)"
  assert_config CONFIG_LIBXAVS2_ENCODER   "AVS2 编码 (libxavs2)"

  if pkg-config --exists sdl2 2>/dev/null; then
    ok "SDL2 就位，ffplay 会一起编"
  fi

  # 记下 capacity 里有没有 ffmpeg/ffprobe 两个程序
  for p in ffmpeg ffprobe; do
    grep -q "^CONFIG_$(echo "$p" | tr a-z A-Z)=yes" "$FF_DIR/ffbuild/config.mak" \
      || die "$p 未被启用（config.mak 里没有 CONFIG_$(echo "$p" | tr a-z A-Z)=yes）"
  done

  log "build FFmpeg"
  local blogf="$LOGS/ffmpeg-build.log"
  ( cd "$FF_DIR" && make -j"$JOBS" ) > "$blogf" 2>&1 \
    || { dump_log "$blogf"; die "FFmpeg 编译失败"; }

  ( cd "$FF_DIR" && make install ) >> "$blogf" 2>&1 \
    || { dump_log "$blogf"; die "FFmpeg 安装失败"; }

  ok "FFmpeg 构建完成"

  # 产物存在性检查：configure 说启用了，不代表真的落地了
  local miss=""
  for p in ffmpeg ffprobe; do
    [ -f "$PREFIX/bin/$p${EXE:-}" ] || miss="$miss $p"
  done
  [ -z "$miss" ] || die "构建结束但缺少可执行文件：$miss"
  ok "产物齐备：ffmpeg${EXE:-} ffprobe${EXE:-}"

  ( "$PREFIX/bin/ffmpeg${EXE:-}" -hide_banner -version | head -3 ) >&2 || true
}
