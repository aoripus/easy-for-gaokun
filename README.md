# easy-for-gaokun

**让 HUAWEI MateBook E Go 2022 性能版（GK-W76）在 Ubuntu 上获得完整、开箱即用的体验。**

本仓库面向**单一机型**做深度适配：从设备鉴别、引导配置、外设驱动修复，到桌面平板化与
Android 容器，目标是把社区内核已经跑通的"能开机"，推进到"能当主力用"。

> **状态：早期适配中；触屏已修复并实机验证通过。** 系统可正常启动并进入 GNOME Wayland 桌面，
> 显示、背光、电源管理、**触摸输入**与**扬声器增益调优**均已完成并实机验证；
> 已可在内置盘上实现 **Windows + Ubuntu 双系统**。
> 剩余缺口见 §2，最主要是视频硬解与手写笔；**指纹已取证结案：硬件不可达，见 §2.2**。

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
| **触控** | **已修复**：接口模式脚 `gpio174` 置低后，Himax HX83121A 走 SPI 上报通路（见 §2.1） |
| 音频 | 声卡 `SC8280XP-HUAWEI-GAOKUN3` 已注册；**已安装 gaokun3 专用 UCM profile**，功放增益由 X13s profile 的 `12`（−3.00 dB）提到内核限幅上限 `17`（**0.00 dB**，+3.00 dB），见 §2.2 与 [`docs/audio.md`](docs/audio.md) |
| 网络 | Wi-Fi 与蓝牙均可正常工作 |
| 双系统 | 内置盘保留 Windows，Ubuntu 装于独立分区，固件引导项可切换（见 §4.3） |

### ❌ 待解决

| 项目 | 现象 | 优先级 |
|------|------|:------:|
| **视频硬解** | `qcom-venus` 拒绝 SC8280XP：固件 `qcvss8280.mbn` 存在但驱动报 `error -22`，内核暂无 8280 支持 | **P1** |
| 镜像默认项 | 镜像自带 `loader.conf` 的 `default` 指向非 `el2` 条目，该内核在 GUI 阶段卡住 | P1 |
| 镜像根属主 | 镜像根目录属主为 **uid 1001** 而非 root，导致 `systemd-tmpfiles` 报 100+ 条 `unsafe path transition` | P1 |
| 手写笔 | Linux 侧**从未实现**笔通道（驱动不声明 `BTN_TOOL_PEN` / `ABS_PRESSURE`） | P2 |
| **指纹** | FocalTech FTE7001；其 SPI **由 Qualcomm 安全世界独占**，非安全侧只拿到一个 GPIO 中断连接。**已取证结案，见 §2.3** | 不可行 |
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

这正是它**极难排查**的原因：驱动侧一切"看起来正常"，日志里一个错误都没有。

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

**这是本项目的第一个上游化候选**：社区设备树与本机固件行为的这一处不一致，
目前没有任何一方处理。

### 2.2 音频：被内核主动锁住的 21 dB（已实机验证）

"音质不像四扬声器 HUAWEI SOUND"不是故障，而是**三层叠加的必然结果**：

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
**净收益 +3.00 dB**；**绝不取消内核限幅** —— Linux 侧没有任何主动扬声器保护
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
且不会被 `alsa-ucm-conf` 升级覆盖。完整论证、量化与安全红线见
[`docs/audio.md`](docs/audio.md)。

### 2.3 指纹：硬件不可达（已取证结案）

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

> ⚠️ **方法论修正**：`Drv/` 目录**不是本机硬件清单**，而是整份 Gaokun 家族主镜像的驱动库
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
├── config/                  运行期配置，由脚本安装到系统
│   └── ucm2/Qualcomm/sc8280xp/HUAWEI-GK-W7X.conf   gaokun3 专用 ALSA UCM2 profile
├── scripts/                 一键化适配与诊断工具
│   ├── lib/common.sh           公共函数库
│   ├── 00-preflight.sh         设备鉴别与前检（变体红线校验）
│   ├── 10-install-dualboot.sh  安装到内置盘（Windows + Ubuntu 双系统）
│   ├── 20-touchscreen.sh       触屏诊断与修复（gpio174 接口模式）
│   ├── 30-audio.sh             音频诊断与调优（安装 gaokun3 专用 UCM profile）
│   ├── 40-fingerprint.sh       指纹调查（只读；结论：SPI 属安全世界，不可达）
│   ├── 50-display.sh           竖屏与显示配置                     [规划中]
│   ├── 60-desktop.sh           平板化桌面（屏幕键盘、手势、扩展）  [规划中]
│   ├── 70-waydroid.sh          Android 容器                       [规划中]
│   └── 90-report.sh            一键生成诊断报告
├── tools/                   独立分析工具（不修改系统的取证/解析脚本）
│   └── win-acpi-hive.py        离线解析 Windows SYSTEM hive，读出本机 ACPI 枚举与资源
├── patches/                 面向上游的内核 / 设备树补丁
└── docs/                    技术文档
    ├── install-dualboot.md  双系统安装完整步骤与踩坑记录
    ├── video-decode.md      视频硬解归因与可行路径
    ├── audio.md             音频质量：诊断与调优
    └── fingerprint.md       指纹可行性调查与结论
```

> 目录中部分内容**仍在陆续落地**，当前进度以本文件 §2 的状态表为准。
> 脚本编号反映**推荐的执行顺序**，不是依赖关系。

### 4.2 目标流程

> 下列为目标流程。标注 `[未实现]` 的步骤仍在开发中。

```bash
git clone https://github.com/aoripus/easy-for-gaokun.git
cd easy-for-gaokun

# ① 设备鉴别与前检（只读，必须先跑）
#    校验设备树、大核频率、面板与触屏设备，任一红线不过则中止
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

- `00-preflight.sh` 只做**只读鉴别**，确认设备树 compatible 与 CPU 最高频率符合 §1 红线；
  **任何后续改动步骤都不得在未通过前检的机器上执行。**
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
所以**这两处配置一个字都不用改** —— 这是该方法最大的优势。

需要特别注意的几点：

| 事项 | 说明 |
|------|------|
| 空间 | 至少腾出 **1 GiB（ESP）+ 12 GiB（rootfs）**；建议 rootfs 给 64 GiB 以上，装完再 `resize2fs` 撑满 |
| 镜像缺陷 | `loader.conf` 的 `default` 指向会卡住的非 `el2` 条目，**安装时必须改写** |
| 镜像缺陷 | 根目录属主为 uid 1001，装完执行 `chown root:root /` |
| 触屏 | `dd` 之前把 `patches/` 里的 `gpio174` 补丁**编译进 ESP 上的 DTB**，首次启动触屏即可用 |
| 固件行为 | 本机固件会把**自建引导项重命名为 "Windows Boot Manager"**；用 `efibootmgr -o` 调整顺序即可，名字改不动 |
| ⚠️ UUID 冲突 | 同一镜像 `dd` 出的两块盘 **UUID 完全相同**，**不可同时接入**，否则 `UUID=… /boot/efi` 可能挂到另一块盘 |

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

## 7. 构建产物与发布

本项目有**两类** Release，标签命名刻意分开，避免混用：

| 类型 | 标签形如 | 内容 |
|------|----------|------|
| **源码里程碑** | [`v0.1.0`](https://github.com/aoripus/easy-for-gaokun/releases/tag/v0.1.0) | 仓库自身状态的快照（GitHub 自动生成源码包）；更新内容见 [`CHANGELOG.md`](CHANGELOG.md) |
| **内核构建产物** | [`kernel-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2-20260913`](https://github.com/aoripus/easy-for-gaokun/releases/tag/kernel-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2-20260913) | `Image`、设备树（含 EL2 变体）、模块包、`.config`、`System.map`、`vmlinux`、构建溯源清单与 SHA-256 |

已发布的构建产物：

| 标签 | 内容 | 状态 |
|------|------|------|
| `kernel-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2-20260913` | IRIS 视频硬解试验内核（`CONFIG_VIDEO_QCOM_IRIS=m`，上游 iris 设备树节点） | 编译通过；**未经启动验证** |

**为什么内核产物要独立打标签**：同一个源码版本会对应多次内核构建
（不同 `.config` / 设备树 / 补丁组合，例如"开 IRIS"与"开 Venus"），
用源码版本号无法区分，必须把「内核 release 串 + 构建日期」写进标签。

内核产物的构建溯源（源码 tag、补丁集、构建脚本、复现命令）随产物一同发布为
`BUILD-PROVENANCE.md`，以满足 GPL-2.0 的对应源码要求并保证可复现。

> ⚠️ 内核产物为**实验性构建**，未经启动验证的一律在 Release 说明里显式标注。
> 本机型**没有 EDL / 9008 救援通道**，刷写前请务必保留可用启动项。

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
一旦引导损坏，恢复手段极为有限。请务必先完整备份。

本项目**仅**针对上述确切机型。作者不对任何数据丢失或硬件损坏负责，使用风险自负。
