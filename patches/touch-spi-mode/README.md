# `patches/touch-spi-mode/` —— 让触屏 IC 走 SPI 上报通路

> **元数据**
>
> - **用途**：在 gaokun3 板级设备树里把 TLMM **`gpio174` 描述为低电平输出**，使 Himax HX83121A 在固件重载前锁存为 **SPI** 主机接口
> - **基线 / Base**：`arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts`（上游自 v6.14 起的板级设备树）
> - **序列 / Order**：见同目录 [`series`](series)
> - **上游状态**：**未投稿**（属本机适配。上游当前仍把触屏描述为 `i2c4@0x4f` 的 `hid-over-i2c`，在本机实测**不绑定**）
> - **是否用于当前发布内核**：✅ 是（自首个自研内核起全部带）
> - **验证**：见下「验证」
> - **回滚**：见下「回滚」

## 为什么需要它

这颗 Himax HX83121A 是级联 IC，**它向哪个主机接口上报数据由一颗接口模式选择脚在运行时决定**：

| `TLMM gpio174` | IC 行为 |
|:---:|---|
| **低** | 走 **SPI** 上报裸触摸数据（本项目驱动 `himax_hx83121a_spi` 需要的通路） |
| 高 | 改走 **I²C-HID**，SPI 通路不再输出触摸数据 |

引导固件把 `gpio174` 留在**高电平**，而社区设备树的 `ts0_default` 只配置了 `gpio175`（中断）
与 `gpio99`（复位）——没有任何一方管理 `gpio174`。结果是：SPI 驱动仍然绑定、能读到芯片 ID、
也完成了触摸固件重载，但**IC 从不发送触摸数据、电平中断只在固件重载时触发一次**，触屏完全不可用。

本补丁在触屏的默认引脚状态里把 `gpio174` 描述为低电平输出，使其在驱动复位 IC 与固件重载**之前**
就已处于 SPI 配置。**引脚只需在重载前正确**：IC 在那一点锁存模式。

## 验证

装机后在目标机上：

```sh
# 触屏输入设备存在
grep -i himax /proc/bus/input/devices

# 触屏 IC 中断持续增长（不是"只有 1 次"）
grep himax-spi-ts /proc/interrupts
sleep 5
grep himax-spi-ts /proc/interrupts

# 不应出现驱动读不到数据的报错
sudo dmesg | grep -i 'failed to get touch data'
```

**判据**：中断计数在两次采样之间明显增长（手指滑动时约 120 次/秒量级），
且 `failed to get touch data!` **不出现**。反过来，"`sense on fail` 没出现"**不能**当作成功判据
——该字符串只在失败路径打印。

## 回滚

本补丁只影响内核产物（DTB），**不改动 ESP 上的任何既有文件**：

```sh
sudo scripts/gk-install-kernel.sh --uninstall --kver <内核串>
```

切回不带该补丁的引导条目即可；不要手工编辑 ESP 上的 DTB。

## 许可

GPL-2.0-only，与 Linux 内核一致。补丁带 `Signed-off-by: aoripus`。
