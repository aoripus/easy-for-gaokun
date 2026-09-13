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

## 实机验证（2026-09-13，GK-W7X，7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+）

| 阶段 | 应用本补丁前 | 应用后 |
|---|---|---|
| `pas_init_image`（认证固件元数据） | `-22` | 通过 |
| `pas_auth_and_reset`（启动并解复位） | 未到达 | **通过** |
| `qcom_scm_mem_protect_video_var`（内容保护内存区） | 未到达 | `-5`（EIO），仅 DRM 需要 |
| `iris_vpu_boot_firmware`（踢核心并等固件应答） | 未到达 | **`-62`（ETIME）** |

第四步的失败细节 —— 在 `iris_vpu_boot_firmware()` 前后各读一次寄存器，读数完全一致：

```text
CTRL_STATUS=0x0                  轮询 1000 次全 0，固件从未置位
WRAPPER_CORE_POWER_STATUS=0x2    wrapper 有电
WRAPPER_TZ_CPU_STATUS=0x0        WFI 位为 0 → 核心不在运行/空闲态
WRAPPER_CORE_CLOCK_CONFIG=0x0
```

已排除的变量：

- **固件代次**：改用 X13s 的 `qcvss8280.mbn`（2,035,812 B；与本机华为那份 2,035,748 B 仅差
  64 字节）后结果相同 —— 同样的 `-62`、同样的寄存器读数；
- **固件内存可达性**：`video-region@86700000`（2.10 GiB，5 MiB）低于 `sm8250_data.dma_mask`
  （`0xe0000000`）。

**结论**：本补丁把失败点从"固件无法认证"推进到"核心未真正脱离复位"，与上游 EL2 补丁 0018
的原文一致（"EL2 下可以认证并启动固件，但 remoteproc 永远不会真正脱离复位"）。remoteproc 靠
`qcom,broken-reset` 跳过复位、attach 已运行的实例绕过；视频核心必须由 Linux 自行启动，没有
attach 可言 —— 因此 **IRIS 视频硬解在 EL2 下不可用**。要让硬解可用需内核运行在 EL1（下方有
hypervisor 代管 PAS），而本机固件是把 Linux 直接投到 EL2。

## 实验时的注意事项（踩过的坑）

iris 驱动在**开机阶段**反复 probe 超时（每次约 110 ms，内核会重试多轮）曾把显示子系统
（`ae00000.display-subsystem`）的探针一起拖到 `-110` 超时并黑屏。做这类实验时应：

1. 在 `/etc/modprobe.d/` 写入 `blacklist qcom_iris`，让系统先正常起来；
2. 系统起来后再手动 `sudo modprobe qcom_iris` 观察。

这样最坏只挂这一次，重启即回到可用状态；而且此时 journald 已启动，日志能落盘（开机阶段崩溃
时日志一条都留不下）。

## 应用方式

`tools/build-iris-x86.sh` 的第 5c 步会自动应用本补丁（可用 `GK_IRIS_EL2_PATCH` 覆盖路径）。
