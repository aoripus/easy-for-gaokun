# ADR-0002：视频硬解走 EL1 + venus（放弃 EL2 + IRIS）

- **状态**：已接受
- **日期**：2026-09-13
- **相关**：[`docs/video-decode.md`](../video-decode.md)、[`docs/windows-video-tz-interface.md`](../windows-video-tz-interface.md)（历史归档）

## 背景（Context）

本机需要视频硬解才能做到"日用"。可用的解码单元（VPU）驱动有两条：**venus** 与 **IRIS**；
启动级别有 **EL1** 与 **EL2**（后者才有 `/dev/kvm`）。实测组合结果：

- **EL2 + IRIS**：固件认证与解复位都能"返回成功"，但视频核**永不上电执行**
  （`CTRL_STATUS` 恒为 `0`）；失败点最早出现在 `qcom_scm_pas_init_image()` 返回 `-22`。
- **EL1 + venus**：解码器与编码器直接出现（`/dev/video32/33`），mpv 走 `h264_v4l2m2m` 实际解码。

同时，Windows 侧逆向显示：**该设备**把视频子系统的安全世界支持（CP 内存保护、子系统状态机）
实现在 QTEE + 签名 TA 之后，Linux 侧够不到；这与同为 SC8280XP 的 Lenovo X13s 不同
（X13s 在 EL2 下跑通了 IRIS）。

## 决策（Decision）

- 视频硬解统一走 **EL1 + venus**：内核串里带 `el1` 与 `venus` 两个字段，`CONFIG_VIDEO_QCOM_VENUS=m`，
  且**必须** `# CONFIG_VIDEO_QCOM_IRIS is not set`（两者节点同地址，不能共存）。
- IRIS / EL2 路线的补丁（[`patches/iris-el2/`](../../patches/iris-el2/README.md)、
  [`patches/el2-v7.2/`](../../patches/el2-v7.2/README.md)）**保留但不用于发布内核**，作为历史归档。
- 需要 KVM 时**另发一个 `el2` 内核**（命名规范允许 `el1`/`el2` 共存），而不是牺牲硬解。

## 后果（Consequences）

- **正面**：硬解可用是"能日用"的分水岭；这条路线与社区（buildbot 镜像）一致，观察可互证。
- **负面 / 代价**：**EL1 没有 `/dev/kvm`** —— 虚拟化（含 Waydroid 之外的 VM 场景）受限。
  要 KVM 就得换 `el2` 内核，那时**没有硬解**（软解兜底见 [`docs/software-video-decode.md`](../software-video-decode.md)：
  1080p30 H.264 约 0.5 个大核）。
- **风险**：上游对 sc8280xp-venus 的支持仍未进 mainline（本项目以补丁携带），
  内核升级时需要重新核对补丁是否仍能落地。

## 替代方案与放弃原因（Alternatives）

| 方案 | 为什么没采用 |
|---|---|
| EL2 + IRIS 硬啃 | 视频核在本机上不了电；该设备的 TZ 把所需安全服务放在 QTEE + 签名 TA 之后，Linux 侧无接口 |
| EL2 + venus | 与 IRIS 死在同一处（`qcom_scm_pas_init_image()` 返回 `-22`） |
| 纯软解 | 可用但代价高（占用 CPU、发热、续航），只作为无 VPU 时的兜底，不作为默认 |
| 用 `qcomtee` 复刻 Windows 的 TZ 调用 | 源码级否决：`op` 被掩到 16 位、且只能调用 QTEE 托管对象，需要签名 TA |

## 证据与出处（Evidence）

- 归因与可行路径：[`docs/video-decode.md`](../video-decode.md)
- EL1 实测（venus 解码/编码器、mpv 走 `h264_v4l2m2m`）：
  [`docs/releases/kernel-7.2.5-aoripus-ml-gaokun-eog-el1-venus-r1-20260913.md`](../releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913.md)
- 负结论的完整取证（寄存器级、Windows TZ 接口）：
  [`docs/windows-video-tz-interface.md`](../windows-video-tz-interface.md)、
  [`docs/iris-windows-ved-register-trace.md`](../iris-windows-ved-register-trace.md)
- 复现命令：见 `docs/video-decode.md` §5「实机判定命令」

## 回滚（Rollback）

`el1` 与 `el2` 是**两个并存的 BLS 条目**，切换只需在引导菜单选择，或重装另一版内核
（`scripts/gk-install-kernel.sh`）。不需要改动 ESP 上任何既有文件。
