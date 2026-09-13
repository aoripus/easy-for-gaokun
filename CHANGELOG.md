# 更新日志

本文件记录 easy-for-gaokun 的所有重要变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> **关于内核产物**：本项目的**二进制内核构建**使用独立的标签与 Release，
> 命名形如 `kernel-<完整内核串>-<YYYYMMDD>`（`<完整内核串>` 即 `uname -r`，
> 例 `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1`），与源码版本号解耦；
> Release **标题**形如 `Kernel <上游> (<级别>) <VPU大写>[ r<n>]`
> （例 `Kernel 7.2.5 (EL1) VENUS r1`），源码里程碑仍用 `vX.Y.Z` 的 tag、标题不再加类别前缀。
> 完整字段定义、派生落点与 `r<n>` 裁决规则见
> [README 的「构建产物与发布」](README.md#7-构建产物与发布) 一节。

## [未发布]

### 修复

- **触屏：`himax_lock()`/`himax_unlock()` 中断使能不对称，任何 sysfs 访问都会"打死"触屏中断。**
  `himax_lock()` 走 `himax_quiesce_irq()`（`disable_irq_nosync()` + `synchronize_irq()`），
  而 `himax_unlock()` **只 `mutex_unlock()`、从不 `enable_irq()`** ⇒ 一次 `inplace_reset`/`afe_cmd`/`algo/*`
  写入就会把触屏中断永久屏蔽，直到下一次完整重初始化（面板 prepared→enabled 之后的
  `himax_hw_reinit()` 会把它重新打开，所以日常使用不易察觉）。该缺陷继承自社区驱动，
  **r0 / r1 / r2 三个已发布内核都带**。修复方式：进入时保存中断使能状态，
  退出时按 `irq_resume && panel_enabled && !idle_active && !shutting_down` 恢复。
  这个缺陷曾把"写 sysfs"误判成"AFE 命令让 IC 停流"，污染了两轮空闲模式实验，
  详见 [`docs/touch-idle-policy.md`](docs/touch-idle-policy.md) §3。

### 新增

- **触屏空闲策略（"幽灵中断"治理）：中断门控采样。** 空闲时 HX83121A 每帧都上报（**120 Hz、单核 1.8–2.0% CPU**），
  根因是本驱动里 **IC 只当传感器、触控判定全部在主机**，IC 无法知道"有没有手指"。
  r3 的做法：连续 `idle_enter_frames`（**默认 7200 帧 ≈ 60 s @120 Hz**）无**已上报**触点后 `disable_irq()`，
  之后每 `idle_poll_ms`（默认 30 ms）**只放行一帧**走正常中断路径判断有无触点，有触点立刻恢复中断模式。
  实测 **120.0 Hz → 22.9 Hz、单核 CPU 2.00% → 0.50%**，且**不需要**任何 AFE 命令、**不需要**芯片重初始化
  （屏蔽中断不影响 IC 扫描，解除屏蔽也不会 storm）。**默认启用**，`idle_enter_frames=0` 可关闭。
  两处实测教训：① 空闲阈值最初设 240 帧（≈2 s），实机**不跟手**（正常停顿即进空闲），故定为 60 s；
  ② 计时器复位**必须用"已上报触点"（`touch_active`）而非原始稳定触点数** —— 用后者时 60 s 阈值
  **永远到不了**（实测 111 s 内 7200 帧都没累积满，偶发单帧噪声不断清零计时）。
  实测数据、AFE 邮箱语义（`0x0a` 真停扫、`0x0e` 真唤醒、`0x01` 无效、协议无 ack）、
  "work 里直接读帧会读到撕裂帧并误判触点"的失败记录，见
  [`docs/touch-idle-policy.md`](docs/touch-idle-policy.md)。
- **内核产物 `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3`**：本项目的第三个 EL1 内核，
  相对 `r1` 增加上述中断缺陷修复与空闲策略，并补上 AFE 邮箱队列初始化与诊断节点
  （`frame`/`idle_state`/`irq_gate`/`regs`）。
  发布说明见 [`docs/releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3-20260913.md`](docs/releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3-20260913.md)。
  （内部构建 `r2` **未发布**：它的空闲策略建立在"AFE `0x0A` 让 IC 停流"这一**测量假象**上，
  修掉 `himax_lock` 缺陷后该结论被推翻。）
- **`patches/touch-idle/`**：驱动增量补丁（+481 / −92 行，22 个 hunk）与说明，
  基线是 r1/r2 出厂驱动（社区驱动 + AFE 传输层），可用 `git apply` / `patch -p1` 落到内核树。
- **`docs/touch-idle-policy.md`**：触屏空闲中断治理笔记（现象量化、架构根因、AFE 语义实测表、
  r3 策略与收益、未采纳方案、诊断节点用法、上游化建议）。

### 变更

- **内核产物命名规范定稿（自 `r1` 起生效）。** 内核串改为
  `<上游>-aoripus-ml-gaokun3-eog-<级别>-<VPU驱动>-r<n>`（例
  `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1`），Release tag 统一为
  `kernel-<完整内核串>-<YYYYMMDD>`，Release 标题为
  `Kernel <上游> (<级别>) <VPU大写>[ r<n>]`。相对旧串新增 `gaokun3`、级别、VPU 驱动与 `r<n>`
  四个字段 —— `gaokun` 改为 `gaokun3` 是因为 `gaokun2` 是 8cx Gen 2（SC8180X），极易混淆。
  两处语义澄清：`ml` 明确指 kernel.org **stable** 树；`venus`/`iris` 是
  **VPU（视频编解码单元）驱动，不是 GPU 驱动**（GPU 是 Adreno 690 / freedreno / Turnip）。
  字段定义、机器侧派生与 `r<n>` 裁决规则见
  [README 的「构建产物与发布」](README.md#7-构建产物与发布)。
- **内核串尾部的 `+`：两个条件缺一不可（实测更正）。** 只关掉 `CONFIG_LOCALVERSION_AUTO`
  **并不能**去掉 `+` —— 内核串由 `scripts/setlocalversion`（`Makefile` 的
  `filechk_kernel.release`）生成，当源码树是一个 git 仓库、且 HEAD 不在名为
  `v$(KERNELVERSION)` 的附注 tag 上时，它在 `AUTO≠y` 的分支里照样打印 `+`。
  VM 实测对照（两种情况 `.config` 都已是 `# CONFIG_LOCALVERSION_AUTO is not set`）：
  `.git` 在场 → `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1+`；`.git` 移开 → `…-venus-r1`。
  因此除 `# CONFIG_LOCALVERSION_AUTO is not set` 之外，**生成内核串时源码树不得带 git 元数据**
  —— 即发行版的标准做法：从 tarball 解包、不带 `.git` 构建；本项目在 `make` 前把 `.git` 移开、
  编完再移回。否则同一份逻辑源码会派生出两个不同的 `/lib/modules/<串>/`、initrd 名与
  systemd-boot 条目名。构建脚本已内建两道断言：配置阶段查 `.config`，编译后查
  `include/config/kernel.release` 不含 `+`。
- **日期不再进入内核串。** 内核串决定机器侧全部落点名（模块目录、`/boot/*-<串>`、BLS 条目名、
  ESP 目录名），日期只出现在 Release tag 里；否则每天都会产生一个新模块目录。
- **历史两次内核构建（IRIS EL2、VENUS EL1）的 tag 与内核串保持不变**，按新规范追溯记为 `r0`。

### 修复

- **构建：EL2 补丁组被整组丢弃。** `git apply` 一次传多个补丁是原子操作，只要有一个失败就
  一个都不应用，而原脚本在失败后仍继续编译。缺失该组补丁的产物在真机上表现为 adsp / cdsp /
  slpi / venus 固件加载全部报 `-22`，**音频与视频同时失效**。构建脚本改为逐个应用、统计失败
  数，失败过多直接中止，并在编译后校验关键标记。
- **构建：`patches/el2/*` 与 v7.2-rc2 不适配。** 该组补丁发布于 2025-07，其中 `0006`（引入
  `enum rproc_auto_boot` 的那个补丁）撞上上游后加的代码，依赖该枚举的 `0010`、`0016` 因此
  级联失败，`0011` 则是 `scm.h` 上下文漂移。适配版见 `patches/el2-v7.2/`。
- **产物：设备树缺少触屏的 `gpio174` 修复。** 此前只有装机脚本会在 ESP 上现打补丁，发布出去
  的 DTB 本身不含该修复，按发布说明直接使用会导致触屏失效。构建流程现已在 base DTS 上应用该
  补丁，并在编译后断言两个 DTB 同时含 `gpio174` 与 IRIS 节点、不含旧 venus 兼容串。
- **产物：模块包漏收 `modules.builtin.modinfo`。** 导致设备上 `depmod` 与 `initramfs` 各报
  一条警告，并影响内置模块的固件查找与 `modinfo`。

### 新增

- `patches/iris-el2/`：IRIS 视频驱动在 EL2 下的适配 —— 分配 `qcom_scm_pas_context` 并置
  `use_tzmem`，改用 `qcom_scm_pas_prepare_and_auth_reset()`，让 SHM bridge 由 Linux 自己
  建立。应用后固件认证与解复位均通过，失败点推进到 `qcom_scm_mem_protect_video_var`（`-5`）。
- `tools/build-iris-x86.sh`、`tools/mk-release.sh`：构建与打包脚本纳入仓库，使
  `BUILD-PROVENANCE.md` 声明的"可由本仓库脚本复现"成立。
- `patches/spi-gsi/`：引入 **Pengyu Luo** 的 v1 两条补丁（`qcom,force-gsi-mode` 的
  binding + driver），让触屏 QUP-SPI 走 **GSI（DMA）模式**。本机 DTS 早已写有该属性，
  但 v7.2.5 的驱动不读它、binding 里也没有，此前一直静默退回 FIFO 模式。选 v1 而非 v2 的
  原因：**v2 已被作者本人撤回**（2026-07-14，「keep using the fifo_disabled variable」）。
  **滑动实测**：每帧触屏 IRQ **15.39 → 3.558（−77%）**、CPU 忙 **14.97% → 5.56%（−63%）**、
  帧间隔 p99 **32.8 → 10.27 ms（−69%）**，报点率与中位帧间隔持平；
  空闲窗口 GENI SE 中断 `998000.spi` 由 **+6,206 降为 0**，改由 `gpi-dma` 完成
  （约 2 次 DMA 中断/次触屏中断），且**滑动全程 SE 中断恒为 0**。
  （早期曾据空闲数据误判"GSI 不影响每帧 IRQ"，已被滑动实测推翻并更正。）
- 内核产物 **`7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1`**：首个按新命名规范发布的 EL1 内核，
  串尾**无 `+`**（构建时移开 `.git`），已实机验证 venus 硬解与触屏均正常。
  发布说明见 [`docs/releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913.md`](docs/releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913.md)。

### 已知问题

- **视频硬解：本机尚未打通；此前"EL2 下不可修复"的判断已被推翻。** 失败表现为
  `iris_vpu_boot_firmware()` 返回 `-62`（ETIME）：`CTRL_STATUS` 轮询 1000 次恒为 `0`。
  2026-09-13 做了第二轮的**逐寄存器**验证，把"缺陷在驱动/设备树/固件选择"的可能性全部排除：

  | 变量 | 实测 | 结论 |
  |---|---|---|
  | 供电 | `mvs0c_gdsc` / `mvs0_gdsc` 均 `PWR_STATE=1`、`SW_COLLAPSE=0` | 正常 |
  | 时钟 | `video_cc_mvs0c_clk` 840 MHz、`video_cc_mvs0_clk` 560 MHz，`hardware_enable=Y` | 正常 |
  | 复位 | 两个 CBCR 的 ARES 位均为 `0`；`GCC_VIDEO_AXI0_CLK_ARES` 亦为 `0` | 正常 |
  | 固件 | 保留区 `0x86700000` 读出合法镜像头 | 正常（由 Linux 的 `qcom_mdt_load` 写入） |
  | 核心是否执行 | `CTRL_STATUS=0`、`WRAPPER_TZ_CPU_STATUS` 的 WFI 位 `=0`，持续 90 s | **不执行** |

  在 90 秒上电窗口内穷举了全部可写路径（`CTRL_INIT`、NOC LPI、TZ 时钟 halt、桥复位、
  TZ FIFO 复位、两次 GDSC 掉电/上电、`CPU_CS_X2RPMH` 的 `MSK_CORE_POWER_ON`——已回读确认
  可写），**`CTRL_STATUS` 始终为 0**。

  根因是上游 EL2 补丁集作者已明确记录的缺陷：*"It's possible to authenticate and start new
  firmware, but the remoteproc is never actually brought out of reset... all the PAS related
  calls still succeed"* —— 所有 PAS 调用都返回成功，但子系统永不真正脱离复位。DSP 靠
  `qcom,broken-reset` 跳过复位、attach 开机时已运行的实例绕过；**视频核没有 attach 可言，
  必须由 Linux 亲自启动**，因此无从绕过。

  设备树侧已无改进空间：本项目的 iris 节点与上游 v7 系列（2026-05）**逐属性一致**
  （含 `iommus = <&apps_smmu 0x2a00 0x400>`），而该系列本身只含 DT 与 binding、不含驱动改动。
  详见 `patches/iris-el2/README.md`。

  **2026-09-13 第三轮更正 —— 上述"EL2 下不可修复"的结论已被推翻。**
  Steev Klimaszewski 在 Lenovo ThinkPad X13s（**同为 SC8280XP**）上实测 iris 通过：
  `v4l2-compliance` 48/48、真实播放正常，且**明确包括 EL2**。同为该 SoC、同为 EL2，
  X13s 能跑而本机不能 —— 这是**设备特有的问题，不是架构性的**；前一轮把"PAS 调用成功但核心
  不起"归因为 EL2 固有缺陷属过度归因（上游 `qcom,broken-reset` 那段话讲的是 DSP 的
  remoteproc，不能外推到视频核）。

  同轮新增的确证事实：

  | 事实 | 依据 |
  |---|---|
  | 本机固件是 **Gen1**，故 `sm8250_data` 是正确选择 | 上游 master `iris_firmware.c` 的判定算法（`video-firmware.1.x` 即 Gen1）比对 `QC_IMAGE_VERSION_STRING=video-firmware.1.1-…`；Xilin Wu 的 `sc8280xp_data` 与 `sm8250_data` 唯一功能差异是多一个 gen2 描述符 |
  | TrustZone **活着且在校验** | 探针模块：`pas_shutdown(9)=0`，不存在的 ID 一律 `-22`，未加载镜像时 `auth_and_reset(9)=-22` |
  | TZ **声称**支持视频 PAS 并报告成功，硬件却不动 | `pas_supported(9)=yes`；镜像已加载时 `auth_and_reset(9)=0` |
  | **`MP_VIDEO_VAR` 被本机 TZ 拒绝**，是与 X13s 的关键差异 | 6 组参数全部 `-5`；`SET_CP_POOL_SIZE` 亦 `-22`，同服务的 `IOMMU_SECURE_PTBL_SIZE` 却返回 0 |
  | 上游已知低 IOVA 区间缺陷并已有 DT 级修复 | `[PATCH 00/22] Restrict lower IOVA range for Venus and Iris VPUs`（含 `sc8280xp: Reserve low IOVA range for Iris`） |

  新增可复现工具 `tools/pas-probe/`（独立探针模块，向 TrustZone 直接问询并逐项对比寄存器）。
  下一步优先级：查清 `MP_VIDEO_VAR` 被拒的原因，并补上低 IOVA 保留。

  **2026-09-13 第四轮：所有 Linux 侧方向已走完，结论定型。**
  把 Windows 驱动 `qcdxkm8280.sys` 的 TrustZone 接口逆向出来后（详见
  `docs/windows-video-tz-interface.md`）确认了三点：

  1. Windows 驱动视频核走的是 **QTEE（TrEE）IOCTL**，不是 Linux iris 用的 SIP SMC；
     且它在视频核初始化时调用了 **Linux 侧完全没有**的 TZ 子系统状态函数
     （`TZ_SUBSYS_STATE_RESUME`、`TZ_SUBSYS_STATE_VENUS_RESTORE_THRESHOLD`，subsys = 9）。
  2. **CP 参数不是原因**：连同从 Windows 逆向出的两套静态参数表共 6 组，在本机全部
     返回 TZ 的 `-EIO`；`mpvv` 在"冷状态"下作为模块的第一个 SCM 调用同样失败，
     说明与顺序/状态无关。
  3. **经 `qcomtee` 复刻这条路被源码否决**：`drivers/tee/qcomtee/core.c` 里
     `op` 被掩到 16 位（`0x02000C08` 当场 `-EINVAL`），且"只能调用 QTEE 托管的对象"，
     即需要**签名 TA**。（本机内核 `# CONFIG_TEE is not set`，`qcomtee` 驱动未编；
     该项可修，但修好也过不了上述两道门。）

  **最终结论**：本机视频硬解不可用，根因是**该设备的 TrustZone 把视频子系统的安全世界支持
  （CP 内存保护 + 子系统状态机）实现在 QTEE + 签名 TA 之后**，Linux 侧够不到。
  注意这**不是** EL2 的架构限制 —— Lenovo X13s（同为 SC8280XP）已在 EL2 下跑通。
  替代方案为软件解码，本机实测 1080p30 H.264 仅需约 0.5 个大核（14.2× 余量），
  详见 `docs/software-video-decode.md`。
- 实验 iris 驱动时需先 `blacklist qcom_iris`、系统起来后再手动 `modprobe`：开机阶段的
  反复 probe 超时曾把显示子系统探针拖到 `-110` 并黑屏。**既然硬解结论已定，建议把这条
  blacklist 长期保留**，避免每次开机都白跑一轮探针并牵连 MDSS。

## [0.1.0] - 2026-09-13

首个版本：设备鉴别、双系统安装、触屏修复、音频调优、外设调查与内核构建配方。

### 新增

- **设备鉴别前检** `scripts/00-preflight.sh`：校验设备树 `compatible`、大核最高频率、
  面板与触控设备，任一判据不符即中止；用于排除 2022 LTE 版（8cx Gen 2 / gaokun2）
  与 2023 降频版。
- **双系统安装** `scripts/10-install-dualboot.sh`：把社区整盘镜像按**分区级 `dd`**
  落到内置盘，保留 Windows；含 GPT 备份、UUID 硬校验、`resize2fs`、
  `loader.conf` 修复与 DTB 预编译。
- **触屏修复** `scripts/20-touchscreen.sh` + `patches/0001-*`：把接口模式脚
  `gpio174` 在触控固件重载前置低，使 Himax HX83121A 走 SPI 上报通路。
- **音频调优** `scripts/30-audio.sh` + `config/ucm2/Qualcomm/sc8280xp/HUAWEI-GK-W7X.conf`：
  gaokun3 专用 ALSA UCM2 profile，功放增益由 X13s profile 的 `12`（−3.00 dB）
  提到内核限幅上限 `17`（0.00 dB）。
- **指纹调查** `scripts/40-fingerprint.sh`：只读探针，含从 Windows 分区取
  `SYSTEM` 注册表 hive 的采集路径。
- **一键诊断报告** `scripts/90-report.sh`：提 issue 用的只读体检报告。
- **分析工具**：`tools/win-acpi-hive.py`（离线解析 Windows 注册表，读出本机真正
  枚举过的 ACPI 设备与资源分配）、`tools/acpi-devmem-dump.py`（从 `/dev/mem`
  读 ACPI 表）、`tools/gaokun-iris-dts-prep.py`（前置上游 IRIS 设备树节点）。

### 文档

- `docs/install-dualboot.md` —— 双系统安装完整步骤与实机踩坑。
- `docs/audio.md` —— 音频质量归因、量化与增益上限。
- `docs/video-decode.md` —— 视频硬解归因（IRIS 而非 Venus）与可行路径。
- `docs/build-kernel-iris.md` —— IRIS 内核构建配方（含实机构建验证后的修正）。
- `docs/fingerprint.md` —— 指纹可行性调查结论。

### 已核实的关键结论

- **触屏**：`gpio174` 为低 ⇒ SPI 上报；为高 ⇒ I²C-HID。引导固件把它留在高电平且
  无人接管，是触屏完全失效的根因。
- **音频**：音质差是三层叠加 —— 内核主动限幅、Linux 侧完全没有 Histen 逐机型调音、
  以及加载了双扬声器的 X13s profile。硬件尚余 21.00 dB 未使用，但主动扬声器保护
  缺失，本项目**只把增益提到内核限幅值，不取消内核限幅**。
- **视频**：本机是 Qualcomm IRIS(Gen1) 而非经典 Venus；v7.1-rc3/v7.2-rc2 的上游树里
  都没有 sc8280xp 视频节点（v7.3-rc1 才有），buildbot 的 `patches/media/0006` 是过时的
  venus 形态。
- **指纹**：FocalTech FTE7001，其 SPI **由 Qualcomm 安全世界独占**，非安全侧只拿到
  一个 GPIO 中断连接 —— Linux 走常规驱动路线不可达。
- **平板不适合作为编译机**：无风扇机型上 `make -j8` 会触发硬件级瞬间断电
  （日志无任何关机序列，温度仅 33 °C）。

### 已知问题

- 视频硬解尚未跑通；IRIS 与 Venus 走同一条 PAS/安全世界通路，其可用性取决于
  `patches/el2/*` 中的 self-owner 与 `qcom,broken-reset` 改动（缺少该组补丁时
  adsp/cdsp/slpi/venus 的固件加载全部报 `-22`，音频与视频同时失效）。
- 手写笔通道未实现。
- `qcom-apm` 开机报 `CMD timeout`（声卡仍能注册）。
- RTC 开机时间错误，依赖 NTP 纠正。

[未发布]: https://github.com/aoripus/easy-for-gaokun/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/aoripus/easy-for-gaokun/releases/tag/v0.1.0
