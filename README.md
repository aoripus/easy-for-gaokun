# easy-for-gaokun

[![CI](https://github.com/aoripus/easy-for-gaokun/actions/workflows/ci.yml/badge.svg)](https://github.com/aoripus/easy-for-gaokun/actions/workflows/ci.yml)
[![License: GPL-2.0-only](https://img.shields.io/badge/license-GPL--2.0--only-blue.svg)](LICENSE)
[![Target device](https://img.shields.io/badge/device-GK--W76%20%2F%20SC8280XP-informational.svg)](#1-目标设备)

**让 HUAWEI MateBook E Go 2022 性能版（GK-W76）在 Ubuntu 上获得完整、开箱即用的体验。**

本仓库面向**单一机型**做深度适配：从设备鉴别、引导配置、外设驱动修复，到桌面平板化与
Android 容器，目标是把社区内核已经跑通的"能开机"，推进到"能当主力用"。

> **状态：日常可用。** 系统可正常启动并进入 GNOME Wayland 桌面；显示、背光、电源管理、
> **触摸输入**、**扬声器增益调优**与**视频硬解（EL1 + venus）**均已实机验证；
> 已可在内置盘上实现 **Windows + Ubuntu 双系统**，并可安装/回滚**本项目自编内核**（见 §7）。
> 剩余缺口见 §2：手写笔通道未实现；指纹的结论是**硬件不可达**（§2.3）；
> EL1 与 KVM 互斥（要 `/dev/kvm` 就得放弃硬解）。

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

### 变体鉴别（操作前须先确认）

同系列存在两个容易混淆、本项目不支持的变体：

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
确认机型应使用下列判据：

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

### 已可用

| 项目 | 状态 |
|------|------|
| 引导 | UEFI + systemd-boot，设备树显式加载，可正常进入系统 |
| 桌面 | Ubuntu 26.04 LTS / GNOME 50 / **Wayland** |
| 显示 | `card0-DSI-1` connected，DSI 面板驱动工作正常 |
| 背光 | 可调（`ae96000.dsi.0`，亮度范围 0–4095） |
| 电源 | EC 驱动上报电池、充电状态与适配器识别（`gaokun-ec-battery`） |
| 温度 | CPU / GPU / 外壳热区传感器可读 |
| 存储 | 内置 NVMe（PCIe）可用 |
| 虚拟化 | 基线 `-el2+` 内核支持 KVM；**本项目自研的 EL1 内核没有 `/dev/kvm`**（与视频硬解互斥，见 §7） |
| **触控** | **已修复**：接口模式脚 `gpio174` 置低后，Himax HX83121A 走 SPI 上报通路（见 §2.1） |
| **视频硬解** | **已可用**：自研 EL1 内核（venus 线）下 venus 解码器/编码器在位，mpv 走 `h264_v4l2m2m`（见 §7 与 [`docs/video-decode.md`](docs/video-decode.md)） |
| **自研内核** | 已按命名规范发布 `r1`/`r3` 并装机运行；只新增 BLS 条目、可一键回滚（见 §7） |
| 音频 | 声卡 `SC8280XP-HUAWEI-GAOKUN3` 已注册；**已安装 gaokun3 专用 UCM profile**，功放增益由 X13s profile 的 `12`（−3.00 dB）提到内核限幅上限 `17`（**0.00 dB**，+3.00 dB），见 §2.2 与 [`docs/audio.md`](docs/audio.md) |
| 网络 | Wi-Fi 与蓝牙均可正常工作 |
| 双系统 | 内置盘保留 Windows，Ubuntu 装于独立分区，固件引导项可切换（见 §4.3） |

### 待解决

| 项目 | 现象 | 优先级 |
|------|------|:------:|
| **视频硬解（IRIS / EL2 路线）** | 该设备把视频子系统的安全世界支持（CP 内存保护、子系统状态机）放在 QTEE + 签名 TA 之后，Linux 侧不可达 ⇒ **该路线已放弃**；当前改走 EL1 + venus（已可用）。取证见 [`docs/video-decode.md`](docs/video-decode.md) | 不可行 |
| 触屏空闲功耗 | 空闲策略已把主机侧中断从 120 Hz 压到约 23 Hz，但 **IC 自身仍在以 120 Hz 扫描**（IC 侧功耗未降）；进一步压低需"AFE 深睡 + 盲唤醒"，代价是 30–50 ms 首触延迟 | P3 |
| 镜像默认项 | 镜像自带 `loader.conf` 的 `default` 指向非 `el2` 条目，该内核在 GUI 阶段卡住 | P1 |
| 镜像根属主 | 镜像根目录属主为 **uid 1001** 而非 root，导致 `systemd-tmpfiles` 报 100+ 条 `unsafe path transition` | P1 |
| 手写笔 | Linux 侧**从未实现**笔通道（驱动不声明 `BTN_TOOL_PEN` / `ABS_PRESSURE`） | P2 |
| **指纹** | FocalTech FTE7001；其 SPI **由 Qualcomm 安全世界独占**，非安全侧只拿到一个 GPIO 中断连接。**见 §2.3** | 不可行 |
| 音频残余 | 四扬声器空间音效（Windows 侧 Histen `SWS_HP_3D*_MULTI`）与主动扬声器保护在 Linux 上无对应实现；**不打算用猜测性软件 EQ 掩盖** | 能力边界 |
| `qcom-apm` | 开机报 `CMD timeout`，`qcom-soundwire` 端口数不匹配（声卡仍能注册，实际影响待评估） | P2 |
| EC 设备链接 | `gaokun-ec` 无法与 USB 控制器建立 device link | P2 |
| RTC | 开机时间错误，需靠 NTP 纠正 | P2 |
| 自动旋转 | 设备树**没有加速度计节点**，硬件层面不可能实现 | — |
| 引导项名称 | 固件把 Linux 引导项也命名为 "Windows Boot Manager"，仅外观问题 | — |

### 2.1 触屏故障：根因与修复（已实机验证）

这颗 Himax HX83121A 是级联 IC，它向哪个主机接口上报数据，由一颗**接口模式选择脚**决定：

| `TLMM gpio174` | IC 行为 |
|:---:|---|
| **低** | 走 **SPI** 上报裸触摸数据 —— 本项目所用驱动 `himax_hx83121a_spi` 需要的正是这条通路 |
| 高 | 改走 **I²C-HID**，SPI 通路不再输出触摸数据 |

引导固件把 `gpio174` 留在了**高电平**，而社区设备树的 `ts0_default` 只配置了 `gpio175`（中断）
与 `gpio99`（复位）——**没有任何一方管理 `gpio174`**。于是：

```text
固件把 gpio174 留在高
  → IC 处于 I²C-HID 模式
  → SPI 驱动仍能读寄存器（芯片 ID 正常、固件重载正常、不报任何错）
  → 但永远收不到触摸数据
  → level-low 中断线从未被拉低（开机至今仅触发 1 次）
  → 触屏表现为完全死掉
```

这使问题难以排查：驱动侧一切看起来正常，日志里没有任何错误。

**实机对照。** 在 `gpio174` 保持低电平、并在该状态下重载触控固件之后：

| 观测 | 修复前 | 修复后 |
|------|--------|--------|
| `/proc/interrupts` 中该 IRQ | 1（开机至今） | 持续增长（实测 13455 → 27199） |
| `gpio174` | `out high`（UNCLAIMED） | **`out low func0 2mA no pull`** |
| `/dev/input/event11` | 0 个事件 | 正常上报触摸 |

修改后 `gpio174` 的 pinctrl 属性（`2mA`、`no pull`）与补丁里写的
`drive-strength = <2>; bias-disable;` 完全一致，可确认是**设备树在控制它**，
而非任何用户态手段。

**修复方式。** 把 `gpio174` 描述为触屏默认状态下的**低电平输出**，补丁见
[`patches/0001-arm64-dts-qcom-sc8280xp-huawei-gaokun3-select-SPI-mode-for-touchscreen.patch`](patches/)。
该脚只需在**触控固件重载之前**为低，模式即被 IC 锁存；安装脚本会在 dd 之前把补丁
预先编译进 ESP 上的 DTB，因此**首次启动触屏就能用**，不需要任何常驻进程或服务。

社区设备树与本机固件行为的这处不一致目前无人处理，是本项目的第一个上游化候选。

### 2.2 音频：被内核主动锁住的 21 dB（已实机验证）

不是故障，而是**三层因素叠加的结果**：

1. **内核主动限幅**。`sound/soc/qcom/sc8280xp.c` 里
   `snd_soc_limit_volume(card, "SpkrLeft PA Volume", 17)`，
   注释写明 `until we have active speaker protection in place`。
   按 wsa883x 的 `DB_RANGE` 曲线（`dB = min_dB + (value − min_index) × step`），
   `17` 就是 **0.00 dB**，而硬件最高档是 **+18.00 dB**。
2. **Linux 侧完全没有 Histen 那层逐机型调音**。Windows 侧有 Histen APO 与
   `histen_config_GaoKunGen3.xml`（34 个 NV 调音块，含四扬声器的 `SWS_HP_3D*_MULTI`）；
   Linux 没有 ACDB 数据，也没有消费它的算法。
3. **跑的是 X13s 双扬声器 profile**。镜像把 `HUAWEI.*MateBook E.*` 显式映射到
   `LENOVO-X13s.conf`，其 `BootSequence` 把功放增益写成 `12` —— 按曲线是 **−3.00 dB**。

**本项目的处置**：只把 PA Volume 从 `12`（−3.00 dB）提到内核上限 `17`（0.00 dB），
**净收益 +3.00 dB**；**不取消内核限幅** —— Linux 侧没有任何主动扬声器保护
（`VISENSE` 在 UCM 里被显式关闭、ADSP Speaker Protection 默认关闭且无校准数据），
越限有烧毁扬声器的实际风险。当前链路总增益 −3.00 dB（数字侧另被限 −3.00 dB），
距硬件可达的 +18.00 dB **仍差 21.00 dB**，这部分在拿到真正的保护与调音数据前不会动。

```bash
sudo ./scripts/30-audio.sh --diagnose   # 只读体检
sudo ./scripts/30-audio.sh              # 安装 gaokun3 专用 UCM profile 并重启音频栈
sudo ./scripts/30-audio.sh --revert     # 精确撤销
```

**关键实现细节**：ucm2 的查找顺序是 `conf.d/<driver>/<CardLongName>.conf` 优先于
`conf.d/<driver>/<driver>.conf`，因此本项目写入 `${CardLongName}.conf`
（本机为 `HUAWEI-GK_W7X-M1010-GK_W7X_PCB`）即可**优先于镜像自带的 DMI 分发器**，
且不会被 `alsa-ucm-conf` 升级覆盖。完整论证、量化与增益上限见
[`docs/audio.md`](docs/audio.md)。

### 2.3 指纹：硬件不可达

**结论**：本机指纹是 **FocalTech FTE7001**（`ACPI\FTE7001`），挂在 **SPI** 上，
但那条 SPI **由 Qualcomm 安全世界（QSEE/TEE）独占**；Windows 的非安全侧驱动
只被分配了**一个 GPIO 中断连接**，没有任何 SPI/I²C 总线资源，取图/特征/模板比对
全部在签名 trustlet `fingerpr.mbn` 内完成。**Linux 无法通过常规内核驱动路线使用它。**

三条独立证据：

| # | 证据 | 来源 |
|:-:|------|------|
| 1 | `Enum\ACPI` 下 **`FTE7001` 有 1 个枚举实例**，`GDIX5125` / `ELAN7001` / `GXFP5130` **均为 0** | 离线解析 Windows `SYSTEM` hive |
| 2 | FTE7001 的 `LogConf\BootConfig` 只有 `Interrupt(GSI 0x8001)` 与 `Class=0x01(GPIO)/Type=0x02(GPIO_INT)`；**没有 `02 02`（SPI）**。同一台机器上已知 SPI 的触屏 `HIMX0002` 有 `02 02`，已知 UART 的蓝牙 `QCOM066B` 有 `02 03` —— 语义被本机数据钉死 | 同上 |
| 3 | `fingerpr.mbn`（3.67 MB，ELF64/AArch64）内含 `focal_fp_spi.c` 与整套 `qsee_spi_open/…/full_duplex`、`attaching to QSEE_SPI_DEVICE_%u (QUP%u SE %u)`；**I²C 相关字符串 0 条** | 本地驱动转储只读分析 |

Linux 侧实测同样干净：`usb_2` 多端口控制器已使能但无指纹 USB 设备（**USB 路线排除**）、
I²C 上只有 EC、24 个 GENI SPI 只有触屏那个 `okay`、**设备树里没有任何指纹节点**、
`gpio185` 虽 `UNCLAIMED` 但同段引脚大量如此（**不能作为证据**）、
内核 `CONFIG_QCOM_QSEECOM=y` 但 `/dev/qseecom` 不存在（DTB 启动无该节点）。

```bash
sudo ./scripts/40-fingerprint.sh              # Linux 侧只读检查
sudo ./scripts/40-fingerprint.sh --windows-hive  # 只读挂载 Windows 分区并解出 ACPI 枚举与资源
```

> **方法论修正**：`Drv/` 目录**不是本机硬件清单**，而是整份 Gaokun 家族主镜像的驱动库
> （`PAR_install.cmd` 用 `DISM /add-driver /recurse` 把 FocalTech 与 Goodix 两套指纹驱动
> 一起注入）。判断本机硬件必须看**运行时枚举结果**，不能看驱动包里有没有某个 INF。
>
> 完整论证、复现步骤与"什么条件下可以重启这项工作"见 [`docs/fingerprint.md`](docs/fingerprint.md)；
> 离线 hive 取证工具见 [`tools/win-acpi-hive.py`](tools/win-acpi-hive.py)。

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

### 4.1 仓库结构

```text
easy-for-gaokun/
├── README.md
├── LICENSE
├── CONTRIBUTING.md
├── .github/                 CI、issue/PR 模板、CODEOWNERS、dependabot
├── config/                  运行期配置，由脚本安装到系统
│   └── ucm2/Qualcomm/sc8280xp/HUAWEI-GK-W7X.conf   gaokun3 专用 ALSA UCM2 profile
├── scripts/                 在目标机上运行的适配与诊断脚本（索引见 scripts/README.md）
│   ├── lib/common.sh           公共函数库
│   ├── 00-preflight.sh         设备鉴别与前检（变体判据校验，只读）
│   ├── 10-install-dualboot.sh  安装到内置盘（Windows + Ubuntu 双系统）
│   ├── 20-touchscreen.sh       触屏诊断与修复（gpio174 接口模式）
│   ├── 30-audio.sh             音频诊断与调优（安装 gaokun3 专用 UCM profile）
│   ├── 40-fingerprint.sh       指纹调查（只读；结论：SPI 属安全世界，不可达）
│   ├── 50-display.sh           竖屏与显示配置                     [规划中]
│   ├── 60-desktop.sh           平板化桌面（屏幕键盘、手势、扩展）  [规划中]
│   ├── 70-waydroid.sh          Android 容器                       [规划中]
│   ├── 90-report.sh            一键生成诊断报告（提 issue 用）
│   ├── gk-install-kernel.sh    安装/回滚本项目自编内核（只新增 BLS 条目）
│   └── check-patches.sh        补丁序列自检（CI 的 patches job 也调用它）
├── tools/                   只读分析工具与构建/打包脚本（索引见 tools/README.md）
│   ├── gk-touch-bench.py       触屏通路量化（报点率 / 帧间隔 / IRQ 效率）
│   ├── win-acpi-hive.py        离线解析 Windows SYSTEM hive，读出 ACPI 枚举与资源
│   ├── acpi-devmem-dump.py     从 /dev/mem 读固件 ACPI 表做取证
│   ├── gaokun-iris-dts-prep.py 前置上游 IRIS 设备树节点（历史路线用）
│   ├── build-iris-x86.sh       x86_64 交叉编译 arm64 内核（文件名为历史遗留）
│   ├── mk-release.sh           打包内核产物、生成校验和与溯源清单
│   └── pas-probe/              向 TrustZone 直接问询 PAS 支持的探针模块
├── patches/                 内核补丁序列（总索引见 patches/README.md；每序列带 series 顺序）
│   ├── touch-spi-mode/         设备树：触屏接口模式脚 gpio174 置低（当前内核使用）
│   ├── spi-gsi/                触屏 SPI 走 GSI / DMA（当前内核使用）
│   ├── touch-idle/             触屏中断使能修复 + 空闲门控采样（当前内核使用）
│   ├── el2-v7.2/               EL2 补丁集在 v7.2-rc2 上的适配（历史归档）
│   └── iris-el2/               IRIS 在 EL2 下的适配（历史归档，路线已放弃）
└── docs/                    实机结论与治理文档（索引见 docs/README.md）
    ├── install-dualboot.md  双系统安装完整步骤与踩坑记录
    ├── video-decode.md      视频硬解归因与可行路径
    ├── audio.md             音频质量：诊断与调优
    ├── fingerprint.md       指纹可行性调查与结论
    ├── touch-idle-policy.md 触屏空闲中断治理
    ├── kernel-7.2.5-el1-build.md  自研内核构建配方与门禁
    ├── architecture.md      仓库结构与时序
    ├── releasing.md         内核发布流程 checklist
    ├── adr/                 架构决策记录
    ├── rfc/                 提案
    ├── releases/            每个内核产物的发布说明（+ `TEMPLATE.md`）
    └── bench/               基准数据归档
```

> 仓库根目录另有工程规范文件：`CONTRIBUTING.md`（贡献与提交规范）、`SECURITY.md`（威胁模型与漏洞上报）、
> `SUPPORT.md`（支持范围）、`GOVERNANCE.md`（治理）、`MAINTAINERS.md`（维护者）、
> `CODE_OF_CONDUCT.md`（行为准则）、`CHANGELOG.md`（变更日志），以及工具链配置
> `Makefile`、`package.json`、`.editorconfig`、`.pre-commit-config.yaml` 等。
> **本地自检**：`make check`（等价于 CI 的六个 job）。

> 目录中部分内容**仍在陆续落地**，当前进度以本文件 §2 的状态表为准。
> 脚本编号反映**推荐的执行顺序**，不是依赖关系。

### 4.2 目标流程

> 下列为目标流程。标注 `[未实现]` 的步骤仍在开发中。

```bash
git clone https://github.com/aoripus/easy-for-gaokun.git
cd easy-for-gaokun

# ① 设备鉴别与前检（只读，必须先跑）
#    校验设备树、大核频率、面板与触屏设备，任一判据不符则中止
sudo ./scripts/00-preflight.sh

# ② 安装到内置盘（Windows + Ubuntu 双系统）   [已实现并实机验证]
sudo ./scripts/10-install-dualboot.sh --target /dev/nvme0n1p4 --image ubuntu-26.04-gaokun3.img

# ③ 触屏诊断与修复                [已实现并实机验证]
sudo ./scripts/20-touchscreen.sh

# ④ 音频诊断与调优（装 gaokun3 专用 UCM profile）  [已实现并实机验证]
sudo ./scripts/30-audio.sh

# ⑤ 指纹调查（只读；结论：SPI 属安全世界，不可达）  [已实现]
sudo ./scripts/40-fingerprint.sh
sudo ./scripts/40-fingerprint.sh --windows-hive

# ⑥ 竖屏与显示配置                [未实现]
sudo ./scripts/50-display.sh

# ⑦ 平板化桌面（屏幕键盘、手势）  [未实现]
sudo ./scripts/60-desktop.sh

# ⑧ Android 容器（Waydroid）      [未实现]
sudo ./scripts/70-waydroid.sh

# ⑨ 生成诊断报告（提 issue 用）   [已实现]
sudo ./scripts/90-report.sh
```

执行约定：

- `00-preflight.sh` 只做**只读鉴别**，确认设备树 compatible 与 CPU 最高频率符合 §1 判据；
  后续改动步骤不应在未通过前检的机器上执行。
- 脚本统一通过 `scripts/lib/common.sh` 复用日志、判别与回滚辅助函数。
- 各步骤相互独立，可按需单独执行；`90-report.sh` 可在任意阶段运行。
- 所有脚本支持 `DRY_RUN=1` 空跑预览；改动类脚本默认逐项确认。

### 4.3 安装到内置盘（Windows + Ubuntu 双系统）

> 完整步骤、命令与踩坑记录见 [`docs/install-dualboot.md`](docs/install-dualboot.md)。本节只给要点。

社区镜像是**整盘镜像**（GPT + 1 GiB FAT32 ESP + ~11 GiB ext4 rootfs），
**不能直接 `dd` 进一个分区**。双系统的做法是**分区级 `dd`**：

```text
从镜像中取出两个分区 → 各自 dd 进内置盘上新建的分区
```

因为 `dd` 会**原样保留文件系统 UUID**，而 `/etc/fstab` 与 BLS 的 `root=UUID=` 完全依赖 UUID，
所以**这两处配置无需改动** —— 这是该方法的主要优势。

需要特别注意的几点：

| 事项 | 说明 |
|------|------|
| 空间 | 至少腾出 **1 GiB（ESP）+ 12 GiB（rootfs）**；建议 rootfs 给 64 GiB 以上，装完再 `resize2fs` 撑满 |
| 镜像缺陷 | `loader.conf` 的 `default` 指向会卡住的非 `el2` 条目，**安装时必须改写** |
| 镜像缺陷 | 根目录属主为 uid 1001，装完执行 `chown root:root /` |
| 触屏 | `dd` 之前把 `patches/` 里的 `gpio174` 补丁**编译进 ESP 上的 DTB**，首次启动触屏即可用 |
| 固件行为 | 本机固件会把**自建引导项重命名为 "Windows Boot Manager"**；用 `efibootmgr -o` 调整顺序即可，名字改不动 |
| UUID 冲突 | 同一镜像 `dd` 出的两块盘 **UUID 完全相同**，**不可同时接入**，否则 `UUID=… /boot/efi` 可能挂到另一块盘 |

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

并在 issue 中附上该文件。请在 issue 开头写明你的机型属于三者中的哪一个
（2022 性能版 / 2022 LTE 版 / 2023 版），以及 §1 三条判据的实际输出。

---

## 7. 构建产物与发布

本项目有**两类** Release，标签与标题按类别区分，避免混用：

| 类型 | 标签形如 | 内容 |
|------|----------|------|
| **源码里程碑** | [`v0.1.0`](https://github.com/aoripus/easy-for-gaokun/releases/tag/v0.1.0) | 仓库自身状态的快照（GitHub 自动生成源码包）；更新内容见 [`CHANGELOG.md`](CHANGELOG.md) |
| **内核构建产物** | [`kernel-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2-20260913`](https://github.com/aoripus/easy-for-gaokun/releases/tag/kernel-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2-20260913) | `Image`、设备树（含 EL2 变体）、模块包、`.config`、`System.map`、`vmlinux`、构建溯源清单与 SHA-256 |

> **标题约定**：Release **标题**不再加 `[工具]` / `[内核]` 之类的类别前缀。
> 源码里程碑用 `vX.Y.Z`；二进制内核构建用 `Kernel <上游> (<级别>) <VPU大写>[ r<n>]`，
> 例 `Kernel 7.2.5 (EL1) VENUS`、`Kernel 7.2.0-rc2 (EL2) IRIS`。标签命名见下表与下节。

已发布的构建产物：

| Release 标题 | 标签 | 内核串（`uname -r`） | 内容 | 状态 |
|------|------|------|------|------|
| `Kernel 7.2.5 (EL1) VENUS r3` | `kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3-20260913` | `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3` | 自研 stable v7.2.5 + EL1 + venus；触屏中断缺陷修复 + 空闲门控采样 | **Latest**；装机复核通过（EL1、venus 解码/编码器、触屏正常；空闲 IRQ 120 → 23 Hz） |
| `Kernel 7.2.5 (EL1) VENUS r1` | `kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913` | `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1` | 同上，另加触屏 SPI 走 GSI（DMA） | 已发布；滑动实测每帧触屏 IRQ 15.39 → 3.56 |
| `Kernel 7.2.5 (EL1) VENUS`（旧命名，追溯记 `r0`） | `kernel-7.2.5-aoripus-ml-gaokun-eog-el1-20260913` | `7.2.5-aoripus-ml-gaokun-eog-el1+` | 首个自研 EL1 内核：打通 venus 硬解与 SPI 触屏 | 已发布；已被 `r1`/`r3` 取代 |
| `Kernel 7.2.0-rc2 (EL2) IRIS`（旧命名，追溯记 `r0`） | `kernel-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2-20260913` | `7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+` | IRIS 视频硬解试验内核（`CONFIG_VIDEO_QCOM_IRIS=m`，上游 iris 设备树节点） | **pre-release**；EL2 下视频核**无法脱离复位** ⇒ IRIS 路线**已放弃**（见 §2 与 `docs/video-decode.md`） |

> 上表两条**旧命名**产物（内核串里还没有 `gaokun3` / 级别 / VPU / `r<n>` 四个字段），
> 按新规范**追溯记为 `r0`**；其 tag 与内核串**保持不变** —— 已发布的 tag 已被外部链接固化，
> 改名会破坏链接。新规范自 `r1` 起生效。

**为什么内核产物要独立打标签**：同一个源码版本会对应多次内核构建
（不同 `.config` / 设备树 / 补丁组合，例如"开 IRIS"与"开 Venus"），
用源码版本号无法区分，必须把「内核 release 串 + 构建日期」写进标签。

### 内核产物命名规范

> 2026-09-13 定稿；**自 `r1` 起生效**。

```text
uname -r = <上游>-aoripus-ml-gaokun3-eog-<级别>-<VPU驱动>-r<n>
例       = 7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1        （41 字符）
tag      = kernel-<完整内核串>-<YYYYMMDD>
标题     = Kernel <上游> (<级别>) <VPU大写>[ r<n>]
```

| 字段 | 取值 | 说明 |
|---|---|---|
| `<上游>` | 如 `7.2.5` | kernel.org **stable** 树版本；不含 `rc`、不含 `r<n>` |
| `aoripus` | 固定 | 维护者标识 |
| `ml` | 固定 | 构建源码树 = kernel.org **stable** 树（**不是** mainline master，**不是**发行版内核） |
| `gaokun3` | 固定 | 设备树代号（GK-W76 / SC8280XP）。**不用 `gaokun`** —— `gaokun2` 是 8cx Gen 2 / SC8180X，极易混淆 |
| `eog` | 固定 | 机型系列 MateBook E Go |
| `<级别>` | `el1` / `el2` | `el1`：视频硬解可用、**无 `/dev/kvm`**；`el2`：有 `/dev/kvm`、**视频核起不来** |
| `<VPU驱动>` | `venus` / `iris` | 启用的**视频编解码单元（VPU）**驱动线。**VPU 不是 GPU** —— GPU 是 Adreno 690（freedreno / Turnip） |
| `r<n>` | 从 `r1` 起 | 修订号；作用域 = **同一上游版本 + 同一级别 + 同一 VPU 驱动** |

**机器侧派生**：内核串同时决定 `/lib/modules/<串>/`、
`/boot/{vmlinuz,initrd.img,dtb,config}-<串>`、systemd-boot 条目名
`loader/entries/<machine-id>-<串>[-<tag>].conf` 与 ESP 目录 `<machine-id>/<串>[-<tag>]/`
（实现见 `scripts/gk-install-kernel.sh`）。⇒ **日期只进 Release tag，绝不进内核串**，
否则每天都会产生一个新的模块目录、每天都要重编。

**强制门禁**：`CONFIG_LOCALVERSION_AUTO` 必须关闭（`.config` 中应为
`# CONFIG_LOCALVERSION_AUTO is not set`）。该选项会在源码树非 pristine（无 tag / 有未提交改动）时
给内核串追加 `+`，使同一份逻辑源码在 clean 与 dirty 两种状态下派生出**两个不同的模块目录**，
发布串不可复现。

**`r<n>` 裁决规则**

| 情形 | 处置 |
|---|---|
| 产物语义变化（补丁 / DTB / `.config`） | 重编 → `r+1` → **新 tag** |
| 内核字节不变（仅说明文档、资产重传） | 内核串与 `r` 都**不动**；优先**就地替换同一 release 的 asset**（tag 不变） |
| 上游版本升级 | `r` **归零**重排 |
| 只改 Release 标题 / 说明 | 随时可改，不产生新版本 |

发布流程（构建 → 门禁 → 打包 → 发布 → 装机复核 → 回滚）已固化为可照做的 checklist：
见 [`docs/releasing.md`](docs/releasing.md)；发布说明模板见 [`docs/releases/TEMPLATE.md`](docs/releases/TEMPLATE.md)。

下一版候选（尚未排期）：热管理（75 °C 节流）与音频 UCM 纳入内核配套；
用 Chromium 复核 `V4L2VideoDecoder`；产出"本项目补丁 vs mainline vs pgs666"差异清单。

内核产物的构建溯源（源码 tag、补丁集、构建脚本、复现命令）随产物一同发布为
`BUILD-PROVENANCE.md`，以满足 GPL-2.0 的对应源码要求并保证可复现。

> 内核产物为**实验性构建**，未经启动验证的一律在 Release 说明里显式标注。
> 本机型**没有 EDL / 9008 救援通道**，刷写前应保留可用启动项。

---

## 8. 致谢与上游资产

本项目建立在以下社区工作之上：

- [KawaiiHachimi/linux-gaokun-buildbot](https://github.com/KawaiiHachimi/linux-gaokun-buildbot)
  —— 成品镜像、内核与固件包、补丁集与 CI，是本项目的基线来源。
- [right-0903/linux-gaokun](https://github.com/right-0903/linux-gaokun)
  —— gaokun3 面向上游的适配工作：设备树、EC、摄像头、面板；
  本项目的触屏根因分析直接依据其关于 `gpio174` 接口模式选择的一手说明。
- [chiyuki0325/EGoTouchRev-Linux](https://github.com/chiyuki0325/EGoTouchRev-Linux)
  —— Himax HX83121A SPI 触屏驱动。
- [awarson2233/EGoTouchRev](https://github.com/awarson2233/EGoTouchRev)
  —— Windows 侧触控/手写笔驱动的 clean-room 逆向实现。
- 以及上游内核社区：`panel-himax-hx83121a.c` 面板驱动作者、
  Huawei gaokun EC 驱动作者，以及 gaokun3 设备树的所有贡献者。

---

## 9. 许可

本项目以 **GPL-2.0-only** 发布，详见 [LICENSE](LICENSE)。

仓库中的内核补丁与设备树派生自 Linux 内核（GPL-2.0），沿用同一许可。

---

## 10. 免责声明

刷写镜像、修改分区与引导配置**可能导致设备无法启动**。本机型**没有 EDL / 9008 救援通道**，
一旦引导损坏，恢复手段有限，操作前应完整备份。

本项目**仅**针对上述确切机型。作者不对任何数据丢失或硬件损坏负责，使用风险自负。
