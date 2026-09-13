# 术语表

> 本表只收录**在本仓库文档里出现过、且有明确含义**的术语；释义逐条取自文末所列的仓库内文档，
> **不作外推、不引入仓库未记录的含义**。
> 若某个术语在仓库中只有一处出处，出处即该文档的相应小节。
> 置信度标识沿用全仓库口径（见 [`style-guide.md`](style-guide.md) §2）。

## 1. 设备与平台

| 英文 / 标识符 | 中文 | 一句话解释 | 出处 |
|---|---|---|---|
| `gaokun3` | 设备树代号 | 本项目唯一支持机型的设备树代号（`compatible` 含 `huawei,gaokun3`）；`gaokun2` 是 8cx Gen 2 / SC8180X 的另一机型，**极易混淆**，因此内核串里必须写 `gaokun3` 而不是 `gaokun` | [`../README.md`](../README.md) §1 · [`kernel-7.2.5-el1-build.md`](kernel-7.2.5-el1-build.md) §0.1 |
| `GK-W76` | 市场型号 | 目标机的市场型号字符串；**不能单独作为判据** —— 本机 DMI 实际报 `GK-W7X`/`GK-W7X-PCB`，且电商页面存在把 2023 版标成 `GK-W76` 的情况，必须用设备树 `compatible` 与大核最高频率判定 | [`../CONTRIBUTING.md`](../CONTRIBUTING.md) §目标设备 · [`../README.md`](../README.md) §1 |
| `SC8280XP` | 高通骁龙 8cx Gen 3 平台 | 目标机 SoC（Snapdragon 8cx Gen 3）；2022 LTE 版是 SC8180X（8cx Gen 2），两者设备树与补丁完全不通用 | [`../README.md`](../README.md) §1 · [`../CONTRIBUTING.md`](../CONTRIBUTING.md) §目标设备 |
| `HX83121A` | Himax 触屏控制器 | 本机触屏的级联 IC 型号，挂在 SPI 上（`spi0.0`）；它向哪个主机接口上报数据由 `TLMM gpio174` 决定 | [`../README.md`](../README.md) §2.1 · [`touch-idle-policy.md`](touch-idle-policy.md) §2 |

## 2. 引导与执行级别

| 英文 / 标识符 | 中文 | 一句话解释 | 出处 |
|---|---|---|---|
| `slbounce` | Secure Launch 引导驱动 | systemd-boot 的 EFI driver，**按设备树嗅探自行决定留在 EL1 还是切到 EL2**；因此切级别只需换 BLS 条目里的 `devicetree`，**切勿**靠移除 EFI driver 来"回退到 EL1"（会破坏引导链导致黑屏挂死） | [`video-decode.md`](video-decode.md) 开头更正块 · [`releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913.md`](releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913.md) §5 |
| `qebspil` | DSP 预启动 EFI driver | 另一个 systemd-boot EFI driver，用于在 EL2 下**预启动 DSP**（音频等 DSP / remoteproc 相关功能依赖它）；与 `slbounce` 同为引导链的一部分，不可随手移除 | [`kernel-7.2.5-el1-build.md`](kernel-7.2.5-el1-build.md) §1 · [`audio.md`](audio.md) §5 |
| `EL1` / `EL2` | ARM64 异常级别 | CPU 的执行级别（Exception Level）。本项目实测：**EL1 下 venus 视频硬解可用、但没有 `/dev/kvm`**；**EL2 下 venus/iris 均 probe 失败于 `-22`，但保留 KVM** —— 即"硬解与 KVM 目前互斥" | [`video-decode.md`](video-decode.md) 开头更正块 · [`kernel-7.2.5-el1-build.md`](kernel-7.2.5-el1-build.md) §1 |
| `BLS`（systemd-boot 条目） | 引导加载规范条目 | systemd-boot 的 Boot Loader Specification 条目，位于 `$ESP/loader/entries/<machine-id>-<KVER>[-<TAG>].conf`；EL1/EL2 的差别就是条目里 `devicetree =` 指向哪一个 DTB。本项目安装内核**只新增 BLS 条目**，不动 `loader.conf` 默认项与 EFI 变量 | [`video-decode.md`](video-decode.md) 开头更正块 · [`kernel-7.2.5-el1-build.md`](kernel-7.2.5-el1-build.md) §9.1 |
| `ESP` | EFI 系统分区 | FAT32 的 EFI System Partition，存放引导加载器、内核/initrd/DTB 与 BLS 条目；本项目推荐**独立 ESP**（完全不碰 Windows 引导文件，风险最低），并在镜像基础上把 DTB 预编译进去 | [`install-dualboot.md`](install-dualboot.md) §0/§7 · [`../CONTRIBUTING.md`](../CONTRIBUTING.md) §安全约束 |
| `DTB` / `DTS` | 设备树二进制 / 设备树源 | 本机以**设备树启动**而非 ACPI（`/sys/firmware/acpi/` 不存在）；`DTS` 是源文件（如 `sc8280xp-huawei-gaokun3.dts`），`DTB` 是其编译产物，由 `/etc/kernel/devicetree` 显式指定给引导链 | [`fingerprint.md`](fingerprint.md) §2.1 · [`kernel-7.2.5-el1-build.md`](kernel-7.2.5-el1-build.md) §0.1 |

## 3. 视频 / VPU

| 英文 / 标识符 | 中文 | 一句话解释 | 出处 |
|---|---|---|---|
| `venus` | Qualcomm Venus 视频编解码驱动 | 上游 `qcom-venus` 驱动，本机**在 EL1 下**可正常工作（出现 `qcom-venus-decoder`，支持 H264 / VP8 / VP9 / HEVC / MPEG-2）；节点号每次开机可能互换，**不得硬编码** | [`video-decode.md`](video-decode.md) 开头更正块 |
| `iris` | Qualcomm IRIS 视频编解码驱动 | 与 venus **互斥**的另一条 VPU 驱动线（`CONFIG_VIDEO_QCOM_IRIS`）：venus 的 IRIS2 / HFI-6XX 支持被 `#if (!IS_ENABLED(CONFIG_VIDEO_QCOM_IRIS))` 包住，一旦启用 iris，venus 相应支持会被整体编译掉且**无任何编译错误** | [`video-decode.md`](video-decode.md) §3.3 · [`kernel-7.2.5-el1-build.md`](kernel-7.2.5-el1-build.md) §5 |
| `-22`（`-EINVAL`） | 固件初始化失败返回值 | venus/iris 的 VPU 固件在 **EL2** 下 probe 失败的报错（`error -22 initializing firmware`）；它是 `venus_boot()` 把任何失败**无条件改写**成的返回值，**不表示固件文件有问题** | [`video-decode.md`](video-decode.md) §2/§3.4 |

## 4. SPI 与中断

| 英文 / 标识符 | 中文 | 一句话解释 | 出处 |
|---|---|---|---|
| `GSI`（Generic Software Interface） | 通用软件接口模式 | QUP-SPI 的 DMA 工作模式：传输完成由 **GPI DMA 控制器**报告中断，GENI SE 中断恒为 0。本项目用 `qcom,force-gsi-mode` 属性强制启用，使触屏每帧 IRQ 从 15.39 降到 3.558 | [`releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913.md`](releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913.md) §2.1/§2.2 · [`bench/touch-bench-20260913.md`](bench/touch-bench-20260913.md) §3 |
| `GPI DMA` | Generic Packet Interface DMA | 与 GSI 模式配套的 DMA 控制器（`gpi-dma` 中断线）；实测负载下 DMA 中断数约为触屏 IC 中断数的 **2.0 倍**（一次传输一对 TX/RX 完成中断） | [`bench/touch-bench-20260913.md`](bench/touch-bench-20260913.md) §3 |
| `FIFO`（SPI 模式） | 先进先出（逐传输）模式 | QUP-SPI 不使用 GSI 时的回退模式，**逐传输中断**；本机的表现是 `998000.spi`（GENI SE）中断随每次 SPI 读增长，每帧触屏中断偏高。r0 内核即此模式 | [`releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913.md`](releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913.md) §2.1 · [`kernel-7.2.5-el1-build.md`](kernel-7.2.5-el1-build.md) §7 |
| `ghost interrupt` | 幽灵中断 | 空闲（面板点亮、无人触摸）时触屏 IRQ 仍以约 **119–120 Hz**、每帧一次触发，却不产生任何输入事件的现象；根因是 **IC 只当传感器、触控判定全部在主机**，因此必须每帧上报 —— 属架构必然，不是固件配错 | [`touch-idle-policy.md`](touch-idle-policy.md) §1/§2 · [`bench/touch-bench-20260913.md`](bench/touch-bench-20260913.md) §4 |

## 5. 触屏 IC 内部接口

| 英文 / 标识符 | 中文 | 一句话解释 | 出处 |
|---|---|---|---|
| `AFE`（Himax 邮箱） | Himax 芯片侧命令邮箱 | Himax IC 的命令邮箱通道（16 B 包：魔数 `a8 8a` + cmd + val + 校验和，5 个 slot 轮转）。实测语义：`0x0A/0x00`（EnterIdle）会让 IC **真的停扫**（帧全 0），`0x0E/0x00`（ForceToScanRate）是**真唤醒**；协议**没有 ack**（16 B 回读被公开实现直接丢弃） | [`touch-idle-policy.md`](touch-idle-policy.md) §4 · [`releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3-20260913.md`](releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3-20260913.md) §2.2 |
| `interrupt-gated sampling` | 中断门控采样 | r3 的空闲策略：连续 **7200 帧（≈60 s @120 Hz）**无已上报触点后 `disable_irq()`，随后每 **30 ms** 只放行一帧走正常中断路径判断有无触点，检出即恢复中断模式。实测空闲 IRQ 120 Hz → 22.9 Hz、kthread CPU 2.00% → 0.50% | [`touch-idle-policy.md`](touch-idle-policy.md) §5 · [`releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3-20260913.md`](releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3-20260913.md) §1 |

## 6. 音频

| 英文 / 标识符 | 中文 | 一句话解释 | 出处 |
|---|---|---|---|
| `UCM`（Use Case Manager） | ALSA 用例管理器 | ALSA 的用户态音频配置（`alsa-ucm-conf`），决定各控件初值。本机原本跑的是**为双扬声器 ThinkPad X13s 写的** profile；本项目产出 gaokun3 专用 profile，只把 `SpkrLeft/Right PA Volume` 由 `12`（−3.00 dB）提到内核限幅上限 `17`（0.00 dB） | [`audio.md`](audio.md) §0/§5.2 · [`releases/v0.1.0.md`](releases/v0.1.0.md) |

## 7. 内核版本与构建

| 英文 / 标识符 | 中文 | 一句话解释 | 出处 |
|---|---|---|---|
| `LOCALVERSION` | 内核本地版本串 | `CONFIG_LOCALVERSION`，本项目把命名规范里除上游版本外的全部字段（`-aoripus-ml-gaokun3-eog-el1-venus-r<n>`）都放进它；它决定机器侧所有落点名（`/lib/modules/`、`/boot/*-<串>`、BLS 条目名、ESP 目录名） | [`kernel-7.2.5-el1-build.md`](kernel-7.2.5-el1-build.md) §0.1–§0.3 |
| `r<n>` | 内核修订号 | 内核串末位的修订号（自 `r1` 起）。作用域 = **同一上游版本 + 同一级别 + 同一 VPU 驱动**；只有**产物语义变化**（补丁 / DTB / `.config`）才 `r+1`，只改说明或重传资产不改串也不改 r，上游升级则 r 归零重排 | [`kernel-7.2.5-el1-build.md`](kernel-7.2.5-el1-build.md) §0.1 · [`../README.md`](../README.md) §7 |
| `preflight` | 前检 | 运行 `scripts/00-preflight.sh`（**只读脚本**）校验设备树 `compatible`、大核最高频率（目标机 `2995200` kHz）与面板/触屏枚举，用于排除 2022 LTE 版（8cx Gen 2 / `gaokun2`）与 2023 降频版 | [`releases/v0.1.0.md`](releases/v0.1.0.md) §设备鉴别与前检 · [`../CONTRIBUTING.md`](../CONTRIBUTING.md) §目标设备 |

---

## 相关文档

- 文档索引与各篇状态：[`README.md`](README.md)
- 写作规范（置信度、可复现性、命名与行尾）：[`style-guide.md`](style-guide.md)
- 贡献流程与实机证据要求：[`../CONTRIBUTING.md`](../CONTRIBUTING.md)
