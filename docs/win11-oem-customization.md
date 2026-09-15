# 原厂基线解剖与 (a) 工作包可行性（Windows 可行性报告 · 工作包 (a)）

> 目标设备：**HUAWEI MateBook E Go 2022 性能版（GK-W76 / Snapdragon 8cx Gen 3 / SC8280XP）**
> 取证对象：本项目已转储的原厂恢复分区（`Recovery/`，1,222 文件 / 3,987.7 MB）与 Windows 驱动转储
> （`Drv/`，962 文件 / 1,153.6 MB）。**两者都不入库**（体积 + 专有软件，见项目 §0.4 第 6 条）。
> 本章只回答"原厂到底装了什么、是什么架构、能不能换"，**不含实现**。
> 置信度口径：**【已核实】**=本次直读一手文件/官方文档 · **【社区报告】**=他人实测 · **【未核实】**=尚未确认。

## 0. 结论摘要

| 问题 | 结论 |
|---|---|
| 「原厂自带 x64 应用」这个前提成立吗？ | **在"应用"这一层成立，在"驱动"这一层不成立**【已核实】。驱动转储里 177 个 PE 有 **133 个是 ARM64 原生**；而原厂预装软件载荷（ICB）里 2,767 个二进制中 **2,513 个（91%）是 x86/x64** |
| 举几个最硬的例子 | **Office 2021 装的是 x64 版**（`WINWORD.EXE`/`EXCEL.EXE` 在 `root\Office16` 下是 `0x8664`）【已核实】；**华为电脑管家 13.0.2.330 的 42 个 exe 全是 x64**【已核实】；只有**华为浏览器**和 **Edge/EdgeWebView** 是 ARM64 |
| 那"重写成 ARM64"可行吗？ | **不是重写，是替换与取舍**：有官方 ARM64 版的（Office、Edge、VC++ 运行库）换官方版；没有的（华为自有组件）只能在"保留模拟运行 / 找开源等价物 / 自研"之间选。**反编译闭源二进制再重编不合法也不现实** |
| 原厂自己是怎么装机的？ | 一套**脚本化的 OOBE 定制框架**（`setup.cmd` → `InstallCustomization.cmd` → 逐目录 `install.cmd`）+ **驱动预注入 WinPE** + **预装软件用 ICB（Initial Configuration Blob）回放**。这套框架是我们复刻"干净版"的直接模板 |
| ★ 最大的风险 | **原厂 OS 镜像不在我们的转储里**（`Recovery/` 下无 `.swm/.wim/.esd`，也没有 `C:\Shipping_Image`）⇒ **一旦抹盘，原厂系统就再也回不来了**。必须在动手前先把内置盘的 WinPE/Onekey/WinRE 分区完整 dump 出来 |

## 1. 取证对象与方法（可复现）

| 对象 | 内容 | 规模 |
|---|---|---|
| `Drv/` | Windows **驱动**转储，按设备管理器 19 个类别组织 | 962 文件 / 1,153.6 MB / 146 `.inf` / 69 `.sys` |
| `Recovery/OEM/` | 原厂**首次开机定制脚本** + WinPE 平台驱动 + WinRE/WinPE 支持文件 | 1,220 文件 / 1,259.1 MB |
| `Recovery/OEM/Customization/` | 定制脚本树（`General` / `Product` / `Regional`） | 1,161 文件 / 882.9 MB |
| `Recovery/OEM/OOBEExtraSource/` | 首次开机后要安装的载荷（GPU 驱动包 + 账户初始化工具） | 43 文件 / 376.1 MB |
| `Recovery/Customizations/USMT.ppkg` | **原厂预装软件与机器状态快照（ICB）** | 2.66 GB（解压后 8.19 GB） |

**两个关键取证技巧（都会写进新仓库的工具）**

1. **读 PE 机器类型**：读 `e_lfanew` 处的 `Machine` 字段 —— `0xAA64`=ARM64、`0x8664`=x64、`0x014c`=x86、`0x01c4`=ARM32。
2. ★ **`USMT.ppkg` 其实是一个 WIM**（魔数 `MSWIM`，1 个映像 `Initial Configuration Blob`），但 **DISM 会因为
   `.ppkg` 扩展名直接报 `Error: 87 参数错误`**；在**同一卷**上建一个 `.wim` 硬链接（`New-Item -ItemType HardLink`）
   后即可 `dism /Mount-Image /ReadOnly` 挂载浏览【已核实】。ICB 的头信息就写在 `ICB/ICB.xml` 里。

## 2. ★ 原厂预装软件的权威清单（`ICB.xml`）【已核实】

`ICB.xml` 是原厂机器状态的元数据，直接给出**参考机信息**与**预装应用清单**：

| 元数据 | 值 |
|---|---|
| 来源机型 | `HUAWEI` / **`GK-W7X`**（与目标机同款平台） |
| 来源 OS | Windows 11 **build 22000**，架构码 `12`（ARM64），语言 `2052`（简体中文） |
| 来源固件 | BIOS **2.09**，日期 **2022-09-21** |
| 来源 SoC / 内存 | Snapdragon **8cx Gen 3 @ 3.0 GHz**（ARMv8 64-bit）/ 16 GB |
| AoAc（Modern Standby 能力） | **Yes** |
| 构建主机名 | `WIN-OLG5KM804J4`（原厂打包机） |
| **预装应用数** | **13** |

| # | 应用 | 发布者 | 版本 |
|:-:|---|---|---|
| 0 | AppGallery | Huawei Technologies | 2.2.10.300 |
| 1 | HMS Core | Huawei Technologies | 6.7.0.300 |
| 2 | Microsoft Office 家庭和学生版 2021（zh-cn） | Microsoft | 16.0.14326.20454 |
| 3 | HW OSD | Huawei Device | 13.0.2.300 |
| 4 | Cloud（华为云空间） | Huawei Technologies | 11.2.2.300 |
| 5 | Microsoft OneNote（zh-cn） | Microsoft | 16.0.14326.20454 |
| 6 | **华为电脑管家（多屏协同和官方驱动）** | Huawei Device | 13.0.2.330 |
| 7 | 华为浏览器 | Huawei Software Technologies | 12.0.1.300 |
| 8 | Microsoft Edge | Microsoft | 90.0.818.66 |
| 9 | Microsoft Edge Update | Microsoft | 1.3.143.57 |
| 10 | Microsoft Edge WebView2 Runtime | Microsoft | 90.0.818.66 |
| 11 | WDT_Device_Driver | — | — |
| 12 | **Microsoft Visual C++ 2019 Redistributable (Arm64)** | Microsoft | 14.29.30035 |

**两个可以直接读出来的信号**：① 原厂**主动选择了 Arm64 版 VC++ 运行库**，说明这台机器上的原生 ARM64
组件是"有意为之"的；② 预装清单里**没有第三方杀软、没有游戏、没有推广全家桶**，比同价位消费级笔记本干净得多
—— "干净无预装"这条目标的实际起点比想象的高，**主要工作量在"换掉华为生态组件"而不是"清理垃圾"**。

## 3. ★ 架构量化：应用层几乎全是 x64【已核实】

对 ICB 内全部 2,767 个 PE 二进制（`.exe/.dll/.sys/.efi`）逐个读机器类型：

| 架构 | 文件数 | 占比 | 合计体积 |
|---|---:|---:|---:|
| **x86-64（`0x8664`）** | **1,851** | **66.9%** | **2,827.6 MB** |
| x86（`0x014c`） | 662 | 23.9% | 897.5 MB |
| **ARM64（`0xAA64`）** | **240** | **8.7%** | 949.7 MB |
| ARM32（`0x01c4`） | 4 | 0.1% | 3.5 MB |
| 非 PE / 无法解析 | 10 | 0.4% | — |

即 **91.3% 的预装二进制不是 ARM64**。但"是非 ARM64 二进制"≠"是必须重写的 x64 应用"，按目录拆开后结论清晰得多：

| 组件（`C:\` 下） | 文件数 | 体积 | ARM64 | x64 | x86 | 判读 |
|---|---:|---:|---:|---:|---:|---|
| `Program Files\Huawei\PCManager` | 427 | 380.0 MB | 5 | **374** | 48 | **华为电脑管家整体是 x64**（42 个 exe 全 x64） |
| `Program Files\Huawei\Cloud` | 417 | 486.3 MB | 0 | **402** | 15 | 华为云空间 x64 |
| `Program Files\Huawei\AppGallery` | 91 | 450.3 MB | 0 | **88** | 3 | 应用市场 x64（含 139.6 MB 的 `AppGallery.exe`） |
| `Program Files\Huawei\Browser` | 36 | 246.9 MB | **33** | 0 | 3 | **华为浏览器是 ARM64** |
| `Program Files\Huawei\HMS Core` | 59 | 42.1 MB | 0 | **58** | 0 | x64 |
| `Program Files\Huawei\Hiview` | 58 | 46.3 MB | 0 | **57** | 0 | x64（日志/诊断组件） |
| `Program Files\Huawei\HwSmartAudio` | 48 | 53.7 MB | 0 | 38 | 10 | x64 |
| `Program Files\Huawei\BasicService` 等 | 178 | ~130 MB | 1 | 157 | ~20 | 基本全 x64 |
| `Program Files\Microsoft Office\root` | 970 | 1,957.9 MB | 26 | **539** | 396 | **Office 2021 装的是 x64/x86 版**，不是 ARM64 版 |
| `Program Files (x86)\Microsoft\Edge*`（Edge/EdgeCore/EdgeWebView） | 135 | ~683 MB | **120** | 0 | 15 | **Edge 系是 ARM64**（装在 `(x86)` 路径下只是 Chromium 的历史习惯） |
| `Program Files (x86)\Microsoft\EdgeUpdate` | 101 | 9.5 MB | 3 | 3 | 95 | 更新器仍是 x86 |
| `Program Files\Common Files\microsoft shared` | 149 | 92.1 MB | 0 | 117 | 32 | ClickToRun 等 x64 共享组件 |
| `Windows\System32`（增量部分） | 67 | 61.4 MB | 52 | 15 | 0 | OS 本体 ARM64；x64 集中在 `System32\HWAudioDriver` |
| `Windows\SysWOW64` | 15 | 24.1 MB | 0 | 0 | 15 | 32 位子系统；含 Adreno 的 `qcdxx86compiler8280.DLL` |
| `Program Files (Arm)` | 0 | — | — | — | — | **空**（原厂没有把任何应用装进 Arm 目录） |

**Office 的铁证**：`root\Office16\WINWORD.EXE`、`EXCEL.EXE`（69.9 MB）、`POWERPNT.EXE`、`ONENOTE.EXE`
以及 `Common Files\microsoft shared\ClickToRun\OfficeClickToRun.exe` 全部是 `0x8664`；另有 `Microsoft Office 15\ClientX64` 目录。
⇒ **原厂在这台 ARM64 机器上装的是 x64 版 Office，靠 Windows 11 的 x64 模拟运行**【已核实】。

## 4. 三层结论与「重写」的正确定义

| 层 | 原厂实际 | 「x64→ARM64」是否适用 |
|---|---|---|
| **驱动 / 固件** | **ARM64 原生**（`Drv/` 177 个 PE 中 133 个 ARM64；非 ARM64 的 22 个 x86 + 19 个 ARM32 全是 Adreno 的 CHPE/着色器编译器，存放在 `qcdx8280.inf_arm64_*` 这类 **ARM64 驱动包**里，供 x86 应用 JIT 自己的着色器） | **不适用**——没有"x64 驱动"可重写 |
| **操作系统** | ARM64 原生（`System32` 中 52/67 ARM64） | 不适用 |
| **应用** | **x64/x86 为主**（91.3%） | **适用**，但只能"换版本 / 换代品 / 自研 / 保留模拟"，**不能反编译重写** |

**"重写"的四种可行手段**（按性价比排序）：

1. **换成官方 ARM64 版本**：Office（ARM64 版官方存在）、Edge（已是 ARM64）、VC++ 运行库（原厂已选 Arm64）。
   零法律风险、零开发量。
2. **换成开源/商店等价物**：华为浏览器 → Edge/Chromium（已是 ARM64）；华为云空间 → OneDrive/网盘客户端；
   应用市场 → winget/Store。
3. **自研替代**：华为电脑管家 → 本项目 (b) 工作包的自研管家 APP（**原生 ARM64 才有意义**，见
   `win11-manager-app.md`）。
4. **保留 x64 靠模拟运行**：Windows 11 ARM64 自带 x64 模拟层，代价是性能与功耗 —— 这也是**原厂的选择**。
   对"省电优先"的目标来说，把高频常驻组件（PC Manager、云空间、HMS Core）换成 ARM64 或移除，
   是**唯一能直接省电**的一项。

> **红线**：反编译闭源二进制再重新编译成 ARM64 **既不合规也不可行**（无源码、无符号、绕过授权）。
> 本项目公开交付的只能是**脚本、清单与自研 ARM64 组件**；华为/微软的二进制一律不入库。

## 5. 逐应用处置建议

| 应用 | 原厂架构 | 处置建议 | 备注 |
|---|---|---|---|
| Microsoft Office 2021 | **x64** | 装**官方 ARM64 版**（或 Microsoft 365 ARM64） | 体积最大的单项（1.96 GB），换版收益最直接 |
| Microsoft Edge / WebView2 | ARM64 | **保留并升级**（原厂停在 90.0.818.66，2022 年版本） | 已是 ARM64，无需处理 |
| Microsoft Edge Update | x86 | 随 Edge 升级 | 更新器仍为 x86 |
| MSVC++ 2019 Redist (Arm64) | ARM64 | 保留 | 原厂已经选对 |
| 华为电脑管家 13.0.2.330 | **x64** | **自研管家替代**（(b)）或整体移除 | 42 个 x64 exe；它是常驻组件，替换的省电收益最大 |
| 华为云空间 / AppGallery / HMS Core / Hiview / HwSmartAudio | **x64** | 按需保留；不要的**整体移除**（不是逐个换架构） | 移除后靠 x64 模拟层的负载随之消失 |
| 华为浏览器 | ARM64 | 可保留，或换 Edge | 原厂唯一 ARM64 的自研应用 |
| HW OSD / WDT_Device_Driver | 【未核实】 | 先确认职责再决定 | 两者在 ICB 的 `C:\` 快照里未定位到文件，可能属驱动/服务组件 |

## 6. 原厂首次开机流程（逐条解析）【已核实】

原厂不是"装完镜像就完事"，而是一套**可编程的定制框架**。链条如下：

```
WinRE / 恢复环境
  └─ Recovery\OEM\ResetConfig.xml        ← 工厂重置的入口声明
       ├─ Phase=BasicReset_AfterImageApply / FactoryReset_AfterImageApply → 运行 setup.cmd（超时 5）
       └─ SystemDisk: MinSize=8000, DiskpartScriptPath=ReCreatePartitions.txt,
          OSPartition=3, WindowsREPartition=4, WindowsREPath=Recovery\WindowsRE
  └─ Recovery\OEM\setup.cmd
       ├─ 从 HKLM\SOFTWARE\Microsoft\RecoveryEnvironment 的 TargetOS 解析目标系统盘
       ├─ 日志写 <系统盘>\Recovery\OEM\recovery.log
       ├─ 调 InstallCustomization.cmd recovery
       └─ ★ 把系统盘根目录下**除** Program Files / Program Files (x86) / Users / Windows
          之外的**所有目录 `attrib +h` 隐藏**（这就是出厂系统里 `C:\Recovery` 看不见的原因）
  └─ Recovery\OEM\InstallCustomization.cmd
       ├─ 从 Recovery\OEM\Version.txt 解析 SKU（本机 = Gaokun-W7821T 3.212.0.23(**C233**) → china）
       ├─ 依次遍历 Customization\General → \Regional → \Product 下的**每一个 install.cmd**
       └─ 以 `install.cmd <install|recovery> <sku> <office_installed>` 调用（错误即中断整体流程）
  └─ 各 install.cmd 均有**双分支**：
       install  分支 = 直接改当前系统（reg add / powercfg）
       recovery 分支 = `reg load HKLM\TempHive <系统盘>\Windows\System32\config\System` → 离线改注册表 → unload
  └─ 首次开机后：Recovery\OEM\RecoveryTool\OOBE_Install.cmd
       ├─ 遍历 C:\Recovery\OEM\OOBEExtraSource 下的 App_list.txt（或目录里的 *.cmd/*.bat/*.exe）**逐个执行**
       ├─ 结果写 result.txt
       └─ 删除 C:\Shipping_Image（安装源，回收空间）
  └─ Recovery\OEM\RecoveryTool\preload_startup.cmd → C:\Shipping_Image\InstallTool\preload_installer.exe
```

**已被解析出的关键事实**

- **SKU 映射**（`InstallCustomization.cmd`）：`C128/C129/C138`=运营商、`C233/C243/C235/C245`=中国、
  `C228/C229/C239/C189`=日本、`C001/C010/C170/C171/C331/C188`=美国、`C300`=零售。本机 **C233**。
- **原厂参数表**（`RecoveryTool\product.ini`）：`product_name=Gaokun`、`product_model=MateBook E Go`、
  `product=GK-W7X`、`critical_power_percentage=2`、`disconnect_standby=001`、`adaptive=1`、`brightness=50`。
- **OEM 系统版本串**：`Gaokun-W7821T 3.212.0.23(C233)`；构建配置 `preload_final_config.ini`：
  `final_install_way=MasterInstall`、`install_type=PXE`、`csup_time=09-21-2022`。
- **原厂 OS 镜像是 3 段拆分 WIM**（`clear_items_file.txt`）：
  `05018SSN_Gaokun-W7821T_3.212.0.23-C233_T0-part.swm` + `part2` + `part3`，
  装完即删除；`InstallOrder.ini` 里唯一的安装项是 `%SystemDrive%\Recovery\Customizations\USMT.ppkg`。
- **`Product\` 定制（与省电/可用度直接相关）**：
  | 脚本 | 动作 |
  |---|---|
  | `close_allow_wake_timers` | SUB_SLEEP 的 `BD3B718A-0680-4D9D-8AB2-E1D2B4AC806D`（允许唤醒定时器）在 Balanced 计划 DC 置 **0** |
  | `ssd_power_reduce` | SUB_DISK 的 `d639518a-e56d-4345-8af2-b9f32fb26109` DC 置 **20**（SSD 空闲相关） |
  | `critical_battery_percentage` | 用 `product.ini` 的 `critical_power_percentage=2` 写 SUB_BATTERY 的 `9a66d8d7-…` 到三个计划 ⇒ **关键电量 2%** |
  | `backlight_optimization` | 导入 `source\Brightness3.reg` |
  | `HVCI_VBS` | `DeviceGuard\EnableVirtualizationBasedSecurity=1` 且 `HypervisorEnforcedCodeIntegrity\Enabled=0` ⇒ **VBS 开、HVCI 关** |
  | `uninstall_graphics` | recovery 分支用 `dism /get-drivers` + `DISM /Remove-Driver` 把 **`qcdx8280`（Adreno 显示驱动）从镜像里移除** |
  | `Dirvers2PE\PAR_install.cmd` | `DISM /image:w:\ /add-driver /driver:<PlatformDriver> /recurse` 注入 **WinPE**（PE 盘符 = `W:`），并复制 `qdcmlib\*` 到 `W:\Windows\System32` |
- ⇒ **原厂"先卸后装"显示驱动的用意**：镜像里不带 Adreno 驱动，等进了系统再用 `pnputil` 装 —— 这是我们
  做"干净镜像 + 驱动后注入"路线可以直接照抄的手法（`OOBEExtraSource\singleDriverInstall.cmd` 只有一行
  `pnputil -i -a C:\Recovery\OEM\OOBEExtraSource\qcdx8280\*.inf`）。
- `Dirvers2PE\PAR_install.cmd` 里有大段**被注释掉的实验代码**（导入 `EnableHyperV.reg`、导入
  `oem_test_cert.reg`、把 `qdcmlib\x64\qdcmlib.dll` 复制成 `qdcmlib_x64.dll`）—— 说明原厂曾尝试在 PE 里
  打开 Hyper-V/HVCI 并携带 x64 助手，最终**没有启用**。这与 (d) 工作包的 WSL2/Hyper-V 议题直接相关。

## 7. 驱动覆盖清单（`Drv/`，按设备管理器类别）【已核实】

| 类别 | 文件数 | 体积 | `.inf` | 说明 |
|---|---:|---:|---:|---|
| 显示适配器 | 78 | 750.0 MB | 3 | Adreno 690（`qcdx8280.inf`）+ `mm.inf`；体积最大项 |
| 扩展 | 388 | 267.9 MB | 52 | 各子系统的 Extension INF（相机/音频/子系统/子系统散热…） |
| 音频处理对象 (APO) | 30 | 38.1 MB | 5 | Histen / HiVA / HWVE / VoiceClarity（华为音效链） |
| 照相机 | 43 | 34.5 MB | 8 | 高通相机栈（ISP/JPEG/MIPI-CSI/前摄/后摄/Flash/AVS/Platform） |
| 系统设备 | 203 | 18.2 MB | 45 | PMIC、PIL、SCM、I2C/SPI/GPIO、子系统散热管理、WLAN 睡眠管理等 |
| 网络适配器 | 38 | 17.6 MB | 2 | `qcwlan8280.inf`（WCN6856）+ `rtucx22arm64.inf`（USB-C 网卡） |
| 软件组件 | 21 | 13.0 MB | 2 | 华为音频服务、ListenSM |
| 生物识别设备 | 14 | 5.5 MB | 2 | FocalTech + Goodix 指纹（**Linux 侧不可用**，见 `docs/fingerprint.md`） |
| 传感器 | 12 | 2.5 MB | 3 | 常开 CV 传感器、人体存在传感器、高通传感器框架 |
| 存储控制器 | 9 | 1.5 MB | 3 | `xvdd.inf`（虚拟盘）等 |
| 声音、视频和游戏控制器 | 10 | 1.4 MB | 2 | 高通音频（`qcaucd8280`） |
| 蓝牙 | 45 | 1.3 MB | 2 | `qcbtfmuart_hsp8280` |
| 通用串行总线设备 / 控制器 | 19 | 1.0 MB | 5 | `qcusbcucsi8280`、`qcxhcifilter8280` 等 |
| FS HSM 筛选器 | 9 | 0.5 MB | 3 | `gameflt.inf` 等 |
| 端口 (COM 和 LPT) | 8 | 0.3 MB | 1 | `qcuart8280` |
| 打印机 | 21 | 0.2 MB | 4 | Microsoft 通用打印驱动（非厂商） |
| **THP devices** | 8 | 0.1 MB | 2 | **`hidinjectorthp.inf` / `spbthptool.inf`**：触屏/笔的 HID 注入与 SPI 测试通道（Linux 侧触屏逆向的第一手参考） |
| 监视器 | 6 | 0.1 MB | 2 | `monitor.inf`（内屏 PnP ID） |
| 合计 | **962** | **1,153.6 MB** | **146** | |

**结论**：**没有任何硬件类别缺驱动** —— 显示、音频、相机、指纹、传感器、触屏/笔、蓝牙、WLAN、USB-C、
存储、子系统散热管理全部在转储里，且**全部是 ARM64 原生包**。⇒ 只要这块盘不丢，"重装原厂 Windows"
在驱动层面是完备的。

## 8. ★ 备份完整性核对（回答 §16.1 的遗留问题）

**核对方法**：在 `Recovery/` 全域按扩展名搜索 OS 镜像，并核对原厂脚本引用的路径是否存在。

| 检查项 | 结果 |
|---|---|
| `Recovery/` 下的 `.swm / .wim / .esd / .iso / .vhd(x)` | **零命中**（除 ICB 之外没有任何 OS 镜像） |
| 原厂脚本引用的 `C:\Shipping_Image\`（`InstallSource\OS\*.swm` 所在处） | **转储里不存在** |
| 原厂镜像文件名（`05018SSN_Gaokun-W7821T_3.212.0.23-C233_T0-part*.swm`） | 只出现在 `clear_items_file.txt` 的**文字**里 |
| 有的东西 | `Drv/`（驱动 1.15 GB）、`Recovery/OEM/`（定制脚本 + WinPE 平台驱动 + GPU 载荷 1.26 GB）、`Recovery/Customizations/USMT.ppkg`（ICB 2.66 GB） |

⇒ **结论【已核实】：本次转储不包含原厂 OS 镜像。** 原厂系统的唯一副本目前仍在内置盘的
**WinPE（p5）/ Onekey（p6）/ WinRE（p7）** 分区里。**在抹盘或重装之前，必须先完整 dump 这三个分区**，
否则原厂系统永久丢失（本机 **无 EDL/9008 救援通道**，项目已多次记录该风险）。

## 9. 原厂分区蓝图（重装脚本的直接依据）【已核实】

原厂自带三套 diskpart 脚本 + 参数文件：

| 文件 | 用途 | 关键参数 |
|---|---|---|
| `HuaweiPartitionSize.txt` | 参数 | `OnekeySize=18`（GB） |
| `DiskpartScript.txt` | 18 GB Onekey 机型 | ESP 300 MB FAT32 / MSR 16 MB / Windows **122,880 MB** / Data(shrink 20,480) / **WinPE 19,456 MB FAT32** / Onekey 1,024 MB / WinRE 剩余 |
| `DiskpartScript128G.txt`、`DiskpartScript2HD.txt` | 128 GB 与双盘机型变体 | 同上，容量策略不同 |
| `ReCreatePartitions.txt` | **工厂重置时使用**（`ResetConfig.xml` 指定） | ESP 300 / MSR 16 / Windows 122,880 MB / **WinRE 1,024 MB** / Data 剩余；`OSPartition=3`、`WindowsREPartition=4` |

所有恢复类分区都打 **WinRE 类型 GUID `de94bba4-06d1-4d40-a16a-bfd50179d6ac`**。
⇒ 重装脚本必须**逐字节复刻这套布局**（尤其是 ESP 300 MB 与 WinPE 的 FAT32 19 GB），否则原厂的
一键恢复（Onekey）与 WinRE 恢复链会失效。

## 10. 未核实项与下一步

1. **HW OSD 与 WDT_Device_Driver 的架构与职责未定位**（`ICB.xml` 报了这两个"应用"，但在 ICB 的 `C:\`
   快照里没有对应目录）⇒ 可能是驱动/服务组件。核对方法：在活的系统上看
   `Get-CimInstance Win32_Service | ? { $_.PathName -match 'OSD|WDT' }`。
2. **活系统上的预装应用实况未取**（本章的架构统计来自**原厂打包时的 ICB 快照**，不是目标机出厂后的实测；
   出厂后系统可能已通过 Store/更新改变了版本）。建议在目标机上执行
   `Get-AppxPackage | Select-Object Name,Architecture,Version` 与
   `Get-CimInstance Win32_Product | Select-Object Name,Version` 做一次对账。
3. **`Program Files (Arm)` 为空**是否等价于"系统里没有任何 ARM64 应用"——不能这么推：ARM64 应用也可以装在
   `Program Files`（华为浏览器就在 `Program Files\Huawei\Browser`）。
4. **WinPE/Onekey/WinRE 三分区的镜像与工具清单未取**（本章只确认了"转储里没有"）⇒ 抹盘前必须补齐。
5. **华为电脑管家是否有 ARM64 版本**：公开渠道未见 ARM64 版发行，**未核实**；这决定 (b) 工作包自研管家的
   必要性（见 `win11-manager-app.md`）。

## 11. 复现命令

```powershell
# 1) PE 架构统计（对任意目录递归）
$files = Get-ChildItem <目录> -Recurse -File -Include *.exe,*.dll,*.sys,*.efi
foreach ($f in $files) {
  $fs = [IO.File]::OpenRead($f.FullName); $b = New-Object byte[] 4
  [void]$fs.Seek(0x3C, 'Begin'); [void]$fs.Read($b, 0, 4)
  $pe = [BitConverter]::ToInt32($b, 0); [void]$fs.Seek($pe + 4, 'Begin'); [void]$fs.Read($b, 0, 2)
  $fs.Dispose(); '{0:X4}  {1}' -f [BitConverter]::ToUInt16($b, 0), $f.FullName
}

# 2) 挂载原厂 ICB（关键：必须用同卷 .wim 硬链接，否则 DISM 报 Error 87）
$src = 'D:\androidGaokun\Recovery\Customizations\USMT.ppkg'
New-Item -ItemType Directory D:\icbtmp -Force | Out-Null
New-Item -ItemType HardLink -Path D:\icbtmp\USMT.wim -Target $src | Out-Null
dism /English /Mount-Image /ImageFile:D:\icbtmp\USMT.wim /Index:1 /MountDir:D:\icbtmp\mnt /ReadOnly
Get-ChildItem D:\icbtmp\mnt\ICB\0\MachineSpecific\File\C$ -Force   # 原厂 C:\ 快照
Get-Content  D:\icbtmp\mnt\ICB\ICB.xml                              # 预装应用清单
dism /English /Unmount-Image /MountDir:D:\icbtmp\mnt /Discard       # 收尾

# 3) 原厂定制脚本树
Get-ChildItem D:\androidGaokun\Recovery\OEM\Customization -Recurse -Filter install.cmd
```
