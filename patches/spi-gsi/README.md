# `patches/spi-gsi/` —— 让触屏 QUP-SPI 走 GSI（DMA）模式

> **元数据**（字段定义见 [`patches/README.md`](../README.md)）
>
> - **用途**：让触屏的 QUP-SPI 走 **GSI（DMA）** 模式，取代逐字 FIFO 传输
> - **基线 / Base**：`v7.2.5`（`drivers/spi/spi-geni-qcom.c` 的 pre-image 为 blob
>   `26e723cfea61ef53068e3f1265430cc3a315e6a3`）
> - **序列 / Order**：见同目录 [`series`](series)（binding 与驱动两条必须成对）
> - **上游状态**：**已投稿、未合入**（Pengyu Luo 的 v1，2026-06-14）；**v2 已被作者本人撤回**
> - **是否用于当前发布内核**：✅ 是（自 r1 起）
> - **验证**：见下「应用与验证」（GENI SE 中断 `998000.spi` 恒为 0、`gpi-dma` 持续增长）
> - **回滚**：不应用本序列即回到 FIFO 模式（功能可用，但每次触屏中断对应的 SPI 完成中断更多）

这两条补丁**不是本项目的原创**，而是 **Pengyu Luo `<mitltlatltl@gmail.com>`**（即 gaokun3
设备树的上游作者、`right-0903`）投给上游的 v1 系列，本项目**原样携带**以便复现 r1 内核产物。

| 文件 | 内容 | 上游状态 |
|---|---|---|
| `0001-spi-dt-bindings-…-Add-property-to-force-GSI-mode.patch` | `Documentation/devicetree/bindings/spi/qcom,spi-geni-qcom.yaml` 增加 `qcom,force-gsi-mode`（flag），+5 行 | **未合入** |
| `0002-spi-qcom-geni-Add-property-to-force-GSI-mode.patch` | `drivers/spi/spi-geni-qcom.c` 读取该属性并强制 `fifo_disable = 1`，从而走 `spi_geni_grab_gpi_chan()` 的 GSI 路径，+7 行 | **未合入** |

- 邮件列表原文：[`[PATCH 1/2]`](https://lore.kernel.org/linux-arm-msm/20260614083424.464132-1-mitltlatltl@gmail.com) ·
  [`[PATCH 2/2]`](https://lore.kernel.org/linux-arm-msm/20260614083424.464132-2-mitltlatltl@gmail.com)（2026-06-14）
- 本项目的 DTS 里**早已写了** `qcom,force-gsi-mode`（来自社区板级 DTS），但 v7.2.5 的驱动
  **不读这个属性**，binding 里也没有它 ⇒ 之前一直静默退回 FIFO 模式。这两条补丁正是让它生效。

## ★ 为什么用 v1 而不是 v2

作者后来在 `Suggested-by: Dmitry Baryshkov` 下投了 **v2**（*"Use GSI mode if DMA channels are
available"*，改为"只要有 DMA 通道就用 GSI"，不再需要 DT 属性）。**该 v2 已被作者本人撤回**：

> Re: [PATCH v2] spi: qcom-geni: Use GSI mode if DMA channels are available（2026-07-14）
> *"Please ignore this patch. After discussion, let us keep using the fifo_disabled variable to
> determine the mode."*
> —— <https://patchew.org/linux/20260616122605.668908-1-mitltlatltl@gmail.com/>

⇒ 在 v7.2.5 上，**v1 的 DT 属性路线是唯一可行解**。

## 应用与验证

补丁的 pre-image 与 v7.2.5 完全一致（`drivers/spi/spi-geni-qcom.c` blob
`26e723cfea61ef53068e3f1265430cc3a315e6a3`），可直接应用：

```bash
git apply patches/spi-gsi/0001-*.patch
git apply patches/spi-gsi/0002-*.patch
```

**生效判据**（已实测，见 [`docs/releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913.md`](../../docs/releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913.md)）：

- `998000.spi`（GENI SE 中断）**恒为 0**；
- `gpi-dma` 中断持续增长，约为触屏中断数的 **2 倍**（一次传输一对 TX/RX 完成）。

**前置条件**（本机已满足）：`CONFIG_QCOM_GPI_DMA=m`、`qcom,sc8280xp-gpi-dma` 节点
`status = "okay"`、触屏 SPI 节点带 `dmas` / `dma-names = "tx","rx"`。

## ⚠️ 它**不能**解决什么

GSI **不改变触屏 IC 自身的中断速率**（`msmgpio 175 / himax-spi-ts`）。实测 r0 与 r1 都是
约 120 次/秒（空闲时亦然）。`tools/gk-touch-bench.py` 报出的「每帧 15.39 个触屏 IRQ」
是 IC/驱动交互的行为，与本组补丁无关 —— 早期把它归因于 FIFO 模式的推断**已被实测推翻**。
GSI 的真实收益是：每次触屏中断对应的 **SPI 完成中断从 ≈2.59 降到 ≈2.00（−23%）**，
并把逐字 FIFO 处理换成 DMA。

## 许可

上游补丁，`Signed-off-by: Pengyu Luo`，随 Linux 内核以 **GPL-2.0** 分发。本仓库为 GPL-2.0-only。
