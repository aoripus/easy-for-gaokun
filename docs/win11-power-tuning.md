# 调度与省电调优（Windows 可行性报告 · 工作包 (c)）

> **目标机**：HUAWEI MateBook E Go **2022 性能版**（`GK-W76` / Snapdragon 8cx Gen 3 / **SC8280XP** / 无风扇 /
> 出厂 Windows 11 ARM64）。本文只回答**能不能省电、靠什么省、怎么证明省下来了**，不含实现，不改任何设置。
>
> **取证环境边界**：标 `[旁证]` 的实测跑在**另一台 x64 机器**（AMD64 / Windows 10 LTSC 10.0.19044 /
> `powercfg.exe` 10.0.19041.1），**不是 GK-W76、也不是 Windows 11**；它只能证明 **GUID、注册表结构、
> 属性位在真实 Windows 上是否存在**，**不能**证明其在 GK-W76 上取值如何、是否生效。涉及目标机而未取证者一律标 **【未核实】**。
>
> **置信度**：**【已核实】** = 一手官方文档原文或旁证机只读实测 · **【社区报告】** = 可信第三方实测或源码 ·
> **【推测】** = 由已知事实推导 · **【未核实】** = 查不到来源，须真机取证。

---

## 0. 结论摘要

1. **最大的杠杆不是"调频旋钮"，而是先把"它压根没在省电"量化出来。** `powercfg /sleepstudy` 给出的
   **DRIPS 驻留率**与 **exit reason 码**，等价于在 Linux 侧用 `/sys/power/pm_wakeup_irq` 做的事，
   而且是官方工具做完的 ⇒ **测量优先于一切调优**。
2. **四类真旋钮**：① **电源模式滑块**（overlay scheme）；② **PPM**（`PROCTHROTTLEMAX` / `PROCTHROTTLEMIN` /
   `PERFBOOSTMODE` / EPP / 核心停泊）；③ **EcoQoS**；④ **待机行为**（自适应休眠预算 `standbybudgetpercent`
   默认 **5%**，压到 2–3% 等于给待机装断路器）。其中**滑块别选"最佳性能"**——官方明文那会关掉 Power Throttling，
   而该功能的官方量化收益是 **"up to 11% in CPU power"**。**限制**：PPM 可写，但**生效层在固件 `_CPC` 之下，
   第三方只能提请求**。
3. **平台模型开关是红线。** 官方原文："**Switching the power model is not supported in Windows without a
   complete OS re-install**"；GK-W76 **无 EDL/9008 救援通道**（项目已核实）⇒ 用 `CsEnabled` /
   `PlatformAoAcOverride` 关掉 Modern Standby 回退 S3 **列为红线**。
4. **Modern Standby 的 DRIPS 质量取决于高通固件与驱动，第三方脚本改不到那一层。** 官方要求
   "**both software and hardware must be made ready for low-power operation**"。若固件没把平台送进最深空闲态，
   Windows 侧同样修不了 —— 这与 Linux 侧 s2idle 留不住、PDC 秒级拉醒是**同一现象**。用户能做的上限是
   **"缩短非 DRIPS 时间 + 更早进休眠"**，**不能把 DRIPS 从 0 修成 80%**。
5. **华为"高能模式"走厂商私有通路（raw HID/WMI → EC），不是 Windows 电源方案**【社区报告】⇒ 脚本改不到；
   且华为官方"高能模式"适用产品列表里**没有 MateBook E Go**【已核实-官方支持页】。
6. **本文最大的不确定性**：GK-W76 上 `/a` 与 `/sleepstudy` 的**实际输出完全未知**——这是整份报告的地基（§8 第 1、2 条）。

---

## 1. 适用范围与前置条件

| 项 | 内容 |
|---|---|
| 适用机型 | 仅 `GK-W76`（8cx Gen 3 / SC8280XP）。**不适用** 2022 LTE 版（8cx Gen 2）与 2023 版（8cx Gen 3 降频版） |
| 适用系统 | Windows 11 ARM64（出厂预装） |
| 前置条件 | **必须先有"什么都没改"的基线**（§2.4） |
| 不在本文范围 | 厂商 EC 行为；PPM profile 的镜像级下发（§7 只提通道） |
| 交叉核对物 | 微软 2010 年《Power Policy Configuration and Deployment in Windows》**只能核对 2010 年即已存在的设置**（**共 6 项**：`PROCTHROTTLEMAX`、`PROCTHROTTLEMIN`、`HIBERNATEIDLE`、`STANDBYIDLE`、`DISKIDLE`、`ASPM` 的 GUID 与别名，见 §9）；它成文于 Vista/Win7 时代，**没有** overlay scheme、EcoQoS、Modern Standby、自适应休眠 |

---

## 2. 测量方法（可复现，**先做这一步**）

### 2.1 `powercfg /sleepstudy`

生成 HTML，默认覆盖最近 **3 天**（`/duration` 上限 **28** 天）；**需要管理员**；**只有具备 Modern Standby
能力的机器**才生成有内容的报告；session **不足 10 分钟不记录**，官方建议观察 **1 小时以上**。
【已核实-[MS 文档 SleepStudy](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/modern-standby-sleepstudy)】

```powershell
powercfg /sleepstudy                          # 当前目录生成 Sleepstudy-report.html（需管理员）
powercfg /sleepstudy /duration 7              # 覆盖 7 天
powercfg /sleepstudy /output C:\path\ss.html
powercfg /sleepstudy /xml                     # XML，可 /transformxml 转 HTML
```

| 看什么 | 字段 | 判读标准 |
|---|---|---|
| **DRIPS 驻留率** | `% LOW POWER STATE TIME` | `HW:` 前缀的**硬件 DRIPS** 只在 **Intel 与 Qualcomm** SoC 上可用 ⇒ 本机应能看到，比 Linux 侧更细。**但它由固件上报，不报就退化** |
| **掉电速率** | `ENERGY CHANGE`（mWh + 占比）/ `CHANGE RATE`（mW，带 `Drain`/`Charge`） | **红 = 掉电 ≥1%/h 或 DRIPS <80%；黄 = 0.33–1%/h 或 DRIPS 80–94%；绿 = 其余**；官方：<0.333%/h ⇒ 待机可达 **12 天以上** |
| **是否真进了低功耗态** | 2004 起拆成 `Screen Off` 与 `Sleep` 两个 state | `Sleep` = **等价于 S3 的长期低功耗态**。**只有 Screen Off 段而几乎没有 Sleep 段 ⇒ 从未真正进入低功耗**，与 Linux 侧同源 |
| **被什么唤醒** | 每段 **Exit reasons**（§2.2） | 关注**周期性**出现的码：`27`（PDC Signal）、`12`（Video Idle Timeout）、`16777225`（Wake on LAN） |
| **谁在耗电** | **Top Offenders**（每段 5 个），类型分 `Fx Device` / `Activator` / `Networking` / `Processor` / `PDC Phase` / `Other` | 活动时间 **>10% 标红、5–10% 标橙**。`Fx Device` = 实现了 PoFx 的驱动（一般在 SoC 上）；`Activator` = 能在待机中干活的软件组件 |
| **阻塞者 / 版本** | Screen Off 段的 **blockers**；报告开头 system information | 有红色子 blocker ⇒ 父段也标红；官方强调 OS/固件/BIOS 变化显著影响续航 ⇒ **A/B 必须记录固件版本** |

### 2.2 Exit reasons 码表（节选，官方原文）

| 码 | 含义 | 码 | 含义 |
|---|---|---|---|
| `1` | Power Button | `27` | **PDC Signal**（平台级唤醒源） |
| `4` | User Input | `54` | Input Touch |
| `12` | Video Idle Timeout | `55` | **Restricted Standby Battery Drain Budget Exceeded** |
| `15` | Lid | `56` / `57` | Restricted Standby【`56` 官方出处待核实】（`57` = Smart Restricted Standby） |
| `21` | System Idle Timeout | `16777223` | **SleepStudy Accounting** |

Sleep→Screen Off 专用表（码 ≥ 16777216，节选）：`16777225` = **PDC Task Client: Wake on LAN**、
`16777221` = Sync Client、`16777224` = Windows Update Client。
⇒ `16777223` 说明**测待机这件事本身就会唤醒系统**，报告里看到它属正常。

### 2.3 其余四条命令与唤醒面查询

| 命令 | 输出什么 | 权限与条件 |
|---|---|---|
| `/systempowerreport`（`/spr`） | 电源转换 + connected standby 效率，**明确包含 `Networking in standby` 字段** | **官方明文需要管理员** |
| `/energy` | HTML 效率报告（错误/警告/信息三级），点名 **USB 选择性挂起失效的设备、把定时器精度抬到 1 ms 的请求者、CPU 利用率高的进程、唤醒源** | 官方：**"should be used when the computer is idle and has no open programs"**；`/duration` 默认 **60 s** |
| `/batteryreport` | 设计容量 vs 满充容量（算健康度）、循环次数、近期用量；**容量比可能 >100%，属正常** | `/output`、`/xml`、`/duration <天数>` |
| `/srumutil` | 从 **SRUM**（即 **EEE / Energy Estimation Engine** 的数据落点）导出**整机能源估计**：`/srumutil /output x.csv /csv`，用于**按进程/服务/应用归因能耗**（任务管理器"能耗"列的后端） | EEE 注册表落点 `HKLM\SYSTEM\CurrentControlSet\Control\Power\EnergyEstimation` **在真实 Windows 上存在** `[旁证]`；**Qualcomm ARM64 上是否启用、精度如何：未核实** |
| `/systemsleepdiagnostics` | 用户不在场的时段 + 系统是否真的睡了 | **官方明文：requires administrator privileges and must be executed from an elevated command prompt** |

**唤醒面与阻塞者**：`/lastwake`、`/devicequery wake_armed`（**当前被授权唤醒系统的设备清单** —— Linux 侧
`/sys/kernel/irq/*/wakeup` 的对应物）、`/waketimers`、`/requests`（**谁在阻止休眠/息屏**）。
确认元凶后可用 `powercfg /requestsoverride process <进程名> Display System` 强制覆盖；`[旁证]` 实测
`/requestsoverride`（无参数）返回 `[SERVICE]` / `[PROCESS]` / `[DRIVER]` 三张空清单 ⇒ **命令与子命令存在已核实**，
语法为 `/requestsoverride <caller_type> <name> <request>`。
日志兜底：`System` 日志中 **Kernel-Power** 与 **Power-Troubleshooter**（含 sleep time / wake time / wake source）；
**具体事件 ID 需现场核实**【社区报告】。

**WPR + WPA**（Windows Performance Toolkit，随 Windows ADK 分发）**值得，但只在 sleepstudy 指向驱动/固件层问题时**：
官方专章 *Debugging Power Problems with Standby* 的 DRIPS 插件与四个演练恰好覆盖本机最关心的四件事
（**Spurious Wakes / Missing Drivers / Missing Constraints / USB Devices**），代价是**要装 GB 级 ADK**；
**ARM64 版 ADK/WPT 是否提供：未核实**。【已核实-官方文档】
x86 的 MSR 直写工具（ThrottleStop / QuickCPU 类）在 ARM64 上**无意义**：没有 x86 MSR 这一层。【推测】

### 2.4 可复现测量协议

```powershell
# 0) 一次性准备
powercfg /a
powercfg /batteryreport /output "$env:TEMP\win-report\baseline-battery.html"

# 1) 固定实验条件（写操作，须先告知使用者）：电池供电（DC）、拔扩展坞与 USB 外设、
#    关闭自动维护与 Windows Update 活动窗口、关闭"用户不在时降 QoS"（DisableUserPresenceQos = 1，见 §4.4）；
#    记录固件版本（msinfo32）、当前活动方案、亮度、Wi-Fi 连接状态

# 2) 基线：什么都不改，合盖待机一夜（≥ 6 h，最好 12 h）
powercfg /systempowerreport /output "$env:TEMP\win-report\spr-base.html"      # 管理员
powercfg /sleepstudy /duration 3 /output "$env:TEMP\win-report\ss-base.html"  # 管理员

# 3) 记录唤醒面
powercfg /devicequery wake_armed
powercfg /waketimers
powercfg /requests
powercfg /lastwake

# 4) 之后每改一项（一次只改一项）就重复 2)，比较 DRIPS% / 掉电 mW / Exit reasons / Top Offenders
# 5) 回滚见 §6.2
```

**基线报告要回答三个问题**：① `Sleep` 段存在吗？② DRIPS% 是多少（含 `HW:` 项）？
③ Exit reasons 里有没有**周期性**的码（`27` / `16777225` / `12` 循环）？
**若基线就是"DRIPS < 80% + 只有 Screen Off"** ⇒ §4 的旋钮只能在边缘上省，真正解法是"更早进休眠"。
这与 Linux 侧"不装任何东西也掉 70%"的观察自洽。【推测】（依据：两侧同一平台与固件；验证方式：执行上述协议）

---

## 3. 两条必须先纠正的社区通行说法

| 流传说法 | 事实 | 置信度 |
|---|---|---|
| "`ConnectivityInStandby` 是 `SUB_NONE` 下的一项，用 `powercfg /setacvalueindex SCHEME_CURRENT SUB_NONE f15576e8-98b7-4186-b944-eafa664402d9 0` 关掉即可" | **两处都错。** 官方 *Allow networking during standby* 明文写着 GUID `f15576e8-98b7-4186-b944-eafa664402d9` 是**一个 setting**，标注 `Hidden: Yes`，且 **Deprecated starting in Windows 10, version 2004**。`[旁证]` 实测：它出现在注册表 `HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\F15576E8-98B7-4186-B944-EAFA664402D9` 下作为**子组**（FriendlyName = "Networking connectivity in Standby"），`Attributes = 0x1`（隐藏位），子项 `0/1/2`（Disable / Enable / Managed by Windows）⇒ **子组写错了、设置也已废弃**；2004+ 由 **ACS（Adaptive Connected Standby）** 取代 | 【已核实-官方文档 + 旁证机实测】 |
| "改 `HKLM\SYSTEM\CurrentControlSet\Control\Power\CsEnabled` 或 `PlatformAoAcOverride` 就能关掉 Modern Standby、换回 S3" | 官方原文：**"Switching between S3 and Modern Standby cannot be done by changing a setting in the BIOS. Switching the power model is not supported in Windows without a complete OS re-install."** ⇒ ARM64 上大概率**无效**，社区有"改完睡不着/睡不醒/唤醒后黑屏"案例；GK-W76 **无 EDL/9008 救援通道** ⇒ **列入红线**（§5 T4） | 【已核实-官方文档】+【社区报告】 |

**Windows 11 24H2 起的新机制**：官方 *Modern Standby Wake Sources* 原文 —— 24H2 引入新省电措施，
**若检测到异常掉电，大部分唤醒源会被禁用，此时只能用电源键或开盖唤醒**；sleepstudy 的 exit reason
**`55` / `56` / `57`** 就是这套 **Restricted Standby** 在动作，这也是"以前能网络唤醒、现在不行了"的常见答案。

---

## 4. 旋钮表

> **列含义**：**命令或 API** = 可直接复制；**作用** = 机理与量级（**没有来源就不写数字**）；
> **重启** = 是否需要重启/重新插拔；**独/等**：**W** = Windows 独占、**L** = Linux 有等价或更强的旋钮、**B** = 两边等价。

### 4.1 电源模式滑块（overlay scheme，三个 GUID + 空 GUID）—— **第一优先**

| 名称 | 命令或 API | 作用 | 风险 | 重启 | 独/等 |
|---|---|---|---|---|---|
| 三个 GUID + 空 GUID | **最佳能效** `961cc777-2547-4f9d-8174-7d86181b8a7a`<br>**平衡** = 空 GUID（无覆盖）<br>**更好性能** `3af9b8d9-7c97-431d-ad78-34a8bfea439f`（**出厂默认**）<br>**最佳性能** `ded574b5-45a0-4f42-8737-46345c09c238` | 官方：overlay **只能定制 PPM 与 Graphics 两个子组**（别名 `SUB_PROCESSOR` / `SUB_GRAPHICS`）里"性能 vs 省电"的取舍，写其它子组会报错 | 低 | 否 | W |
| 设置入口 | API `PowerSetActiveOverlayScheme(GUID)`（`powrprof.dll`）；持久化到 `HKLM\SYSTEM\CurrentControlSet\Control\Power\User\PowerSchemes` 的 **`ActiveOverlayAcPowerScheme` / `ActiveOverlayDcPowerScheme`** | 第三方参考实现（LenovoLegionToolkit `WindowsPowerModeController.cs`）用的正是这三个 GUID + 这两个注册表值 + 该 API，并**先 `PowerSetActiveScheme(Balanced)` 再设 overlay**（滑块只在 Balanced 系方案下出现） | 低 | 否 | W |
| **头号陷阱** | — | 官方原文：**"Power throttling is always engaged, unless the slider is set to Best Performance. In this case, all applications will be opted out of power throttling."** ⇒ **拉到"最佳性能"= 关掉 Power Throttling**（量化见 §4.4）；**省电方向正确的一步是保持"最佳能效"或"平衡"** | — | 否 | W |
| 官方量化参考 | — | 官方给 "Best Performance" 的 EPP 覆盖示例为 `PerfEnergyPreference DcValue = 30`，"Better Battery" 为 **60**（**OEM 示例值，不是 GK-W76 的实际值**）；方向：更靠左 ⇒ EPP 更大 ⇒ 更省电 | — | 否 | W |
| 前提、查询与一处矛盾 | `powercfg /qh`（官方建议重定向到文件） | 滑块**只在活动方案为 Balanced 或其派生方案时出现**，换成 High performance / Power Saver 后失效。另：官方对 "Better Performance" 给了**两个不同 GUID**（滑块默认值表 `3af9b8d9-7c97-431d-ad78-34a8bfea439f`；INF 指令表 `{381B4222-F694-41F0-9685-FF5BB260DF2E}` = Balanced 方案 GUID）⇒ **须现场用 `/qh` 核实本机用哪个** | 低 | 否 | 【已核实-文档冲突；本机取值未核实】 |

### 4.2 处理器 PPM（Processor Power Management）

**总原则（官方原文）**：**"PPM profiles are tuned by Silicon vendors … reach out to your silicon vendor for
tuning guidance before modifying processor power management settings."** ⇒ 默认值是**高通在固件里调好的**，
改它们等于重新调参，**没有官方推荐值可抄**。【已核实】

| 名称 | 命令或 API | 作用 | 风险 | 重启 | 独/等 |
|---|---|---|---|---|---|
| **`PROCTHROTTLEMAX`**（最大处理器状态，`bc5038f7-23e0-4960-96da-33abaf5935ec`，不隐藏） | `powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMAX 80` | 官方语义 = **"maximum processor performance state，以最大处理器性能的百分比表示"**（**不是"额定频率百分比"**）。降到 70–90%（DC）是无风扇平板最经典的限频降温手段 | 中（过低 ⇒ 卡顿，易被误判为"系统坏了"） | 否 | L |
| **`PROCTHROTTLEMIN`**（最小处理器状态，`893dee8e-2bef-41e0-89c6-b55d0929964c`） | `powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PROCTHROTTLEMIN 5` | 提高最小值会**阻止降频与 idle**（费电）；省电方向 = 压到 0–5%。GUID 与 FriendlyName 依据旁证机注册表 `SUB_PROCESSOR`【已核实-旁证机注册表】 | 低 | 否 | L |
| **`PERFBOOSTMODE`**（性能提升模式，`be337238-0d82-4146-a960-4f3749d470c7`，**隐藏**） | `powercfg -attributes SUB_PROCESSOR be337238-0d82-4146-a960-4f3749d470c7 -ATTRIB_HIDE`<br>`powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PERFBOOSTMODE <0/1/2/3/4>` | 官方明确 **Arm-based devices: Supported**。`0`=Disabled、`1`=Enabled、`2`=Aggressive、`3`/`4` 等价 `1`/`2`（分列 ACPI P-State / CPPC-PEP / **Autonomous CPPC-PEP**）。**省电方向 = 0**；对无风扇机器是"用峰值换持续"的取舍 | 中 | 否 | B |
| **`PERFEPP` / `PERFEPP1`**（EPP 能效偏好，**隐藏**） | `powercfg -attributes SUB_PROCESSOR PERFEPP -ATTRIB_HIDE` 后 `powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR PERFEPP 100` | 官方语义：写 energy performance preference 寄存器，`0` 偏性能、`100` 偏省电，中间值按 `(setting*255)/100` 映射。**注意：官方 "Applies to" 表把 `PerfEnergyPreference` 的 Arm-based 列为 `N/A`，而同页 `PERFBOOSTMODE` / `MaxPerformance` 列为 `Supported`** ⇒ **自相矛盾，必须实机核实是否透传到 CPPC** | 中（未透传即纯自我安慰） | 否 | **L 更确定可用** |
| **核心停泊** `CPMINCORES` / `CPMAXCORES` / `CPCONCURRENCY` / `CPHEADROOM` / `CPDISTRIBUTION` / `CPLATENCYHINTUNPARK` | `powercfg -attributes SUB_PROCESSOR <各设置GUID> -ATTRIB_HIDE`（可能需先取消隐藏），读值与写值同 §4.7 | 官方 `CPMinCores` 的单位是**每效率类的核数**。`[旁证]` 的 Win10 LTSC 注册表 `SUB_PROCESSOR` 下**只枚举到 6 个设置，这些未出现** ⇒ 目标机需现场确认 | 中（错误的核心选择可能同时伤性能与功耗） | 否 | W |
| **异构调度**（big.LITTLE）`93b8b6dc-0698-4d1c-9ee4-0644e900c85d`、`bae08b81-2d5e-4688-ad6a-13243356654b` | `powercfg -attributes SUB_PROCESSOR 93b8b6dc-0698-4d1c-9ee4-0644e900c85d -ATTRIB_HIDE`（另一项 `bae08b81-2d5e-4688-ad6a-13243356654b` 同法） | `[旁证]` 实测**两项存在但均隐藏**；Windows 侧 QoS→核心选择的映射由 `SchedulingPolicy` / `ShortSchedulingPolicy` 控制 ⇒ **Windows 相对 Linux 的可调增量** | 中（需 A/B） | 否 | W |
| **`MaxFrequency` / `MaxFrequency1`**（频率上限，若存在） | 官方 QoS 设置列表包含 `MaxFrequency` | 比百分比更直觉的"锁频"手段 | — | 否 | **在 PPM profile 之外是否作为普通 power setting 暴露：未核实** |

**QoS 与 PPM profile 的关系**：处理器策略是**按使用场景切换的一套 profile**：`Default` / `LowLatency`（启动期）/
`LowPower`（媒体缓冲）/ `GameMode` / `Mixed Reality`（别名 `SustainedPerf`）/ `Constrained` /
**`ScreenOff`（息屏、无远程桌面、无执行请求、无热点时启用）** / **`Standby`（进入长期睡眠阶段后启用）**。
⇒ **对"整夜待机"最有价值的两个正是 `ScreenOff` 与 `Standby`**，官方明说它们为 Modern Standby 而设；
**但其配置通道是 Windows Provisioning Framework，不是 `powercfg /setdcvalueindex`**（见 §7）。
`/queryprofile`（`/qp`）与 `/setacprofileindex` / `/setdcprofileindex` 是较新版本才有的命令，**真机是否存在未核实**。

### 4.3 自适应休眠（Adaptive Hibernate）—— **针对"整夜掉电"最直接的一招**

| 名称 | 命令或 API | 作用 | 风险 | 重启 | 独/等 |
|---|---|---|---|---|---|
| **`standbybudgetpercent`**（待机预算百分比） | `powercfg /setdcvalueindex scheme_current sub_presence standbybudgetpercent <2..5>` | 官方定义：待机中每个刷新周期允许消耗的电池百分比，**默认 5%**，**超过就休眠**；官方 provisioning 示例值就是 **3** ⇒ **把 5 改成 2–3 = 给 Modern Standby 装"漏电就转休眠"的断路器**（S4 掉电极低） | 低（更早进休眠，唤醒稍慢） | 否 | **W**（Linux 对应物是 `suspend-then-hibernate`） |
| **`STANDBYBUDGETREFRESHINTERVAL`** / **`STANDBYBUDGETREFRESHCOUNT`** | `powercfg /setdcvalueindex SCHEME_CURRENT SUB_PRESENCE STANDBYBUDGETREFRESHINTERVAL <小时>`；`powercfg /setdcvalueindex SCHEME_CURRENT SUB_PRESENCE STANDBYBUDGETREFRESHCOUNT <n>` | 官方默认 **12 小时**刷新、最多 **4 次**：该间隔内未超预算即继续待机并刷新预算 | 低 | 否 | W |
| **`standbyreservetime`**（保底可用时间） | `powercfg /setdcvalueindex scheme_current sub_presence standbyreservetime <秒>` | 官方默认 **1200 s**：从待机/休眠醒来后**保证还能亮屏用多久** ⇒ 调大 = 更早转休眠、更保命 | 低 | 否 | W |
| **`HIBERNATEIDLE`**（`9d7815a6-7ee4-497e-8888-515a05f02364`，**隐藏**） | `powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE <秒>` | 官方语义：**"Specifies the duration of time after sleep that the system automatically wakes and enters hibernation. This settings enables hibernate option on Modern Standby systems."** **值 `0` = 用自适应休眠阈值**；Windows 有 **15 分钟宽限期**。官方忠告：固定定时器有 UX 缺陷，**优先用自适应休眠** | 中（太短 ⇒ 动不动就休眠） | 否 | W |
| **`STANDBYIDLE`**（`29f6c1db-86da-48c5-9fdb-f2b67b1f44da`，SUB_SLEEP）/ 唤醒定时器 | `powercfg /change standby-timeout-dc 5`；`powercfg /waketimers` 查、任务计划程序里关 | 息屏后多久进入 Standby；自动维护、Windows Update、同步客户端都能把机器叫醒（sleepstudy 的 `PDC Task Client` 码表就是它们在点名）。GUID 与别名 `(Standby after)` 经旁证机注册表核对【已核实-旁证机】 | 低 | 否 | B |
| **平台模型开关** | ~~`CsEnabled` / `PlatformAoAcOverride`~~ | **见 §3 与 §5 T4（红线）** | **极高** | 是 | 两边都是"固件说了算" |

**网络连接待机的正确做法**（2004+）：由 **ACS** 自动管理 —— **只有"用户开了远程桌面"或"某个 UWP 应用被设为
始终后台运行"时才保持联网**，否则待机时静默网络活动。判断当前到底连没连，用 **`/spr` 的
`Networking in standby` 字段**。【已核实-官方 ACS 一节】

### 4.4 EcoQoS / Power Throttling

| 项 | 内容 |
|---|---|
| **是什么** | 官方：**"When a process opts into enabling `PROCESS_POWER_THROTTLING_EXECUTION_SPEED`, the process will be classified as EcoQoS. The system will try to increase power efficiency through strategies such as reducing CPU frequency or using more power efficient cores."** 任务管理器里的"效率模式"就是它 |
| **API** | `SetProcessInformation(hProcess, ProcessPowerThrottling, &state, sizeof(PROCESS_POWER_THROTTLING_STATE))`；`state.Version = PROCESS_POWER_THROTTLING_CURRENT_VERSION`，`ControlMask` 选机制、`StateMask` 声明开关。两个机制：**`PROCESS_POWER_THROTTLING_EXECUTION_SPEED`**（EcoQoS）与 `PROCESS_POWER_THROTTLING_IGNORE_TIMER_RESOLUTION`；线程级用 `SetThreadInformation` + `THREAD_POWER_THROTTLING_EXECUTION_SPEED` |
| **量化收益** | 官方 *Customize the Windows performance power slider*：**"Power throttling saves up to 11% in CPU power by throttling CPU frequency of applications running in the background."** —— **本报告里唯一一条官方量化收益** |
| **QoS 分级语义** | `High`（前台/有声/显式标记）· `Medium`（可见但未聚焦；**新增：用户不活动一段时间后把前台应用降到 Medium，仅 DC**）· **`Low`（不可见/无声：DC 下选最省频率并调度到效率核）** · **`Utility`（后台服务：DC 下选最省频率并调度到效率核，Win11 22H2 起）** · **`Eco`（显式标记：始终选最省频率并调度到效率核）** · `Media` · `Deadline` |
| **"用户不在就降 QoS"** | 默认在检测到用户不活动后把前台应用 QoS 降到 `Medium`。**关闭方法**：`HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling` → REG_DWORD **`DisableUserPresenceQos` = 1**。官方明确提醒：**跑电池基准测试时必须关它**，否则自动化测试无输入会触发降级、污染结果 |
| **总开关的误区** | 官方：**"OEMs do not have an option to disable or change power throttling on any of the Windows slider modes"** ⇒ **用户唯一能关掉它的路径就是把滑块拉到 Best Performance**（代价见 §4.1） |
| **正确用法 / Linux 对照** | 对**不需要前台性能的后台常驻进程**（同步盘、IM、浏览器后台标签、更新器）显式打 EcoQoS；对**前台交互/音频**绝不要打 —— 官方：**"EcoQoS should not be used for performance critical or foreground user experiences"**。Linux 侧无等价物（`sched_setattr` / util-clamp / `cpu.max` 语义不同）⇒ **W**【后者为推测】 |

### 4.5 外设与平台组件

| 名称 | 命令或 API | 作用 | 风险 | 重启 | 独/等 |
|---|---|---|---|---|---|
| **显示器超时 / 变暗** | `powercfg /change monitor-timeout-dc 3`；细项在 **SUB_VIDEO**：`VIDEOIDLE` = `3c0bc021-c8a8-4e07-a973-6b14cbcb2b7e`、Dim display after = `17aaa29b-8b43-4b94-aafe-35f64daaf1ee`、Display dim brightness = `f1fbfde2-a960-4165-9f88-50667911ce96`、Display brightness = `aded5e82-b909-4619-9949-f5d71dac0bcb` | 面板是待机耗电大头；`[旁证]` 实测 GUID 与 FriendlyName 一一对应 | 低 | 否 | B |
| **自适应亮度** / **锁屏后熄屏超时** | `ADAPTBRIGHT`（`fbd9aa66-9553-4097-ba44-ed6e9d65eab8`）；`${8EC4B3A5-6868-48c2-BE75-4F3044BE88A7}` = "Console lock display off timeout" | `powercfg /aliases` 可列出 `ADAPTBRIGHT`；后者决定锁屏后多久熄屏。两项的 GUID 与 FriendlyName 已在旁证机上实测核对【已核实-旁证机实测】 | 低 | 否 | 部分等价（ALS + 用户态） |
| **设备空闲策略** | 子组 `4faab71a-92e5-4726-b531-224559672d19`，**0 = Performance / 1 = Power savings** | `[旁证]` 存在；**在 ARM64 Win11 上的存在性未核实**【未核实】⇒ **全局设备空闲偏置，省电方向 = 1** | 低 | 否 | B（Linux runtime PM） |
| **断开式待机模式** | 子组 `68AFB2D9-EE95-47A8-8F50-4115088073B1`，**0 = Normal / 1 = Aggressive** | `[旁证]` 存在；**在 ARM64 Win11 上的存在性未核实**【未核实】。Aggressive = 待机时更激进地断网（省电，可能丢通知） | 低 | 否 | W |
| **USB 选择性挂起** | 子组 `2a737441-1930-4402-8d77-b2bebba308a3`：`48e6b7a6-50f5-4782-a5d4-53bb8f07e226`（USB selective suspend）、`0853a681-27c8-4100-a2fd-82013e970683`（Hub Selective Suspend Timeout）、`d4e98f31-5ffe-4ce1-be31-1b38b384c009`（USB 3 Link Power Management） | `[旁证]` GUID 与 FriendlyName 一致；官方 `/energy` 会点名"USB 设备没进选择性挂起" | 低 | 否（需重插设备） | B（`usbcore.autosuspend`） |
| **PCIe 链路电源（ASPM）** | 子组 `501a4d13-42af-4429-9fd1-a8218c268e20`，唯一设置 `ee12f906-d277-404b-b6da-e5fa1a576df5` = 别名 **`ASPM`** | GUID 经 2010 年官方文档交叉核对一致；**取值档位（Off / Moderate / Maximum）需真机 `/q` 核实** | 低 | 部分档位需重启 | **L 略强**（`pcie_aspm.policy`） |
| **磁盘空闲（NVMe 省电）** | 子组 `0012ee47-9041-4b5d-9b77-535fba8b1442`，设置 `6738e2c4-e8a5-4a42-b16a-e040e769756e` = 别名 **`DISKIDLE`**；`powercfg /change disk-timeout-dc <分钟>` | Windows 侧**只有"空闲多久后断电"**。Linux 侧的 **NVMe APST**（`nvme_core.default_ps_max_latency_us`）由存储驱动与设备固件自行协商，**无等价用户旋钮**（未找到官方文档） | 低 | 否 | **L 略强** |
| **USB 设备唤醒** | `powercfg /devicequery wake_armed` 查 → `powercfg /devicedisablewake "<设备名>"` | 华为官方支持页把这条列为"睡眠耗电快"的**头号原因**：合盖睡眠状态可被外接设备（无线 2.4G 鼠标、USB 鼠标等）唤醒并增加功耗 | 中（**全关会连键盘一起关掉**，见 §6.1） | 否 | B（`/sys/bus/*/power/wakeup`） |
| **WLAN 省电** | `Set-NetAdapterPowerManagement -Name "<适配器>" -SelectiveSuspend Enabled -DeviceSleepOnDisconnect Enabled -D0PacketCoalescing Enabled -WakeOnMagicPacket Disabled -WakeOnPattern Disabled -NoRestart` | 官方 cmdlet，参数集逐项核实：`ArpOffload` / `D0PacketCoalescing` / `DeviceSleepOnDisconnect` / `NSOffload` / `RsnRekeyOffload` / `SelectiveSuspend` / `WakeOnMagicPacket` / `WakeOnPattern`（均 `Enabled`/`Disabled`）；`-NoRestart` 可避免重载驱动 | 低 | 部分属性需重载适配器 | B |
| **网卡"省电模式"档位** | 设备管理器 → 网卡 → 高级 → "省电模式 / Power Save Mode"（通常 Maximum/Medium/Minimum Power Saving） | **不是 Windows 通用 API**，属厂商 INF 暴露的高级属性。GK-W76 的 WLAN 芯片型号与可选值 **未核实**（8cx Gen 3 平台通常配 FastConnect 6900 / WCN685x，但本项目未取证） | 低 | 否 | 厂商专有 |
| **散热策略 `SYSCOOLPOL`** | `powercfg /setdcvalueindex SCHEME_CURRENT SUB_PROCESSOR SYSCOOLPOL <0/1>` | 只有被动/主动两档，很粗；无风扇机器应被动优先。设置本身可写，但**实际效果未核实**【未核实】（见 §4.7 与 §8 第 13 条） | 低 | 否 | B（thermal zone `policy`） |

### 4.6 后台应用与启动项策略

| 名称 | 命令或 API | 作用 | 重启 |
|---|---|---|---|
| **允许后台应用运行** | 设置 → 系统 → 电池 → 逐应用 `Never` / `Let Windows decide` / `Always` | 官方原文：**"By default, apps are set to 'Let Windows decide,' which will not cause the app to remain connected."** ⇒ **只有设为 `Always` 才会让它在待机时保持联网**（UWP 后台任务的网络访问权直接由该开关控制）⇒ **省电方向 = 全部设为 `Never` / `Let Windows decide`** | 否 |
| **启动项** | 任务管理器 → 启动应用；`HKLM\…\ContentDeliveryManager\SilentInstalledAppsEnabled` | 减少常驻进程数量；**要先测再改**，不要凭印象关【未核实量化】 | 部分需要 |
| **Defender 扫描计划 / 遥测** | `Set-MpPreference`（如 `-ScanScheduleDay`）、任务计划程序、DiagTrack 服务 | **未找到"扫描计划/遥测对续航影响"的官方量化数字。** 可知的是：sleepstudy 的 **Top Offenders / Activators** 会点名它们，`/waketimers` 会点名唤醒定时器 ⇒ **先测再改**（关 Defender/DiagTrack 有合规与安全代价） | 部分需要 |

### 4.7 隐藏设置：怎么列、怎么读、哪些真有用

**为什么 `/q` 看不到**【已核实-官方文档 + `[旁证]`】：隐藏设置的 `Attributes` 位含 `0x1`
（`[旁证]` 实测 `PERFBOOSTMODE` 即如此），而 `powercfg /q SCHEME_CURRENT SUB_PROCESSOR`
**只列出可见项**；带别名直接 `/q ... PERFBOOSTMODE` **只回显方案头、不回显设置**。

```powershell
# 需要管理员权限（在提权 PowerShell 里执行）
# ① 取消隐藏 → 读 → 改回隐藏（只临时改变"可见性"，不改值）
powercfg -attributes <子组GUID> <设置GUID> -ATTRIB_HIDE
powercfg /q SCHEME_CURRENT <子组GUID> <设置GUID>
powercfg -attributes <子组GUID> <设置GUID> +ATTRIB_HIDE

# ② 纯只读（最安全，零副作用）：直接读注册表
#    定义：HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerSettings\<子组GUID>\<设置GUID>
#          FriendlyName / ValueMinimum / ValueMaximum / ValueIncrement / ValueUnits / Attributes
#    当前值：HKLM\...\Power\User\PowerSchemes\<方案GUID>\<子组GUID>\<设置GUID>
#          ACSettingIndex / DCSettingIndex

# ③ 导出整个方案再查
powercfg /export C:\path\scheme.pow SCHEME_CURRENT
```

**别名表不完整**【已核实 + `[旁证]`】：`powercfg /aliases` 只列常用别名，
**不含 `PERFBOOSTMODE` / `PERFEPP`** ⇒ **"查不到别名"不等于"设置不存在"**，必须查注册表或官方设置页。

| 项 | 判断 |
|---|---|
| `HIBERNATEIDLE` | **正例**：官方有定义与命令行；2010 年官方文档亦收录其 GUID 与 `(Hibernate after)` 名称 |
| `standbybudgetpercent` / `STANDBYBUDGETREFRESHINTERVAL` / `standbyreservetime` | **正例**：官方给出 `/setdcvalueindex` 原样命令与默认值 |
| `PERFBOOSTMODE` | **正例**：官方声明 ARM 支持 |
| `SYSCOOLPOL`（散热策略） | **未定**：`/setdcvalueindex` 可写、官方设置存在，但**实际效果未核实**（无风扇平台上的实测收益无来源） ⇒ 不要当"成熟旋钮"用 |
| `ConnectivityInStandby`（`f15576e8-98b7-4186-b944-eafa664402d9`） | **反例**：2004 起已 deprecated、被 ACS 取代；流传写法**子组都写错了** |
| `CsEnabled` / `PlatformAoAcOverride` | **反例且危险**：官方明文不支持换电源模型（+ 社区失败案例） |
| `Device idle policy` / `Disconnected Standby Mode` / `Allow Standby States` / `Legacy RTC mitigations` | **未定**：`[旁证]` 存在但均隐藏；**改变它们的实测效果没有可靠证据** ⇒ 不要当"秘技"传播 |

### 4.8 Windows 独占 vs Linux 等价（对照）

> 本表的 Windows 列来自上文的【已核实】条目；**Linux 列是依据本项目 Linux 侧既有实测与接口语义的对照判断**【推测】，
> 用于判断"某个旋钮在 Linux 侧是否已有更直接的对等物"，不构成对 GK-W76 Windows 侧行为的断言。

| 能力 | Windows | Linux（本项目现状） | 谁更强 |
|---|---|---|---|
| 待机质量归因 | `/sleepstudy`：DRIPS%（含 `HW:`）、掉电 mW、Top Offenders、Exit reasons、blockers | 自建：`pm_wakeup_irq`、`/proc/interrupts` 差分、`rtcwake`、`charge_now` 差分 | **Windows 强**（现成、有模型）；HW DRIPS 依赖固件上报 |
| 按进程/服务能耗归因 | **EEE + SRUM**（`/srumutil`）、任务管理器"能耗"列 | 无等价（`powertop` 是估算/ACPI 事件级） | **Windows 独占** |
| EPP | `PERFEPP`（ARM64 适用性**未核实**，官方自相矛盾） | `energy_performance_preference`（本项目已在用） | **Linux 更确定可用** |
| Boost | `PERFBOOSTMODE`（官方声明 ARM 支持）、`PERFBOOSTPOL` | `cpufreq` boost / `sched` / OPP | 各有胜负 |
| 核心停泊 / 异构调度 | `CPMINCORES`/`CPMAXCORES`、Heterogeneous thread scheduling policy、QoS→效率核 | 无等价的"用户可调档位"，由 EAS/调度器内部决定 | **Windows 独占（可调面）** |
| PCIe ASPM | `ASPM`；NVMe APST 无旋钮 | `pcie_aspm.policy`、`nvme_core.default_ps_max_latency_us` | **Linux 略强** |
| USB 选择性挂起 / WLAN 省电 | USB 子组 + `/energy` 点名；`Set-NetAdapterPowerManagement` | `usbcore.autosuspend`、`power/control`；`iw dev <if> set power_save on`、WoWLAN | 等价 |
| 唤醒设备管理 | `/devicequery wake_armed` + `/devicedisablewake` | `/sys/bus/*/power/wakeup`、`/sys/kernel/irq/*/wakeup` | 等价（Windows 命令更整齐） |
| "睡下去了但被拉醒"的最终判定 | `/lastwake` + sleepstudy exit reason | `pm_wakeup_irq` + `/proc/interrupts` 差分 | **Windows 更省事** |
| 电源模型切换（S0ix ↔ S3） | **不支持**（要重装） | 由 ACPI/固件决定，`mem_sleep` 可切（目标机 Linux 侧已证 s2idle 唯一） | 两边都是"固件说了算" |
| 调频调压 / 降压 | 无（ARM64 无 MSR 通道） | OPP / regulator / cpufreq 全链路（也很容易搞坏） | **Linux 强得多** |
| 散热策略 | `SYSCOOLPOL`（两档，很粗） | thermal zone + `policy`（本项目已做 75 °C 节流） | 等价 |

---

## 5. 分级建议 T0–T4

> **前置铁律**：**先做 §2.4 的基线测量**；**一次只改一项**，改完复测。
> 「代价与回退」列同时给出该步的代价与回退手段；**独/等** 列含义见 §4 表头。

| 级 | # | 动作 | 代价与回退 | 独/等 |
|---|---|---|---|---|
| **T0** 零风险 / 纯只读（立刻可做） | 1 | 跑 §2.4 的全部只读命令：`/a`、`/sleepstudy`、`/spr`、`/srumutil`、`/devicequery wake_armed`、`/waketimers`、`/requests`、`/lastwake`、`/batteryreport` | 无代价；天然可回退（不写任何设置） | — |
| **T0** | 2 | **建立回滚点**：`powercfg /export` 导出当前方案；记录固件版本（`msinfo32`）与 WLAN 型号 | 无代价 | — |
| **T1** 安全、可逆、立刻生效（推荐作为"魔改版"出厂默认） | 3 | **滑块设为"最佳能效"或"平衡"**，**绝不设"最佳性能"** | 峰值性能略降；改回滑块 | W |
| **T1** | 4 | 后台应用全部设为 `Let Windows decide` / `Never` | 后台通知/同步可能延迟；逐项改回 | W |
| **T1** | 5 | `monitor-timeout-dc` 降到 2–3 分钟 + 开启自适应亮度 | 无代价；`powercfg /change` 回退 | B |
| **T1** | 6 | `/devicedisablewake` 关掉不必要的外设唤醒（**保留键盘与电源键**，见 §6.1） | 需按电源键唤醒；`/deviceenablewake` 回退 | B |
| **T1** | 7 | WLAN：`-SelectiveSuspend Enabled -D0PacketCoalescing Enabled -WakeOnPattern Disabled`（先 `-NoRestart`） | 待机时网络通知可能延迟；反向设置回退 | B |
| **T1** | 8 | USB 选择性挂起打开 + PCIe ASPM 设省电档（若真机有该档位） | 外设唤醒延迟；反向设置回退 | B |
| **T1** | 9 | 跑续航基准时设 `DisableUserPresenceQos = 1`（**日常可不开**——它本身是省电功能） | 无代价；删除该值 | W |
| **T2** 中等风险、需要复测（"魔改版"的调优包） | 10 | **自适应休眠三件套**：`standbybudgetpercent` 设 2–3、`standbyreservetime` 视需要调大、必要时固定 `HIBERNATEIDLE`（如 1800–3600 s） | 更早转休眠、唤醒稍慢；回默认值或 `-restoredefaultschemes` | W |
| **T2** | 11 | `PROCTHROTTLEMAX` 限到 70–90%（DC） | 重负载明显变慢；回 100 | L |
| **T2** | 12 | `PROCTHROTTLEMIN` 压到 0–5%（DC） | 无代价；回默认 | L |
| **T2** | 13 | 给明确的**后台常驻进程**打 **EcoQoS**（**只给后台，不给前台/音频**） | 被标记进程变慢；`StateMask = 0` 关闭 | W |
| **T2** | 14 | `SYSCOOLPOL` 改为**被动** | 持续性能略降；改回 | B |
| **T2** | 15 | 用 `/energy` 做一次 60 s 全系统检查，按它点名的项逐条处理 | 无代价；逐项回退 | — |
| **T3** 激进 / 需要"能重装系统"的觉悟 | 16 | `PERFBOOSTMODE = 0`（禁 boost） | 短时爆发性能下降；无风扇机器上"削峰"换更稳的持续性能 | B |
| **T3** | 17 | **EPP 设 100** | 性能下降。**前提：先实机确认 `PERFEPP` / `PERFEPP1` 存在且在 ARM64 上真的透传到 CPPC**；否则纯属自我安慰 | L |
| **T3** | 18 | 核心停泊 / 异构调度策略改激进省电档 | **可能同时伤性能与功耗** ⇒ **必须先做 A/B** | W |
| **T3** | 19 | 关闭遥测/DiagTrack、Defender 计划扫描、预装应用静默安装 | 安全与合规代价，**且无量化收益证据**；建议只做"计划扫描挪到 AC 时"这类低代价动作 | — |
| **T4** 不可由用户调优解决 | 20 | **`CsEnabled` / `PlatformAoAcOverride` 关 Modern Standby（红线）** | **不要做**：官方明文不支持换电源模型；社区有睡死案例；GK-W76 **无 EDL/9008 救援通道** | — |
| **T4** | 21 | **DRIPS 驻留率低** | 官方原文：待机低功耗要求 **"Both software and hardware must be made ready for low-power operation"** ⇒ 固件/驱动没把平台送进最深空闲态时，**Windows 侧无法修** | — |
| **T4** | 22 | **平台级唤醒源** | Linux 侧实测到 PDC 上的 DP PHY 唤醒 IRQ 秒级拉醒；Windows 侧对应 sleepstudy 的 **`27 PDC Signal`** 与 **`PDC Task Client:*`（含 `16777225`）**。**固件在这里动作，Windows 也只能"记下来"**（24H2 的 Restricted Standby 是唯一反制） | — |
| **T4** | 23 | **厂商 EC 行为**（风扇/温度门限/充电策略/平台功耗上限） | 走 **WMI/ACPI → EC**，**第三方脚本改不到** | — |

---

## 6. 风险与恢复

### 6.1 最容易把人搞死的行为清单

| 行为 | 后果 | 恢复 |
|---|---|---|
| 改 `PlatformAoAcOverride` / `CsEnabled` 试图关 Modern Standby | 睡不着 / 睡死 / 无法唤醒 / 唤醒后黑屏；**官方明文：换电源模型要重装系统** | 删除该值 + 重启（社区做法）；**若无效只能重装**；本机无 EDL/9008 通道 ⇒ 只能靠 WinRE/重装介质 |
| 改 `HKLM\SYSTEM\CurrentControlSet\Control\Power` 下的自由值（`HiberFileSizePercent`、`AwayModeEnabled`、`ModernSleep`/`PDC` 子键） | 休眠文件失效 / 唤醒异常 / 待机行为诡异 | 删除或还原该值；`HiberFileSizePercent` 用 `powercfg /hibernate /size` 回正 |
| `HIBERNATEIDLE` 设得过小 | 动不动就休眠（体验崩） | `powercfg /setdcvalueindex SCHEME_CURRENT SUB_SLEEP HIBERNATEIDLE 0`（回到自适应）或 `powercfg -restoredefaultschemes` |
| **全部** `powercfg /devicedisablewake`（含键盘） | 待机后**无法用键盘唤醒**（目标机键盘可拆，只能靠电源键） | 逐个 `powercfg /deviceenablewake`。**保守做法：只关鼠标/网卡/触屏，保留键盘与电源键** |
| `PROCTHROTTLEMAX` 设得过低（如 30%） | 电池下明显卡顿，易被误判为"系统坏了" | 回 100 |
| 关 Defender / DiagTrack | 安全与合规代价，**收益未量化** | 逐项回滚；**建议不做** |
| 对前台/音频进程打 EcoQoS | 卡顿 / 掉帧 / 音频爆音（官方明确禁止） | `ControlMask = PROCESS_POWER_THROTTLING_EXECUTION_SPEED; StateMask = 0` |

### 6.2 恢复手段（从轻到重）

```powershell
# 需要管理员权限（在提权 PowerShell 里执行）
# ① 只回滚覆盖方案（最轻，滑块类问题）
powercfg /setactive SCHEME_BALANCED
# ② 从备份导入自己导出的方案（推荐：所有实验前先 export）
powercfg /import C:\path\before.pow
# ③ 恢复全部电源方案为出厂默认（会丢弃自定义方案）
powercfg -restoredefaultschemes
# ④ 休眠文件相关
powercfg /hibernate /size 0
powercfg /hibernate /type reduced
# ⑤ 注册表级回滚（仅在前述无效时，且务必先导出该键）
reg export "HKLM\SYSTEM\CurrentControlSet\Control\Power" C:\path\power-backup.reg /y
reg import C:\path\power-backup.reg
```

**`-restoredefaultschemes` 用短横线**（不是 `/`）；它**恢复内置方案的默认值，不会"撤销"改过的注册表隐藏值，
也不保证恢复 OEM 自定义的方案**（OEM 方案常由厂商 INF / 首次开机脚本写入）。语法存在【已核实-官方支持页面】；
**实际效果未实测**【推测-需实测】。**最强保险 = 实验前 `powercfg /export` 一份 `.pow` + `reg export` 一份
`Control\Power`** —— 这两样才是"可执行的回滚点"。

### 6.3 一条必须先讲的"坏消息"

官方原文：**"Switching between S3 and Modern Standby cannot be done by changing a setting in the BIOS.
Switching the power model is not supported in Windows without a complete OS re-install."**
⇒ "把 Win11 魔改成一台会真正省电待机的机器"这件事，**有一部分不属于可调优范围，而属于平台/固件质量**。
Linux 侧实测（s2idle 留不住、PDC 秒级拉醒、venus 挂起 `-110`）已证明这台机器在低功耗路径上有真实缺陷。
Windows 侧的合理期望只有三条：**① 用 `sleepstudy` 把真相量化；② 用 T1/T2 把"非 DRIPS 时间"压小、
把"漏电就转休眠"做早；③ 不要指望把 DRIPS 修好。**

---

## 7. 可交付形态

| 形态 | 能覆盖 | 不能覆盖 | 结论 |
|---|---|---|---|
| **一条命令** | 改 overlay（滑块）+ `powercfg /change monitor-timeout-dc 3` | 几乎所有细项 | 只够做"开关" |
| **一个 `.pow` 方案文件** | `PROCTHROTTLEMAX`/`MIN`、超时、USB/PCIe ASPM、`DISKIDLE`，以及导出时已在方案内的隐藏项 | overlay 覆盖方案、隐藏的 `sub_presence` 值、网卡高级属性、唤醒设备清单 | **基础层用 `.pow`，其余用脚本补** |
| **一个 PowerShell 脚本（推荐主交付）** | 全部 `powercfg` 写操作 + `Set-NetAdapterPowerManagement` + `/devicedisablewake` + EcoQoS（需小 EXE 或 `Add-Type` 调 `SetProcessInformation`）+ 注册表 `DisableUserPresenceQos` | 厂商 EC / 性能模式 | **可按档位参数化（`-Profile Safe/Balanced/Aggressive`）+ `-Revert`** |
| **一个 MSIX 应用** | 上面全部 + GUI + 一键测量（调用 `/sleepstudy` 并解析 HTML）+ 一键回滚 | 同上 | **最像"管家"的形态；但 MSIX 装服务/驱动受限**，常驻与开机自启需走**计划任务** |
| **provisioning package（`.ppkg`）/ `customizations.xml`** | 官方给 OEM 的正规通道，可覆盖 **PPM profile（含 `ScreenOff` / `Standby`）+ QoS 档 + overlay + 自适应休眠** | — | 官方支持 `powercfg /pxml /output x.xml` 自动生成 provisioning XML |
| **必须重启才生效的项** | ① PCIe ASPM 部分档位；② 网卡高级属性（部分需重载适配器）；③ **任何经由 provisioning/INF 下发的 PPM profile 与 QoS 档**；④ 电源模型类改动 | — | **其余（滑块、超时、隐藏值、EcoQoS、唤醒设备）都不需要重启** |

**一处必须写清的机制边界**：**PPM profile（含专为待机设计的 `ScreenOff` / `Standby` 档）不是 `powercfg`
的普通设置**，其下发通道是 **Windows Provisioning Framework（provisioning package / INF / 镜像阶段）**。
因此"用脚本把待机调好"这条路**够不到 profile 层**；要做"魔改版镜像"，这才是正路。【已核实-官方文档】

---

## 8. 待真机核实清单（按重要性排序）

| # | 未核实项 | 为什么重要 | 怎么取证（只读） |
|:-:|---|---|---|
| 1 | **GK-W76 的 `powercfg /a` 实际输出**（有没有 S3？`Network Connected` 还是 `Disconnected`？） | 决定"整夜能不能进低功耗"和后续全部策略 | `powercfg /a` |
| 2 | **`/sleepstudy` 在 GK-W76 上是否真的生成报告**；报告里 **DRIPS% / `HW:` 硬件 DRIPS / `Sleep` 段是否存在 / Exit reasons** | **整份报告的地基**；社区有"某些 ARM64 设备不生成 sleepstudy"的说法 | 管理员运行 `/sleepstudy`，看是否落盘 HTML |
| 3 | **`PERFEPP` / `PERFEPP1` 的 GUID 是否存在，以及 ARM64 上是否真的透传到 CPPC** | 官方 "Applies to" 表把 Arm 列为 `N/A`，同页其它设置却是 `Supported` ⇒ **自相矛盾，必须实机判定** | `/aliases` + 扫注册表 `SUB_PROCESSOR` + 改值后看频率/功耗 |
| 4 | **`CPMINCORES` / `CPMAXCORES` / `CPCONCURRENCY` 是否存在** | 核心停泊是"异构调度"最直接的旋钮；`[旁证]`（Win10 LTSC）**未命中** | 扫注册表 `SUB_PROCESSOR` 全部子键；`powercfg /qh` |
| 5 | **8cx Gen 3 的核心拓扑是否 4+4 以及各簇频率** | 影响"停大核/留小核"这类策略是否成立 | `msinfo32`、任务管理器；或 Linux 侧 `lscpu` / DTB（本项目已有） |
| 6 | **华为"高能模式"在本机上是否存在** | 决定"厂商侧还有没有额外杠杆"；华为官方支持页**未把 MateBook E Go 列入适用产品** | PC Manager → 优化 → 是否有性能调优；或 `Fn+P` |
| 7 | **华为"高能模式"在 Windows 侧到底改了什么** | 若是 EC 直控，Windows 脚本无法复刻。公开逆向只到"PC Manager 走 raw HID + WMI 改 EC"这一层，**具体到性能模式无公开证据** | 无公开来源可查 ⇒ 只能实测观察 |
| 8 | **本机 WLAN 芯片型号与"省电模式"可选档位** | WLAN 是待机耗电常客 | 设备管理器 / `Get-NetAdapter`；`Drv/` 转储的 INF 中可能找到 |
| 9 | **24H2 的 Restricted Standby 是否已生效**（是否出现 exit reason `55`/`56`/`57`） | 决定"唤醒源被 Windows 主动关掉"是否已发生 | sleepstudy 报告 |
| 10 | **`powercfg -restoredefaultschemes` 的实际效果** | 它是最后一道回滚 | 只能在可重装的机器上做 |
| 11 | **EEE 在 Qualcomm ARM64 上的启用状态与精度** | 决定 `/srumutil` 的能耗归因能不能信 | `HKLM\...\Control\Power\EnergyEstimation` 的实际配置 + 与实测对比 |
| 12 | **ARM64 版 Windows ADK/WPT（WPR/WPA）是否提供** | 决定"要不要走 WPA 深入" | 下载页核实 |
| 13 | **`SYSCOOLPOL` 的实际效果**（被动 vs 主动到底改变了什么） | 文档把它当可写旋钮，但**实际效果未核实**；无风扇平台上若它只改风扇策略则完全没有收益 | 改值前后对同一负载记录频率/温度/功耗与 `gpu-thermal` 类热区读数；对照 Linux 侧 thermal zone `policy` 行为 |

> 已闭合项：`powercfg /requestsoverride` 的命令名与子命令 —— `[旁证]` 实测命令存在，无参数时列出
> `[SERVICE]` / `[PROCESS]` / `[DRIVER]` 三张空表。

---

## 9. 来源

**Microsoft 官方文档（一手）**

- [Powercfg command-line options](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/powercfg-command-line-options) —— 全部命令、参数与权限
- [Modern standby SleepStudy](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/modern-standby-sleepstudy) —— DRIPS%、颜色阈值、Exit reasons 码表、Top Offenders
- [Debugging Power Problems with Standby](https://learn.microsoft.com/en-us/windows-hardware/test/wpt/debugging-problems-with-standby) —— WPR/WPA、DRIPS 插件与四个演练
- [What is Modern Standby](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/modern-standby) —— 电源模型不可在 Windows 内切换（原文）
- [Modern Standby vs S3](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/modern-standby-vs-s3) —— `Screen Off` / `Sleep` 语义
- [Modern Standby Wake Sources](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/modern-standby-wake-sources) —— 唤醒源全表与 **24H2 Restricted Standby**
- [Network connectivity（ACS）](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/modern-standby-network-connectivity) —— ACS 与 `/spr` 的 `Networking in standby`
- [Overview of Modern Standby Validation](https://learn.microsoft.com/en-us/windows-hardware/design/device-experiences/overview-of-modern-standby-validation) —— `powercfg /a` 的期望输出
- [Allow networking during standby](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/no-subgroup-settings-allow-networking-during-standby) —— `f15576e8-98b7-4186-b944-eafa664402d9` 的身份与弃用声明
- [Customize the Windows performance power slider](https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/customize-power-slider) —— overlay GUID、EPP 示例值、power throttling "up to 11%"
- [Processor power management options](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/configure-processor-power-management-options) —— PPM profile（含 `ScreenOff`/`Standby`）与 QoS
- [PERFBOOSTMODE](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfboostmode) —— 取值表与 Arm-based: Supported
- [PerfEnergyPreference（PERFEPP）](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-perfenergypreference) —— EPP 语义与 Arm-based: N/A
- [MaxPerformance（PROCTHROTTLEMAX）](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/options-for-perf-state-engine-maxperformance) —— 语义与 Arm 支持
- [Adaptive Hibernate](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/adaptive-hibernate) —— standby budget 三件套的命令与默认值
- [Hibernate idle timeout（HIBERNATEIDLE）](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/sleep-settings-hibernate-idle-timeout) —— GUID 与语义
- [Quality of Service](https://learn.microsoft.com/en-us/windows/win32/procthread/quality-of-service) —— QoS 分级与 `DisableUserPresenceQos`
- [SetProcessInformation](https://learn.microsoft.com/en-us/windows/win32/api/processthreadsapi/nf-processthreadsapi-setprocessinformation) —— EcoQoS 与官方 C 示例
- [Set-NetAdapterPowerManagement](https://learn.microsoft.com/en-us/powershell/module/netadapter/set-netadapterpowermanagement) —— WLAN 省电参数集
- [ShortSchedulingPolicy（异构调度）](https://learn.microsoft.com/en-us/windows-hardware/customize/power-settings/configuration-for-hetero-power-scheduling-shortschedulingpolicy) —— 异构调度参数
- *Power Policy Configuration and Deployment in Windows*（2010-10-21，微软白皮书）—— **仅**用于交叉核对 **6 项**：`PROCTHROTTLEMAX`、`PROCTHROTTLEMIN`、`STANDBYIDLE`、`HIBERNATEIDLE`、`DISKIDLE`、`ASPM` 的 GUID 与别名；不含 overlay scheme、EcoQoS、Modern Standby、自适应休眠。**说明**：该白皮书的交叉核对来自同批取证下载的官方文档，**不是**本工作包原始调研报告的内容（调研报告只核对了其中 4 项）

**厂商官方**

- [华为：华为笔记本电脑睡眠状态下耗电快](https://consumer.huawei.com/cn/support/content/zh-cn00729197/) —— 官方承认三条原因（扩展坞、外设唤醒、计划任务）与 `powercfg waketimers` 检查法
- [华为：如何开启或关闭高能模式](https://consumer.huawei.com/cn/support/content/zh-cn01040494/) —— 三种模式与 `Fn+P`，**适用产品列表里没有 MateBook E Go**

**第三方来源**

- [LenovoLegionToolkit `WindowsPowerModeController.cs`](https://github.com/LenovoLegionToolkit-Team/LenovoLegionToolkit/blob/master/LenovoLegionToolkit.Lib/Controllers/WindowsPowerModeController.cs) —— 三个 overlay GUID、`PowerSetActiveOverlayScheme`、`ActiveOverlayAc/DcPowerScheme`
- [Escaping Huawei/Honor PC Manager](https://www.tinyedi.com/escaping-huawei-honor-pc-manager/) —— PC Manager 经 raw HID + WMI → EC 与硬件通信

**旁证机实测（AMD64 / Windows 10 LTSC，只证明 GUID 与注册表结构存在，不代表 GK-W76）**

- `powercfg /aliases`、`powercfg /query SCHEME_CURRENT SUB_PROCESSOR`、`powercfg /batteryreport /?`、`powercfg /requestsoverride`
- 注册表 `HKLM\SYSTEM\CurrentControlSet\Control\Power\{EnergyEstimation, ModernSleep, PDC, PowerSettings, Profile, User}` 与 25 个 PowerSettings 子组的 `FriendlyName` / `Attributes` / 子项
- 实测确认：`ConnectivityInStandby` 是**隐藏子组**、`PERFBOOSTMODE` 的 `Attributes` 含隐藏位、`powercfg /q` 不回显隐藏项

---

## 10. 与其它章节的关系

| 章节 | 关系 |
|---|---|
| 主报告 [`win11-feasibility.md`](win11-feasibility.md) | 工作包划分、发布红线与立项结论；本文是其 (c) 章的展开 |
| 原厂基线（工作包 (a) 章） | 原厂首次开机脚本已含 `standbybudgetpercent 2` 等电源动作，是"最省电 Win11"的 ground truth，**本文策略应以它为准再叠加** |
| 管家 APP（工作包 (b) 章） | 本文的 T0 测量与 T1/T2 写操作正是管家 APP 电源模块可直接调用的能力；**厂商 EC 通路不在其中** |
