# ADR-0003：触屏走 SPI 通路，放弃上游的 I²C-HID 描述

- **状态**：已接受
- **日期**：2026-09-13
- **相关**：[`patches/touch-spi-mode/`](../../patches/touch-spi-mode/README.md)、[`README.md`](../../README.md) §2.1

## 背景（Context）

本机触屏是 Himax **HX83121A** 级联 IC。它向哪个主机接口上报数据，由一颗**接口模式选择脚**
`TLMM gpio174` 在运行时决定：拉**低**走 SPI 上报裸触摸数据，留**高**则改走 I²C-HID。
引导固件把该脚留在**高电平**，而社区设备树只配置了 `gpio175`（中断）与 `gpio99`（复位），
**没有任何一方管理 `gpio174`**。

上游 mainline 对该机触屏的描述是 `i2c4@0x4f` 的 `hid-over-i2c`。实机结果：
`4-004f` 设备节点存在，但 **`i2c_hid` 从不绑定**，没有输入设备，也没有中断。

## 决策（Decision）

- 采用**社区 SPI 驱动**（`himax_hx83121a_spi`，挂 `spi0.0`），并在板级设备树里把
  `gpio174` 描述为**低电平输出**，使 IC 在驱动复位与固件重载**之前**就已锁存到 SPI 模式。
- 补丁以 [`patches/touch-spi-mode/`](../../patches/touch-spi-mode/README.md) 单独成序列（一条补丁）。
- **不采用**上游的 I²C-HID 描述；该路线在本机实测作废。

## 后果（Consequences）

- **正面**：触屏可用；驱动每次中断读一整帧原始电容网格（40×60），主机侧算法决定触控行为。
- **负面 / 代价**：走上 SPI 后，**IC 每帧都上报**（空闲时约 120 Hz、单核 1.8–2.0% CPU）——
  因为这个驱动把触控判定全放在主机，IC 不可能知道"有没有手指"。这是后续 ADR-0004 的直接起因。
- **风险**：该引脚语义来自实机取证（固件行为）而非上游文档；换固件版本需重新验证。

## 替代方案与放弃原因（Alternatives）

| 方案 | 为什么没采用 |
|---|---|
| 上游 I²C-HID（`i2c4@0x4f`，零补丁） | 实机 `i2c_hid` 从不绑定，无输入设备、无中断 |
| 在用户态脚本里临时拉低 `gpio174` | 只在固件重载前的窗口有效，无法保证每次开机都生效；设备树才是正确落点 |
| 换用其他厂商的 HX83121A 驱动 | 现有社区驱动已能工作，问题在引脚模式而不在驱动 |

## 证据与出处（Evidence）

- 引脚语义与根因链：[`README.md`](../../README.md) §2.1「触屏故障：根因与修复」
- 补丁与验证判据：[`patches/touch-spi-mode/README.md`](../../patches/touch-spi-mode/README.md)
- 两条通路的量化对比工具：[`tools/gk-touch-bench.py`](../../tools/gk-touch-bench.py)
- 复现命令：`grep himax-spi-ts /proc/interrupts`（两次采样应持续增长）、
  `dmesg | grep 'failed to get touch data'`（不应出现）

## 回滚（Rollback）

不安装带该补丁的内核即可（内核产物与 BLS 条目一一对应）；
`scripts/gk-install-kernel.sh --uninstall --kver <串>` 删除对应条目。ESP 上既有文件不受影响。
