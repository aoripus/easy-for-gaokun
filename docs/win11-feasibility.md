# Windows 11 改造可行性报告（`easy-for-gaokun-win` 立项前评估）

> 目标设备：**HUAWEI MateBook E Go 2022 性能版（GK-W76 / Snapdragon 8cx Gen 3 / SC8280XP）**
> 状态：**调研完成**（2026-09-15）。本文是**主报告**：给出已核实的一手事实、四个工作包的可行性读数与发布红线；
> 每个工作包的完整论证在独立章节（见 §4）。
> 立场：只回答"能不能做、代价多大、风险在哪"，**不含实现**。
> 置信度口径：**【已核实】**（本机/转储实测、一手源码或官方文档）· **【社区报告】**（他人实测）· **【推测】** · **【未核实】**。

## 0. 用户提出的四个工作包

| # | 工作包 | 用户原话 | 章节 |
|:-:|---|---|---|
| (a) | 原厂自带的 x64 应用 → ARM64 | 「把原厂系统自带的 X64 应用都重写成 arm64 的」 | [`win11-oem-customization.md`](win11-oem-customization.md) |
| (b) | 自研"管家"APP | 「我们自己实现一个管家APP」 | [`win11-manager-app.md`](win11-manager-app.md) |
| (c) | 调度优化 / 省电 | 「做一做调度优化」 | [`win11-power-tuning.md`](win11-power-tuning.md) |
| (d) | 装 Linux 与 Android | 「装一下linux和android就完事了」 | [`win11-wsl-android.md`](win11-wsl-android.md) |

形态：**新仓库 `easy-for-gaokun-win`**（用户已拍板）；目标优先级：**可用度 / 省电 / 干净无预装 / 开发环境全选**。

## 1. 已核实的一手事实（本机转储实测）

### 1.1 原厂**驱动**转储是 ARM64 原生的，(a) 在驱动层面不成立【已核实】

对 `Recovery/` + `Drv/` 下 177 个 PE 文件（`.exe/.dll/.sys/.efi`）逐个读 PE 头的 Machine 字段：

| 架构 | 文件数 | 合计体积 | 说明 |
|---|---:|---:|---|
| **ARM64**（`0xAA64`） | **133** | 272,198,472 B | 绝大多数：显示/相机/音频/系统驱动 |
| x86（`0x014c`） | 22 | 105,209,688 B | **全部**是高通 Adreno 的 CHPE 着色器编译器与 x86 用户态助手 |
| arm（`0x01c4`） | 19 | 40,937,312 B | 同上，ARM32 版本 |
| x64（`0x8664`） | **3** | 1,315,720 B | 其中一个是 ARM64 音频 APO 包里的 `PCHDRec.dll` |

- 非 ARM64 的代表：`qcdxchpecompiler8280.dll`、`qcdxx86compiler8280.DLL`、`qcdxarm32compiler8280.DLL`、
  `qcdx11x86um8280.dll`、`qcdxsdchpe.dll` —— 它们**所在的驱动包目录名就是 `qcdx8280.inf_arm64_*`**，
  即"ARM64 驱动包里故意附带的 x86/ARM32 助手"（让运行在模拟层的 x86 应用能 JIT 自己的着色器）。
- ⇒ **结论**：驱动侧**没有"x64 驱动等着被重写"这件事**。但这**不**等于"没有 x64 应用"——见 §1.6。

### 1.2 原厂应用不在 `Recovery/` 的散文件里【已核实；结论已于 §1.6 补全】

`Recovery/` 全域递归按扩展名统计：`.appx/.msix/.appxbundle/.msixbundle` **零命中**。
该目录实际是**驱动 + 固件仓库**：`.inf` 156、`.cat` 156、`.dll` 135、`.sys` 94、`.bin` 107、`.mbn` 28（高通固件）、
`.so` 34（248 MB）。

> **【2026-09-15 补全】**"应用不在转储里"这个初判**只对了一半**：应用确实不是散文件，但它们**以快照形式存在**——
> `Recovery/Customizations/USMT.ppkg` 是一个 **ICB（Initial Configuration Blob）WIM**，里面就是原厂机器的
> `C:\` 快照与 13 个预装应用的清单。取证方法与内容见 §1.6 与
> [`win11-oem-customization.md`](win11-oem-customization.md)。**最终结论见 §2 (a)**。

### 1.3 找到了"原厂答案"：首次开机配置脚本【已核实】

`Recovery\OEM\Customization\` 下是原厂 OOBE/首次开机定制，分 `General` / `Regional` / `Product` 三类，
每个子目录一个 `install.cmd`，由 `InstallCustomization.cmd` 递归调用（参数 `install|recovery`、SKU、是否装了 Office）：

```text
General\AR000DOIT7\PAR_install.cmd   General\close_bitlocker\install.cmd
General\deviceform_setting\install.cmd   General\edge_setting\install.cmd
General\oem_infomation\install.cmd   General\oem_license\install.cmd
General\sata_ssd_control_setting\install.cmd   General\sleep_mode_setting\install.cmd
Product\close_allow_wake_timers\  ssd_power_reduce\  critical_battery_percentage\
        HVCI_VBS\  uninstall_graphics\  Dirvers2PE\  Ignore_touch\  rotation_ms_screen\  …
Regional\AR000DOIT3_Gaokun\  desktop_setting_china\  DiskpartScript_18GB_arm\  oobe_requirement_common\ …
```

另有 `Recovery\OEM\Customization\Product\Dirvers2PE\PlatformDriver\`（**预置进 WinPE 的平台驱动**，
含高通的 `qcSubsysThermalMgr`，`DriverVer 06/07/2022,1.0.3508.3900`，`[Manufacturer] … NTARM64`）、
`Recovery\OEM\OOBEExtraSource\`（首次开机后安装的载荷 + GPU 驱动包）、`Recovery\OEM\RecoveryTool\`。

⇒ **意义**：原厂为这台机器设定的**睡眠/存储/热管理/显示驱动安装策略都写在它自己的脚本里** ——
这是"最省电的 Win11"与原厂安装流程的 ground truth，比凭经验猜可靠得多。逐条解析见
[`win11-oem-customization.md`](win11-oem-customization.md) §6。

### 1.4 原厂自己的"省电/睡眠"答案（脚本原文）【已核实】

| 脚本 | 它做了什么 |
|---|---|
| `sleep_mode_setting` | 先查 `HKLM\SYSTEM\CurrentControlSet\Control\Power\ModernSleep\EnabledActions` 判断本机是否支持 **Modern Standby**；支持则执行 `powercfg /setdcvalueindex scheme_current sub_presence standbybudgetpercent 2`（**待机预算 2%**）；再把 `e73a048d-…\9a66d8d7-…` 在 Balanced / High performance / Power saver 三个计划里都设为 `2`；最后 `powercfg /X hibernate-timeout-dc 180` + `hibernate-timeout-ac 180`，并把注册表 `9d7815a6-…`（"Hibernate after"）写成 `10800` 秒 ⇒ **空闲 180 分钟自动休眠** |
| `sata_ssd_control_setting` | `powercfg /setAcValueIndex` + `/setDcValueIndex <Balanced> 0012ee47-…(SUB_DISK) 0b2d69d7-…(磁盘空闲超时) 3`；随后 `powercfg -attributes SUB_DISK 0b2d69d7-… +ATTRIB_HIDE` —— **把这项设置从电源界面隐藏**（用户改不了） |
| `close_bitlocker` | 仅当支持 Modern Sleep 时写 `HKLM\SYSTEM\CurrentControlSet\Control\BitLocker\PreventDeviceEncryption = 1` ⇒ **关闭自动设备加密** |
| `close_allow_wake_timers` | SUB_SLEEP 的 `BD3B718A-0680-4D9D-8AB2-E1D2B4AC806D`（允许唤醒定时器）DC 置 `0` |
| `ssd_power_reduce` | SUB_DISK 的 `d639518a-e56d-4345-8af2-b9f32fb26109` DC 置 `20` |
| `critical_battery_percentage` | 用 `RecoveryTool\product.ini` 的 `critical_power_percentage=2` 写 SUB_BATTERY 的 `9a66d8d7-…` 到三个计划 |
| `HVCI_VBS` | `DeviceGuard\EnableVirtualizationBasedSecurity=1` 且 `HypervisorEnforcedCodeIntegrity\Enabled=0`（**VBS 开、HVCI 关**） |
| `deviceform_setting` / `edge_setting` / `oem_infomation` / `oem_license` / `AR000DOIT7\PAR_install.cmd` | 形态/地区/许可证与安装参数 |

> **【2026-09-15 更正】**本节初稿把 `e73a048d-bf27-4f12-9731-8b2076e8891f` 认作 SUB_BUTTONS。
> 追加的 `critical_battery_percentage` 脚本与 `product.ini` 证明它是 **SUB_BATTERY**，
> `9a66d8d7-4ff7-4ef9-b5a2-5a326ca2a469` 是其中的**关键电量百分比**（原厂值 = **2%**）【已核实】。

★ **对"待机掉电"的直接启示（Windows 与 Linux 两侧都适用）**：原厂策略**不是**"靠省电熬过 s2idle"，
而是 **Modern Standby(s2idle) + 空闲 180 分钟转休眠(S4)**。Linux 侧缺的正是这一步 ⇒
**r5 应当优先验证 `suspend-then-hibernate`**（systemd `HibernateDelaySec`）：屏灭后先 s2idle、到点转 S4。
额外好处——**不必先解决 PDC 秒醒问题**：秒醒只是退回 s2idle，最终仍会被 hibernate 兜住。

### 1.5 Linux 侧 S4 可用性实测（r5 的直接依据）【已核实】

| 检查 | 结果 |
|---|---|
| `/sys/power/state` | **`freeze mem disk`** —— 支持 s2idle / S3 / **S4(disk)** |
| 内核配置 | `CONFIG_HIBERNATION=y`、`CONFIG_HIBERNATION_SNAPSHOT_DEV=y`、`CONFIG_SWAP=y`、`CONFIG_PM_SLEEP=y` |
| swap | **完全没有**（`/proc/swaps` 空）；cmdline 上也没有 `resume=` |
| systemd | `systemd 259`，`systemd-suspend-then-hibernate.service` **存在** |
| 内存 | 15 GiB 级（hibernation `image_size` 提示 5.9 GiB） |

⇒ **结论**：本机**具备 S4 能力**，`suspend-then-hibernate` 只差三件事：
① 建一块 **swap 分区**；② 在自己的 BLS 条目 cmdline 上加 `resume=UUID=<swap>`；③ 设 `HibernateDelaySec`（180 分钟）并 A/B 实测。
修 Linux 待机是**另一条线**的工作（本项目 r5），本文只把它作为"原厂策略 → Linux 可借鉴"的旁证。

### 1.6 ★ 原厂预装软件与架构量化：应用层确实以 x64 为主【已核实】

`Recovery/Customizations/USMT.ppkg`（2,861,094,849 B）**其实是一个 WIM**（魔数 `MSWIM`，映像名
`Initial Configuration Blob`，解压后 8,186,610,667 B）。**DISM 会因为 `.ppkg` 扩展名直接报 `Error: 87`**；
在**同一卷**上建一个 `.wim` 硬链接后即可 `dism /Mount-Image /ReadOnly` 浏览（取证方法见 §5）。

**① 原厂预装应用清单（`ICB/ICB.xml`，权威）**：参考机 = `HUAWEI` / `GK-W7X`、Windows 11 build 22000 / ARM64 /
zh-CN、BIOS 2.09（2022-09-21）、8cx Gen 3 @ 3.0 GHz、16 GB、AoAc = Yes；**预装应用共 13 个**：
AppGallery、HMS Core、Office 家庭和学生版 2021（zh-cn）、HW OSD、Cloud、OneNote、
**华为电脑管家（多屏协同和官方驱动）13.0.2.330**、华为浏览器、Microsoft Edge / Edge Update / Edge WebView2、
WDT_Device_Driver、**Microsoft Visual C++ 2019 Redistributable (Arm64)**。

**② 架构量化（ICB 内 2,767 个 PE 逐个读机器类型）**：

| 架构 | 文件数 | 占比 | 体积 |
|---|---:|---:|---:|
| **x86-64** | **1,851** | 66.9% | 2,827.6 MB |
| x86 | 662 | 23.9% | 897.5 MB |
| **ARM64** | **240** | **8.7%** | 949.7 MB |
| ARM32 | 4 | 0.1% | 3.5 MB |

即 **91.3% 的预装二进制不是 ARM64**：

| 组件 | ARM64 | x64 | 判读 |
|---|---:|---:|---|
| `Program Files\Huawei\PCManager`（427 个文件） | 5 | **374** | **华为电脑管家整体是 x64**（42 个 exe 全 x64） |
| `Program Files\Huawei\Cloud` / `AppGallery` / `HMS Core` / `Hiview` | 0 | 402 / 88 / 58 / 57 | 华为生态组件均为 x64 |
| `Program Files\Huawei\Browser` | **33** | 0 | **华为浏览器是 ARM64** |
| `Program Files\Microsoft Office\root`（970 个文件） | 26 | **539** | **Office 2021 装的是 x64 版**：`root\Office16\WINWORD.EXE`/`EXCEL.EXE`/`POWERPNT.EXE`/`ONENOTE.EXE` 全是 `0x8664` |
| `Program Files (x86)\Microsoft\Edge*`（135 个文件） | **120** | 0 | **Edge / EdgeWebView 是 ARM64**（装在 `(x86)` 路径只是 Chromium 的历史习惯） |
| `Program Files (Arm)` | — | — | **空**（原厂没把任何应用装进 Arm 目录） |

⇒ **结论**：用户的直觉在**应用层成立**、在**驱动层不成立**。"重写"的正确定义是
**换官方 ARM64 版 / 换开源等价物 / 自研（如管家 APP）/ 或保留 x64 模拟运行**；反编译闭源二进制再重编不可行也不合规。
逐应用处置建议见 [`win11-oem-customization.md`](win11-oem-customization.md) §5。

### 1.7 ★ 备份完整性核对：**原厂 OS 镜像不在转储里**（抹盘前必须处理）【已核实】

| 检查项 | 结果 |
|---|---|
| `Recovery/` 下的 `.swm / .wim / .esd / .iso / .vhd(x)` | **零命中** |
| 原厂脚本引用的 `C:\Shipping_Image\InstallSource\OS\*.swm` | **转储里不存在** |
| 原厂镜像文件名 `05018SSN_Gaokun-W7821T_3.212.0.23-C233_T0-part{1,2,3}.swm` | 只出现在 `clear_items_file.txt` 的文字里 |
| 已有的东西 | `Drv/`（驱动 1.15 GB / 146 `.inf` / 69 `.sys`）、`Recovery/OEM/`（脚本 + WinPE 平台驱动 + GPU 载荷 1.26 GB）、`USMT.ppkg`（ICB 2.66 GB） |

⇒ **原厂系统的唯一副本目前仍在内置盘的 WinPE（`p5`）/ Onekey（`p6`）/ WinRE（`p7`）分区里。**
**在抹盘或重装之前必须先完整 dump 这三个分区**；本机**无 EDL/9008 救援通道**，一旦丢失不可恢复。
分区蓝图（原厂三套 diskpart 脚本 + `ResetConfig.xml`）见 [`win11-oem-customization.md`](win11-oem-customization.md) §9。

## 2. 各工作包可行性读数（结论）

| 工作包 | 读数 | 一句话依据 | 章节 |
|---|---|---|---|
| (a) x64 → ARM64 | **前提部分成立，目标需重新定义** | 驱动已全 ARM64；但**应用层 91.3% 的预装二进制是 x86/x64**（华为全家桶 + x64 版 Office）。可行手段只有"换官方 ARM64 版 / 换开源等价物 / 自研 / 保留模拟"，**不能反编译重写** | [§1.1](#11-原厂驱动转储是-arm64-原生的a在驱动层面不成立已核实) · [§1.6](#16--原厂预装软件与架构量化应用层确实以-x64-为主已核实) · [章节](win11-oem-customization.md) |
| (b) 自研管家 APP | **可行，且唯一能做满功能的路线是标准 WMI** | 标准 API 覆盖约 80%（电池健康/循环/功率、PDH 降频归因、GPU 利用率+显存、EcoQoS、SMBIOS）；**充电阈值只能走 `ROOT\WMI → OemWMIMethod::OemWMIfun`，且必须用 C++/COM**（PowerShell/C# 调用会报"无效参数"）；**一期不要写驱动** | [章节](win11-manager-app.md) |
| (c) 调度/省电 | **有真实杠杆，但上限受固件限制** | 第一步必须是 `powercfg /sleepstudy` 量化（DRIPS%、掉电 mW、exit reasons）；最对症的是**自适应休眠**（`standbybudgetpercent`）与**电源模式滑块别选"最佳性能"**；DRIPS 质量取决于高通固件，脚本改不到那一层 | [章节](win11-power-tuning.md) |
| (d) WSL2 + Android | **WSL2 本体可用；Android 没有好路径** | WSL2 ARM64 可安装可自动化（一次 UAC + 一次重启）；**但 GPU 加速当前不可用**（`dxgkrnl` 不给 `/dev/dri/renderD128`，Mesa 回落 llvmpipe，上游 issue 仍 open，而同 SoC 在 2023 年曾成功）；**ARM64 无嵌套虚拟化** ⇒ AVD/redroid/crosvm 全出局；**WSA 已 EOL**（2025-03-05） | [章节](win11-wsl-android.md) |

## 3. 发布边界（红线，已定）

1. 改过的 **Windows 镜像不可公开分发**（微软许可）；`Drv/` 厂商驱动**不可入库**（项目台账的 `.gitignore` 红线）。
2. 可公开交付的只有**脚本与配置**：`unattend.xml`、去预装/去遥测清单、winget/DISM 清单、
   **驱动注入脚本（引用用户本地 `Drv/` 路径）**、WSL2/WSLg 配置、电源调优 `.pow` + 脚本、以及复现文档。
3. **反编译闭源二进制再重编** 既不合规也不现实 —— 不作为路线。
4. **★ 抹盘前置条件（新增）**：在动分区表之前，先把内置盘的 **WinPE(p5) / Onekey(p6) / WinRE(p7)** 三个分区
   完整 dump 出来（§1.7）。这是不可逆操作，且本机没有 EDL/9008 救援通道。
5. **Linux 线处置建议**：**不删、不放弃** —— 保留现有 Ubuntu 分区与 r1/r3/r4 release 作为零成本回退路径，
   只是暂停投入；`loader.conf` 默认项与 EFI 变量依旧不动。

## 4. 章节索引

| 章节 | 内容 |
|---|---|
| [`win11-oem-customization.md`](win11-oem-customization.md) | 原厂基线解剖（ICB 取证、13 个预装应用、架构量化、逐应用处置）、首次开机流程逐条解析、驱动注入链、驱动覆盖清单、**备份完整性核对**、分区蓝图、复现命令 |
| [`win11-manager-app.md`](win11-manager-app.md) | 自研管家的能力矩阵（36 项功能 → 接口 → 可行性）、厂商专有 WMI 通路与硬约束、否定结论、法律与分发四档风险、技术栈建议、未核实清单 |
| [`win11-power-tuning.md`](win11-power-tuning.md) | 测量方法（`sleepstudy` 等六条命令 + 可复现协议）、两处推翻社区通行说法、旋钮表（含 Windows 独占 vs Linux 等价对照）、T0–T4 分级建议、风险与恢复、可交付形态 |
| [`win11-wsl-android.md`](win11-wsl-android.md) | WSL2 ARM64 可用性与自动化、**GPU 加速现状的完整证据链与不确定性**、被连坐否决的一类方案、Android 三条路线对比、许可与功耗边界 |

## 5. 方法与可复现性

- **PE 架构统计**：读 `e_lfanew` 处的 Machine 字段（`0xAA64`=ARM64、`0x8664`=x64、`0x014c`=x86、`0x01c4`=ARM32）。
  对 `Recovery/`+`Drv/` 与 ICB 各跑一遍，命令见 [`win11-oem-customization.md`](win11-oem-customization.md) §11。
- **★ 挂载原厂 ICB**：`USMT.ppkg` 是 WIM，但 DISM 会拒绝 `.ppkg` 扩展名（`Error: 87`）——
  用**同卷硬链接**换成 `.wim` 再 `dism /Mount-Image … /ReadOnly`，浏览 `ICB/0/MachineSpecific/File/C$`，
  元数据在 `ICB/ICB.xml`；用完 `dism /Unmount-Image /Discard`。**本报告的全部 ICB 数据均由该方法取得。**
- **本报告不含实现**；四份原始调研产物（未入库）与两处取证机（x64 Win10 LTSC、非目标机）的边界，
  已在各章节内逐一标注——**凡需真机的项一律标【未核实】**，不用取证机状态推断目标机。

## 6. 结论与待用户拍板的问题

**能不能做**：能，而且比预想的干净 —— 出厂系统本身几乎没有第三方垃圾，**主要工作量在"换掉华为生态组件 +
把 Office/常驻组件换成 ARM64 或移除"**，而不是"清理预装软件"。**三个必须先解决的前置问题**：

1. **先备份再动手**：内置盘 WinPE/Onekey/WinRE 三区的原厂镜像（§1.7）——不可逆。
2. **三项真机前置验证**（都很便宜，且都决定后续路线）：
   - (b)：平板管理员 PowerShell 跑 `Get-CimClass -Namespace root\wmi -ClassName OemWMIMethod` ——
     **无结果则"深度管家"整体作废**（只需 10 秒，只读）；
   - (c)：`powercfg /a` + `powercfg /sleepstudy` —— 决定"整夜到底有没有进 DRIPS"；
   - (d)：WSL2 里四条只读探针（`ls -l /dev/dri/`、`glxinfo -B`、`GALLIUM_DRIVER=d3d12 glxinfo -B`、`vulkaninfo`）——
     决定"WSL2 的 Android 路线值不值得投入"。
3. **发布边界**：改过的 Windows 镜像不公开分发，只交付脚本与配置（§3）。

**待用户拍板**：① Linux 线是否按 §3.5 保留分区（推荐保留）；② Android 三条路线选哪条（当前建议：
纯 Windows 单系统下用社区 WSABuilds 过渡，不投主线；长期最优是本机 Linux 分区 + Waydroid）；
③ 是否先做"真机三项前置验证"，再决定实现顺序。
