# 技术文档 —— ffmpeg-avs-bin-6

FFmpeg **6.1.6** + AVS2/AVS3 完整编解码能力的静态构建系统。

本文档面向**维护者**：讲清楚这套构建脚本是怎么组织的、每个设计决策为什么这么定、
踩过哪些坑、改哪里会影响哪里。面向使用者的内容见 [README](../README.md)。

> **与 9.0.2 仓库（`ffmpeg-avs-bin-9`）的关系**：两仓脚本同源，
> 但**差异不止版本号**，见 [§11](#11-与-902-仓库的差异)。改代码前务必先读那一节。

---

## 目录

1. [整体架构](#1-整体架构)
2. [构建流程](#2-构建流程)
3. [基础设施层 lib.sh](#3-基础设施层-libsh)
4. [依赖体系](#4-依赖体系)
5. [AVS 四件套](#5-avs-四件套)
6. [FFmpeg 补丁机制](#6-ffmpeg-补丁机制)
7. [平台差异](#7-平台差异)
8. [CI 与发布](#8-ci-与发布)
9. [常见改动指引](#9-常见改动指引)
10. [已知陷阱清单](#10-已知陷阱清单)
11. [与 9.0.2 仓库的差异](#11-与-902-仓库的差异)
12. [附录：快速自检清单](#附录快速自检清单)

---

## 1. 整体架构

### 1.1 目录职责

```
ffmpeg-avs-bin-6/
├── scripts/
│   ├── env.sh              ★ 唯一版本源：所有外部依赖版本集中在这
│   ├── lib.sh              ★ 基础设施：fetch / autotools_build / edit_exact …
│   ├── build-common.sh     ★ 构建主流程 + 打包 + 冒烟测试
│   ├── build-<platform>.sh ★ 平台入口（windows / linux / android）
│   ├── build-ffmpeg.sh     ★ FFmpeg 本体 configure 参数 + 产物断言
│   ├── patch-ffmpeg.sh     ★ 给 FFmpeg 源码打 AVS3 编码器接线
│   ├── libs/               ★ 各第三方库的构建函数
│   │   ├── avs.sh          AVS 四件套（741 行，最复杂）
│   │   ├── video.sh        x264/x265/dav1d/vpx/aom/webp
│   │   ├── audio.sh        lame/ogg/vorbis/opus
│   │   └── misc.sh         zlib/openssl/freetype/fontconfig/…/硬件编码
│   ├── etr290.py           TR 101 290 体检
│   └── verify-urls.sh      依赖 URL 存活性检查
├── patches/
│   └── libuavs3e.c         AVS3 编码器的 FFmpeg 封装（326 行，上游没有）
├── .github/workflows/
│   └── build.yml           三平台构建 + tag 时发布
└── docs/TECHNICAL.md       本文档
```

### 1.2 分层原则

```
平台入口 (build-windows/linux/android.sh)
    ↓ 只负责：设 TARGET_OS / TARGET_ARCH / 工具链 / EXTRA_CFLAGS / EXTRA_LIBS
构建主流程 (build-common.sh::build_everything)
    ↓ 只负责：按依赖顺序调用各 build_xxx()
库构建函数 (libs/*.sh)
    ↓ 只负责：取源码 → 打补丁 → configure/build/install → require_pc 自检
基础设施 (lib.sh)
    ↓ 提供：fetch / autotools_build / meson_build / cmake_build / edit_exact …
```

**关键约定：新增一个库，只需改两处** —— `env.sh` 加一条 `DEPS`，`libs/*.sh` 加一个 `build_xxx()`，
然后在 `build-common.sh` 的对应位置调用（或在 `build_misc_all` 里）。

⚠️ **只在 `DEPS` 里登记、不写 `build_xxx()` 函数，这个库就永远不会被安装。**
这是本项目历史上真实踩过的坑（nvcodec/amf/libvpl 曾因此从未被构建，见 §10.1）。

---

## 2. 构建流程

### 2.1 执行顺序与理由

`build-common.sh::build_everything()` 的顺序**不是随意的**，依赖关系如下：

```
zlib ──> freetype ──> fontconfig ──> libass
openssl ──> srt
ogg ──> vorbis
freetype ──> harfbuzz ──> libass
AVS 四件套 ──> FFmpeg
```

实际执行顺序：

| 步骤 | 内容 | 为什么这个位置 |
|---|---|---|
| 1 | zlib, openssl | 几乎所有人依赖 |
| 2 | **AVS 四件套** | 本项目核心，尽早暴露问题 |
| 2.5 | `probe_avs_pc_links` | ★ 关键：模拟 configure 的链接测试，把「30 分钟后的失败」提前到 3 分钟 |
| 3 | 视频（x264/x265/dav1d/vpx） | |
| 4 | 音频 | |
| 5 | 字幕链 + 网络 + 平台专属 + 硬件编码 | |
| 6 | **FFmpeg 本体** | 最后 |

**2.5 步的价值**：`require_pkg_config` 在 configure 里排第 6 步，前面所有依赖都编完了。
如果某个 AVS 库静态链接缺符号，configure 只会吐一句 `xxx not found using pkg-config`，
看不出根因，而且白等 30 分钟。提前到第 2.5 步，3 分钟就能定位。

### 2.2 单个库的构建范式

```bash
build_foo() {
  dep_needed foo || return 0          # 平台/开关过滤
  local dir; dir="$(fetch foo)"       # 下载 + 解包，返回源码目录
  # （按需）edit_exact 打补丁
  autotools_build "$dir" foo --disable-shared --enable-static
  require_pc foo                      # 装完立刻验证 .pc 能被识别
}
```

`require_pc` 是**强制自检**：装完立刻用 pkg-config 查一遍。
少了这步，问题会推迟到 configure 阶段才暴露。

### 2.3 打包

`package_output()`：

- 只打 zip（MSYS2 / Alpine / Ubuntu 三处都有 `zip`，7z/tar.xz 可用性不一致）
- **strip 在打包时做**，不在编译期（`--disable-stripping`）—— 编译失败时还能拿到带符号的二进制定位
- **许可证必须随包**：GPL 分发的硬要求。协议全文从 FFmpeg 源码树直接拷，保证与上游逐字一致
- ⚠️ 协议版本要跟实际配置一致：开了 `--enable-version3` 就必须附 GPLv3，
  只附 GPLv2 是错的（`package_output` 里会检测 `FF_ARGS` 自动选择）

---

## 3. 基础设施层 lib.sh

### 3.1 核心函数

| 函数 | 作用 | 注意点 |
|---|---|---|
| `fetch <name>` | 按 `DEPS` 规格下载/解包，返回源码目录 | 支持 `tar` 和 `git` 两种；git 类型带重试 |
| `autotools_build` | configure + make + install | 自动处理 `autoreconf`（GitHub 归档的 tarball 常缺 configure） |
| `meson_build` | meson setup + ninja + install | 固定 `--default-library=static` |
| `cmake_build` | cmake + make + install | 自动带 `CMAKE_POLICY_VERSION_MINIMUM`（CMake 4.x 兼容） |
| `custom_configure` | 只要 configure 不要 install | 给自行处理 install 的库用 |
| `edit_exact <file> <old> <new>` | ★ 精确文本替换 | 见 §3.2 |
| `require_pc <name>` | 装完立刻验证 .pc | 失败即 die |
| `pc_ensure_version` | 检查 .pc 版本号是否达标 | |
| `install_static_lib` / `install_header` | 手工安装（无 Makefile install 目标的库） | |

### 3.2 edit_exact —— 补丁机制的核心

```bash
edit_exact "$file" '旧内容' '新内容'
```

**语义**：`旧内容` 必须在文件里**精确出现且只出现 1 次**，否则 die。

**为什么不直接用 `patch(1)`**：

| | patch(1) | edit_exact |
|---|---|---|
| 上游改了一行 | 模糊匹配可能偏移 | 精确匹配，立刻失败 |
| 锚点不存在 | `-N` 模式下静默跳过 | 立刻 die |
| 产物状态 | 可能「看起来打了其实没打」 | 要么打上要么停 |

「静默打不上」是最危险的：构建能过，产物功能缺失，只有人工验证才发现。

**配合的辅助函数**：

- `edit_crlf` —— 给 CRLF 行尾的文件用。`edit_exact` 按 `\n` 比对，
  CRLF 文件里的锚点永远匹配不上（xavs2 源码就是 CRLF）

⚠️ **6 仓没有 `local-verify-patch.sh`**。改锚点后只能推 CI 验证（约 50 分钟）。
如需本地快速校验，可从 9 仓拷这个脚本过来（它不依赖版本，只需改期望的锚点数）。

### 3.3 fetch 的重试逻辑

```bash
for ca in 1 2 3; do
  git clone --quiet "$url" "$dir" && break
  warn "$name: 克隆第 $ca 次失败，重试…"
  rm -rf "$dir"
  [ "$ca" = "3" ] && die "..."
done
```

**为什么要重试**：x264 从 `code.videolan.org` 拉，跨洲链路偶发超时。
一次抖动就让 20 分钟的 linux 构建报废。实测 `v6.1.6-avs.3` 第一次打 tag 就栽在这。

---

## 4. 依赖体系

### 4.1 env.sh 的结构

```bash
DEPS=(
  "name|kind|url|ref"
  ...
)
```

- `kind`：`tar` 或 `git`
- `ref`：tar 忽略；git 填分支/标签/commit
- 想临时覆盖版本：`FFMPEG_VERSION=6.1.5 ./scripts/build-linux.sh`

### 4.2 平台裁剪

```bash
WINDOWS_ONLY_DEPS="nvcodec amf libvpl sdl2"
```

`dep_needed <name>` 会据此过滤。Linux/Android 上这些库编了也用不到，白等时间。

### 4.3 可选库

```bash
ENABLE_SVTAV1 / ENABLE_AOM / ENABLE_WEBP   # 默认全 0
```

默认关闭的原因：aom 官方源在国内常不可达，svtav1/webp 用户需求低。
真编不过就保持关闭，不影响 AVS 能力。

### 4.4 依赖清单分组

| 组 | 内容 | 备注 |
|---|---|---|
| FFmpeg 本体 | ffmpeg | 版本由 `FFMPEG_VERSION` 控制 |
| **AVS 家族** | davs2 / xavs2 / uavs3d / uavs3e | 本项目核心，见 §5 |
| 视频 | x264 / x265 / dav1d / libvpx | x265 只有 8bit |
| 音频 | lame / ogg / vorbis / opus | |
| 基础 | zlib / openssl / expat | openssl 3.x 强制 `--enable-version3` |
| 字幕 | freetype / fribidi / harfbuzz / libass / fontconfig | fontconfig 仅非 Windows |
| 图像/缩放 | zimg | |
| 网络 | srt | |
| Windows 专属 | nvcodec / libvpl / amf / sdl2 | 见 §7.2 |

⚠️ **本仓没有 pixman / cairo** —— FFmpeg 6.1 主线没有 drawvg 滤镜，装了也用不到。见 §11。

---

## 5. AVS 四件套

这是本项目存在的理由。四个库都有「上游没做」或「上游做错了」的地方，
全部通过 `edit_exact` 在构建时打补丁修正。

### 5.1 davs2 —— AVS2 解码（10bit）

| 项 | 内容 |
|---|---|
| 上游 | `xatabhk/davs2-10bit`（不是 pkuvcl 官方） |
| 关键改动 | 放开 `build/linux/configure` 的位深限制 |
| 为什么 | 官方 davs2 是**编译期单一位深**，`--bit-depth=9/10` 直接 `exit 1`。`xatabhk` 分支改了源码但没改 configure |
| 额外 | 10bit SIMD 例程的 `min/max` 未限定命名空间，需补 `std::` |
| 平台差异 | **ARM 没有 10bit 汇编**（`source/common` 下只有 x86 和 vec），走纯 C，慢 3~5 倍但结果正确 |

**色彩透出**（本项目自己加的，不在上游）：davs2 从不读「序列显示扩展」里的色彩描述，
补丁让它把 `colour_description` 填进 `AVCodecContext`。详见源码开头那段注释。

### 5.2 xavs2 —— AVS2 编码

| 项 | 内容 |
|---|---|
| 版本 | 1.4（tar） |
| 限制 | **只有 8bit**，上游硬限制，不是我们的选择 |
| 注意 | 源码是 **CRLF 行尾**，多行锚点必须用 `edit_crlf` |
| 构建 | 用 `custom_configure` + `make install-lib-static install-lib-dev`（不用标准 install） |

### 5.3 uavs3d —— AVS3 解码（10bit）

**三个必改点**（都是「上游没做」而非「上游做错了」）：

1. **位深是编译期的**：`com_def.h` 的 `BIT_DEPTH` 决定 pel 类型。
   README 明写「要解 10bit 就把 BIT_DEPTH 改成 10」。
   ⚠️ 原来传的 `-DCOMPILE_10BIT=ON` 是**无人引用的变量**，cmake 只警告
   unused —— 也就是说之前编出来的其实是 8bit-only。
   改成 10bit 后是**超集**：`bit_depth_internal` 由码流决定，8/10bit 都能解。

2. **`source/CMakeLists.txt` 无条件把 x86 的 sse/avx2 目录加进目标**，
   ARM 上会拿 x86 intrinsics 编 ARM（NDK clang 直接 20 个 error）。需要按架构裁剪。

3. **ARM 的 NEON 汇编不能做通用 10bit 解码**：`def_arm64.S` 里写死
   `#define COMPILE_10BIT 0`，8bit 分支用 `.16b/u8`、10bit 分支用 `.8h/s16`，
   是**编译期二选一**。所以 ARM 上关掉 NEON 汇编走纯 C，代价是慢 2~4 倍。

### 5.4 uavs3e —— AVS3 编码

| 项 | 内容 |
|---|---|
| 上游 | `uavs3/uavs3e` master |
| 关键改动 | 三个：CMake 最低版本、ARM 的 x86 源文件、`com_api.h` 的门控 |
| 为什么 CMake | `cmake_minimum_required(VERSION 2.8)`，CMake 4.x 移除了 <3.5 兼容，直接报错 |
| 为什么 com_api.h | 用 `#if defined(__linux__)` 门控 10bit，**MinGW 上把 COMPILE_10BIT 强制归零** —— Windows 不打这个补丁就只有 8bit |

**这是唯一需要给 FFmpeg 打补丁的库**，见 §6。

---

## 6. FFmpeg 补丁机制

### 6.1 为什么必须打补丁

AVS3 编码器 `libuavs3e` **至今仍未进入 FFmpeg 主线**：
6.1.6 的 `EXTERNAL_LIBRARY_LIST` 里只有 `libdavs2 / libuavs3d / libxavs / libxavs2`，
没有任何 `uavs3e` 字样。

所以要自己做两件事：

1. **写封装**：`patches/libuavs3e.c`（326 行）—— 一个完整的 `AVCodec` 实现
2. **接线**：把新编解码器登记进 FFmpeg 的构建系统

### 6.2 六处接线

`patch-ffmpeg.sh` 打的补丁（全部用 `edit_exact`，锚点必须精确命中 1 次）。

> 下表的文件路径都是 **FFmpeg 源码树内部**的相对路径（`$FF_DIR/` 下），不是本仓库的文件。

| # | 文件 | 内容 |
|---|---|---|
| 1 | `configure` | `EXTERNAL_LIBRARY_LIST` 加 `libuavs3e` |
| 2 | `configure` | `EXTERNAL_LIBRARY_VERSION_LIST` 加版本 |
| 3 | `configure` | 依赖检测 `require_pkg_config libuavs3e ...` |
| 4 | `configure` | 编码器声明 `libuavs3e_encoder_deps="libuavs3e"` |
| 5 | `libavcodec/Makefile` | `OBJS-$(CONFIG_LIBUAVS3E_ENCODER) += libuavs3e.o` |
| 6 | `libavcodec/allcodecs.c` | `extern const FFCodec ff_libuavs3e_encoder;` |

此外还有 **2 处 `libdavs2.c`** 的色彩搬运补丁（见 §5.1）。

### 6.3 版本护栏

```bash
case "${FFMPEG_VERSION}" in
  6.*) ;;
  *) die "AVS3 补丁只在 FFmpeg 6.x 验证过（当前 ${FFMPEG_VERSION}）。
          跨大版本必须先重新核对锚点并移植 libuavs3e.c。" ;;
esac
```

跨大版本（比如 6.1 → 7.0）时的风险：

- `configure` 的锚点可能漂移
- `libuavs3e.c` 用的 `AVCodec` 字段布局可能变（9.0 就移除了 `.pix_fmts`）
- `FF_API_*` 系列的 `#if` 可能跳空或报错

⚠️ **本仓没有 `local-verify-patch.sh`**，改锚点只能推 CI 验证。建议从 9 仓拷一份。

### 6.4 VERSION 文件

```bash
printf '%s\n' "$FFMPEG_VERSION" > "$FF_DIR/VERSION"
```

**为什么需要**（`ffbuild/version.sh` 指 FFmpeg 源码树里的脚本，不是本仓库的）：

GitHub 的 tag tarball 里既没有 `VERSION` 也没有 `.git`，
而 `ffbuild/version.sh` 第一个动作是 `git describe --tags --always`。
在「没有 .git 的子目录」里跑这句，git 会**向父目录逐级查找** ——
在 Actions 里正好命中本项目仓库的 `.git`，产物版本串变成我们的 commit sha
（实测 `ffmpeg version daff97d`，完全看不出是哪个 FFmpeg 版本）。

`version.sh` 里 `version=$(cat VERSION)` 的优先级高于 revision，写一个就压住。

---

## 7. 平台差异

### 7.1 三平台入口

| 平台 | 工具链 | 关键设置 |
|---|---|---|
| **Windows** | MSYS2 UCRT64 + MinGW-w64 GCC | `EXE=.exe`、`EXTRA_LIBS` 带一堆 win32 系统库 |
| **Linux** | Alpine 容器（musl）+ gcc | 全静态（`-static`） |
| **Android** | NDK r25c | armv7→API19、arm64→API21 |

### 7.2 硬件编码（Windows 专属）

三个库 + 一个坑：

| 库 | 产物 | 注意 |
|---|---|---|
| `nvcodec` | `ffnvcodec.pc` | 只有头文件，无库。实现在 NVIDIA 驱动里，运行时动态加载 |
| `libvpl` | **`vpl.pc`**（不是 libvpl.pc） | configure 里写的是 `check_pkg_config libmfx "vpl >= 2.6"` |
| `amf` | 无 .pc，只有头文件 | configure 检查 `AMF/core/Version.h` |

**AMF 版本门槛（本仓 = 6.1.6 的要求，比 9.0 宽松）**：

```
(MAJOR << 48 | MINOR << 32 | RELEASE << 16 | BUILD) >= 0x00010004001d0000
即 MINOR >= 4 且 RELEASE >= 0x1d (29)
```

| 版本 | 计算值 | 6.1.6 | 9.0.2 |
|---|---|---|---|
| 1.4.33 | `0x1000400210000` | ✅ 过 | ❌ 不过（MINOR<5） |
| 1.5.0 | `0x1000500000000` | ✅ 过 | ❌ 不过（RELEASE 位不够） |
| 1.5.2 | `0x1000500020000` | ✅ 过 | ✅ 过 |

**本仓用 1.4.33**（已满足 6.1.6），9 仓必须用 1.5.2。这是刻意不同，不是漏同步。

`build_amf` 里的版本断言会按 `FFMPEG_VERSION` 自动选门槛：

```bash
case "${FFMPEG_VERSION:-}" in
  6.*) need=0x10004001d0000 ;;
  *)   need=0x1000500020000 ;;
esac
```

⚠️ **若两仓脚本将来合并，这段分支必须保留**，否则 6 仓会误报、9 仓会放行旧版。

**libvpl 的 MinGW 补丁**：`mfx_dispatcher_defs.h` 里
`#if _MSC_VER < 1400` 这个判断，MinGW 不定义 `_MSC_VER` 会被当成 0，
走进一个坏掉的多行宏分支，语法直接崩。上游 2.13/2.14/2.15 都没修。

### 7.3 支持的 Android 版本

| ABI | 最低 API | 最低系统 | 产物包 |
|---|---|---|---|
| `armeabi-v7a` | **19** | Android **4.4 KitKat**（含 4.4.2） | `…-android-armv7-api19.zip` |
| `arm64-v8a` | **21** | Android 5.0 Lollipop | `…-android-arm64-api21.zip` |

**为什么停在 API 19**：NDK r26 起官方移除 KitKat 支持，r25c 是最后一个还能编 4.4 的。
再往下要退到 r23 以前、垫片工作量翻倍，而 armv7 + API 19 已覆盖存量老机。
arm64 从 5.0 才存在，所以是 21，不是「选择」而是客观下限。

**产物二进制实测**（解压 release 包验证，两仓一致）：

```
.note.android.ident  ->  api_level = 19
ELF                  ->  32-bit ARM, type=DYN (PIE)
PT_INTERP            ->  /system/bin/linker          # 32 位链接器，4.4 就是这个路径
NEEDED               ->  libm.so, libc.so, libdl.so  # 全是 4.4 自带
```

`NEEDED` 只有三个系统库、其余全部静态链进去 ⇒ 不挑系统版本，也不要求设备上
有 `libc++_shared.so`。**只出 armv7/arm64，没有 x86/x86_64 包**，
Intel 芯安卓设备（ZenFone 那批）用不了。

### 7.4 Android 特殊处理

| 机制 | 说明 |
|---|---|
| `api19_compat.c` | 495 行垫片，补 13 个 bionic 到 API 21 才提供的符号（清单见下） |
| `-DHB_NO_SETLOCALE` | API<21 时关掉 harfbuzz 对 newlocale/freelocale/uselocale 的调用 |
| `--disable-iconv` | API 19 的 bionic 没有 iconv，留着会让 configure 探测出一堆假阳性 |
| `fix_android_pc_files` | 修 .pc 里的绝对路径和 `-L` 顺序 |
| `scan_avs_deplib` | 扫 MSVC 残留的 `/DEPENDENTLOADFLAG` 之类指令，只有 NDK 的 lld 会当真 |
| `verify_cross_binary` | 交叉编译产物不能跑，改用 `file` + `readelf` + `strings` 静态取证 |

**能落到 API 19 靠三层，缺任一层 armv7 包都编不出来**：

1. **`libc++_static.a` 是按 API 21 编的**。NDK r25c 的 `locale.o` 直接引用
   `mbsnrtowcs` / `mbtowc` / `localeconv` / `strtoll_l` / `strtoull_l` /
   `strtold_l` / `wcstoll` / `wcstoull` / `wcstof` 九个符号，API 19 上没有 → 链接失败。
   垫片给最小实现（bionic 只有 `"C"` locale，语义可放心简化）。另外还补了
   `newlocale` / `freelocale` / `uselocale` / `mbsinit`，共 13 个。
2. **harfbuzz 也会调 `newlocale` / `freelocale` / `uselocale`**，而垫片只挂在
   **FFmpeg** 的 `--extra-libs` 上，不参与依赖库自己的构建 —— harfbuzz 由 meson
   独立编译、独立链接，够不到垫片。meson 的 `has_function` 探测用通用 stub 能过，
   按 API 19 真链才炸，所以只能在源码层用官方开关 `HB_NO_SETLOCALE` 绕开 ——
   它把 `hb_locale_t` 定义成 `void *` 后连参数都不展开，比补符号更干净。
3. **垫片必须挂在 `--extra-libs` 的最后**，即在 `-lc++_static` 之后。
   否则 `locale.o` 的未定义引用还没出现，链接器不会去拉它。

垫片**故意不 include 任何系统头文件**：NDK unified header 里这些函数带
`__INTRODUCED_IN(21)`，在 `__ANDROID_API__ < 21` 的编译单元里一提到就报
`is unavailable: introduced in Android 21`。所以它自带类型、参数只用指针和定宽整数，
与真实原型 ABI 一致。只在 API<21 时编译，arm64 用不到。

**为什么不能跑 smoke_test**：ARM 二进制在 x86 runner 上会 `Exec format error`，
看起来像构建失败。`verify_cross_binary` 改查：
ELF 架构 / NEEDED 里有无非 bionic 库 / AVS 符号是否链进去。

⚠️ **没有在真机 4.4.2 上验证过**。CI 只能做到结构取证，要真验证得
`adb push` 到 `/data/local/tmp`、`chmod 755`、跑 `./ffmpeg -version`。

---

## 8. CI 与发布

### 8.1 build.yml 结构

```
windows (windows-latest, MSYS2)  ┐
linux   (ubuntu-latest, Alpine)  ├─→ release (仅 tag 触发)
android-arm64 / armv7 (NDK)      ┘
```

**并发控制**：

```yaml
concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true
```

⚠️ **main 上还有运行在跑时再推 main，旧运行立刻 cancelled**。
想连推两次 → 先等前一轮结束，或提交信息带 `[skip ci]`。

### 8.2 耗时基线

| job | 单独跑 | 两仓同时跑（run#41164830785 实测） |
|---|---|---|
| windows | 46~52 min | **53 min** |
| linux | 13~20 min | **18 min** |
| android-arm64 | 6~7 min | **6 min** |
| android-armv7 | 6~10 min | **8 min** |

两仓同时跑会抢 CPU，windows 从 46 涨到 58 min（9 仓那边涨得更明显）。
一批全绿要等 **50 分钟出头**，别在 20 分钟时就怀疑卡住。

### 8.3 产物断言

`build-ffmpeg.sh::assert_config` 在 configure 之后检查 `config_components.h`，
确认 **14 项**关键能力真的被启用：

```
AVS：  LIBDAVS2_DECODER / LIBUAVS3D_DECODER / LIBUAVS3E_ENCODER / LIBXAVS2_ENCODER
硬件： FFNVCODEC / NVENC / NVDEC / CUVID / H264_NVENC_ENCODER
       LIBVPL / QSV / H264_QSV_ENCODER / AMF / H264_AMF_ENCODER
```

（9 仓多两条：`CAIRO` / `DRAWVG_FILTER`）

**为什么需要**：configure 会静默 disable 不满足条件的项。参数加了不代表真开成了。

### 8.4 发布流程

```bash
# 1. 确认 main 全绿（必须！tag 打在没验证的提交上会白等一轮）
# 2. 打附注 tag
git tag -a v6.1.6-avs.N -F -   # 消息会成为 release notes
# 3. 推送
git push origin v6.1.6-avs.N
```

`generate_release_notes: true` 会从 tag 消息自动生成说明。

⚠️ **tag 必须指向已验证的提交**。核对方法：
```bash
git rev-parse <tag>^{commit}   # 与 git rev-parse HEAD 比对
```

---

## 9. 常见改动指引

### 9.1 升级 FFmpeg 小版本（6.1.6 → 6.1.7）

```bash
# 1. 改 env.sh
FFMPEG_VERSION="${FFMPEG_VERSION:-6.1.7}"

# 2. 直接推 main 验证（本仓没有 local-verify-patch.sh）
# 3. 若锚点失配，按 CI 报错改 patch-ffmpeg.sh 里的 edit_exact
# 4. 全绿后再打 tag
```

小版本升级通常锚点不变，但**务必确认** `EXTERNAL_LIBRARY_LIST` 里
是否还没收录 `libuavs3e`（若已收录，补丁可以删）。

### 9.2 升级到 7.x / 8.x / 9.x（大版本）

**高风险**，必须先评估：

1. `configure` 锚点几乎肯定漂移
2. `patches/libuavs3e.c` 用的 `AVCodec` 字段可能被移走
   （9.0 把 `.pix_fmts` 搬进了 `FFCodec` 的匿名 union，只能用 `CODEC_PIXFMTS` 宏）
3. `FF_API_CODED_FRAME` 之类可能在 `#if` 判断后跳空或报错

**推荐做法**：不要在本仓硬升，直接参考 9 仓（`ffmpeg-avs-bin-9`）
—— 那边已经把 9.0.2 跑通了，`patches/libuavs3e.c` 已适配新 API。

### 9.3 新增一个依赖库

```bash
# 1. env.sh 的 DEPS 加一行
"foo|tar|https://.../foo-1.2.3.tar.gz|"

# 2. libs/misc.sh（或对应分类）加函数
build_foo() {
  dep_needed foo || return 0
  local dir; dir="$(fetch foo)"
  autotools_build "$dir" foo --disable-shared --enable-static
  require_pc foo
}

# 3. build-common.sh 的 build_everything 里按依赖顺序调用
# 4. build-ffmpeg.sh 里 _enable_if_pc foo --enable-libfoo
# 5. build-ffmpeg.sh 的 assert_config 里加一条断言
```

**第 5 步不能省** —— 不加断言，库没装成也看不出来。

### 9.4 修改 AVS 补丁

改 `patch-ffmpeg.sh` 里的 `edit_exact` 锚点后，本仓只能推 CI 验证。
**建议先跑一次 9 仓的 `local-verify-patch.sh`**（如果两仓版本不同则需改期望锚点）。
3 秒 vs 50 分钟，值得。

---

## 10. 已知陷阱清单

按踩坑时间排序，每条都是真实发生过的。

### 10.1 DEPS 登记了但没有 build 函数 ⇒ 库永远不会被安装

**现象**：构建全绿，产物里 `ffmpeg -encoders | grep nvenc` 是 0 条。

**原因**：`DEPS` 只管下载清单和缓存 key，真正构建靠 `build_xxx()` 函数。
函数不存在 → `_have_pc` 探测必然失败 → 一路 WARN 跳过 → 构建照样成功。

**修复**：补函数 + 把 warn 改成 die + 加 `assert_config` 断言。

**教训**：安静型故障比构建失败更难发现。改动依赖清单后，
必须用 `ffmpeg -encoders | grep xxx` 人工数一遍。

### 10.2 AMF 版本不达标会伪装成「找不到」

**现象**：`ERROR: amf requested but not found`，看起来像头文件没装。

**真实原因**：configure 的 `check_cpp_condition` 检查版本号，不达标就
`disable amf`，然后 `requested && !enabled` 触发 die，报出上面那句误导性信息。

**排查方法**：看 configure 里 `enabled amf &&` 后面那行十六进制数，
自己按 `(MAJOR<<48 | MINOR<<32 | RELEASE<<16 | BUILD)` 算一遍。

⚠️ **6.1.6 的门槛比 9.0 低**，1.4.33 在这边够用，在 9.0 那边不够。

### 10.3 MSYS2 的 pkgconf 会吞掉 Cflags 里的 `-D`

**现象**：`.pc` 里明明写了 `-DXXX`，但 `pkg-config --cflags` 的输出里没有它。

**绕过**：放到 `build-windows.sh` 的 `EXTRA_CFLAGS` 里全局传。

**排查方法**：把 `pkg-config --cflags` 的原始输出打进日志。靠推断极低效，
打出来一行就看到。

（本仓目前没有需要这个机制的库；9 仓给 cairo 用过。）

### 10.4 Python 在 MSYS2 下输出中文会崩

**现象**：`UnicodeEncodeError: 'charmap' codec can't encode characters`，
整个构建被一行提示语打挂。

**原因**：MSYS2 的 Python 默认 stdout 编码是 cp1252。

**规则**：`scripts/` 下所有 `<<'PY'` 块里**禁止 print 中文**。
需要提示就交给 bash 侧的 `ok`/`warn`。

**回归检查**：
```bash
python3 -c "
import re,pathlib
for p in pathlib.Path('scripts').rglob('*.sh'):
    for m in re.finditer(r\"<<'PY'\n(.*?)\nPY\", p.read_text(encoding='utf-8'), re.S):
        for ln in m.group(1).splitlines():
            if re.search(r'print\s*\(', ln) and re.search(r'[\u4e00-\u9fff]', ln):
                print('高危:', p, ln.strip())
"
```

### 10.5 pacman 半装状态会被 `--needed` 跳过

**现象**：`gcc.exe: fatal error: cannot execute 'cc1obj'`，
或 `stdbit.h: No such file`，最后报一句完全无关的
`ERROR: amf requested but not found`。

**原因**：网络中断留下的半装状态，`pacman -S --needed` 认为「已装」就跳过。

**修复思路**：装完做真编译探针（`gcc probe.c`），失败则
`pacman -S --overwrite '/'` 强制重装。

⚠️ **`stdbit.h` 不存在是正常的**（GCC 主线没有，FFmpeg 有 compat fallback），
别拿它当完整性判据。

⚠️ **本仓的 `build.yml` 还没有这个探针**（9 仓已加）。MSYS2 装包失败时，
本仓会以误导性的 configure 报错收场。若遇到，先查「安装 MSYS2 工具链」那一步的日志。

### 10.6 tag 不能打在未验证的提交上

**实测**：`v6.1.6-avs.3` 第一版打在重试修复**之前**的提交上，
linux 因 x264 网络抖动挂掉，只能删 tag 重打（本地 + 远端都要删）。

**核对方法**：
```bash
git rev-parse <tag>^{commit}   # 必须等于 git rev-parse HEAD
```

### 10.7 冒烟测试不要锚定标志位列

```bash
# 错：一旦 avs3 有了编码器，标志位从 D.V.L. 变成 DEV.L.，列宽变了就误判
grep 'D.V.L.' 

# 对：只证明「这一行里出现了某个库名」
grep -E '[[:space:]]avs3[[:space:]]' | grep -q 'libuavs3e'
```

### 10.8 段错误时不要用管道吞输出

```bash
# 错：段错误时管道把一切都吞掉，日志只剩 "exit code 139"
"$bin" ... 2>&1 | wc -l

# 对：落盘 + 显式查退出码
"$bin" ... >"$log" 2>&1 || rc=$?
```

---

## 11. 与 9.0.2 仓库的差异

两仓脚本同源，但**差异不止版本号**。以下是完整清单：

| 项 | 本仓（6.1.6） | `ffmpeg-avs-bin-9`（9.0.2） | 原因 |
|---|---|---|---|
| `FFMPEG_VERSION` | 6.1.6 | 9.0.2 | 主线不同 |
| **drawvg 滤镜** | ❌ 无 | ✅ 有 | **6.1 主线 configure 里没有 drawvg** |
| **pixman / cairo** | ❌ 不构建 | ✅ 构建 | 同上，装了 cairo 也无用武之地 |
| **AMF 版本** | 1.4.33 | 1.5.2 | 门槛不同（6.1 要 MINOR>=4 且 REL>=29；9.0 要 MINOR>=5） |
| **版本护栏** | `case 6.*` | `case 9.*` | 各自主线 |
| **上游巡检** | ❌ 无 | ✅ `watch-upstream.yml` | 6.1 是 EOL 主线，巡检无意义 |
| **本地锚点校验** | ❌ 无 | ✅ `local-verify-patch.sh` | 9 仓开发时补的工具 |
| `patch-ffmpeg.sh` | `6.*` 分支 | `9.*` 分支 | |
| `libuavs3e.c` | 326 行 | 342 行 | 9 仓适配了 `CODEC_PIXFMTS` 等新 API |
| `avs.sh` | 741 行 | 741 行 | 内容有差异但行数相同（修重复标题后） |

### ⚠️ 不要做的事

以下三件**看起来像漏同步，实际是刻意不同**，别去「修复」：

1. **不要给 6 仓加 cairo / pixman** —— 6.1 没有 drawvg，加了纯浪费构建时间
2. **不要把 6 仓的 AMF 升到 1.5.2** —— 1.4.33 已满足 6.1.6，没必要
3. **不要给 6 仓加 watch-upstream** —— 6.1 已 EOL，没有新版本可追

### 反过来：可以考虑从 9 仓搬运的

1. **`local-verify-patch.sh`** —— 纯收益，改锚点时省 45 分钟
2. **`build.yml` 的工具链完整性探针** —— 防 pacman 半装状态
3. **`patches/libuavs3e.c` 的 `CODEC_PIXFMTS` 兼容写法** —— 虽然 6.1 用不到，
   但用 `#if defined(CODEC_PIXFMTS)` 分流后一份源码通吃，便于将来升级

---

## 附录：快速自检清单

改动后的必做检查：

- [ ] `bash -n` 所有改过的脚本
- [ ] 改了 `patch-ffmpeg.sh` → **推 CI 前最好借 9 仓的 `local-verify-patch.sh` 跑一遍**
- [ ] 加了依赖 → `env.sh` 有 `DEPS` 条目 **且** 有 `build_xxx()` 函数
- [ ] 新增能力 → `build-ffmpeg.sh` 有 `assert_config` 断言
- [ ] 改了 python 块 → 无中文 print
- [ ] 打了 tag → `git rev-parse <tag>^{commit}` 等于 HEAD
- [ ] 发布后 → 下载产物用 `ffmpeg -encoders | grep` 人工核对一遍
- [ ] 改动涉及 §11 表格里那几项 → 确认是**有意的**，不是误改
