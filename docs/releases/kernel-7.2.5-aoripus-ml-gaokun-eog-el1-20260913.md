# Kernel 7.2.5 (EL1) — `7.2.5-aoripus-ml-gaokun-eog-el1+`

**发布日期**：2026-09-13
**基线**：Linux **stable v7.2.5**（mainline 的 stable 版本，**非 RC**）
**目标设备**：HUAWEI MateBook E Go 2022 性能版（**GK-W76**）/ SC8280XP / `gaokun3`
**启动级别**：**EL1**（标准启动；`slbounce` 依设备树嗅探后留在 EL1）

---

## 1. 这一版解决了什么

| 问题 | 之前（基线 EL2 内核） | 本版（EL1） |
|---|---|---|
| **视频硬解** | 无任何 V4L2 解码器（venus/iris 均 probe 失败于 `-22`） | ✅ `/dev/video*` 出现 **`qcom-venus-decoder`**，支持 H264 / VP8 / VP9 / HEVC / MPEG-2 |
| **触屏** | 完全无输入（中断计数恒为 1） | ✅ `Himax Capacitive TouchScreen` 正常工作，中断持续触发 |
| 内核来源 | 第三方构建 | ✅ **本项目自编**（稳定版 mainline + 本项目自有补丁） |
| KVM | 有 `/dev/kvm` | ❌ 无（EL1 的固有代价；硬解与 KVM 目前互斥） |

**实机验证（已核实）**

```text
$ uname -r
7.2.5-aoripus-ml-gaokun-eog-el1+
$ dmesg | grep 'started at EL'
[    0.008204] CPU: All CPU(s) started at EL1
$ v4l2-ctl --list-devices
Qualcomm Venus video decoder (plat:aa00000.video-codec:dec):  /dev/video33
Qualcomm Venus video encoder (plat:aa00000.video-codec:enc):  /dev/video32
$ mpv --hwdec=v4l2m2m-copy -v test1080p.mp4      # 片段节选
[vd] Trying hardware decoding via h264_v4l2m2m-v4l2m2m-copy.
[vd] Using underlying hw-decoder 'h264_v4l2m2m'
[ffmpeg/video] h264_v4l2m2m: Using device /dev/video33
$ grep himax /proc/interrupts
 322:      90419 ... msmgpio  175 Level  himax-spi-ts
```

触屏通路实测（45 s 有效窗口、匀速滑动）：

| 指标 | 值 |
|---|---|
| 帧间隔 中位 / p95 / p99 | 8.328 / 9.38 / 32.8 ms |
| 由中位间隔推算的报点率 | **≈120 Hz** |
| 每帧触屏 IRQ 数 | 15.39 |
| CPU 忙 | 15 % |

---

## 2. 关键结论：为什么必须 EL1

- 上游 **venus / iris 驱动都按 EL1 写**：`qcom_mdt_load(…, NULL)` 分配固件缓冲 + 裸调
  `qcom_scm_pas_auth_and_reset()`。EL1 下这两步由 EL2 的 hypervisor 代管；
  在 **bare-metal EL2** 下无人代管，固件元数据会被 TrustZone 以 `-22` 拒绝。
- 即便补上 SHM bridge 侧的处理，上游 EL2 补丁集亦明确记载：
  *"可以在 EL2 认证并启动固件，但 **remoteproc 永不脱离复位**"* —— DSP 靠
  `qcom,broken-reset`/attach 兜底，而**视频核没有 attach 可言**。
- 因此本机（GK-W76）**经 EL2 无法让视频核工作**；EL1 是唯一可行路径。

EL1/EL2 的切换**只需要换 BLS 条目里的 `devicetree`**：
`sc8280xp-huawei-gaokun3.dtb`（EL1）↔ `sc8280xp-huawei-gaokun3-el2.dtb`（EL2）。
`slbounce` 会嗅探设备树并决定留在 EL1 还是切到 EL2。
**不要**用"移除 `EFI/systemd/drivers/` 下的 slbounce/qebspil"来试图回退到 EL1 —— 那会破坏引导链导致黑屏。

---

## 3. 相对 mainline v7.2.5 的改动（自有补丁）

单一补丁：`gaokun3-7.2.5-el1.patch`（**159,047 B，21 个文件，+4512 −196**）。

| 方面 | 内容 | 来源 |
|---|---|---|
| 板级设备树 + defconfig | 内屏双 DSI/面板/背光、SPI 触屏、EC、热区、摄像头等完整板级描述 | 社区（right-0903 系） |
| 显示驱动 | 面板默认开 DSC、DPU DSC 时序宽度取整、面板 `bl` 供电表 | 社区 |
| 触屏 | Himax HX83121A **SPI** 驱动（12 文件）+ DTS `gpio174` 输出低 | 社区 + 本项目 |
| 视频 | venus 的 `sm8350_res`/`sc8280xp_res`、`sc8280xp.dtsi` 的 `venus`/`videocc`/`pil_video_mem` | Konrad Dybcio / Johan Hovold |
| 本项目自有 | 板级 `&venus { firmware-name = …; status = "okay"; };`；EC 节点引脚/中断按社区意图收敛；`pdc_map` 移除 `gpio175` 映射 | 本项目 |
| EL2 补丁集 | **一律不套用**（本内核目标是 EL1） | — |

**上游状态提示**：mainline v7.2.5 的板级 DTS **内屏是空的**（只有 `simple-framebuffer`），
且把触屏描述成 `i2c4@0x4f` 的 `hid-over-i2c` —— 后者在本机**实测无法枚举**（见 §4）。

---

## 4. 已知问题

1. **上游 `hid-over-i2c` 触屏描述对本机无效**：`4-004f` 设备节点存在但 `i2c_hid` 从不绑定、
   无输入设备、无中断。⇒ 必须走 SPI 路线（本内核即如此）。
2. **每帧 15.39 个触屏 IRQ 偏高**：DTS 里写了 `qcom,force-gsi-mode`，但 v7.2.5 的
   `spi-geni-qcom.c` **不读该属性**，SPI 退回 FIFO 模式（逐传输中断）。
   待补 `spi: qcom-geni: Add property to force GSI mode`（或跟进其 v2「DMA 可用即用 GSI」）。
3. 无 `/dev/kvm`（EL1 代价）。
4. 本内核**未经长时间日常使用验证**，建议保留原 EL2 菜单项作为兜底。
5. 音频 UCM、热管理节流（75 °C）等增强项未纳入本版。

---

## 5. 产物

| 文件 | 说明 |
|---|---|
| `Image` | ARM64 内核镜像（24,734,208 B） |
| `sc8280xp-huawei-gaokun3.dtb` | **EL1** 用设备树（配本内核） |
| `modules-7.2.5-aoripus-ml-gaokun-eog-el1+.tar.zst` | 全量模块树（360 个 `.ko`） |
| `config-7.2.5-aoripus-ml-gaokun-eog-el1+` | 完整内核配置（可审计） |
| `gaokun3-7.2.5-el1.patch` | 本项目相对 mainline v7.2.5 的**全部改动** |
| `System.map-…` / `sha256sums.txt` | 符号表与校验和 |

**安装**（只新增菜单项，不动默认启动项，可一键回滚）：

```bash
sudo ./scripts/gk-install-kernel.sh \
  --kver 7.2.5-aoripus-ml-gaokun-eog-el1+ \
  --image Image \
  --dtb sc8280xp-huawei-gaokun3.dtb \
  --modules modules-7.2.5-aoripus-ml-gaokun-eog-el1+.tar.zst
```

---

## 6. 复现构建

见 [`docs/kernel-7.2.5-el1-build.md`](../kernel-7.2.5-el1-build.md)：包含完整配方、补丁来源表、
**必须钉死的编译门禁**（`CONFIG_VIDEO_QCOM_IRIS` 必须为 `n`，否则 venus 的 compatible 会被
预处理器静默删除、零报错、永不出解码器）。

```bash
curl -sSLO https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.5.tar.xz
# 施加 gaokun3-7.2.5-el1.patch，然后
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- gaokun3_defconfig
# 断言：CONFIG_VIDEO_QCOM_VENUS=m 且 # CONFIG_VIDEO_QCOM_IRIS is not set
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image modules dtbs
```

---

## 7. 许可证与致谢

内核本体为 **GPL-2.0-only**；本项目补丁沿用同一许可。
板级支持与驱动修复来自社区多位作者的成果，详见
[`docs/kernel-7.2.5-el1-build.md`](../kernel-7.2.5-el1-build.md) 的补丁来源表与仓库 README 的致谢列表。
