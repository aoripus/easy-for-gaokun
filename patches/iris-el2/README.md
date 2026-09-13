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
| `pas_init_image` | `-22` | 通过 |
| `pas_auth_and_reset` | `-22` | **通过** |
| `qcom_scm_mem_protect_video_var` | 未到达 | `-5`（EIO） |

即：固件已能认证、核心已能解复位，但最后一步"为视频核心设置受保护内存区"被 TrustZone 拒绝。
上游 EL2 补丁 0018 的原话是"EL2 下可以认证并启动新固件，但 remoteproc 永远不会真正脱离复位"——
remoteproc 靠 attach 已运行的实例绕过，视频核心没有 attach 可言。因此**视频硬解在 EL2 下仍不可用**，
本补丁把失败点从未能加载固件推进到"核心未真正运行"，为后续排查留下了明确边界。

## 应用方式

`tools/build-iris-x86.sh` 的第 5c 步会自动应用本补丁（可用 `GK_IRIS_EL2_PATCH` 覆盖路径）。
