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

## ★ 结论（2026-09-13 第二轮寄存器级深挖后确定）

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

### 另外两处与 Windows 的差距（同向证据，但不是本次阻塞点）

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

### 因此：可行的与不可行的

| 方案 | 可行性 | 说明 |
|---|---|---|
| 改 DTS / 换固件 / 补寄存器 | **无效** | 逐寄存器实测已排除；华为与 X13s 两份 `qcvss8280.mbn` 结果完全相同 |
| 让内核运行在 EL1（下方保留 Gunyah） | **不可行** | 本机固件把 Linux 直接投到 EL2；需要改 bootloader/固件 |
| 复刻 Windows 的 TZ 视频服务 | **不可行** | 需要 SMC 功能号与 TZ API 契约，全在闭源签名驱动里 |
| 上报上游 | **推荐** | 应告知 iris/sc8280xp 系列"DT 可以合并，但硬件在 EL2 下不工作"，避免误导 |
| 软解 | **推荐** | 当前唯一可用的播放路径；硬解不可得 |

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
