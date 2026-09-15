# Windows 11 改造可行性报告（`easy-for-gaokun-win` 立项前评估）

> 目标设备：**HUAWEI MateBook E Go 2022 性能版（GK-W76 / Snapdragon 8cx Gen 3 / SC8280XP）**
> 状态：**调研中**（本文档随调研推进更新；每个工作包独立成节，标注【已核实】/【推测】/【待调研】）
> 立场：只回答"能不能做、代价多大、有什么风险"，**不含实现**。

## 0. 用户提出的四个工作包

| # | 工作包 | 用户原话 |
|:-:|---|---|
| (a) | 原厂自带的 x64 应用 → ARM64 | 「把原厂系统自带的 X64 应用都重写成 arm64 的」 |
| (b) | 自研"管家"APP | 「我们自己实现一个管家APP」 |
| (c) | 调度优化 / 省电 | 「做一做调度优化」 |
| (d) | 装 Linux 与 Android | 「装一下linux和android就完事了」 |

形态：**新仓库 `easy-for-gaokun-win`**（用户已拍板）；目标优先级：**可用度 / 省电 / 干净无预装 / 开发环境全选**。

## 1. 已核实的一手事实（本机转储实测）

### 1.1 原厂驱动转储是 **ARM64 原生**的，(a) 的前提基本不成立【已核实】

对 `D:\androidGaokun\`（`Recovery/` + `Drv/`）下 177 个 PE 文件（`.exe/.dll/.sys/.efi` 等，按体积取前 500）
逐个读 PE 头的 Machine 字段，结果：

| 架构 | 文件数 | 合计体积 | 说明 |
|---|---:|---:|---|
| **ARM64**（`0xAA64`） | **133** | 272,198,472 B | 绝大多数：显示/相机/音频/系统驱动 |
| x86（`0x014c`） | 22 | 105,209,688 B | **全部**是高通 Adreno 的 CHPE 着色器编译器与 x86 用户态助手 |
| arm（`0x01c4`） | 19 | 40,937,312 B | 同上，ARM32 版本 |
| x64（`0x8664`） | **3** | 1,315,720 B | 其中一个是 ARM64 音频 APO 包里的 `PCHDRec.dll` |

- 非 ARM64 的代表：`qcdxchpecompiler8280.dll`、`qcdxx86compiler8280.DLL`、`qcdxarm32compiler8280.DLL`、
  `qcdx11x86um8280.dll`、`qcdxsdchpe.dll` —— 它们**所在的驱动包目录名就是 `qcdx8280.inf_arm64_*`**，
  即"ARM64 驱动包里故意附带的 x86/ARM32 助手"（让 x86 应用能 JIT 自己的着色器）。
- ⇒ **结论**：驱动侧**没有"x64 应用等着被重写成 ARM64"这件事**。「重写 x64 应用」这个目标需要**重新定义**。

### 1.2 原厂应用**不在**我们的转储里【已核实】

`Recovery/` 全域递归按扩展名统计：`.appx/.msix/.appxbundle/.msixbundle` **零命中**。
该目录实际是**驱动 + 固件仓库**：`.inf` 156、`.cat` 156、`.dll` 135、`.sys` 94、`.bin` 107、`.mbn` 28（高通固件）、
`.so` 34（248 MB）。⇒ 要回答"哪些预装应用是 x64"，**必须在活的 Windows 上点名**
（`Get-AppxPackage | Select Name,Architecture` / 卸载表 / 逐文件读 PE 头）。

### 1.3 找到了"原厂答案"：首次开机配置脚本【已核实目录结构，内容调研中】

`Recovery\OEM\Customization\General\` 下是原厂 OOBE/首次开机定制，每个子目录一个 `install.cmd`：

```
AR000DOIT7\PAR_install.cmd        close_bitlocker\install.cmd      deviceform_setting\install.cmd
edge_setting\install.cmd          oem_infomation\install.cmd       oem_license\install.cmd
sata_ssd_control_setting\install.cmd                               sleep_mode_setting\install.cmd
```

另有 `Recovery\OEM\Customization\Product\Dirvers2PE\PlatformDriver\`（**预置进 WinRE 的平台驱动**，
含高通的 `qcSubsysThermalMgr`（Subsystem Thermal Manager，`DriverVer 06/07/2022,1.0.3508.3900`，
`[Manufacturer] ... NTARM64`）、`Recovery\OEM\OOBEExtraSource\`、`Recovery\OEM\RecoveryTool\`。

⇒ **意义**：原厂为这台机器设定的**睡眠/存储/热管理策略写在它自己的脚本里**——这是"最省电的 Win11"的
ground truth，比我们凭经验猜要可靠得多（正在逐条解析原文命令）。

### 1.4 原厂自己的"省电/睡眠"答案（脚本原文）【已核实】

`Recovery\OEM\Customization\General\` 下这些 `install.cmd` 的**实际动作**：

| 脚本 | 它做了什么 |
|---|---|
| `sleep_mode_setting` | 先查 `HKLM\SYSTEM\CurrentControlSet\Control\Power\ModernSleep\EnabledActions` 判断本机是否支持 **Modern Standby**；支持则执行 `powercfg /setdcvalueindex scheme_current sub_presence standbybudgetpercent 2`（**待机预算 2%**），把 `e73a048d-…\9a66d8d7-…`（SUB_BUTTONS 下的动作项）在 **Balanced / High performance / Power saver 三个计划**里都设为 `2`（该 GUID 对的确切语义待核，标【推测】），最后 `powercfg /X hibernate-timeout-dc 180` + `hibernate-timeout-ac 180`，并把注册表 `Themes\…\9d7815a6-…`（"Hibernate after"）写成 `10800` 秒 ⇒ **空闲 180 分钟自动休眠** |
| `sata_ssd_control_setting` | `powercfg /setAcValueIndex` + `/setDcValueIndex <Balanced> 0012ee47-…(SUB_DISK) 0b2d69d7-…(磁盘空闲超时) 3`；随后 `powercfg -attributes SUB_DISK 0b2d69d7-… +ATTRIB_HIDE` —— **把这项设置从电源界面隐藏**（用户改不了） |
| `close_bitlocker` | 仅当支持 Modern Sleep 时写 `HKLM\SYSTEM\CurrentControlSet\Control\BitLocker\PreventDeviceEncryption = 1` ⇒ **关闭自动设备加密** |
| `deviceform_setting` / `edge_setting` / `oem_infomation` / `oem_license` / `AR000DOIT7\PAR_install.cmd` | 形态/地区/许可证与安装参数（与省电无关，逐条解析进行中） |

★ **对"待机掉电"的直接启示（Windows 与 Linux 两侧都适用）**：原厂策略**不是**"靠省电熬过 s2idle"，
而是 **Modern Standby(s2idle) + 空闲 180 分钟转休眠(S4)**。我们 Linux 侧缺的正是这一步 ⇒
**r5 应当优先验证 `suspend-then-hibernate`**（systemd `HibernateDelaySec`）：屏灭后先 s2idle、
到点转 S4。这个方案还有个额外好处——**不必先解决 PDC 秒醒问题**：秒醒只是退回 s2idle，
最终仍会被 hibernate 兜住。前置条件：本机 `/sys/power/state` 必须含 `disk`，且要有可用的 swap 分区。

### 1.5 Linux 侧 S4 可用性实测（r5 的直接依据）【已核实】

在平板（本项目的 r4/r4-dev 内核）上实测：

| 检查 | 结果 |
|---|---|
| `/sys/power/state` | **`freeze mem disk`** —— 支持 s2idle / S3 / **S4(disk)** |
| 内核配置 | `CONFIG_HIBERNATION=y`、`CONFIG_HIBERNATION_SNAPSHOT_DEV=y`、`CONFIG_SWAP=y`、`CONFIG_PM_SLEEP=y` |
| swap | **完全没有**（`/proc/swaps` 空）；cmdline 上也没有 `resume=` |
| systemd | `systemd 259`，`systemd-suspend-then-hibernate.service` **存在** |
| 内存 | 15 GiB 级（hibernation `image_size` 提示 5.9 GiB） |

⇒ **结论**：本机**具备 S4 能力**，`suspend-then-hibernate` 这条路只差三件事：
① 建一块 **swap 分区**（优于 swap 文件：免 `resume_offset`，且必须先于 swap 文件排除在 rootfs 快照之外）；
② 在我们自己的 BLS 条目 cmdline 上加 `resume=UUID=<swap>`（仍然只改我们的条目）；
③ 设 `HibernateDelaySec`（对应原厂的 180 分钟）并 A/B 实测。
这与 §1.4 原厂策略完全吻合（**s2idle + 180 min 转 S4**），也是解决"整夜掉电"最短的一条路：
**秒醒不再致命**——每次被 PDC 拉醒只是回到 s2idle，计时到点仍会转 S4。

## 2. 各工作包可行性读数（随调研更新）

| 工作包 | 当前读数 | 依据 |
|---|---|---|
| (a) x64→ARM64 | **重新定义**：驱动已全 ARM64；应用侧待查（若确有 x64 应用，**没有源码就不存在"重写"**，只能找 ARM64 官方版 / 商店·开源等价物 / 对自研小工具做 clean-room） | §1.1 §1.2 |
| (b) 管家 APP | 【待调研】标准 API 能覆盖的部分大概率可行；电池保养阈值/性能模式/Huawei Share/指纹与笔设置很可能在专有驱动后面 | 调研中 |
| (c) 调度省电 | 【待调研】EcoQoS、EPP/核心停泊、Modern Standby 网络活动等官方旋钮 + `powercfg /sleepstudy` 测量；**另有原厂脚本可参照** | §1.3 + 调研中 |
| (d) Linux + Android | 【待调研】WSL2/WSLg 在 ARM64 可用；**ARM64 的 WSL GPU 直通需核实**；WSA 已于 2025-03-05 终止 ⇒ 安卓看 Waydroid（自建 binder 内核）或社区魔改 | 调研中 |

## 3. 发布边界（红线，已定）

- 改过的 **Windows 镜像不可公开分发**（微软许可）；`Drv/` 厂商驱动**不可入库**（项目 §0.4 第 6 条）。
- 可公开交付的只有**脚本与配置**：`unattend.xml`、去预装/去遥测清单、winget/DISM 清单、
  **驱动注入脚本（引用用户本地 `Drv/` 路径）**、WSL2/WSLg 配置、电源调优、以及复现文档。

## 4. 待补章节（调研中，产物在 `%TEMP%\win-report\`）

- `A2-oem-customization.md`：原厂首次开机脚本逐条解析 + 驱动覆盖清单（能否装回原样、缺什么）
- `B-manager-app.md`：管家 APP 的接口边界（标准 API vs 厂商专有）
- `C-power-tuning.md`：调度/省电旋钮与测量方法
- `D-wsl-android.md`：WSL2 ARM64（含 GPU 与自建内核）+ 安卓路径对比

## 5. 方法与可复现性

本节的 PE 架构统计可用等价命令复现（PowerShell，读 `e_lfanew` 处的 Machine 字段；`0xAA64`=ARM64、
`0x8664`=x64、`0x014c`=x86、`0x01c4`=ARM），脚本见 `%TEMP%\win-pe-tally.ps1`（本报告不附代码，避免误用）。
