# ffmpeg-avs-bin

带 **AVS2 / AVS3 完整编解码能力** 的 FFmpeg 静态构建，Windows / Linux / Android 三平台。

由 GitHub Actions 从源码构建，产物是可直接拷走使用的单文件可执行程序。

---

## 1. 为什么需要这个项目

官方 FFmpeg **没有 AVS3 编码器**，而 AVS2 的 10bit 解码在主流发行版里也拿不到。具体来说：

| 能力 | 官方 FFmpeg | gyan.dev 的 full build | 本项目 |
|---|---|---|---|
| AVS1 解码 | ✅ 原生 `cavs` | ✅ | ✅ |
| AVS2 解码 8bit | ✅ `libdavs2` | ✅ | ✅ |
| **AVS2 解码 10bit** | 取决于链接的 davs2 | ❌ 上游 davs2 只编 8bit | ✅ **10bit 构建（超集）** |
| AVS2 编码 | ✅ `libxavs2` | ✅（仅 8bit） | ✅（仅 8bit，上游硬限制） |
| AVS3 解码 | ✅ `libuavs3d` | ✅ | ✅ 8/10bit |
| **AVS3 编码** | ❌ **不存在** | ❌ | ✅ `libuavs3e` + 补丁 |

### 一个容易搞错的点：10bit 构建是超集，不是二选一

davs2 的位深是**编译期**固定的，`build/linux/configure` 甚至把 `--bit-depth=10` 写死成 `exit 1`。
但源码里的位深检查是这样的（`source/common/header.cc`）：

```c
#if HIGH_BIT_DEPTH
    g_bit_depth = h->sample_bit_depth;      // 位深跟着码流走，8 或 10 都行
#else
    if (g_bit_depth != h->sample_bit_depth) {
        davs2_log(h, DAVS2_LOG_ERROR, "Un-supported bit-depth %d in this version.\n", ...);
        return -1;
    }
#endif
```

`--bit-depth=10` 会定义 `HIGH_BIT_DEPTH=1`（configure 第 1068 行），于是走上面那个分支。

> **结论：10bit 构建同时能解 8bit 和 10bit 码流。** 选 10bit 没有任何损失。
> 真正只能在「8 或 10」之间二选一的，是把 davs2 当**系统预编译库**用的时候。

---

## 2. 为什么锁 FFmpeg 6.1.6 而不是最新的 9.x

**因为 `libuavs3e` 从来没有进入 FFmpeg 主线。**

主线 `configure` 的外部库清单里只有 `libdavs2` / `libuavs3d` / `libxavs` / `libxavs2`，一个 `uavs3e` 字样都没有。
社区现成的封装补丁最新只到 **v6.0**（`LuoZijun/FFmpeg` 的 `patch-avs3/v4.4`、`v5.1`、`v6.0`）。

要上 7.x+ 必须先把 `libuavs3e.c` 的 API 整体移植（7.0 起 `AVCodec` 字段全面搬进 `.p.*`，
`avctx->coded_width` 等也被移除），那是另一个独立任务，不是改版本号。

**6.1.6 的选择依据**：`n6.0`、`n6.0.1`、`n6.1.6` 三个 tag 上，本项目的 6 个补丁锚点
**都精确匹配且仅匹配 1 次**。因此没有理由停在 6.0 —— 6.1.6 带 6.1 分支的安全修复。

### 补丁到底改了什么（6 处文本替换 + 1 个新文件）

| 位置 | 改动 | 为什么 |
|---|---|---|
| `configure` | 帮助文本加 `--enable-libuavs3e` | 让选项合法 |
| `configure` | `EXTERNAL_LIBRARY_LIST` 加 `libuavs3e` | 让 `--enable-libuavs3e` 能被接受 |
| `configure` | `libuavs3e_encoder_deps="libuavs3e"` | 编码器组件的依赖关系 |
| `configure` | `require_pkg_config libuavs3e ...` | 探测库是否存在 |
| `libavcodec/Makefile` | 加 `OBJS-$(CONFIG_LIBUAVS3E_ENCODER) += libuavs3e.o` | 编译单元 |
| `libavcodec/allcodecs.c` | 加 `extern const FFCodec ff_libuavs3e_encoder;` | **必需**，见下 |
| `libavcodec/libuavs3e.c` | 新增封装实现 | 编码器主体 |

> `allcodecs.c` 里那行 extern **不是装饰**。configure 第 4100 行是这么取编码器清单的：
> ```sh
> ENCODER_LIST=$(find_things_extern encoder FFCodec libavcodec/allcodecs.c)
> ```
> 删掉它，编码器就不会出现在 `codec_list.c` 里，`--enable-libuavs3e` 会变成空操作。

补丁用**严格锚点替换**（`edit_exact`）而不是 `patch(1)`：锚点必须精确匹配 N 次，
不匹配就立即失败。`patch` 的 fuzz 和 `--forward` 会留下「看起来打了其实没打」的半残状态。

---

## 3. 产物

| 平台 | runner | 产物 | 说明 |
|---|---|---|---|
| Windows x86_64 | `windows-latest` + MSYS2 UCRT64 | `ffmpeg.exe` `ffprobe.exe` `ffplay.exe` | 全静态，不依赖任何 DLL |
| Linux x86_64 | Alpine 3.20 + **musl** | `ffmpeg` `ffprobe` | 全静态（`ldd` 显示 not a dynamic executable） |
| Android armv7 | ubuntu + **NDK r25c** | `ffmpeg` | API 19（Android 4.4.2），单文件 |
| Android arm64 | 同上 | `ffmpeg` | API 21（Android 5.0） |

### 为什么 Linux 必须用 musl

glibc 静态链接后 `getaddrinfo` / NSS 会在**运行时**静默失败（dlopen 不到 `libnss_*`），
DNS 直接不工作 —— `http`/`rtmp`/`srt` 全部失效，而且报错现场离原因很远。
musl 没这个问题，代价是整个 libc 要换掉。

### 为什么 Android 叫「单文件」而不是「全静态」

bionic 不能静态链（会丢 TLS/atfork，运行时随机崩，官方不支持）。所以 Android 产物是
**一个二进制 + 依赖系统自带的 libc/libm/libdl/liblog**，除 libc 外全部静态。
放到 `/data/local/tmp` 就能 `./ffmpeg` 跑，不需要 root。

---

## 4. 能力清单

`--enable-gpl`（GPL v2），包含：

- **AVS**：`libdavs2`(10bit 超集) `libxavs2` `libuavs3d`(10bit) `libuavs3e`(10bit)
- **视频**：`libx264` `libx265` `libdav1d` `libvpx`；可选 `libsvtav1` `libaom` `libwebp`
- **音频**：`libmp3lame` `libvorbis` `libopus`
- **字幕**：`libass` `libfreetype` `libfribidi` `libharfbuzz`
- **缩放/色彩**：`libzimg`（zscale）
- **网络**：`openssl`(TLS) `libsrt`
- **硬件编码（仅 Windows）**：`nvenc`/`nvdec` `amf` `QSV`(libvpl)
- **播放器**：`ffplay`（仅 Windows，SDL2）

### 明确的取舍

**没有 fdk-aac。** 它的许可与 GPL 不兼容，要 `--enable-nonfree` 才能编，而 nonfree 产物
**不可再分发**。AAC 用 FFmpeg 自带编码器。需要 fdk-aac 就自己改 `LICENSE_GPL=0`。

**x265 只有 8bit。** x265 一个构建只出一个位深。gyan 那种「一个库支持 8/10/12bit」
是 `make multi-lib` 把三份对象合并，依赖上游 `multilib.mak`，跨平台可用性差。
10bit HEVC 需要另编一份 `-DHIGH_BIT_DEPTH=ON` 的 x265 并单独发版。

**xavs2 永远只能 8bit。** 上游硬限制，不是配置问题。

**Android 不启用硬编解码。** `mediacodec` 需要 JVM 上下文，静态 CLI 里开了也跑不通。

---

## 5. 目录结构

```
scripts/
  env.sh            版本锁 —— 所有依赖的版本/URL 只在这里出现
  lib.sh            fetch / autotools / cmake / meson / edit_exact / .pc 工具
  build-ffmpeg.sh   FFmpeg configure 参数组装 + 防静默失败断言
  build-common.sh   构建顺序、打包、冒烟测试、交叉产物结构验证
  patch-ffmpeg.sh   AVS3 编码器补丁（6 处锚点替换）
  libs/avs.sh       davs2 / xavs2 / uavs3d / uavs3e
  libs/video.sh     x264 / x265 / dav1d / libvpx / svt-av1 / aom / webp
  libs/audio.sh     lame / ogg / vorbis / opus
  libs/misc.sh      zlib / openssl / expat / fontconfig / freetype /
                    fribidi / harfbuzz / libass / zimg / srt / sdl2
  build-windows.sh  build-linux.sh  build-android.sh
  verify-urls.sh    依赖地址可达性自检
patches/
  libuavs3e.c       AVS3 编码器封装（约 300 行）
.github/workflows/
  build.yml         4 个并行 job + tag 自动发 Release
```

**一套依赖脚本 + 三套工具链**：库脚本只认 `CC CXX AR RANLIB STRIP CFLAGS LDFLAGS PREFIX`
和 `autotools_build` / `cmake_build` / `meson_build`，平台差异全部收敛在 `build-*.sh` 里。
改一个库只改一处。

---

## 6. 构建

### 本地（Windows / MSYS2 UCRT64）

```bash
pacman -S --needed base-devel mingw-w64-ucrt-x86_64-toolchain \
    mingw-w64-ucrt-x86_64-nasm mingw-w64-ucrt-x86_64-cmake \
    mingw-w64-ucrt-x86_64-meson mingw-w64-ucrt-x86_64-ninja \
    mingw-w64-ucrt-x86_64-pkgconf autoconf automake libtool python zip
./scripts/build-windows.sh
```

### 本地（Linux / musl）

```bash
docker run --rm -v "$PWD":/src -w /src alpine:3.20 sh -c '
  apk add --no-cache bash build-base linux-headers nasm cmake meson ninja \
      pkgconf perl autoconf automake libtool git curl python3 zip file binutils &&
  bash ./scripts/build-linux.sh'
```

### 本地（Android）

```bash
ANDROID_NDK_HOME=/opt/ndk-r25c ./scripts/build-android.sh armv7
ANDROID_NDK_HOME=/opt/ndk-r25c ./scripts/build-android.sh arm64
```

### CI

推送 / 手动触发即构建；打 `v*` tag 会把四个产物 + `SHA256SUMS.txt` 挂到 Release。

---

## 7. 构建期做了什么验证

光「编过了」不算数。每次构建都会跑：

1. **configure 回读断言** —— FFmpeg 的 `--enable-xxx` 找不到库时**不报错、只静默关掉**。
   所以 configure 之后必须回读 `config_components.h`：
   `CONFIG_LIBDAVS2_DECODER` / `CONFIG_LIBUAVS3D_DECODER` /
   `CONFIG_LIBUAVS3E_ENCODER` / `CONFIG_LIBXAVS2_ENCODER` 必须全为 1。
2. **冒烟测试（Windows / Linux）** —— `-codecs` 断言四个 AVS 编解码器带对应库名；
   然后用 `testsrc2` 真跑一次 `libuavs3e` 编码，再解回来核对。
3. **交叉产物结构验证（Android）** —— ARM 二进制在 x86 runner 上执行不了，
   所以改为静态取证：ELF 架构对不对、`NEEDED` 里有没有混进主机库、
   二进制里有没有 `libuavs3e` / `libdavs2` 符号。
4. **静态性验证（Linux）** —— `ldd` 必须是 `not a dynamic executable`。

---

## 8. 已知限制

| # | 限制 | 影响 |
|---|---|---|
| 1 | Android 需 NDK **r25c**（r26 起不支持 API 19） | 想升 NDK 就必须放弃 4.4.2 |
| 2 | NDK r24+ 的 armv7 sysroot 按 NEON 编译 | 无 NEON 的老芯片（部分 MTK/全志盒子）跑不起来 |
| 3 | davs2 的 10bit SIMD 只有 x86 版 | ARM 上走纯 C，解码慢 3~5 倍（结果正确） |
| 4 | x265 只有 8bit | 10bit HEVC 编码不可用 |
| 5 | xavs2 只有 8bit | AVS2 10bit 编码不可用（上游限制） |
| 6 | aom 官方源在国内常不可达 | 可选库，默认关闭，不影响 AVS |

---

## 9. 许可证

本项目为 **GPL v2**。产物包含 GPL v2 的 `x264` / `x265` / `davs2` / `xavs2`，
因此**产物整体按 GPL v2 分发**。打包时会自动附带 FFmpeg 源码树里的
`COPYING.GPLv2` 全文（不自己抄，保证与上游逐字一致）。

各依赖的许可证以其上游为准。`patches/libuavs3e.c` 源自 `LuoZijun/FFmpeg` 的
`patch-avs3` 分支，遵循其原始许可。
