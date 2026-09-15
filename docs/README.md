# docs/ —— 文档索引

本目录的文档**都是实机结论的沉淀，不是研究笔记**。

每一篇都来自在 HUAWEI MateBook E Go 2022 性能版（GK-W76 / SC8280XP / 设备树 `gaokun3`）
上的真实操作：可复现的命令、实机输出、以及"哪一条结论已被后来的实测推翻"的留痕。
被推翻的结论**不删除**，而是原地标注更正并保留证据链——因为"当时为什么判断错了"
本身就是可追溯性的一部分。贡献方式、实测证据要求与提交规范见 [`../CONTRIBUTING.md`](../CONTRIBUTING.md)。

> **置信度统一标识**（全仓库一致）：**【已核实】** = 本机实测或直读一手源码/固件 ·
> **【社区报告】** = 论坛 / 邮件列表 / 第三方他人实测 · **【推测】** = 本项目推断，尚未验证。
> 详细的写作规范见 [`style-guide.md`](style-guide.md)，术语释义见 [`glossary.md`](glossary.md)。

---

## 1. 阅读顺序建议

第一次接触本项目，建议按下列顺序读（前一篇的结论是后一篇的前提）：

| 顺序 | 读什么 | 目的 |
|:---:|---|---|
| 0 | [`../README.md`](../README.md) §1–§2、[`../CONTRIBUTING.md`](../CONTRIBUTING.md) | 先确认**自己手里的机器是不是目标机型**（2022 LTE 版与 2023 版不支持） |
| 1 | [`../scripts/00-preflight.sh`](../scripts/00-preflight.sh)（前检，只读） | 用设备树 `compatible` + 大核最高频率 + 面板/触屏枚举三条判据判定变体 |
| 2 | [`install-dualboot.md`](install-dualboot.md) | 在保留出厂 Windows 的前提下把 Ubuntu 装进内置盘 |
| 3 | [`touch-idle-policy.md`](touch-idle-policy.md) + [`releases/`](releases/) | 触屏为什么必须走 SPI、空闲中断治理、以及各版内核的差异 |
| 4 | 显示相关：`kernel-7.2.5-el1-build.md` §4/§6（DSC/面板补丁与 `DRM_PANEL_HIMAX_HX83121A`） | 内屏与背光是怎么被带起来的 |
| 5 | [`video-decode.md`](video-decode.md) → [`software-video-decode.md`](software-video-decode.md) | 硬解走 venus（EL1）；软解保底方案与播放器配置 |
| 6 | [`audio.md`](audio.md) | 声音为什么"不像四扬声器"、能改到什么程度、以及不能再改的红线 |
| 7 | [`fingerprint.md`](fingerprint.md) | 指纹为什么在 Linux 上不可行（可复现的负结论） |

只想复现内核的读者，直接读 [`kernel-7.2.5-el1-build.md`](kernel-7.2.5-el1-build.md)（含命名规范 §0、配方 §3、门禁 §5、配置表 §6）。

---

## 2. 文档索引

**状态口径**：`已实机核实` = 主要结论在本机验证过 · `部分核实` = 部分实证、部分推断，或结论已被更新的文档部分推翻 ·
`历史归档` = 已被取代但按可追溯原则保留 · `规划中` = 尚未成文。

**最后核实日期**只填该文件内**确实写着**的日期（发布日、"实机验证（YYYY-MM-DD）"等）；文件内没有日期的填 `—`，
不作推测。

### 2.1 安装与系统

| 文档 | 职责 | 状态 | 最后核实日期 |
|---|---|---|---|
| [`install-dualboot.md`](install-dualboot.md) | 内置盘 Windows + Ubuntu 双系统的分区级 `dd` 安装流程、UUID 校验、扩容与踩坑记录 | 已实机核实 | — |
| [`software-video-decode.md`](software-video-decode.md) | 无可用 VPU 时的软件解码路线、播放器/浏览器配置与实测性能量级 | 部分核实 | 2026-09-13 |

> `software-video-decode.md` 的前置假设（"本机 IRIS VPU 尚未打通、无 `/dev/video*`"）已被
> EL1 + venus 的实测取代；文中的软解配置与实测数据仍然有效，**作为保底方案阅读**。

### 2.2 触屏

| 文档 | 职责 | 状态 | 最后核实日期 |
|---|---|---|---|
| [`touch-idle-policy.md`](touch-idle-policy.md) | 触屏"幽灵中断"的量化、根因、`himax_lock/unlock` 缺陷、r3 中断门控采样空闲策略与 AFE 邮箱实测 | 已实机核实 | 2026-09-13 |
| [`bench/touch-bench-20260913.md`](bench/touch-bench-20260913.md) | 触屏基准的**原始 JSON 与 `/proc/interrupts` 增量**（r0 FIFO vs r1 GSI），另含测量口径的两处相反偏差说明 | 已实机核实 | 2026-09-13 |

### 2.3 音频

| 文档 | 职责 | 状态 | 最后核实日期 |
|---|---|---|---|
| [`audio.md`](audio.md) | 音质"不像四扬声器"的三层归因、量化余量、gaokun3 专用 UCM profile 的处置方案与不可越过的安全红线 | 已实机核实 | 2026-09-13 |

### 2.4 视频 / VPU

| 文档 | 职责 | 状态 | 最后核实日期 |
|---|---|---|---|
| [`video-decode.md`](video-decode.md) | 视频硬解归因；**开头即为 2026-09-13 更正**：硬解在 EL1 + venus 下可用，EL2 下不可用，下方原结论保留作历史 | 部分核实 | 2026-09-13 |
| [`build-kernel-iris.md`](build-kernel-iris.md) | 用 `CONFIG_VIDEO_QCOM_IRIS` 替代 venus 构建内核的配方（基线 `v7.2-rc2`、不写 ESP、可安全回退） | 部分核实 | 2026-09-13 |

> `build-kernel-iris.md` 的构建流程本身已实机跑通，但**其目标（IRIS 路线）已被 EL1 + venus 取代**；
> 保留价值在于"如何把 v7.3-rc1 的视频节点前置到旧基线"这一手法与门禁命令。

### 2.5 指纹与安全

| 文档 | 职责 | 状态 | 最后核实日期 |
|---|---|---|---|
| [`fingerprint.md`](fingerprint.md) | FocalTech FTE7001 的硬件身份与总线归属取证，以及"为什么 Linux 拿不到这条 SPI"的证据链与能力边界 | 部分核实 | — |

> 文中 §9 明确标注了未解问题（`\_SB.SPBA` 的 `_HID`/`_CRS`、`gpio185` 语义等仍**未证实**），
> 故整篇按 `部分核实` 归档；其**主结论（非安全世界拿不到该总线）为【已核实】**。

### 2.6 内核构建与发布

| 文档 | 职责 | 状态 | 最后核实日期 |
|---|---|---|---|
| [`kernel-7.2.5-el1-build.md`](kernel-7.2.5-el1-build.md) | 自研内核的完整配方：命名规范（§0）、构建宿主、补丁集、必须钉死的 `CONFIG_VIDEO_QCOM_IRIS=n` 陷阱、defconfig 门禁、产物与逐版修订记录 | 已实机核实 | 2026-09-13 |

### 2.7 Releases（`docs/releases/`）

每个文件与同名 git tag / GitHub Release 逐一对应，命名规范见 `kernel-7.2.5-el1-build.md` §0.1。

| 文档 | tag | 标题 | 状态 | 发布日期 |
|---|---|---|---|---|
| [`releases/kernel-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2-20260913.md`](releases/kernel-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2-20260913.md) | `kernel-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2-20260913` | `[内核] 7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+`（旧命名，追溯记 r0） | 历史归档 | 2026-09-13 |
| [`releases/kernel-7.2.5-aoripus-ml-gaokun-eog-el1-20260913.md`](releases/kernel-7.2.5-aoripus-ml-gaokun-eog-el1-20260913.md) | `kernel-7.2.5-aoripus-ml-gaokun-eog-el1-20260913` | `Kernel 7.2.5 (EL1) — 7.2.5-aoripus-ml-gaokun-eog-el1+`（旧命名，追溯记 r0） | 历史归档 | 2026-09-13 |
| [`releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913.md`](releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913.md) | `kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913` | `Kernel 7.2.5 (EL1) VENUS r1` | 已实机核实 | 2026-09-13 |
| [`releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3-20260913.md`](releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3-20260913.md) | `kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3-20260913` | `Kernel 7.2.5 (EL1) VENUS r3` | 已实机核实 | 2026-09-13 |
| [`releases/v0.1.0.md`](releases/v0.1.0.md) | `v0.1.0` | `[工具] v0.1.0`（旧标题前缀，已废除） | 历史归档 | 2026-09-13 |

> 这三篇用**已废除的旧命名 / 旧标题前缀**，按"不改写历史"的原则原样保留；
> 它们记录的产物本身仍可安装、可回滚，只是已被 r1 / r3 取代，**不推荐新装**。
> 现行命名规范见 `kernel-7.2.5-el1-build.md` §0.1 与 [`../README.md`](../README.md) §7。
> r1 与 r3 的发布说明**原地更新过**（`gh release edit --notes-file`，tag 与标题未动），
> 因此其正文不完全是首次发布时的那一份。

### 2.8 GPU 遥测

| 文档 | 职责 | 状态 | 最后核实日期 |
|---|---|---|---|
| [`gpu-telemetry.md`](gpu-telemetry.md) | 系统监视器（Resources）GPU 页"全部不可用"的根因（应用侧接口契约 + msm 缺失的节点）、自研 msm 遥测补丁、实测取值，以及**为什么功耗项永远只能是 N/A** | 已实机核实 | 2026-09-14 |

### 2.9 历史取证归档（保留以便追溯）

以下文档记录的是**已被后续实测取代的结论链**，或**外部二进制的逆向取证**。
它们**不是当前技术路线**，但提供了第一手证据与可复核的方法；引用其结论前请先看 `video-decode.md` 开头的更正块。

| 文档 | 职责 | 状态 | 最后核实日期 |
|---|---|---|---|
| [`iris-windows-ved-register-trace.md`](iris-windows-ved-register-trace.md) | 从 Windows `qcdxkm8280.sys` 反汇编还原 IRIS/Venus 视频核 `Ved*` 上电寄存器写序列（逐站点地址与常量） | 历史归档 | — |
| [`windows-video-tz-interface.md`](windows-video-tz-interface.md) | 同一驱动的 TrustZone 接口逆向（TZ ABI、`TZ_MEM_PROTECT_VIDEO_VAR` 调用点、QTEE 通路源码级否决） | 历史归档 | — |

> 归档理由：两篇的技术取证（反汇编结论、置信度表）本身是【已核实】的，
> 但其**应用前景**已被 `video-decode.md` 开头的 2026-09-13 更正取代 ——
> 硬解的正确路线是 **EL1 + venus**，不需要复刻 Windows 的 QTEE/TZ 通路。
> 保留它们是为了：① 留下"为什么 Linux 侧走不通 TZ 路线"的完整证据；
> ② 提供 VED 寄存器级参考资料；③ 记录反汇编方法论。

### 2.10 Windows 11 可行性报告（`easy-for-gaokun-win` 立项前评估）

面向**新立项**的 `easy-for-gaokun-win`（把出厂 Windows 11 做成"最适合这台机器"的版本）的调研交付物。
**只回答"能不能做、代价多大、风险在哪"，不含实现**；结论里的目标机相关项一律标【未核实】。

| 文档 | 职责 | 状态 | 最后核实日期 |
|---|---|---|---|
| [`win11-feasibility.md`](win11-feasibility.md) | **主报告**：原厂转储的一手事实（含 ICB 取证与架构量化）、四个工作包（(a) x64→ARM64 · (b) 自研管家 · (c) 调度省电 · (d) WSL2+Android）的可行性读数、发布红线与**抹盘前置条件** | 已实机核实（转储取证） | 2026-09-15 |
| [`win11-oem-customization.md`](win11-oem-customization.md) | (a) 原厂基线解剖：ICB 挂载取证、**13 个预装应用与逐组件架构量化**、首次开机流程逐条解析、驱动注入链与驱动覆盖清单、**备份完整性核对**、分区蓝图 | 已实机核实 | 2026-09-15 |
| [`win11-manager-app.md`](win11-manager-app.md) | (b) 自研"管家"APP 的接口边界：标准 API 能力矩阵、厂商 WMI 通路与硬约束、否定结论、法律与分发风险、技术栈建议 | 部分核实（目标机待验证） | 2026-09-15 |
| [`win11-power-tuning.md`](win11-power-tuning.md) | (c) 调度/省电：测量方法（`sleepstudy` 等）、两处社区通行说法的更正、旋钮表与 T0–T4 分级建议、风险与恢复 | 部分核实（目标机待验证） | 2026-09-15 |
| [`win11-wsl-android.md`](win11-wsl-android.md) | (d) WSL2 与 Android：WSL2 ARM64 可用性与自动化、**GPU 加速现状的完整证据链**、被连坐否决的一类方案、三条 Android 路线对比 | 部分核实（目标机待验证） | 2026-09-15 |

> 标注"部分核实"的三篇：**事实与官方文档/上游 issue 已核实，但目标机（GK-W76）上的行为尚未实测**
> （调研取证跑在另一台 x64 机器上）；每篇文末都附了"待真机核实清单"。

---

## 3. 其它文档位置

| 路径 | 内容 | 状态 |
|---|---|---|
| [`adr/`](adr/) | 架构决策记录（ADR，回溯 EL1/触屏/空闲策略/命名等关键决策） | 待创建 |
| [`rfc/`](rfc/) | 提案（RFC，含仓库标准化提案） | 待创建 |
| [`releasing.md`](releasing.md) | 发布流程（tag、asset、release notes 与 `r` 裁决规则） | 待创建 |
| [`releases/TEMPLATE.md`](releases/TEMPLATE.md) | 发布说明模板 | 待创建 |
| [`../patches/README.md`](../patches/README.md) | 补丁序列索引与元数据规范 | 待创建 |
| [`../tools/`](../tools/) 与 [`../scripts/`](../scripts/) 下的 `README.md` | 工具与脚本的用法 | — |

> 上表标 `待创建` 的条目（`adr/`、`rfc/`、`releasing.md`、`releases/TEMPLATE.md`、`../patches/README.md`）
> 目前尚未入库。在它们真正入库之前，对应的决策与流程先看 [`../AGENTS.md`](../AGENTS.md) 与
> [`../CHANGELOG.md`](../CHANGELOG.md)；本索引给出的相对链接在文件创建后即自动生效，无需再改本页。

---

## 4. 维护这份索引

- **新增文档**：在对应主题小节加一行，并填上职责、状态与文件内可查到的日期。
- **结论被推翻**：不要删除文档，也不要只改结论 —— 在**文档开头**加更正块，并把本索引的状态改为
  `部分核实` 或 `历史归档`，同时在"历史取证归档"小节说明归档理由。
- **每篇文档都必须能被本页链接到**；禁止出现"孤儿文档"。
- 写作规范（置信度标注、可复现性、表格优先、行尾 LF 等）见 [`style-guide.md`](style-guide.md)。
