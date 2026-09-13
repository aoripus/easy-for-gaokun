# ADR-0004：触屏空闲治理用主机侧中断门控采样

- **状态**：已接受
- **日期**：2026-09-13
- **相关**：[`docs/touch-idle-policy.md`](../touch-idle-policy.md)、[`patches/touch-idle/`](../../patches/touch-idle/README.md)

## 背景（Context）

触屏走 SPI 后（见 ADR-0003），**空闲时 IC 仍以约 120 Hz 上报**：这台机器的驱动把触控判定
全部放在主机，IC 只当传感器，因此它无法知道"有没有手指"。代价是可量化的：约 120 次中断/秒、
单核 **1.8–2.0%** CPU，只为确认"没有手指"。

Windows 侧的做法是让 IC 进空闲（AFE 邮箱命令 `0x0A`）并把主机取帧降到 50 ms 一次；
但 Windows 是**定时轮询取帧**的驱动（`WaitInterrupt()` 是死代码），我们是 **IRQ 驱动**，
照搬会直接让触屏失效。另外，让 IC 停扫后主机读不到帧，也就无从判断何时该唤醒。

## 决策（Decision）

- 采用**主机侧中断门控采样**：
  连续 `idle_enter_frames`（默认 **7200 帧 ≈ 60 s**）无**已上报**触点后 `disable_irq()`；
  随后每 `idle_poll_ms`（默认 **30 ms**）**只放行一帧**走**正常中断路径**跑完整算法；
  该帧上检出已上报触点（`algo->touch_active`）就恢复中断模式，否则再次屏蔽并重排 work。
- **不向 IC 发任何空闲命令**（不发 `0x0A`、不做芯片重初始化），因此首触延迟只有一个采样周期量级。
- 策略默认启用；`idle_enter_frames=0` 可完全关闭。

## 后果（Consequences）

- **正面**（实测）：空闲 IRQ **120.0 Hz → 22.9 Hz（−81%）**，触屏 kthread CPU
  **2.00% → 0.50%（−75%）**；唤醒路径经真手指验证（`idle exit: touch after 30ms sampling`），
  退出后 IRQ 回到约 118.7 Hz。
- **负面 / 代价**：首触延迟从"一帧 ≈8.3 ms"变为"≈30 ms 采样周期 + 一帧"；
  空闲时 **IC 自身仍以 120 Hz 扫描**（IC 侧功耗没有降低）。
- **风险**：阈值设太小会"不跟手"（240 帧 ≈2 s 的实机反馈）；计时器复位条件若用内部中间量
  （原始稳定触点数）会因单帧噪声**永远到不了阈值**——本 ADR 要求复位只由**已上报触点**触发。

## 替代方案与放弃原因（Alternatives）

| 方案 | 为什么没采用 |
|---|---|
| AFE `0x0A` 让 IC 停扫 + 定时轮询 | 停扫期间主机读不到帧，无法判断"手指来了没有"；唤醒要付完整重初始化（约 30–50 ms） |
| 在 work 里直接读帧轮询（不走中断路径） | 离开中断上下文读 event stack 与 IC 帧边界无关，读到**撕裂帧**导致算法误判触点，策略每约 2 s 振荡（实测 IRQ 62 Hz） |
| 保持 120 Hz 不动 | 白烧 1.8–2.0% 单核 CPU 与相应功耗，且这是可消除的 |

## 证据与出处（Evidence）

- 现象量化、架构根因、AFE 语义实测、策略收益与失败记录：
  [`docs/touch-idle-policy.md`](../touch-idle-policy.md)
- 驱动增量与基线说明：[`patches/touch-idle/README.md`](../../patches/touch-idle/README.md)
- 装机复核（r3）：[`docs/releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3-20260913.md`](../releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3-20260913.md)
- 观测入口：`/sys/bus/spi/devices/spi0.0/idle_state`（`active` / `sampling` / 已累积帧数 / 阈值 / 周期）

## 回滚（Rollback）

运行时：`echo 0 > /sys/module/himax_hx83121a_spi/parameters/idle_enter_frames` 立即关闭策略；
持久回滚：切回不带该补丁的内核条目，或卸载对应 BLS 条目。
