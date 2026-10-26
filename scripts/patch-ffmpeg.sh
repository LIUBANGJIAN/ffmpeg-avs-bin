#!/usr/bin/env bash
# ==============================================================================
# 给 FFmpeg 6.0 补上 libuavs3e（AVS3 编码器）
#
# 为什么必须自己打：libuavs3e 从未进入 FFmpeg 主线。master 的 EXTERNAL_LIBRARY_LIST
# 里只有 libdavs2 / libuavs3d / libxavs / libxavs2，一个 uavs3e 字样都没有。
#
# 为什么只有 5 处接线：
#   - matroska.c 的 V_AVS2 / V_AVS3 标签 n6.x 已自带（第 81-82 行），旧补丁那两行多余
#   - allcodecs.c 在 6.x 里没有 REGISTER_* 宏，注册表由 configure 生成的
#     codec_list.c 决定。而 configure 第 4100 行是这么取编码器清单的：
#         ENCODER_LIST=$(find_things_extern encoder FFCodec libavcodec/allcodecs.c)
#     也就是说 allcodecs.c 里那行 extern 是**清单的唯一来源**，删掉它就等于
#     编码器不存在 —— 它不是装饰，是必需项。
#
# 锚点全部来自 n6.0 原文，用 edit_exact 严格匹配：锚点漂移会立刻失败，
# 不会出现"看起来打了补丁其实没打"的沉默故障。
# ==============================================================================

apply_ffmpeg_avs3_patch() {
  local dir="$1"
  [ -d "$dir" ] || die "apply_ffmpeg_avs3_patch: 目录不存在 $dir"

  # ---- 版本护栏：这套锚点只在 6.x 上验证过（6.0 / 6.0.1 / 6.1.6 各验一遍）----
  # 7.0 起 AVCodec 的字段整体搬进 .p.*，且 libuavs3e.c 里的
  # avctx->coded_width 等已移除，直接跨大版本会编不过，必须重做锚点和封装。
  case "${FFMPEG_VERSION}" in
    6.*) ;;
    *) die "AVS3 补丁只在 FFmpeg 6.x 验证过（当前 ${FFMPEG_VERSION}）。跨大版本必须先重新核对锚点并移植 libuavs3e.c。" ;;
  esac

  if [ -f "$dir/libavcodec/libuavs3e.c" ]; then
    warn "libavcodec/libuavs3e.c 已存在，跳过补丁（可能是重复构建）"
    return 0
  fi

  # ---- ① configure：帮助文本 ----
  edit_exact "$dir/configure" \
    '  --enable-libuavs3d       enable AVS3 decoding via libuavs3d [no]' \
    '  --enable-libuavs3d       enable AVS3 decoding via libuavs3d [no]
  --enable-libuavs3e       enable AVS3 encoding via libuavs3e [no]'

  # ---- ② configure：外部库清单（放在 generic 列表里，紧跟 libuavs3d）----
  edit_exact "$dir/configure" \
    '    libuavs3d
' \
    '    libuavs3d
    libuavs3e
'

  # ---- ③ configure：编码器依赖 ----
  edit_exact "$dir/configure" \
    'libuavs3d_decoder_deps="libuavs3d"' \
    'libuavs3d_decoder_deps="libuavs3d"
libuavs3e_encoder_deps="libuavs3e"'

  # ---- ④ configure：pkg-config 探测 ----
  edit_exact "$dir/configure" \
    'enabled libuavs3d         && require_pkg_config libuavs3d "uavs3d >= 1.1.41" uavs3d.h uavs3d_decode' \
    'enabled libuavs3d         && require_pkg_config libuavs3d "uavs3d >= 1.1.41" uavs3d.h uavs3d_decode
enabled libuavs3e         && require_pkg_config libuavs3e uavs3e "uavs3e/uavs3e.h" uavs3e_enc'

  # ---- ⑤ libavcodec/Makefile：编译单元 ----
  edit_exact "$dir/libavcodec/Makefile" \
    'OBJS-$(CONFIG_LIBUAVS3D_DECODER)          += libuavs3d.o' \
    'OBJS-$(CONFIG_LIBUAVS3D_DECODER)          += libuavs3d.o
OBJS-$(CONFIG_LIBUAVS3E_ENCODER)          += libuavs3e.o'

  # ---- ⑥ libavcodec/allcodecs.c：extern 声明（与其它外挂库保持一致）----
  edit_exact "$dir/libavcodec/allcodecs.c" \
    'extern const FFCodec ff_libxavs2_encoder;' \
    'extern const FFCodec ff_libxavs2_encoder;
extern const FFCodec ff_libuavs3e_encoder;'

  # ---- ⑦ 放入封装实现 ----
  local src="$ROOT/patches/libuavs3e.c"
  [ -f "$src" ] || die "找不到 patches/libuavs3e.c（封装实现必须随仓库一起走）"
  cp -f "$src" "$dir/libavcodec/libuavs3e.c"
  ok "已放入 libavcodec/libuavs3e.c"

  ok "FFmpeg AVS3 编码补丁应用完成（6 处文本替换 + 1 个新文件）"
}
