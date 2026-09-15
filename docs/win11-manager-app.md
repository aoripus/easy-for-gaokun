# 自研"管家"APP 的接口边界（Windows 可行性报告 · 工作包 (b)）

> **适用设备**：HUAWEI MateBook E Go **2022 性能版**（`GK-W76`，Snapdragon 8cx Gen 3 / SC8280XP，Adreno 690，**无风扇**，Windows 11 ARM64）；**不适用于** 2022 LTE 版与 2023 版（变体鉴别见项目台账 §0.2）。
> **本文回答**：自研 ARM64 原生"管家"（对标华为电脑管家 / Lenovo Vantage）能拿到哪些接口、哪些功能做不到、法律与分发边界在哪、技术栈怎么选；不含实现与 UI 设计。置信度标 **【已核实】/【社区报告】/【推测】/【未核实】**，凡"目标机 `GK-W76` 上是否有值"未经真机验证的一律写 **【未核实】**。
> **★ 证据环境边界**：标准 API 的枚举与调用实测跑在**另一台 x64 机器**（AMD64 笔记本，Windows 10 企业版 LTSC 10.0.19044）上，**不是 `GK-W76`**。实测只证明"该 API 在真实 Windows 上**存在、可调用、可能被填充**"，**不代表目标机有值**：IOCTL / PDH 计数器集 / WMI 类 / WinRT 契约等 API 契约跨架构不变，取值由固件或驱动决定，故取值类结论逐条标注。

## 0. 结论摘要

| 项 | 结论 | 置信度 |
|---|---|---|
| 标准 API 覆盖率 | 用户日常关心的功能约 **80%** 可由公开 API 覆盖：电池健康度 / 循环次数 / 充放电功率、**降频归因**、GPU 利用率与显存、电源计划与 EcoQoS、SMBIOS、启动项与服务、驱动清单、WU 查询 | 【已核实】API 存在，取值为 x64 取证机 |
| 唯一的硬墙 | **充电阈值 / 保养模式**：Windows **没有任何**公开 API 具备阈值语义（`BATTERY_SET_INFORMATION` 只有充 / 放电 / 临界偏置三个枚举值，已逐值核对官方文档） | 【已核实】 |
| 唯一的门 | 华为**标准 ACPI-WMI 通路**：`ROOT\WMI` → `OemWMIMethod::OemWMIfun`，GUID `{ABBC0F5B-8EA1-11D1-A000-C90629100000}`，设备 `ACPI\PNP0C14\HWMI_0`，载荷 `03 10 [下限][上限]` | 【已核实】双来源互证；目标机是否枚举见 §5 |
| 不存在的数据源 | GPU **频率 / 温度 / 功耗**无任何可信来源；`Win32_TemperatureProbe.CurrentReading` 官方声明不填充（见 §3.1） | 【已核实】（本行两项） |
| 取值不可信的数据源 | `MSAcpi_ThermalZoneTemperature` 类存在但取值**因固件而异**，社区大量垃圾值报告（见 §1 与 §3.1） | 【社区报告】（该项**没有**被并入上行的【已核实】） |
| 厂商深度接口特别窄 | 驱动转储 `Drv/` 内 **0 个 `.mof`、0 条 `DeviceInterfaceGUIDs`、0 处 `OemWMIfun`** ⇒ 不向用户态暴露自定义设备接口 | 【已核实】取证 |
| 最大非技术风险 | 不是版权，而是**签名与分发成本**：EV 证书**已不再**绕过 SmartScreen，Windows 11 的 Smart App Control 会拦未签名文件；衍生风险为 ARM64 杀软误报与 **`GK-W7X` 无 EDL/9008 硬件级救援通道** | 【已核实】官方原文 + 项目自证 |
| 技术栈 | 因 §2.1 的调用约束，**纯 C# / 纯 PowerShell 无法完成充电阈值这一项**；建议"**C++/COM 核心库 + C#/WinUI 3 外壳**" | 【已核实】约束 +【推测】选型 |
| 一期不做的事 | **一期不要写内核驱动**：唯一需要的厂商能力（充电阈值）本身就是用户态 WMI；写驱动会把成本从"约 10 美元/月"抬到"EV + attestation 签名 + ARM64 WDK 工具链"，且与 MSIX 分发基本互斥 | 【已核实】+【推测】成本量级 |

## 1. 能力矩阵：功能 → 接口 → 能否实现

> "⚠️"表示**接口存在，但是否有值取决于固件或驱动** ⇒ 必须运行时校验，不可当可信数据源。

| 功能 | 依赖的接口 | 能否实现 | 置信度 | 备注 |
|---|---|---|---|---|
| 电池健康度 | `IOCTL_BATTERY_QUERY_INFORMATION` + `BATTERY_INFORMATION` 设计 / 满充容量；WinRT `BatteryReport` | ✅ / ⚠️ WinRT | 【已核实】 | 官方以两者之比估算损耗 [1]；WinRT 在电池不在位或控制器未上报时**所有属性返回 null** [2] |
| 电量 / 交流状态 / 充电中 | `GetSystemPowerStatus`、`Win32_Battery`、`RegisterPowerSettingNotification` | ✅ | 【已核实】 | 含 `GUID_BATTERY_PERCENTAGE_REMAINING`、`GUID_ACDC_POWER_SOURCE` [3] |
| 循环次数 | `BATTERY_INFORMATION.CycleCount`；`root\WMI` 的 `BatteryCycleCount` | ✅ | 【已核实】 | 不支持的电池该成员为 **0**；**WinRT 上报属性表无 CycleCount** ⇒ 必须走 IOCTL / WMI [1] |
| 充 / 放电功率 | `root\WMI` → `BatteryStatus.ChargeRate` / `DischargeRate`；`IOCTL_BATTERY_QUERY_STATUS` 的 `Rate`；`BatteryReport.ChargeRateInMilliwatts` | ✅ 三条独立路径 | 【已核实】 | 三条均可调用 |
| 电池温度 | `IOCTL_BATTERY_QUERY_INFORMATION` + `BatteryTemperature` | ⚠️ | 【已核实】 | 单位 1/10 开尔文；控制器不上报时返回 `ERROR_INVALID_FUNCTION` [4] |
| **充电阈值 / 保养模式** | **无公开 API**；唯一通路 `ROOT\WMI` → `OemWMIMethod::OemWMIfun` | ❌ 标准 API / ✅ 厂商通路 | 【已核实】 | 见 §2 |
| **降频归因**（为什么被限频） | PDH `\Processor Information(*)\`：`Performance Limit Flags`、`% Performance Limit`、`% of Maximum Frequency`、`Processor Frequency`、`% Processor Performance`、`% Processor Utility` | ✅✅ | 【已核实】 | 本工作包**最有价值的一项**：限频原因被做成公开计数器（可区分热限 / 功耗限等），比温度读数更可解释 |
| GPU 利用率（按进程 + 按引擎） | PDH `\GPU Engine(*)\Utilization Percentage` + `Running Time` | ✅ | 【已核实】 | 与任务管理器同源；实例名形如 `pid_…_luid_…_engtype_3d` |
| 显存占用 / 适配器信息 | PDH `\GPU Adapter Memory(*)\`（`Dedicated Usage` / `Shared Usage` / `Total Committed`）；`Win32_VideoController` | ✅ | 【已核实】 | 计数器集完整枚举；`AdapterRAM` 为 32 位字段，>4 GB 失真 |
| **GPU 频率 / 温度 / 功耗** | —— | ❌ | 【已核实】 | GPU PDH 计数器集**只有** utilization 与 adapter memory 两类，无这些字段；**任务管理器本身也不显示** ⇒ **不是实现难度，是数据源不存在**；Adreno 690 亦无面向第三方的 Windows 遥测 SDK【推测】 |
| CPU / 主板温度（经典 WMI） | `Win32_TemperatureProbe.CurrentReading` | ❌ | 【已核实】 | 官方原文："**current implementations of WMI do not populate** the CurrentReading property" [5]；取证机返回**空实例集** |
| 温度（ACPI 热区） | `root\WMI` → `MSAcpi_ThermalZoneTemperature` | ⚠️ | 【社区报告】 | 类存在但**因固件而异**；社区大量"卡在 0.2 °C"之类垃圾值报告 [6] ⇒ 必须做区间校验，**不可作可信数据源** |
| 温度（性能计数器） | `Win32_PerfFormattedData_Counters_ThermalZoneInformation` | ⚠️ | 【已核实】 | 类存在，取证机**无实例**；目标机有无实例 **【未核实】** |
| 电源计划 / 细粒度调优（EPP、性能提升模式、**核心停泊**） | `powercfg /setactive`、`PowerSetActiveScheme`；`powercfg /setacvalueindex`、`PowerWriteACValueIndex` | ✅（调优需管理员） | 【已核实】 | 可用 GUID 见 [3]；`-attributes` 可解除隐藏项 |
| 电源模式滑块 —— 读 / 通知 | `PowerRegisterForEffectivePowerModeNotifications` | ✅ | 【已核实】 | 官方明示：**只注册通知，不能设置** [7] |
| 电源模式滑块 —— 写（"性能模式"） | `PowerSetActiveOverlayScheme` / `PowerGetEffectiveOverlayScheme` | ⚠️ 未文档化 | 【已核实】 | 取证机 `powrprof.dll` 内**命中全部符号**，而 Microsoft Learn 对应页 **404** ⇒ **不受支持面**；商店政策 10.2.8 亦禁止以不受支持方式使用未文档化 API |
| 每进程能效（EcoQoS） | `SetProcessInformation(..., ProcessPowerThrottling, ...)` + `PROCESS_POWER_THROTTLING_STATE` | ✅ | 【已核实】 | 官方原文："the process will be classified as **EcoQoS**"，含官方示例 [8] |
| 省电模式状态 / 睡眠能力探测 | `GUID_POWER_SAVING_STATUS`、`GUID_ENERGY_SAVER_STATUS`、`powercfg /a` | ✅ | 【已核实】 | |
| 原始 SMBIOS（厂商 / 型号 / 内存槽） | `GetSystemFirmwareTable('RSMB', ...)`；替代 `MSSMBios_RawSMBiosTables` | ✅ | 【已核实】 | 打包应用需 `smbios` 受限能力且只能取 RSMB [9] |
| **枚举 OEM 私有 ACPI 表**（自查固件是否提供 HWMI） | `EnumSystemFirmwareTables('ACPI', ...)` + `GetSystemFirmwareTable('ACPI','PCAF',...)` | ✅ | 【已核实】 | **表 ID 需字节序反转**；这是回答 §5 第 1 项的官方手段 [9] |
| 传感器（加速度 / 陀螺 / 环境光 / 接近 / **开合角**） | WinRT `Windows.Devices.Sensors` | ✅ API，⚠️ 取决于驱动 | 【已核实】 | 目标机 `qcsensors.inf` 的 `REGISTERED_SENSORS` 已明列 `accel`/`gyro`/`mag`/`ambient_light`/`proximity`/`hinge_angle` 等 |
| 触摸 / 笔能力探测 | `Windows.Devices.Input`（`TouchCapabilities`、`PenDevice`）、`GetPointerDevices` | ✅ | 【已核实】 | 仅探测能力，非设置 |
| **笔的设置**（压感曲线 / 笔键 / 快捷键） | 无公开 API | ❌ | 【已核实】 | 目标机 `Drv\THP devices\` 只有 `spbthptool`（触屏 SPI 测试工具）与 `hidinjectorthp`（HID 注入器），**不是笔设置接口** |
| 蓝牙 / WLAN 状态与开关、WLAN 扫描连接 | `Windows.Devices.Bluetooth`、`Windows.Devices.Radios.Radio`；`wlanapi.dll`（`WlanOpenHandle` / `WlanQueryInterface` / `WlanConnect`） | ✅ | 【已核实】 | `Windows.Devices.WiFi` **已弃用**，新代码必须用 `wlanapi` |
| 移动宽带 / LTE | `Windows.Networking.NetworkOperators` | ✅ | 【已核实】 | `GK-W76` 是否带 5G 模组须按机型确认（本项目列为与 LTE 版的鉴别项） |
| Type-C 状态 / 协商功率（UCSI） | 仅**驱动侧**框架（`UcmUcsiCx` / `UcmCx`） | ⚠️【未核实】 | 【未核实】 | **未找到用户态公开 API**；目标机有 `qcusbcucsi8280.sys` |
| 外接显示器拓扑 | `QueryDisplayConfig`、`GetDisplayConfigBufferSizes`、`EnumDisplayDevices` | ✅ | 【已核实】 | |
| 驱动枚举 / 签名状态 / 安装更新回滚 | `pnputil /enum-drivers`、`Win32_PnPSignedDriver`；`pnputil /add-driver … /install`、`/delete-driver … /uninstall`、SetupAPI | ✅（安装更新需管理员） | 【已核实】 | 取证机返回 238 条；安装与 MSIX 打包存在硬冲突，见 §4.6 |
| Windows Update 查询（可按类别搜"驱动"） | WUA：`IUpdateSearcher::Search`、`IUpdateSession` | ✅ | 【已核实】 | 仅查询；第三方主动刷 UEFI 固件**不建议自研**【未核实】 |
| 启动项枚举 / 启用禁用 | `Win32_StartupCommand`；WinRT `Windows.ApplicationModel.StartupTask` | ✅（经典项覆盖不全） | 【已核实】 | 经典接口只覆盖注册表 Run 键与启动文件夹，**不覆盖打包应用的启动任务**；StartupTask 即"任务管理器 → 启动应用"同源能力 |
| 服务管理 | `OpenSCManager` / `EnumServicesStatusEx` / `ChangeServiceConfig` / `ControlService` | ✅ 需管理员 | 【已核实】 | |
| 用户级临时文件清理 | Win32 文件 API + 已知路径 | ✅ | 【已核实】 | 系统级 Storage Sense **无公开触发 API**【未核实】 |
| 磁盘健康（SMART） | `root\WMI` → `MSStorageDriver_FailurePredictStatus` / `_FailurePredictData` | ⚠️ | 【已核实】类存在 | 是否上报取决于存储驱动；目标机 **【未核实】** |
| 风扇转速 | 无公开 API | ❌ n/a | 【已核实】 | `GK-W76` 无风扇；HWiNFO 一类工具靠内核驱动直读 EC / MSR【推测】 |
| 性能模式 / Fn+P 智能档位 | 无接口级证据 | ❌ | 【未核实】 | 见 §2.2 |
| Huawei Share / 多屏协同 | 无接口级证据 | ❌ | 【未核实】 | 推测为 Wi-Fi / 蓝牙 P2P + 用户态服务，NFC 仅作触发 |
| 指纹设置 | 无接口级证据 | ❌ | 【未核实】 | 目标机指纹为 Goodix（`gfspi.inf`，SPI）；厂商工具很可能只是调 Windows 生物识别 API |

**与 Linux 侧的交叉印证**：Windows 侧"GPU 频率 / 温度 / 功耗拿不到"与本项目 Linux 侧的坑**完全同构**（Linux 上 GPU 功耗 / 显存频率 / 功耗墙同样没有可信来源，见 [`gpu-telemetry.md`](gpu-telemetry.md) §5）⇒ 这是**平台 / 固件层面的数据缺失**，不是某个 OS 或驱动实现的疏漏；管家 APP 必须**如实显示"不可用"**，不得伪造读数。

## 2. 厂商专有通路：充电阈值 / 保养模式

**最重要的发现：华为没有用自定义 IOCTL，而是用了 Windows 标准的 ACPI-WMI 映射机制。**

| 项 | 值 |
|---|---|
| 命名空间 / 类 / 方法 | `ROOT\WMI` → `OemWMIMethod` → `OemWMIfun`（`WmiMethodId(1)`） |
| MOF GUID | `{ABBC0F5B-8EA1-11D1-A000-C90629100000}` |
| ACPI 设备实例 | `ACPI\PNP0C14\HWMI_0` |
| 方法签名 | `void OemWMIfun([in, MAX(64)] uint8 u8Input[], [out] uint32 u32Resrved, [out, MAX(256)] uint8 u8Output[])` |
| 载荷（小端 64 位） | `03 10 [下限] [上限]`，命令字 `0x00001003`（`\SBTT`）；读回 `03 11 …`（`0x00001103`，`\GBTT`） |
| 实抓值 | 关闭 `0x64001003`、90% `0x5A461003`、70% `0x46281003`、100% `0x645F1003` |

- GUID 与上游 Linux 内核 `drivers/platform/x86/huawei-wmi.c` 的 `HWMI_METHOD_GUID` **完全一致**，字节布局**逐字节一致**（`0x46281003` 小端为 `03 10 28 46`，即 start=40、end=70）⇒ 双来源互证 [10] [11]。
- 机型名 `Huawei Matebook E GO` 见于第三方开源 CLI 的 tested-on 列表，raw 值 `0x46281003` 为实机打印 [11]，但**未标注年款 / LTE / 2023 变体**。【社区报告】
- 厂商工具调用链经逆向为 `PCManager.exe` → `PCManagerMainService.exe` → **`HardwareHal.dll`** → `HalWmi::GetOutPutUIntEx` → WMI [12]。【社区报告，单来源一手逆向】

**为什么这是"使用公开接口"而非"逆向"**：它就是一次标准 WMI 方法调用（`IWbemServices::ExecMethod`），与调用 `Win32_Battery` 无本质区别；该类在 `ROOT\WMI` 中**可被任意进程枚举**，是**厂商主动注册到操作系统里的调用面**，不是受访问控制保护的内容。接口事实（GUID、命令码、布局）来自上游 **GPL-2.0 内核驱动**与公开逆向记录，**接口事实本身不受版权保护，逐字复制代码才受保护**【推测】；稳妥做法是 clean-room（一人写规格、另一人照规格实现），**对外发布前应取得正式法律意见**。

### 2.1 ★ 实现细节的硬约束（直接决定技术栈）

- `u64Input` 用**十进制字符串**填充（`VT_BSTR`），`u8Input` 是 **`SAFEARRAY(64)`，`vt = 8209`（`VT_ARRAY | VT_UI1`）**。
- **PowerShell 的 `Get-WmiObject … .OemWMIfun(...)` 与 C# 的 `InvokeMethod` 都会报"无效的参数"** ⇒ **必须走 C++/COM**（`IWbemServices::ExecMethod`，或手工 `IWbemClassObject::Put` 构造 `SAFEARRAY`）【已核实】⇒ 纯 C# / 纯 PowerShell 路线在这**一个**功能上会撞墙。
- 新机型 / 新 BIOS 另有 `--new` 路径：raw 形态 `0x<上限><下限>48011503`（命令字由 `0x1003` 变为 `0x0115`），**字节语义未解析** ⇒ **【未核实】**。

### 2.2 其它厂商功能的证据强度

| 功能 | 依赖什么 | 置信度 |
|---|---|---|
| **Fn 锁定**（≠ 性能模式） | 两侧源码常量完全一致：EC 寄存器 `0x6B` 读 / `0x6C` 写，`0x5A` = on、`0x55` = off；x86 侧经 WMI `0x00000604`(`\GFRS`) / `0x00000704`(`\SFRS`)，新机型改为直接 ACPI 方法 `\GFRS` / `\SFRS` | 【已核实】源码（`huawei-wmi.c` 与 `huawei-gaokun-ec.c` 常量相同 ⇒ 固件命令集同源） |
| **性能模式 / Fn+P**（智能 / 高性能 / 省电） | **无任何接口级证据**。Fn+P 只是热键事件（事件 GUID `ABBC0F5C-8EA1-11D1-A000-C90629100000`）；"切档"由谁执行、写哪个寄存器或命令码无公开记录 ⇒ 推测仍是 `OemWMIfun` 的另一条 `0x10xx` 命令或 EC 直写 | **【未核实】** |
| 驱动更新 | 无接口级证据；厂商工具从自有 catalog 联网下载安装，纯用户态 + 网络 | 【推测】 |
| Huawei Share / 多屏协同（NFC） | **无接口级证据**；**推测走 Wi-Fi / 蓝牙 P2P + 用户态服务，NFC 仅作触发** | 【未核实】【推测】 |
| 指纹设置 / 手写笔设置 | 同上，**均无接口级证据**。★ **PC Manager 整体通道综述**：社区综述称厂商工具主要通过 **raw HID 与 WMI 两条通道**与硬件通信（键盘背光与**充电阈值**走 WMI，触摸板力度走 raw HID），这些值最终落到 **EC** | 【未核实-接口】【社区报告-通道级】 |

> 可复用的现成参考实现：[Wintego/Honor-PC-Helper](https://github.com/Wintego/Honor-PC-Helper)、[AceDroidX/HuaweiBatteryControl](https://github.com/AceDroidX/HuaweiBatteryControl) [11] [19]。

## 3. 否定结论：做不到的与不可依赖的

### 3.1 数据源根本不存在

| 项 | 事实 | 置信度 |
|---|---|---|
| GPU 频率 / 温度 / 功耗 | GPU PDH 计数器集**只有** utilization 与 adapter memory 两类；`Win32_VideoController` 无这些字段；任务管理器同样不显示；Adreno 690 无面向第三方的公开 Windows 遥测 SDK | 【已核实】+【推测】 |
| `Win32_TemperatureProbe.CurrentReading` | 官方**明文声明**不填充（原文见 [5]）；取证机返回空实例集 | 【已核实】 |
| `MSAcpi_ThermalZoneTemperature` | 类存在，但取值**因固件而异**；社区大量垃圾值报告 ⇒ 必须做 0–120 °C 之类区间校验，不可作可信数据源 | 【社区报告】 |

### 3.2 厂商驱动不向用户态暴露自定义设备接口

对 `D:\androidGaokun\Drv\`（19 类 / 962 文件 / 1153.6 MB，标准驱动库导出形态）做全域递归检索：

| 检索项 | 结果 | 含义 |
|---|---|---|
| `.mof` 文件 | **0 命中** | 厂商没有通过 MOF 注册自定义 WMI provider |
| INF 中的 `DeviceInterfaceGUIDs` | **0 命中** | 不向用户态暴露自定义设备接口 |
| `OemWMIfun` / `OemWMIMethod` / `HWMI_0` / `PNP0C14` | **全库零命中** | 属固件 DSDT，**驱动转储无法回答"固件是否提供 HWMI"** ⇒ §5 第 1 项 |
| 厂商管家组件（`PCManager` / `HardwareHal` / `MBAMain` / `BatteryCare` 匹配） | **0 命中** | 转储是驱动库，不含管家用户态部分 |

- 两条**保留意见**（诚实边界）：WMI provider 也可把 MOF 内嵌为 DLL / SYS 资源；驱动也可运行时用 `WdfDeviceCreateDeviceInterface()` 注册而不写进 INF。故上述非绝对证明，但四条同时为零，结论站得住。
- **对比意义重大**：**联想**的驱动**是**暴露自定义接口的，**Lenovo Legion Toolkit 正是靠它工作** ⇒ **本机的"深度管家"路径比联想机器窄得多**，深度能力只能指望 ACPI-WMI（若固件提供）。
- 另一条负面结论：转储里**没有任何厂商 EULA / 许可文本** ⇒ "华为驱动 EULA 写了什么"**无法从本地转储闭环**（见 §5）。

### 3.3 厂商热管理驱动只应观测、不应改写

`Drv\系统设备\qcsubsysthermalmgr.inf_*` 绑定 `ACPI\QCOMFFE0` 与 `ACPI\QCOM06E5`，`Class=SYSTEM`，`DriverVer 06/07/2022, 1.0.3508.3900`；安全描述符 `D:P(A;;GA;;;BA)(A;;GA;;;SY)(A;;GA;;;S-1-5-84-0-0-0-0-0)` ⇒ **仅管理员 / LocalSystem / UMDF 有全权，普通用户态拿不到**。【已核实】取证

它是本机**降频 / 温控的实际执行者** ⇒ 管家 APP 的正确定位是**观测**（读 PDH 的 `Performance Limit Flags` 与 `% Performance Limit`），而不是改写。

## 4. 法律、分发与技术栈

> 法律部分为**工程可行性评估，不是法律意见**；对外发布前须咨询执业律师。

### 4.1 为什么调用公开 WMI 类不构成"规避技术措施"

1. **条文**：DMCA §1201 禁止的是"规避有效控制访问的技术措施"（17 U.S.C. §1201(a)(1)(A)）[13]。一个**公开、可枚举、可正常调用**的 WMI 类 / 方法**不是**技术措施 ⇒ 调用它**不构成规避**，连 §1201(f) 互操作例外都不必动用。
2. **EU 侧姿态更稳**：Software Directive 2009/24/EC **Art.5(3)**（为探知思想与原理而观察 / 研究 / 测试程序功能）覆盖的正是"在自己机器上运行并观察"；**Art.6**（为互操作而反编译）本案**可能根本不需要动用**。条号与主题准确，但本次**未抓到逐字原文**（legislation.gov.uk 返回 202 / 空正文）⇒ 逐字引用需换 EUR-Lex 核对（§5）。
3. **判例**：Sega v. Accolade 与 Sony v. Connectix 确立"为互操作所作的中间复制可构成合理使用"（一手判决文本本次未抓到，属**通说结论**【推测】）；Google v. Oracle (2021) 认定重实现 API 属合理使用，**且明确不裁断"接口是否可版权"**这一前提问题 [14] ⇒ 它是**合理使用判决，不是"接口不可版权"判决**。我们连声明代码都不复制，只按接口契约发 WMI 请求，**转化性更强**，但这**不是已决的法律问题**。
4. **先例全部存活**：`huawei-wmi`（**同一个 GUID**）、`dell-wmi-sysman`（Dell BIOS 属性，**含电池设置**）、`lenovo-wmi-*` 均已被 **Linux 内核主线接受**（`dell-wmi-sysman` **是否为 Dell 官方背书未核实**，见 §5 第 13 项）；Windows 侧的 LLT（**已签名发布**，README 自述会引发杀软误报）、LLL、G-Helper、UXTU、NBFC、OpenRGB、RyzenAdj、ThrottleStop、FanControl 均存活 [15]。**且检索不到任何厂商因第三方调用其 PC 驱动接口而起诉的公开案例** —— 这是最重要的经验事实。
5. **必须下的对照结论**：**存活 ≠ 合法**。上述项目多处于**厂商无商业动机追究**的领域（本地管理工具不直接冲击厂商订阅收入）；**若某产品直接冲击厂商增值服务，态度可能完全不同**。【推测】

### 4.2 红线

| 红线 | 说明 |
|---|---|
| 不破签名 | 不绕过驱动签名校验、不绕过固件签名验证、不解密固件镜像 —— 这才是 §1201 真正的高压线 |
| 不再分发厂商二进制 | `Drv/` 的 INF / SYS / DLL 与厂商 UI 资源（图标、字符串）属纯版权再分发，**无任何例外可依赖** ⇒ 与项目台账 §0.4 第 6 条"`Drv/` 与 `Recovery/` 永不入库"一致，该判断正确 |
| 不提供绕过签名的工具 | 与第一条同源，但**分发**行为会额外放大风险 |

### 4.3 分发四档风险、保修与签名

| 做法 | 风险 | 依据 |
|---|---|---|
| 只在自有设备上私用 | **极低** —— 在自己的硬件上运行自己的程序，且接口公开可调用 | §1201 条文；2009/24/EC Art.5(3) |
| 公开发布源代码 | **低** —— §1201(f)(3) 明确允许把互操作所得信息 / 手段提供给他人（限于互操作目的）。**必须：不内嵌厂商二进制、不含厂商资源 / 字符串 / 图标** | §1201(f)(3)、(f)(4) |
| 发布签名的二进制 | **较低但成本高** —— 法律风险同级，**证书成本 + 杀软误报处理是真实成本项** | LLT README FAQ |
| 再分发厂商驱动二进制 | ❌ **明确不可做** | 通行版权法；项目自身规则 |

**保修**【已核实-条文】：Magnuson-Moss（15 U.S.C. §2302(c)）禁止把保修**以使用特定品牌标识的物品 / 服务为条件**；16 C.F.R. §700.10 规定**除保证人能证明非原厂件是故障原因外，不得拒保**；FTC 曾就"使用非原厂件即保修失效"的表述发出警告函 [16]。
⇒ 「装了也不失保修」成立；「装了**并弄坏了**」厂商可就该故障拒修，**但因果举证责任在厂商** ⇒ **只读遥测几乎无此风险；写入类功能（EC / 固件）有** ⇒ 产品文档必须明示"自担风险 + 一键回滚"。

**代码签名与 SmartScreen（2026 现状）**【已核实-MS 原文】[17]：

| 项 | 结论 |
|---|---|
| **EV 证书还能免 SmartScreen 吗** | ❌ **不能了**。官方逐字："**EV certificates no longer bypass SmartScreen.** … **Paying a premium for EV solely to avoid SmartScreen warnings is no longer justified.**" |
| OV / EV 证书 | ⚠️ 首次下载仍警告："app flagged as unrecognized until reputation accumulates"（只是会显示已验证的发布者名） |
| 未签名 | ⚠️ 弹"Windows protected your PC"；**企业策略可直接阻止** |
| **Smart App Control**（Windows 11） | ⚠️ **"will block execution of unsigned files unless the file has a positive reputation"**，且**适用于所有可执行文件，不只下载来的** ⇒ 未签名的管家 App 在目标机上**可能被直接拦死** |
| Azure Artifact Signing（原 Trusted Signing） | **9.99 美元/月起**（Basic，5,000 次签名/月；Premium 99.99 美元/月 10 万次），无需硬件令牌，可接 CI/CD；需身份验证（Public Trust 有地域与经营年限门槛） |
| 微软商店 | ✅ "No warning — covered by Microsoft's certificate"，**是唯一能完全免除 SmartScreen 警告的分发方式** |
| 其它正路 | 签名 + 下载量积累（"several weeks and hundreds of clean installs"），签名身份必须一致 |

**其它被低估的风险**：

- **杀软误报是必然成本项，不是"也许"**：LLT README 自述会因大量低层 Windows API 被杀软误报；签名能降低 SmartScreen 等级，**消除不了启发式误报**；**ARM64 加剧问题**（低层安全工具样本极少、白名单薄、申诉周期长）。【已核实-项目原文 + 推测】
- **维护成本远超法律成本**：接口随厂商驱动 / BIOS 版本变动失效（同类 LLL README 有大量"特定 BIOS 版本才行"的机型矩阵）。【已核实-项目 README】
- **真正的风险放大器**：`GK-W7X` **无 EDL/9008 救援通道**（本项目已自证）⇒ 一旦引导层出问题**没有硬件级救援**，这比"EC 写入"本身更值得警惕。【项目自证事实】
- **商标风险高于版权风险**：命名 / 图标若与"华为""MateBook""电脑管家"产生关联暗示即危险，但**可通过命名与视觉设计完全规避**（同类项目只做描述性兼容使用并附"not affiliated"声明）。【推测】
- **反作弊 / 内核组件冲突**：LLT README 明确警告 Riot Vanguard 会导致其 RGB 控制失效 ⇒ 低层工具可预期的兼容性事故来源。【已核实-原文】

### 4.4 三条候选路线

| | **A：纯标准 API「轻量管家」** | **B：+ 厂商 ACPI-WMI「深度管家」** | **C：只监控 + 脚本编排** |
|---|---|---|---|
| 定位 | 覆盖面优先的通用管家 | A + 电池保养模式 | 不做设置，只观测与自动化 |
| 能做 | §1 中标 ✅ 的全部项目 | A 全部 **+ 充电阈值 / 保养模式**（`OemWMIfun`），可能再挖性能模式 | 全部只读遥测 + 阈值告警 + 计划任务触发 |
| 做不到 | 充电阈值、性能模式、笔设置、GPU 温频功耗、Huawei Share | 仍需解析 `--new`；Huawei Share / 多屏协同 / 指纹 / 笔设置大概率仍做不到；**GPU 温频功耗永远做不到** | 所有设置类功能 |
| 技术风险 | **极低**（全在微软支持面内） | **低–中**：单点写入、固件自带范围校验；但 `OemWMIfun` **未文档化** | **极低** |
| 签名 / 杀软 / 保修 | 低，仍建议签名；保修 ≈0 | 中：低层 WMI + 可能提权 ⇒ **误报是必然成本项**；保修低 | 低；保修 ≈0 |
| 分发形态 | MSIX / exe / winget 皆可 | **必须 full-trust + 管理员**，MSIX 受限 | 极灵活 |
| 前置验证成本 | 0（立即可开工） | **1 次只读 WMI 查询**，失败则本方案作废 | 0 |

**务实路线**：**先做 C 的安全子集 → 立刻扩到 A（两步零前置风险、零法律风险）→ 用一次 10 秒只读查询判定 B → 可行则把"电池保养模式"作为 B 的旗舰功能增量交付**；即 **A / C 无论如何都交付，B 是"低成本高回报的期权"，不是前提**。三条路线都可开源（不含厂商二进制与资源）。

### 4.5 技术栈建议

★ **推荐"C++/COM 核心库 + C#/WinUI 3 外壳"**：§2.1 的调用约束意味着充电阈值**只能**落在 C++（`IWbemServices::ExecMethod`），而整个应用写成纯 C++ 会显著降低 UI 迭代速度；核心库保持纯 C ABI 导出、由 C# 侧 P/Invoke 调用即可。

| 技术栈 | ARM64 成熟度 | 优点 | 缺点 |
|---|---|---|---|
| **C# + .NET 8/9 + WinUI 3**（Windows App SDK） | **高** | 现代 Fluent UI；.NET 官方支持 Arm64；可与 WMI / PDH / P-Invoke 混合 | **不支持 AnyCPU**，必须显式指定 `x86` / `x64` / `arm64` |
| **C++/WinRT 或 C++ + Win32/WIL** | **高** | 无托管运行时；**可直接调 WMI COM（`IWbemServices`）、PDH、ETW、IOCTL**；最"薄" | 开发效率最低；第三方库 ARM64 生态要自己解决 |
| Rust + Tauri v2（WebView2） | 中高 | Rust 侧任意 Win32；前端迭代快；包体小 | 依赖 WebView2 Runtime；**Tauri 官方 Prerequisites 未对 ARM64 作专门声明**【未核实】 |
| 纯 Win32 + 自绘（Direct2D / DirectComposition） | 高 | 完全掌控、体积最小、可深度集成托盘与热键 | 控件 / 无障碍 / DPI / 输入法 / 暗色主题全自研 ⇒ 对标 Vantage 的投入产出比差【推测】 |
| WPF / WinUI 2 / Electron | 中–高 | 成熟 | WPF 观感旧需第三方主题；WinUI 2 需 UWP / AppContainer 宿主；Electron 100 MB 以上 |

**ARM64 上的三个硬约束**：

1. **WMI 可达性 —— 已修复的历史坑**：`System.Management` 在 win-arm64 上曾去找 `Framework64\wminet_utils.dll` 而崩溃（`Win32Exception (193)`）；修复进入 `System.Management` 6.0.1 / 7.0.1 / 8.0.0-preview.3（2023-04）[18]【已核实】⇒ 已解除，但 .NET 路线的 WMI **依赖机器上存在 .NET Framework 的 ARM64 组件**（本项目主力数据源正是 WMI ⇒ "安全但必须知道"）。
2. **ARM64EC 官方矩阵**：x64 / Arm64EC 进程**不支持** Arm64 二进制，Arm64 进程不支持 x64 / Arm64EC 二进制；★ **仿真只支持用户态、不允许内核态，任何内核态组件必须编译为 Arm64**【已核实】[20] ⇒ 对"要不要写驱动"是硬约束。
3. **NativeAOT 的悖论**：.NET 8 起支持 Windows Arm64【已核实】，**但 Windows 上 NativeAOT 没有内建 COM** ⇒ `IWbemServices`、PDH 等 COM 路径要手工 P/Invoke ⇒ **本项目大量走 WMI，NativeAOT 并不划算**【推测】，self-contained + trimming 或 framework-dependent 更省事。另：Windows App SDK 的 `PublishSingleFile` **仅支持 unpackaged + self-contained**（1.5+）【已核实】。

### 4.6 打包分发与"一期不要写驱动"

- MSIX **能**装全信任的系统管理类应用（`rescap:runFullTrust` + `uap10:TrustLevel="mediumIL"`），**但不能替代 MSI / EXE 的安装能力**；「MSIX 不支持服务 / 驱动 / System32 / WMI provider」这一"官方 MUST NOT 清单"**本次未能取到** ⇒ **【未核实】**。
- 微软商店政策 **10.2.4**「一般不允许依赖非微软驱动或 NT 服务」、**10.2.8**「禁止以不受支持的方式使用未文档化 API」【已核实-政策层】。★ 10.2.8 对本项目是真实约束：§1 里未文档化的 `PowerSetActiveOverlayScheme` 若要用即与商店政策冲突 —— **但自行分发不受此限**。

★ **一期不要写内核驱动**，成本量级对比即核心理由：

| 分发形态 | 成本量级 |
|---|---|
| 用户态应用签名（Azure Artifact Signing Basic） | **约 10 美元/月**，无需硬件令牌，可接 CI/CD |
| 自研内核驱动 | **EV 证书 + 微软硬件开发者中心 attestation 签名 + ARM64 WDK 工具链**（WDK 10.0.26100.1 起才支持在 Arm64 主机上原生开发 / 测试 / 部署驱动，需 SDK/WDK 26100+）【已核实】，**且该路径与 MSIX 分发基本互斥** |

而 §2 表明**一期唯一需要的厂商能力（充电阈值）恰好是用户态 WMI，不需要驱动** ⇒ 两条结论互相加强：**一期不做驱动**。将来若确有必要（例如直读 EC 获取温度），再单独立项评估 —— 必须如实承认那是**成本分水岭**，而不是一个增量功能。

## 5. 未核实清单

★ 的一项**最该先做真机验证**：它一条决定"深度管家"整条路线成立与否，成本却只有 10 秒。

| # | 未核实内容 | 为什么没核实 | 补齐方式 |
|---|---|---|---|
| **1** ★ | **`GK-W76` 固件是否真的枚举 `ACPI\PNP0C14\HWMI_0` / `OemWMIMethod`** —— **决定方案 B 是否成立** | 现有证据只是"机型名 `Huawei Matebook E GO` 被第三方实测过"（**未标注年款与变体**）；**无 DSDT 原件级证据**；驱动转储**无法回答**（属固件，全库零命中） | 目标机上一次**只读**查询，见 §5.1 |
| 2 | **性能模式 / Fn+P 的真实接口** | 完全无来源 | WMI / Procmon 跟踪厂商服务，或查 `OemWMIfun` 其它 `0x10xx` 命令码 |
| 3 | 华为驱动 **EULA 原文**（是否含互操作禁止条款） | 转储里没有 EULA 文本 | 从官方安装包 / 官网获取；或咨询法务 |
| 4 | `GK-W76` 上 `MSAcpi_ThermalZoneTemperature` 是否有值、`MSStorageDriver_FailurePredict*` 是否上报 SMART | 需真机 | 目标机只读查询 |
| 5 | 华为分享 / 多屏协同 / 指纹 / 手写笔设置的具体接口 | 无来源 | Procmon + WMI trace；或对 Goodix `gfspi` 行为分析 |
| 6 | `--new` 路径 `0x…48011503` 的字节语义 | 仅知形态，无解码 | 在**可回滚**前提下做 A/B 实测 |
| 7 | UCSI 是否存在用户态公开 API | 微软只提供驱动侧框架 | 继续查 `Windows.Devices.Usb` / UCM 文档 |
| 8 | 2024（第九轮）§1201 最终规则的完整豁免清单是否含"PC 驱动互操作"类别 | `copyright.gov` 返回 403 | 抓 Federal Register 上的最终规则全文 |
| 9 | 2009/24/EC Art.5(3) / Art.6 逐字原文；Sega v. Accolade / Sony v. Connectix 一手判决；Directive (EU) 2019/771 中"第三方软件致不符合是否免责"的条号 | 抓取受阻（202 / 空正文） | 抓 EUR-Lex CELEX:32009L0024、CELEX:32019L0771 与 CourtListener |
| 10 | 各开源先例项目的确切许可证 | 未逐一读取 | 直接抓各仓库 LICENSE |
| 11 | Windows 11 ARM64 上未签名低层工具的实际杀软检出率 | 需发布前测量 | 用 VirusTotal 对构建产物做基线测量 |
| 12 | `GK-W76` 平台是否存在"工具可致 EC 永久损坏"的路径 | **无公开证据：既不能证有，也不能证无** | 无法直接验证；以"可回滚 + 只读优先"的设计规避 |
| 13 | **`dell-wmi-sysman` 是否真为 Dell 官方背书**（§4.1 第 4 点只证明了"内核主线已接受"） | 仅有主线接受这一事实；**未核到 Dell 官方声明或文档级背书** | 查 Dell 官方文档 / 上游驱动 `MAINTAINERS` 与提交来源 |

### 5.1 最该先做的那一次真机验证（只读，10 秒）

在目标机（平板）上以管理员身份运行，**只枚举、不调用**：

```powershell
Get-CimClass -Namespace root\wmi -ClassName OemWMIMethod
Get-CimInstance -Namespace root\wmi -ClassName OemWMIMethod
Get-PnpDevice -InstanceId 'ACPI\PNP0C14*'
```

> 注意：`Get-CimInstance` **没有 `-List` 参数**（旧写法 `… -ClassName OemWMIMethod -List` 会报"找不到与参数名称 List 匹配的参数"）；枚举类定义用 `Get-CimClass`，取实例用 `Get-CimInstance`。

或用固件表这条独立路径自查（见 §1「枚举 OEM 私有 ACPI 表」）。该路径**没有等价的 PowerShell cmdlet**，需要在 C / C# 里调用 `EnumSystemFirmwareTables`（**表 ID 需字节序反转**），其完整原型为三参数形式：

```text
UINT EnumSystemFirmwareTables(DWORD FirmwareTableProviderSignature, PVOID pFirmwareTableEnumBuffer, DWORD BufferSize);
```

**判读**：若 `OemWMIMethod` 类与 `ACPI\PNP0C14\HWMI_0` 设备同时存在 ⇒ 方案 B 成立，进入充电阈值的实现设计；若不存在 ⇒ **方案 B 作废**，管家定位为方案 A / C，充电阈值不在交付范围内。

## 6. 来源

[1] [BATTERY_INFORMATION 结构](https://learn.microsoft.com/en-us/windows/win32/power/battery-information-str) ·
[2] [BatteryReport 类](https://learn.microsoft.com/en-us/uwp/api/windows.devices.power.batteryreport) ·
[3] [电源设置 GUID](https://learn.microsoft.com/en-us/windows/win32/power/power-setting-guids) ·
[4] [IOCTL_BATTERY_QUERY_INFORMATION](https://learn.microsoft.com/en-us/windows/win32/power/ioctl-battery-query-information) ·
[5] [Win32_TemperatureProbe](https://learn.microsoft.com/en-us/windows/win32/cimwin32prov/win32-temperatureprobe) ·
[6] [oshi: MSAcpiThermalZoneTemperature](https://github.com/oshi/oshi/blob/56a7d95d/oshi-common/src/main/java/oshi/driver/common/windows/wmi/MSAcpiThermalZoneTemperature.java) / [HP 论坛：热区卡在 0.2 °C](https://h30434.www3.hp.com/t5/Business-Notebooks/Firmware-Bug-Thermal-Zones-stuck-at-0-2-C/td-p/9604808) ·
[7] [PowerRegisterForEffectivePowerModeNotifications](https://learn.microsoft.com/en-us/windows/win32/api/powersetting/nf-powersetting-powerregisterforeffectivepowermodenotifications) ·
[8] [SetProcessInformation](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessinformation) ·
[9] [GetSystemFirmwareTable](https://learn.microsoft.com/en-us/windows/win32/api/sysinfoapi/nf-sysinfoapi-getsystemfirmwaretable) ·
[10] [上游内核 `huawei-wmi.c`](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/huawei-wmi.c) ·
[11] [AceDroidX/HuaweiBatteryControl](https://github.com/AceDroidX/HuaweiBatteryControl) ·
[12] [华为笔记本充电控制逆向过程记录](https://blog.acedroidx.top/HuaweiBatteryControl/) ·
[13] [17 U.S.C. §1201](https://www.law.cornell.edu/uscode/text/17/1201) ·
[14] [Google v. Oracle：API 复制可构成合理使用](https://www.wiley.law/alert-Supreme-Court-Determines-Copying-of-Software-API-Can-Constitute-Fair-Use) ·
[15] [`huawei-wmi` 进入 Linux 主线](http://git.armlinux.org.uk/cgit/linux.git/commit/drivers/platform/x86/huawei-wmi.c?id=440c4983de262f78033ec58f6fabcd199a664327d) ·
[16] [FTC 保修警告函](https://www.ftc.gov/business-guidance/blog/2018/04/ftc-staff-sends-warranty-warnings) ·
[17] [SmartScreen 信誉](https://learn.microsoft.com/en-us/windows/apps/package-and-deploy/smartscreen-reputation) / [Azure Artifact Signing 定价](https://azure.microsoft.com/pricing/details/artifact-signing/) ·
[18] [dotnet/runtime#81400](https://github.com/dotnet/runtime/issues/81400) ·
[19] [Wintego/Honor-PC-Helper](https://github.com/Wintego/Honor-PC-Helper) / [tinyedi: Escaping Huawei/Honor PC Manager](https://www.tinyedi.com/escaping-huawei-honor-pc-manager/) ·
[20] [Arm64EC 架构矩阵](https://learn.microsoft.com/en-us/windows/arm/arm64ec) / [How emulation works on Arm](https://learn.microsoft.com/en-us/windows/arm/apps-on-arm-x86-emulation) / [Building Arm64 Drivers with the WDK](https://learn.microsoft.com/en-us/windows-hardware/drivers/develop/building-arm64-drivers) ·
[21] [`windows-video-tz-interface.md`](windows-video-tz-interface.md) / [`iris-windows-ved-register-trace.md`](iris-windows-ved-register-trace.md)（本项目"厂商驱动行为 = 一手 ground truth"的既有取证先例）

> 项目内交叉引用：[`win11-feasibility.md`](win11-feasibility.md)（主报告）、[`gpu-telemetry.md`](gpu-telemetry.md)（Linux 侧同类数据缺失）、[`style-guide.md`](style-guide.md)（写作规范）、[`../CONTRIBUTING.md`](../CONTRIBUTING.md)（安全与发布约束）。

## 7. 一句话结论

**自研 ARM64 原生管家在技术上完全可行：用户真正关心的约 80%（电池健康、循环与功率、降频归因、GPU 利用率与显存、电源与能效、系统维护）全在微软公开 API 覆盖内、零法律风险；唯一需要厂商接口的"充电阈值 / 保养模式"走的是一条标准 ACPI-WMI 调用而非 IOCTL 逆向，法律上有互操作例外与大量存活先例支撑；真正的风险不在版权，而在签名成本、ARM64 杀软误报与目标机无硬件级救援通道；唯一的前置验证 = 一次 10 秒的只读 WMI 查询。**
