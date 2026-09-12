# easy-for-gaokun

**让 HUAWEI MateBook E Go 2022 性能版（GK-W76）在 Ubuntu 上获得完整、开箱即用的体验。**

本仓库面向**单一机型**做深度适配：从设备鉴别、引导配置、外设驱动修复，到桌面平板化与
Android 容器，目标是把社区内核已经跑通的"能开机"，推进到"能当主力用"。

> **状态：早期适配中。** 系统可正常启动并进入 GNOME Wayland 桌面，显示、背光与电源管理正常；
> **触屏目前完全不可用**，这是当前的第一优先阻塞项，正在做根因定位。
> 请勿将本仓库视为"已完成适配"的成品。

---

## 1. 目标设备

| 项目 | 参数 |
|------|------|
| 商品名 | HUAWEI MateBook E Go **2022 性能版** |
| 型号代号 | **GK-W76** |
| SoC | Qualcomm **Snapdragon 8cx Gen 3**（SC8280XP） |
| CPU | 8 核 Cortex-A78C，两簇：cpu0–3 @ 2.44 GHz，cpu4–7 @ **3.0 GHz** |
| GPU | Adreno 690（freedreno / Turnip） |
| 内存 | 15.7 GB |
| 设备树代号 | **`gaokun3`** |
| 内屏 | 12.35"，2560×1600；面板原生 **1600×2560 竖屏**；CSOT `ppc357db1-4` |
| 触控 | Himax **HX83121A** 级联 IC，SPI 接口（`spi0.0`） |
| 形态 | 平板（设备树 `chassis-type = tablet`），磁吸键盘可分离 |
| 安全启动 | 已关闭（本机型需关闭才能引导自编译内核） |

### ⚠️ 变体鉴别（**做任何操作前必须先确认**）

同系列存在两个**极其容易混淆**、且**本项目不支持**的变体：

| 变体 | 关键差异 | 后果 |
|------|----------|------|
| MateBook E Go **2022 LTE 版** | Snapdragon **8cx Gen 2**（SC8180X），GPU **Adreno 680**，设备树为 `gaokun2` | 设备树与内核补丁完全不通用 |
| MateBook E Go **2023 版** | 8cx Gen 3 但**降频**，最高主频约 **2.69 GHz** | 频率与热设计不同，配置不可照搬 |

**型号字符串本身不是可靠判据。** 在目标机上实测得到：

```text
/proc/device-tree/model        = Matebook E Go     （不含型号代号）
/sys/class/dmi/id/product_name = GK-W7X            （不是 GK-W76）
/sys/class/dmi/id/board_name   = GK-W7X-PCB
```

本机 DMI 报的是 `GK-W7X`，而非通常引用的 `GK-W76`；且电商页面存在把 2023 版标成 `GK-W76` 的情况。
**请使用下列硬判据确认机型：**

```bash
# ① 设备树（最可靠）
tr -d '\0' < /proc/device-tree/compatible
#   目标机应为：huawei,gaokun3 qcom,sc8280xp
#   2022 LTE 版会是 gaokun2 / sc8180x

# ② 大核最高频率（区分 2022 性能版与 2023 降频版的决定性判据）
cat /sys/devices/system/cpu/cpu4/cpufreq/cpuinfo_max_freq
#   2995200  →  3.0 GHz  →  2022 性能版（本项目目标）
#   ~2690000 →  2.69 GHz →  2023 版，不受支持

# ③ 内屏面板
tr '\0' ' ' < /proc/device-tree/soc@0/display-subsystem@ae00000/dsi@ae94000/panel@0/compatible
#   应为：csot,ppc357db1-4 himax,hx83121a
```

---

## 2. 当前状态

以下为在目标机上的**实测**结果。

### ✅ 已可用

| 项目 | 状态 |
|------|------|
| 引导 | UEFI + systemd-boot，设备树显式加载，可正常进入系统 |
| 桌面 | Ubuntu 26.04 LTS / GNOME 50 / **Wayland** |
| 显示 | `card0-DSI-1` connected，DSI 面板驱动工作正常 |
| 背光 | 可调（`ae96000.dsi.0`，亮度范围 0–4095） |
| 电源 | EC 驱动上报电池、充电状态与适配器识别（`gaokun-ec-battery`） |
| 温度 | CPU / GPU / 外壳热区传感器可读 |
| 存储 | 内置 NVMe（PCIe）可用 |
| 虚拟化 | `-el2+` 内核支持 KVM |

### ❌ 待解决

| 项目 | 现象 | 优先级 |
|------|------|:------:|
| **触控** | 驱动 `himax_hx83121a_spi` 正常绑定 `spi0.0`，IC 可被识别；但其中断（hwirq 175，level-low）**开机至今仅触发 1 次**，滑动屏幕零事件，中断线始终未被拉低 | **P0** |
| 音频 | `snd_soc_sc8280xp` 模块插入失败（`Invalid argument`），`systemd-modules-load.service` 失败，`qcom-apm gprsvc` 命令超时 | P1 |
| 引导条目 | `loader.conf` 的 `default` 指向非 `el2` 条目，该内核在 GUI 阶段卡住 | P1 |
| 文件系统 | 社区镜像根文件系统属主为 **uid 1001**，导致 `systemd-tmpfiles` 持续报 `unsafe path transition` | P1 |
| 视频硬解 | `qcom-venus` 固件初始化失败（`error -22`） | P2 |
| EC 设备链接 | `gaokun-ec` 无法与 USB 控制器建立 device link | P2 |
| RTC | 开机时间错误，需靠 NTP 纠正 | P2 |
| 手写笔 | Linux 侧**从未实现**笔通道（驱动不声明 `BTN_TOOL_PEN` / `ABS_PRESSURE`） | P2 |
| 自动旋转 | 设备树**没有加速度计节点**，硬件层面不成立 | — |

---

## 3. 基线系统

本项目**只支持**一个基线镜像：

```text
KawaiiHachimi/linux-gaokun-buildbot
release: ubuntu26.04-7.1.0-rc3-gaokun3+el2-20260514004329
```

- **下载**：<https://github.com/KawaiiHachimi/linux-gaokun-buildbot/releases/tag/ubuntu26.04-7.1.0-rc3-gaokun3%2B-el2-20260514004329>
- 内核：`7.1.0-rc3-gaokun3-el2+`（社区自编译）
- 引导：UEFI + systemd-boot，通过 `/etc/kernel/devicetree` **显式提供设备树**

### 为什么官方 Ubuntu 26.04 ISO 无法使用

这不是"发行版不对"，而是**内核与硬件描述方式不对**：

1. **本机在通用 UEFI 下默认走 ACPI。** 官方 ISO 使用官方 generic 内核，通过 ACPI 枚举硬件。
2. **但本机的 ACPI 表只为 Windows 准备。** 它描述 EC、GPIO、PCIe、USB，却**不描述 MDSS / DSI 面板 /
   时钟控制器 / 互联**——Windows 驱动把这些信息写死在驱动代码里，不需要固件告知。
3. **主线设备树也没有接入内屏。** 上游 `sc8280xp-huawei-gaokun3.dts` 中没有任何 DSI 面板节点，
   只有固件遗留的 `simple-framebuffer`（哑帧缓冲，无 modeset、无背光控制）。
4. 因此官方 ISO 表现为：灰屏 → 黑屏 → 重启。

社区内核的价值正在于**自编译内核 + 自带设备树 + 尚未上游的显示补丁**，这也是本项目的立足点。

---

## 4. 快速开始

> 下列为目标流程。标注 `[未实现]` 的步骤仍在开发中。

```bash
git clone https://github.com/aoripus/easy-for-gaokun.git
cd easy-for-gaokun

# ① 设备鉴别与前检（只读，必须先跑）
#    校验设备树、大核频率、面板与触屏设备，任一红线不过则中止
sudo ./scripts/00-preflight.sh

# ② 引导条目修正                  [未实现]
sudo ./scripts/10-boot.sh

# ③ 触屏诊断与修复                [诊断已实现 / 修复进行中]
sudo ./scripts/20-touchscreen.sh

# ④ 竖屏与显示配置                [未实现]
sudo ./scripts/30-display.sh

# ⑤ 音频子系统修复                [未实现]
sudo ./scripts/40-audio.sh

# ⑥ 平板化桌面（屏幕键盘、手势）  [未实现]
sudo ./scripts/50-desktop.sh

# ⑦ Android 容器（Waydroid）      [未实现]
sudo ./scripts/60-waydroid.sh

# ⑧ 生成诊断报告（提 issue 用）   [未实现]
sudo ./scripts/90-report.sh
```

所有脚本支持 `DRY_RUN=1` 空跑预览；改动类脚本默认逐项确认。

---

## 5. 工作原理

```text
┌──────────────────────────────────────────────────────────┐
│  应用层   Waydroid(Android) │ Wine/Steam+FEX │ 原生 Linux │
├──────────────────────────────────────────────────────────┤
│  桌面层   GNOME 50 (Wayland) + 平板化配置与扩展           │
├──────────────────────────────────────────────────────────┤
│  内核层   linux-gaokun-buildbot 自编译内核                │
│           + gaokun3 设备树 + 显示/触屏/EC 补丁            │
├──────────────────────────────────────────────────────────┤
│  引导层   UEFI + systemd-boot + /etc/kernel/devicetree    │
├──────────────────────────────────────────────────────────┤
│  硬件     Snapdragon 8cx Gen 3 / SC8280XP                 │
└──────────────────────────────────────────────────────────┘
```

本项目**不重复造轮子**：内核与设备树来自社区；本仓库负责**设备鉴别、基线之上的增量修复、
桌面平板化，以及回馈上游的补丁**。

---

## 6. 诊断与反馈

提 issue 前请先运行：

```bash
sudo ./scripts/90-report.sh > gaokun-report.txt
```

并在 issue 中附上该文件。请务必在 issue 开头写明你的机型属于三者中的哪一个
（2022 性能版 / 2022 LTE 版 / 2023 版），以及 §1 三条判据的实际输出。

---

## 7. 致谢与上游资产

本项目建立在以下社区工作之上：

- [KawaiiHachimi/linux-gaokun-buildbot](https://github.com/KawaiiHachimi/linux-gaokun-buildbot)
  —— 成品镜像、内核与固件包、补丁集与 CI，是本项目的基线来源。
- [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun)
  —— gaokun3 面向上游的适配工作：设备树、EC、摄像头、面板。
- [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux)
  —— Himax HX83121A SPI 触屏驱动。
- [awarson2233/EGoTouchRev](https://github.com/awarson2233/EGoTouchRev)
  —— Windows 侧触控/手写笔驱动的 clean-room 逆向实现。
- 以及上游内核社区：`panel-himax-hx83121a.c` 面板驱动作者、
  Huawei gaokun EC 驱动作者，以及 gaokun3 设备树的所有贡献者。

---

## 8. 许可

本项目以 **GPL-2.0-only** 发布，详见 [LICENSE](LICENSE)。

仓库中的内核补丁与设备树派生自 Linux 内核（GPL-2.0），沿用同一许可。

---

## 9. 免责声明

刷写镜像、修改分区与引导配置**可能导致设备无法启动**。本机型**没有 EDL / 9008 救援通道**，
一旦引导损坏，恢复手段极为有限。请务必先完整备份。

本项目**仅**针对上述确切机型。作者不对任何数据丢失或硬件损坏负责，使用风险自负。
