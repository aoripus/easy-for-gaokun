# 软件视频解码方案：无 VPU 下怎么把视频放流畅（GK-W76 / SC8280XP）

> 前提不在本文重复：**本机的 IRIS VPU 尚未打通**，无 `/dev/video*`，归因与逐寄存器证据见
> [`video-decode.md`](./video-decode.md) 与 [`../patches/iris-el2/README.md`](../patches/iris-el2/README.md)。
> ⚠️ 注意：**EL2 本身不是原因** —— Lenovo X13s（同为 SC8280XP）已在 EL2 下跑通 iris；
> 本机的问题是设备特有的，仍在调查中。所以本文的软解方案是**保底方案**，一旦硬解打通即可弃用。
> 置信度：【已核实】= 官方文档/源码/一手实测；【社区报告】= 用户实测；【推测】= 外推估算。引用编号见 §6，均为本次调研实际抓取的页面。

## 1. 解码库走哪条路

### 1.1 唯一可用路径：libavcodec / dav1d 纯软解【已核实】

FFmpeg 的 libavcodec（H.264/VP8/VP9 + NEON 汇编）与 dav1d（AV1）是唯一现实的解码后端；mpv、Firefox、Chromium（各自带一份 `libffmpeg.so`）、GStreamer 都只是它的前端。要做的只有三件事：别让播放器在硬解上白费功夫、线程数给够、把缩放/色彩/胶片颗粒交给 GPU。

### 1.2 没有"软件 VA-API"这回事 —— 别装 vaapi / vdpau / v4l2m2m【已核实】

- Mesa 的 VA-API 后端只编出 5 个驱动：`r600 / radeonsi / nouveau / virtio_gpu / d3d12`，**没有 Adreno/freedreno，也没有 llvmpipe/softpipe** [S1][S2]；libva 本身只是 API 与 vendor 驱动壳，不含任何解码器。→ 本机 `vainfo` 必然为空或报错，`LIBVA_DRIVER_NAME` 换任何名字都没用。
- Mesa 的 `virtio_gpu`（virgl）VA 驱动只在**虚拟机里**把解码转给宿主机的真硬解 [S2]；llvmpipe/softpipe 不实现 PIPE_VIDEO。裸机上这两条都是死路。
- `v4l2m2m` 是 V4L2 的 mem2mem **硬解**接口，必须有真实编解码节点；本机没有。V4L2 里唯一的"软件编解码器"是 vicodec，而它是**虚拟测试编解码器**（Kconfig 原文："Driver for a Virtual Codec … emulating a hardware codec"），不解 H.264/VP9/AV1 [S3]。

### 1.3 Adreno 690 能帮上什么：不解码，但很值得用【已核实】

- **解码完全帮不上**：Adreno 上的视频块就是 IRIS/VPU 本体（固件 + PAS 路径）；freedreno 不实现 PIPE_VIDEO，Turnip 也不暴露任何 `VK_KHR_video_decode_*`。Mesa 的 VA 驱动清单里没有 Adreno 是最直接的旁证 [S2]。
- **后处理可以帮很多**：`--vo=gpu-next`（libplacebo）把 1080p→2560×1600 缩放、YUV→RGB、色调映射都放 GPU；AV1 的 film grain 可交 GPU，mpv 手册原文："If video decoding is done on the CPU, doing film grain application on the GPU can speed up decoding." [S4]

### 1.4 现代浏览器在 arm64 + Wayland 上能否软解【已核实】

| 格式 | Firefox | Chromium（Ubuntu snap） | 本机可行性 |
|---|---|---|---|
| H.264 | 内置 libavcodec（`media.ffmpeg.enabled=true`）[S5] | 上游 Chromium **不含** H.264/AAC [S6]；**Ubuntu snap 自带含 H.264 的 libffmpeg.so** [S7] | ★ 主力：1080p60 都能扛 |
| VP9 | 可以（ffvpx/libavcodec）[S5] | 可以（自带 libvpx）[S6] | 1080p 可用，比 H.264 贵 |
| AV1 | dav1d（`media.av1.enabled`、`media.av1.use-dav1d` 默认均为 true）[S5] | dav1d（构建开关 `ENABLE_DAV1D_DECODER`）[S6] | 1080p 勉强可行、更耗电 |
| HEVC | Linux 无平台解码器则不软解【推测】 | 仅平台解码器（`PlatformHEVCDecoderSupport`）[S6] | 避开 |
| 4K AV1 | 能放但不划算 | 同 | **放弃** |

### 1.5 1080p 软解性能量级（4×Cortex-X1 @3.0 + 4×A78）

可直接引用的锚点：

- **H.264**：Pi 4B（4×A72@1.5GHz）用 ffmpeg **软件**解码 1920×1080 得 **108 fps**（≈27 fps/核），720p 243 fps [S8]。
- **AV1**：dav1d 官方称"手机小核 2 线程即可把 Chimera 解到 24fps""**1080p 用两三个核就够**"（Pixel 1 / SD821，2016）[S9]。
- **缺口**：ARM 上的 VP9 / H.265 软解无可信实测；X13s（同 SC8280XP）Ubuntu 主帖 348 帖全文检索确认**没有任何 fps / CPU 占用数据** [S10]。下表为【推测，置信度中】。

| 场景 | 估算（4 大核合计） | 判定 |
|---|---|---|
| 1080p30 H.264 | 0.3–0.6 核 | 轻松，可同时开浏览器 |
| 1080p60 H.264 | 0.8–1.5 核 | 舒适 |
| 1080p60 VP9 | 1.5–2.5 核 | 可行，更耗电 |
| 1080p60 AV1（dav1d） | 2–4 核 | 余量薄，带 film grain 可能跌破 |
| 4K60 AV1 | ≥8 核当量 | **做不到** |

上机实测（跑完即可把上表从【推测】升级为【已核实】）：

```sh
for f in h264.mp4 vp9.webm av1.mkv; do
  echo "== $f"; ffmpeg -benchmark -i "$f" -f null - 2>&1 | tail -2   # 看 fps=
done
```

## 2. 可直接抄的配置（Ubuntu 26.04 + Wayland）

### 2.1 mpv（主播放器）

```ini
# ~/.config/mpv/mpv.conf
vo=gpu-next              # libplacebo：缩放/色彩/颗粒交给 GPU
gpu-api=vulkan           # Turnip；若异常改 opengl（freedreno GL）
gpu-context=wayland
hwdec=no                 # 本机无可用硬解，显式关掉，省掉无用尝试
vd-lavc-threads=6        # 8 核里留 2 个给合成器/浏览器
vd-lavc-dr=yes           # 直接解码进 GPU 缓冲，少一次拷贝
vd-lavc-film-grain=gpu   # AV1 胶片颗粒交 GPU（仅 gpu-next 生效）
profile=fast             # 双线性缩放等，省 CPU/GPU
framedrop=vo             # 吃紧时丢帧保音画同步
ytdl-format=bv*[height<=1080][vcodec^=avc1]+ba/bv*[height<=1080]+ba/b[height<=1080]
# 应急（1080p60 仍卡时再打开，画质有损）：
# vd-lavc-skiploopfilter=nonref
```

### 2.2 Firefox

```js
// snap 版：~/snap/firefox/common/.mozilla/firefox/<profile>/user.js
// deb/tarball：~/.mozilla/firefox/<profile>/user.js
user_pref("media.hardware-video-decoding.enabled", false);   // 关掉无意义的硬解尝试
user_pref("media.hardware-video-decoding.force-enabled", false);
user_pref("media.ffmpeg.enabled", true);                     // H.264 等软解
user_pref("media.av1.enabled", true);                        // dav1d 软解 AV1
user_pref("media.av1.use-dav1d", true);
// 想更省电、彻底避开 AV1 时改成 false（YouTube 会退回 VP9）：
// user_pref("media.av1.enabled", false);
```

系统级等价物（可选）：`/etc/firefox/policies/policies.json`，`Preferences` 策略可写任意 pref [S11]

```json
{"policies":{"Preferences":{"media.hardware-video-decoding.enabled":false}}}
```

Ubuntu 的 Firefox 是 snap，宿主 `/etc/firefox/policies` 未必进得去沙箱 —— 单用户机器优先用 user.js。

验证是否真的在软解：YouTube 右键 → 统计信息，看 codec 是否为 `avc1`；Firefox 侧看 `about:support#graphics` 的 Decision Log，或用 `MOZ_LOG="FFmpegVideo:5"` 启动观察日志 [S19]。

### 2.3 Chromium（Ubuntu 的 chromium 是 snap）

```sh
# ~/.chromium-browser.init   ← snap 版不读 chromium-flags.conf（那是 Arch 包装脚本的特性）
CHROMIUM_FLAGS="--disable-features=AcceleratedVideoDecoder,AcceleratedVideoDecodeLinuxGL"
```

该文件路径经社区验证有效 [S12]；不写也能用（无 VA-API 时 Chromium 自动软解），这两行只是消掉无用的硬解初始化。Chromium ≥140 在 Wayland 会话默认走 Wayland [S6]。

## 3. 浏览器内播放（YouTube / Bilibili）

- **1080p 现实，1440p/4K 放弃**：YouTube 的 H.264 源最高只到 1080p（h264ify README 原文："4K and 1440p videos will not be available because YouTube no longer encodes those videos in H.264"）[S13] —— 对我们恰好就是目标分辨率。AV1/VP9 在 1080p 也能放，但更耗电。
- **装 `enhanced-h264ify`（Firefox + Chromium 双端）强制 H.264**：ArchWiki 在"无 VP8/VP9 硬解时降低 YouTube CPU 占用"处正是推荐它 [S6]；只想屏蔽 AV1 可另加 `Not yet, AV1`。它把最贵的软解换成最便宜的软解。
- **Bilibili**：网页端默认 AVC/HEVC，AV1 需在播放器"更多设置"里手动切（2022 年报道）[S14] → 不会默认撞上 AV1；要避开的是高码率档里的 **HEVC**（浏览器没有可靠的 HEVC 软解路径）。h264ify 类扩展拦的是 MediaSource 层，对 B 站同样生效，但其官方只承诺 YouTube【推测】。
- **最省电的看片方式是 mpv + yt-dlp 直连**（`mpv <URL>`，用 §2.1 的 `ytdl-format`），绕开浏览器 MSE 与合成开销【推测】。

## 4. Waydroid / Android 容器：一定是纯软解，且比原生差

- **硬解路径整体失效**：dragon-waydroid 的硬解就是 `v4l2_codec2` + **Venus 驱动**，其 README 原文点名了本机型号："Add support for HEVC/AVC/VP9 hardware decoding via v4l2_codec2 on Qualcomm mainline Linux devices with the **Venus driver**. Verified on Radxa Dragon Q6A(QCS6490) and **Huawei MateBook E Go(SC8280XP)**." [S15] → VPU 已死，这条路不可能活。
- **容器内连 `/dev/video*` 都没有**：Waydroid 的 LXC 生成逻辑对 `/dev/video*` 做 glob，宿主不存在就不生成挂载；而 v4l2_codec2 的组件列表**不检查设备是否存在**，直到真正创建组件时才报 `No devices supporting …` [S16]。AV1 更缺：arm64 镜像走的 OMX 表里**完全没有 AV1**，只能靠 app 自带 dav1d [S17]。
- **渲染别再降级**：Waydroid HWC 默认把 layer buffer 经 dmabuf 直接 attach 到 `wl_surface`（不额外合成），宿主侧用的就是 `vulkan.freedreno` + `ro.hardware.egl=mesa`；**不要**为了绕黑屏去开 swiftshader，那会让整个容器变成 CPU 渲染 [S18]。
- **流媒体订阅内容别指望**：镜像默认不含 Widevine（`ANDROID_USE_WIDEVINE` 默认关），Netflix/Disney+ 之类 L1 内容必然黑屏 [S15]。
- 净结论：1080p30 H.264/VP9 能放，但多一层 SurfaceFlinger + 跨容器 IPC，AV1 基本没戏；**没有任何比原生 Linux 更好的场景**，只有"Android 独占 app"才值得开。B 站/YouTube 请用原生 Firefox 或 mpv。

## 5. 推荐配置（最小可用）

```sh
sudo apt install mpv ffmpeg yt-dlp mesa-vulkan-drivers vulkan-tools
```

| 步骤 | 解决什么问题 |
|---|---|
| 装 mpv + yt-dlp | 主播放器与站点解析；本地文件与 YouTube/B 站都走最省的软解路径 |
| 装 ffmpeg | 提供 §1.5 的实测基准，也是 libavcodec 的参照实现 |
| 装 mesa-vulkan-drivers + vulkan-tools | 确保 Turnip 可用（§2.1 的 `gpu-api=vulkan`）；`vulkaninfo --summary` 用来确认设备是 Turnip 而非 lavapipe |
| 写 `~/.config/mpv/mpv.conf`（§2.1） | 强制软解 + GPU 后处理 + 线程/丢帧策略 |
| 写 Firefox `user.js`（§2.2） | 关掉无效硬解尝试、保留 dav1d；再装 `enhanced-h264ify` 让 YouTube 1080p 走 H.264 |
| 写 `~/.chromium-browser.init`（§2.3，可选） | 消掉 Chromium 无用的 VA-API 初始化 |

**不要装**：`libva-*`、`vdpau-*`、`intel-media-*`、GStreamer 的 va 插件、任何 iris/venus 固件包 —— 解决不了问题，只制造日志噪音和误判。

验证：

```sh
glxinfo -B | grep -i renderer              # 期望 freedreno/FD690，不是 llvmpipe
vulkaninfo --summary | grep -i deviceName  # 期望 Turnip
mpv --hwdec=no your1080p.mp4               # 按 i 看 dropped 与 CPU
```

## 6. 来源（均为本次调研实际抓取的页面）

| 内容 | 链接 |
|---|---|
| S1 Mesa 的 VA-API 支持面（只有 Radeon/Nouveau）· ArchWiki Hardware video acceleration | <https://wiki.archlinux.org/title/Hardware_video_acceleration> |
| S2 Mesa `src/gallium/targets/va/meson.build`（VA 驱动清单，无 Adreno/llvmpipe） | <https://gitlab.freedesktop.org/mesa/mesa/-/raw/main/src/gallium/targets/va/meson.build> |
| S3 Linux `drivers/media/test-drivers/vicodec/Kconfig`（虚拟编解码器） | <https://raw.githubusercontent.com/torvalds/linux/master/drivers/media/test-drivers/vicodec/Kconfig> |
| S4 mpv 手册 `DOCS/man/options.rst`（master，`vd-lavc-film-grain` 等） | <https://raw.githubusercontent.com/mpv-player/mpv/master/DOCS/man/options.rst> |
| S5 mozilla-central `modules/libpref/init/StaticPrefList.yaml`（pref 默认值） | <https://hg.mozilla.org/mozilla-central/raw-file/tip/modules/libpref/init/StaticPrefList.yaml> |
| S6 Chromium 官方差异文档 / ArchWiki Chromium（h264ify、Wayland、flags） | <https://raw.githubusercontent.com/chromium/chromium/main/docs/chromium_browser_vs_google_chrome.md> · <https://wiki.archlinux.org/title/Chromium> |
| S7 snapcraft 论坛：chromium snap 自带 H.264 等 codec（维护者确认） | <https://forum.snapcraft.io/t/using-chromium-ffmpeg-in-third-party-browser-snaps/6545> |
| S8 raspberrypi/firmware#1238：Pi4 ffmpeg 软解 1080p = 108 fps | <https://github.com/raspberrypi/firmware/issues/1238> |
| S9 jbkempf：dav1d 0.7.0 mobile focus（1080p 两三个核） | <https://jbkempf.com/blog/dav1d-0.7.0-mobile-focus/> |
| S10 Ubuntu Discourse：ThinkPad X13s 支持主帖（同 SoC，无 fps 数据） | <https://discourse.ubuntu.com/t/status-of-ubuntu-support-for-lenovo-thinkpad-x13s/44652> |
| S11 Firefox 策略模板（`Preferences` 策略、Linux policies 路径） | <https://mozilla.github.io/policy-templates/> |
| S12 snapcraft 论坛：snap Chromium 的 flags 写法 `~/.chromium-browser.init` | <https://forum.snapcraft.io/t/how-to-add-chromium-flags-to-snap-chromium/35715> |
| S13 h264ify README（YouTube H.264 上限 1080p） | <https://github.com/erkserkserks/h264ify> |
| S14 IT之家：B 站网页端支持 AV1，需手动切换（2022-02-06） | <https://m.ithome.com/html/601842.htm> |
| S15 dragon-waydroid-builds README（硬解依赖 Venus，点名 MateBook E Go） | <https://github.com/dragon-waydroid/dragon-waydroid-builds> |
| S16 Waydroid `tools/helpers/lxc.py` · v4l2_codec2 `V4L2Device.cpp`（无 `/dev/video*`） | <https://raw.githubusercontent.com/waydroid/waydroid/main/tools/helpers/lxc.py> · <https://raw.githubusercontent.com/dragon-waydroid/android_external_v4l2_codec2/android-16.0/common/V4L2Device.cpp> |
| S17 LineageOS `media_codecs_google_video.xml`（arm64 OMX 表无 AV1） | <https://raw.githubusercontent.com/LineageOS/android_frameworks_av/lineage-23.2/media/libstagefright/data/media_codecs_google_video.xml> |
| S18 Waydroid `hwcomposer/hwcomposer.cpp`（默认不合成） | <https://raw.githubusercontent.com/waydroid/android_hardware_waydroid/lineage-20/hwcomposer/hwcomposer.cpp> |
| S19 ArchWiki Firefox（VA-API/验证方法）· Ubuntu Discourse 26.04 Firefox snap 解码实测 | <https://wiki.archlinux.org/title/Firefox> · <https://discourse.ubuntu.com/t/hardware-video-decoding-working-on-intel-11th-gen-cpu-gpu-ubuntu-26-04-firefox-snap-except-for-av1-decoding/82492> |
