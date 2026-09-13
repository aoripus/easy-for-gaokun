# patches/iris-el2 —— IRIS 视频驱动在 EL2 下的两处修复

`0001-media-iris-use-tzmem-and-ctx-aware-auth-for-EL2.patch` 修改
`drivers/media/platform/qcom/iris/`，让视频固件在 EL2（无 hypervisor）下能够被认证和启动。

## 为什么需要

`qcom_scm.c` 里对两种运行方式有明确区分（见 `qcom_scm_pas_prepare_and_auth_reset()` 的注释）：

- **Linux 运行在 EL1**：EL2 的 Gunyah hypervisor 会 trap `auth_and_reset`，由它代建 SHM bridge；
- **Linux 运行在 EL2**：SHM bridge 必须由 Linux 自己建立，然后才调 TrustZone 认证。

本机跑的是 `-el2` 内核（自己就是 hypervisor），而上游 iris 驱动走的是 EL1 假设：

| 阶段 | 上游写法 | EL2 下的结果 | 本补丁 |
|---|---|---|---|
| 加载固件元数据 | `qcom_mdt_load(..., NULL)`，ctx 为 NULL → 退回 `dma_alloc_coherent()`，不经 SHM bridge | `error -22 initializing firmware` → `firmware download failed` | 分配 `qcom_scm_pas_context` 并置 `use_tzmem = true`，改用 `qcom_mdt_pas_load()` |
| 认证并解复位 | 裸调 `qcom_scm_pas_auth_and_reset(IRIS_PAS_ID)` | `auth and reset failed: -22` | 改用 `qcom_scm_pas_prepare_and_auth_reset(ctx)`，由它先为固件内存区建 SHM bridge |

`qcom_q6v5_pas.c` 早就是这么做的（用 `rproc->has_iommu` 决定 `use_tzmem`），
本补丁让 iris 与之一致。ctx 保存在 `struct iris_core` 中，`devm` 托管。

---

## ★ 结论（2026-09-13 第三轮：**前一轮结论已被推翻，见下**）

> ### ⚠️ 更正：**EL2 不是阻塞点**
>
> 本文件此前给出的"IRIS 在 EL2 下不可用、且不是软件可修复的问题"**已被证伪**，保留原文于下方仅作记录。
>
> **决定性反例【社区报告】**：Steev Klimaszewski 在 **Lenovo ThinkPad X13s（同为 SC8280XP）**
> 上用 iris 驱动实测通过，而且**明确包括 EL2**：
>
> > "after disabling venus module otherwise it loads venus not iris. **In el2**, the device seems to be
> > /dev/video33 … **In el1**, the device becomes /dev/video0"；两种运行级别下 `v4l2-compliance`
> > 均 48/48 全过；"if I let the video play, **it plays just fine**, however, if I attempt to skip
> > forward, back, or even play after the video has played, then I see the smmu fault"
>
> 来源：<https://lists.openwall.net/linux-kernel/2026/03/27/1695> 、
> <https://patchew.org/linux/20260312-iris-sc8280xp-v4-0-a047ef1e3c7d@oss.qualcomm.com/>
>
> **同为 SC8280XP、同为 EL2，X13s 能跑、本机不能** —— 所以 EL2 本身不禁止 IRIS 工作。
> 前一轮把"PAS 调用成功但核心不起"归因为 EL2 的固有缺陷是**过度归因**：
> 上游 `qcom,broken-reset` 那段话描述的是 **DSP 的 remoteproc** 场景，不能直接外推到视频核。
>
> **结论修正为**：本机的失败是**设备特有的**，不是架构性的。截至 2026-09-13，最显著的
> 设备特有差异是 **`qcom_scm_mem_protect_video_var` 被本机 TrustZone 以 `-EIO` 拒绝**
> （X13s 上这一步必须成功，否则上游 iris 会在此中止）。该差异仍在调查中。

### 本机实测的确定事实（不分轮次，按证据强度排列）

| # | 事实 | 证据 | 置信度 |
|---|---|---|---|
| 1 | 固件是 **Gen1** | 上游 master `iris_firmware.c` 的判定算法：`video-firmware.1.x` 即 Gen1；本机固件串为 `QC_IMAGE_VERSION_STRING=video-firmware.1.1-e736ad69…` | 【已核实】 |
| 2 | 因此 `sm8250_data`（gen1 描述符）是**正确**选择 | 同上；Xilin Wu 的 `sc8280xp_data` 与 `sm8250_data` 的唯一功能差异就是多一个 gen2 描述符 | 【已核实】 |
| 3 | TrustZone **活着且在认真校验** | `pas_shutdown(9)=0`，而 `pas_shutdown(0/63/100/200/0xffffffff)=-22`；未加载镜像时 `auth_and_reset(9)=-22` | 【已核实，探针模块】 |
| 4 | TZ **声称**支持视频 PAS 并报告认证复位成功 | `pas_supported(9)=yes`；镜像已加载时 `pas_auth_and_reset(9)=0` | 【已核实，探针模块】 |
| 5 | 但视频核从不执行 | `CTRL_STATUS` 恒 `0`、`WFI` 位 `0`，90 秒窗口 + 穷举全部可写寄存器 | 【已核实】 |
| 6 | **`MP_VIDEO_VAR` 被 TZ 拒绝**（本机与 X13s 的关键差异） | 6 组参数全部 `-5`；`SET_CP_POOL_SIZE` 亦 `-22`，但同服务的 `IOMMU_SECURE_PTBL_SIZE` 返回 0 | 【已核实，探针模块】 |
| 7 | 上游已知低 IOVA 区间缺陷，且已有 DT 级修复 | `[PATCH 00/22] Restrict lower IOVA range for Venus and Iris VPUs`：VPU 保留 IOVA `[0, 0x25800000)`，越界导致 SMMU 故障甚至重启；含 `sc8280xp: Reserve low IOVA range for Iris` | 【已核实，邮件列表】 |
| 8 | EL1 才是这类设备的**默认**级别，EL2 是为 KVM 选的 | slbounce（Secure Launch）+ qebspil 才把 Linux 投到 EL2；EL2 的代价正是"hypervisor 不再代管 remoteproc" | 【已核实，slbounce README】 |

### 待查方向 —— 已全部关闭（2026-09-13 第四轮）

> **2026-09-13 第五轮补充（底层实现尝试，全部为负）**：本轮把"能不能从底层把它写活"直接试了。
>
> | 实验 | 内容 | 结果 |
> |---|---|---|
> | expA | 在 `auth_and_reset` 前补 `qcom_scm_pas_mem_setup(9, 0x86700000, 0x500000)`（DSP 路径必调、iris 从来不调） | TZ 返回 **-22** |
> | expB | expA + 把固件保留区在设备 IOMMU 域里做**恒等映射**（`iommu_map(iova==phys)`） | 映射**建成**（返回 0，二次调用 `-17 EEXIST`），但核心仍不执行 |
> | 旁证 | 读 `apps_smmu` 全局与全部 64 个 context bank 的 FSR/FAR/FSYNR0 | **全部为 0**：核心连一次存储事务都没有发出 |
> | expC | 把所有厂商变体写过、而 vpu2 路径从不触碰的寄存器全试一遍：`0xB0078`、`0xE0028`(SPARE)、`0xE0018`(SW_RESET)、`0xE0020`(NOC_CLK)、`0xA0174`、`0xFF008`，外加 `CPU_CS_X2RPMH ← 0x3` | 六个寄存器**本来就都是 0**，置位后仍 `CTRL_STATUS=0x0` |
>
> 同时排除了两个"代码路径差异"：
> - `iris_vpu3_ops` / `iris_vpu33_ops` 用的 `power_on_hw` / `power_on_controller` 与本机路径**完全相同**（`iris_vpu_common.c` 里同一对函数），因此上电代码不是差异点；
> - `program_bootup_registers`（只写 `0xB0078=1`）与 `iris_vpu_set_preset_registers`（只把 `0xB0088` 写 0）在我们机器上要么已由公共路径调用、要么目标寄存器本来就已是该值。
>
> **结论（本轮）**：SMMU 零故障 + 全部可写寄存器穷举 + 全部厂商变体寄存器无效 ⇒ 核心**被卡在 Linux 无法触及的某个开关上**；而 `iris` 驱动在该 SoC 上跑的代码路径与已知可用平台同源。
> 剩余的信息来源只有一处：**Windows 驱动到底写了什么**。已派出两路逆向量化（`VedInitVideoCore` 的寄存器写入序列、以及全驱动寄存器偏移全量抽取与 Linux 清单做差集），结果回来后按差集实现。

| 方向 | 结果 |
|---|---|
| `MP_VIDEO_VAR` 为何被拒 | **已查清且关闭**：与调用顺序/状态无关（冷状态下作为第一个 SMC 调用仍是 `-5`）；与参数无关（6 组含 Windows 逆向出的两套静态表全部 `-5`）。本机 TZ 就是不接受该 SIP 命令 |
| 经 `qcomtee`（QTEE）复刻 Windows 的调用 | **源码级否决**：`op` 被掩到 16 位（`0x02000C08` 当场 `-EINVAL`），且"只能调用 QTEE 托管的对象"＝签名 TA。详见 [`docs/windows-video-tz-interface.md`](../../docs/windows-video-tz-interface.md) §8 |
| 补上低 IOVA 保留 | **仍值得做，但已非阻塞点**：该缺陷导致 SMMU 故障与重启，是解码阶段的问题；本机连核心都没起来。精确补丁已记录在 `docs/windows-video-tz-interface.md` 与上游 v1-7/22 |
| 改用 EL1 启动 | **不再必要**：X13s 已证明 EL2 下可以跑通，EL1 不是必需 |

**最终结论**：本机视频硬解不可用，根因是**该设备的 TZ 把视频子系统的安全世界支持
（CP 内存保护 + 子系统状态机）实现在 QTEE + 签名 TA 之后**，Linux 侧够不到。
Linux 可走的路（寄存器、参数、平台数据、固件代次、调用顺序、QTEE 客户端）**已全部走完**。
替代方案是软件解码，本机实测 1080p 余量充足，见
[`docs/software-video-decode.md`](../../docs/software-video-decode.md)。

### 下方为已被推翻的前一轮结论（保留作记录）

> **IRIS 硬件视频编解码在本机（GK-W7X / SC8280XP / EL2）不可用，且不是软件可修复的问题。**
> 阻塞点是 **EL2 下 PAS/TrustZone 接口不释放子系统复位**，这已由上游 EL2 补丁集的作者
> 明确记录（见下节引文），并与本机逐寄存器实测完全吻合。

### 根因原文（上游 `el2-patches/0016` 与 `0017`，Stephan Gerhold）

```
The remoteproc PAS firmware interface does not work properly when running
bare-metal without hypervisor in EL2. It's possible to authenticate and
start new firmware, but the remoteproc is never actually brought out of
reset.
...
Detecting this case automatically is tricky since all the PAS related calls
still succeed, it will just not release the remoteproc from reset.
```

译：**EL2 下可以认证并"启动"固件，所有 PAS 调用都返回成功，但子系统永远不会真正脱离复位。**
本机 `qcom_scm_pas_auth_and_reset(9)` 返回 0、核心却一条指令都不执行 —— 与该描述逐字吻合。

**为什么 DSP 没事而视频核有事**（这是本项目最容易被误判的一点）：

| | DSP（adsp / cdsp / slpi） | 视频核（IRIS） |
|---|---|---|
| 开机时状态 | **固件已由 bootloader 启动并在运行** | 未运行 |
| EL2 下的应对 | 补丁 0016/0018 加 `qcom,broken-reset` → **跳过 `auth_and_reset`，attach 已在运行的实例** | 无 attach 可言，**必须由 Linux 亲自启动** |
| 结果 | `attached`，功能正常 | 卡在"调用成功但核不起" |

### 逐寄存器实测（2026-09-13，`7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+`）

在驱动把核心上电、固件已加载、且已写完 UC region 的 **90 秒"上电窗口"** 内
（实验模块在 `iris_vpu_setup_ucregion_memory_map()` 之后插入 90 s 休眠），
从用户态经 `/dev/mem` 读取全部相关寄存器：

| 检查项 | 地址 | 实测值 | 判读 |
|---|---|---|---|
| `video_cc_mvs0c_clk` CBCR | `videocc+0xc34` | `0x00000221`，`bit31=0` | **时钟在跑**（840 MHz，`hardware_enable=Y`） |
| `video_cc_mvs0_clk` CBCR | `videocc+0xd34` | `0x00000221`，`bit31=0` | **核心时钟在跑**（560 MHz） |
| ARES 位（异步复位） | `videocc+0xc34/0xd34` bit2 | `0` / `0` | **不在异步复位** |
| `mvs0c_gdsc` GDSCR | `videocc+0xbf8` | `0xf8282800`，`PWR_STATE=1`,`SW_COLLAPSE=0` | **已上电** |
| `mvs0_gdsc` GDSCR | `videocc+0xd18` | `0xf8282800` | **已上电** |
| `GCC_VIDEO_AXI0_CLK` ARES | `gcc+0x28010` | `0x00000221` | AXI 时钟在跑、无复位 |
| `CTRL_STATUS` | `iris+0xa004c` | `0x0`（轮询 1000 次全 0） | **固件从未应答** |
| `WRAPPER_TZ_CPU_STATUS` | `iris+0xc0010` | `0x0`（WFI 位 = 0） | **CPU 不在 WFI，即不在运行** |
| `WRAPPER_CORE_POWER_STATUS` | `iris+0xb0080` | `0x2` | wrapper 有电 |
| `UC_REGION_ADDR/SIZE` | `iris+0xa0064/68` | `0xdfc00000` / `4 MiB` | 队列区已编程 |
| `QTBL_INFO` / `QTBL_ADDR` | `iris+0xa0050/54` | `0x1` / `0xdfc00000` | 队列表已使能 |
| `SFR_ADDR` | `iris+0xa005c` | `0xdf7f9000` | 已编程 |

**固件确实在内存里**：直接读保留区 `0x86700000`（DT `pil_video_mem`，5 MiB）得到合法的
镜像头 `06 10 00 00 01 ff ff ff 44 10 00 00 …`，前 5 MiB 中有 17 个 64 KiB 块非全零。
需要说明的是：这一段是 **Linux 自己的 `qcom_mdt_load()` 经 `memremap()` 写进去的**
（见 `iris_firmware.c`），所以"固件在内存里"并不能证明 TrustZone 做了任何事。

### 排除性实验（全部在 90 秒窗口内完成，全部无效）

| # | 操作 | `CTRL_STATUS` 结果 |
|---|---|---|
| exp1 | 直接写 `CTRL_INIT=1` + `SCIACMDARG3=1`（驱动原样） | 仍 `0` |
| exp2 | 先撤销 AON MVP NOC / IRIS CPU NOC / 调试桥的 LPI 低功耗请求，再踢 | 仍 `0` |
| exp3 | 再叠加清 TZ 侧 AXI/核心时钟 halt、桥复位、AON NOC clk | 仍 `0` |
| exp8 | 对 `mvs0_gdsc` / `mvs0c_gdsc` 各做一次**掉电→上电**（WAR 陈旧状态） | 仍 `0` |
| exp9 | 写 `CPU_CS_X2RPMH = MSK_CORE_POWER_ON\|MSK_SIGNAL_FROM_TENSILICA`（回读确认**可写**） | 仍 `0` |
| exp9 | `CPU_CS_AHB_BRIDGE_SYNC_RESET = CORE_BRIDGE_HW_RESET_DISABLE` | 仍 `0` |
| exp9 | `WRAPPER_TZ_QNS4PDXFIFO_RESET` 复位序列 | 仍 `0` |

补充事实：**加载驱动之前**，两个 GDSC 已是 `0xf8282800`（已上电）、两个 CBCR 已是 `0x221`
（已使能）—— 视频子系统在开机时就被固件置于上电状态，驱动的"上电"只是空操作。

### ★ 向 TrustZone 直接问询（探针模块 `tools/pas-probe/`）

前面所有实验都是"从 Linux 这一侧看"。为排除"是不是我们在自说自话"，本项目写了
一个独立探针模块 `tools/pas-probe/gkpas.c`，把问题直接问到 TrustZone 面前，
并把调用前后的视频核寄存器逐项列出。实测输出：

```text
gkpas pas_supported(1)  = yes        # adsp
gkpas pas_supported(9)  = yes        # ★ 视频核：TZ 明确声称【支持】
gkpas pas_supported(17) = NO         # slpi 报"不支持"，但 Linux 侧 attach 运行正常
gkpas pas_supported(18) = yes        # cdsp
gkpas pas_supported(63) = NO         # 不存在的 ID

gkpas pas_shutdown(9)                                   = 0
gkpas pas_auth_and_reset(9) [no image loaded]           = -22
gkpas pas_shutdown(0 / 63 / 100 / 200 / 0xffffffff)     = -22

gkpas mpvv(0x0, 0x25800000, 0x01000000, 0x24800000)     = -5
gkpas mpvv(0x0, 0x00000000, 0x00000000, 0x00000000)     = -5
gkpas mpvv(0x0, 0x4b000000, 0x01000000, 0x4a000000)     = -5
gkpas iommu_set_cp_pool_size(0, 0x25800000)             = -22
gkpas mpvv(设池之后)                                     = -5
gkpas iommu_secure_ptbl_size(1)                         = 0
```

调用前后 23 个视频核寄存器**逐项完全一致**（无任何变化）。

**这组结果的解读（关键）**

1. **TZ 是活的，而且在认真校验。** 不存在的 PAS ID 一律返回 `-22`；未加载镜像就调
   `auth_and_reset` 也返回 `-22`。所以 PAS 通路**不是盲桩**。
2. **TZ 对视频 PAS 明确回答"支持"**（`pas_supported(9) = yes`），且
   `pas_auth_and_reset(9)` 在镜像已加载时返回 **0** —— 即 **TZ 认为自己已经认证并复位了视频核**。
   但硬件从不动。
3. **矛盾点正是答案**：`pas_supported(17) = NO`（slpi）而 slpi 在 Linux 侧工作正常；
   `pas_supported(9) = yes` 而视频核完全不工作。**"TZ 说支持"与"硬件真能跑"在这台设备上
   是两件互不相干的事** —— 视频核的"支持"只存在于 TZ 的账面上。
4. **视频内容保护命令被逐条拒绝**：同一个 `QCOM_SCM_SVC_MP` 服务里
   `IOMMU_SECURE_PTBL_SIZE`(0x03) 返回 0，而 `IOMMU_SET_CP_POOL_SIZE`(0x05) 返回 `-22`、
   `MP_VIDEO_VAR`(0x08) 对所有参数组合都返回 `-5`（`-EIO` 是 TZ 自己的返回状态字，
   见 `qcom_scm_mem_protect_video_var()` 的 `return ret ?: res.result[0];`）。
   说明这台设备的 TZ 固件**没有实现视频 CP 相关的命令**。
5. 顺带澄清一个容易误判的点：**`pas_shutdown(9)` 返回 0 且寄存器无变化是预期的**，
   因为发布版 iris 驱动在 `mem_protect_video_var` 失败时已经调用过一次 `pas_shutdown(9)`。
   不要据此得出"PAS 不碰硬件"的结论。

### 与 Windows 的差距（同向证据，但不是本次阻塞点）

`iris_fw_load()` 的真实顺序是：

```c
iris_load_fw_to_memory()                 /* 自己 memremap + qcom_mdt_load 写保留区 */
qcom_scm_pas_auth_and_reset(9)           /* ← EL2 下返回 0 但不解复位 */
for (cp_config…) {
        qcom_scm_mem_protect_video_var(…);   /* ← 本机返回 -5 (EIO) */
        if (ret) { qcom_scm_pas_shutdown(9); return ret; }   /* ← 上游会立刻把核关掉并中止 */
}
```

- `qcom_scm_mem_protect_video_var` 用的是 sm8250 的 `tz_cp_config_vpu2`
  （`cp_start=0, cp_size=0x25800000`），本机返回 `-EIO`。**上游 iris 在这条上会直接
  `pas_shutdown()` 并中止 probe** —— 也就是说即便是"官方路径"，在这个 SoC 上也会更早死掉。
  该项对非 DRM 解码本应无关紧要，我们已在实验模块中改为非致命后继续推进。
- Windows 侧驱动 `qcdxkm8280.sys`（`VedInitVideoCore`，约 `0x140387000`–`0x14038a100`）
  含以下 Linux 侧**完全没有**的 TrustZone 步骤：
  `VedTrEETzVenusRstrThrsh`、`TZ_MEM_PROTECT_VIDEO_VAR`、`TZ_VIDEO_STATE_RESUME`、
  以及 `Failed to write Venus image version to SMEM table`。
  该 `.sys` 内 **`smc`/`hvc` 指令数为 0**，全部 TZ 调用经 IOCTL 交给已签名的闭源
  `qcscm.sys`/`QcTrEE.sys`/`qcpil.sys`，无法从 `.sys` 反推出 SMC 功能号。

### 上游现状（2026-05 最新）

Dmitry Baryshkov 的 `[PATCH v1…v7] media: iris: enable SM8350 and SC8280XP support`
系列（最新 v7，2026-05-15）**只包含 DT 与 binding，没有任何驱动改动**：

- sc8280xp 的 iris 节点用 `compatible = "qcom,sc8280xp-iris", "qcom,sm8250-venus"`，
  即**回退到 `sm8250_data`（gen1/vpu2 平台数据）**；
- cover letter 原文：*"The driver was very lightly tested on SC8280XP"*；
- 本项目的 `tools/gaokun-iris-dts-prep.py` 生成的节点与该系列**逐属性一致**
  （`iommus = <&apps_smmu 0x2a00 0x400>`、`resets`、`power-domains`、`memory-region` 等），
  **所以 DT 侧没有问题，改 DT 不会带来任何改善。**

### 可行与不可行（2026-09-13 第三轮修正后）

| 方案 | 可行性 | 说明 |
|---|---|---|
| 换 IRIS 平台数据（Xilin Wu 的 `sc8280xp_data`） | **无必要** | 其与 `sm8250_data` 的唯一功能差异是多一个 **gen2** 描述符；本机固件经上游算法判定为 **Gen1** |
| 换固件（X13s 的 `qcvss8280.mbn`） | **无效** | 本机实测结果逐字节相同 |
| 在视频核寄存器里继续穷举 | **无效** | 90 秒窗口内全部可写路径已穷尽 |
| 补上**低 IOVA 保留**（2026-08 系列的 DT 改动） | **值得一试，成本极低** | 纯设备树改动；上游已确认该区间越界会引发 SMMU 故障甚至重启 |
| 改用 **EL1** 启动（去掉 slbounce/qebspil） | **可行但不是当前首选** | EL1 本就是这类设备的默认级别；但 X13s 已证明 **EL2 也能跑通**，故 EL1 不是必需。代价是失去 KVM |
| 查清 **`MP_VIDEO_VAR` 被拒** 的原因 | **当前最高优先级** | 这是与已知可用设备（X13s）最明确的差异 |
| 复刻 Windows 的 TZ 视频服务 | **不可行** | 需要 SMC 功能号与 TZ API 契约，全在闭源签名驱动里 |
| 上报上游 | **推荐** | 附本机的逐寄存器证据与 TZ 问询结果，供上游判断 Gen1/Gen2 与 CP 流程 |
| 软解 | **保底可用** | 在硬解打通前，这是唯一能出画面的路径 |

---

## 实验时的注意事项（踩过的坑，务必遵守）

iris 驱动在**开机阶段**反复 probe 超时（每次约 110 ms，内核会重试多轮）曾把显示子系统
（`ae00000.display-subsystem`）的探针一起拖到 `-110` 超时并黑屏。做这类实验时应：

1. 在 `/etc/modprobe.d/` 写入 `blacklist qcom_iris`，让系统先正常起来；
2. 系统起来后再手动 `sudo modprobe qcom_iris` 观察。

这样最坏只挂这一次，重启即回到可用状态；而且此时 journald 已启动，日志能落盘（开机阶段崩溃
时日志一条都留不下）。

**既然结论已定（硬解不可用），建议把这条 blacklist 长期保留**，避免每次开机都白跑一轮
110 ms×N 的探针并牵连 MDSS。

## 应用方式

`tools/build-iris-x86.sh` 的第 5c 步会自动应用本补丁（可用 `GK_IRIS_EL2_PATCH` 覆盖路径）。
