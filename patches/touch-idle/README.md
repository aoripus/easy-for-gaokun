# `touch-idle` —— 触屏中断使能修复 + 空闲采样策略

本目录收录本项目对 Himax HX83121A SPI 触屏驱动（`drivers/input/touchscreen/himax-spi-core.c`）
**相对已发布 r1/r2 内核的两处改动**，以及它们背后的实测依据。

数据与完整推导见 [`docs/touch-idle-policy.md`](../../docs/touch-idle-policy.md)。

## 文件

| 文件 | 说明 |
|---|---|
| `0001-input-himax-hx83121a-fix-irq-enable-and-idle-sampling.patch` | 驱动增量（22 个 hunk，+481/−92 行，27,409 B） |

## 补丁基线（务必看清）

补丁的 **base 不是 mainline**，而是**本仓库 r1/r2 内核里出厂的那份驱动**，也就是

> 社区 `chiyuki0325/EGoTouchRev-Linux` / `pgs666/EGoTouchRev-Linux` 的 HX83121A 驱动
> **＋** 本项目 r2 增加的 AFE 命令邮箱传输层（`himax_hx83121a_afe_*`、`afe_cmd` 节点）。

因此它不能直接打进 mainline 树。落回本项目内核树的正确顺序是：

1. 取 mainline stable 7.2.5；
2. 应用本项目 gaokun3 补丁集（`docs/kernel-7.2.5-el1-build.md` 记录的配方），它会把社区驱动放进
   `drivers/input/touchscreen/`；
3. 再应用本目录的补丁。

验证方式（在任一含上述第 2 步结果的内核树上）：

```sh
git apply --check patches/touch-idle/0001-*.patch
# 或
patch -p1 --dry-run < patches/touch-idle/0001-*.patch
```

本项目的实测校验：对 r1/r2 出厂驱动副本 `patch -p1 --dry-run` **22/22 hunk 全部干净应用**。

## 改动内容

1. **修复 `himax_lock()` / `himax_unlock()` 的中断使能不对称**
   `himax_lock()` 走 `himax_quiesce_irq()`（`disable_irq_nosync()` + `synchronize_irq()`），
   而 `himax_unlock()` 只 `mutex_unlock()`、**从不 `enable_irq()`** ⇒ 任何一次 sysfs 访问都会把触屏
   中断永久屏蔽，直到下一次完整重初始化。修复方式：进入临界区时保存中断使能状态，退出时按
   `irq_resume && panel_enabled && !idle_active && !shutting_down` 恢复。
   **该缺陷继承自社区驱动，r1 与 r2 已发布内核都带**；日常使用不易察觉，因为面板
   prepared→enabled 之后必然跟一次 `himax_hw_reinit()` 会把中断重新打开。

2. **可选空闲策略（中断门控采样）**
   连续 `idle_enter_frames`（默认 **7200 帧 ≈ 60 s @120 Hz**）无触点后 `disable_irq()`，
   之后每 `idle_poll_ms`（默认 **30 ms**）**只放行一帧**走正常中断路径；中断线程在该帧上跑完整算法，
   检出**已上报的触点**（`algo->touch_active`）就恢复中断模式，否则再次屏蔽并重排 work。
   默认启用，`idle_enter_frames=0` 可完全关闭。

3. **诊断节点**（`frame` / `irq_gate` / `regs` / `idle_state` / AFE 回读日志）
   仅在 r3-dev 诊断内核里用于取证；`regs`（裸 AHB 读写）受 `allow_raw_ahb` 门控、默认关闭。

## 实测收益（GK-W76，面板点亮、无人触摸）

| 指标 | 修复前/策略关闭 | r3 策略 | 改善 |
|---|---|---|---|
| 触屏 IRQ 速率 | **120.0 Hz** | **22.9 Hz** | −81% |
| 触屏 kthread CPU | **2.00%**（单核） | **0.50%**（单核） | −75% |
| 首触延迟 | 一帧 ≈8.3 ms | ≈ 采样周期 30 ms + 一帧 | 真手指实测通过 |

**唤醒路径已用真手指验证**：策略开启后点按屏幕，`dmesg` 出现
`idle exit: touch after 30ms sampling`，随后松手 7200 帧再次进入空闲。

## 两个反直觉的实测结论（避免后来者重复踩坑）

- **屏蔽主机中断并不会让 IC 停扫**：屏蔽期间直接读 event stack 得到的帧数据持续变化，
  解除屏蔽也**不会** IRQ storm、**不需要**芯片重初始化。这条是"纯主机侧空闲策略"成立的前提。
- **空闲计数器不能由"原始稳定触点数"复位**：把复位条件写成 `stable_cnt > 0` 时，
  60 s 阈值**永远到不了**（实测 111 s 内 7200 帧都没累积满），因为偶发的单帧噪声会不断清零计时。
  改为**已上报触点**（`touch_active`）后计数单调增长、60 s 准时进入空闲。

## 上游化建议

第 1 项（中断使能不对称）与空闲策略**互相独立**，适合拆成两个提交分别上游化；
提交信息里应带上本目录的实测数据，尤其是"屏蔽中断不影响 IC 扫描"这一条——它决定了这个策略
值不值得做（否则只能靠 AFE `0x0A` 停扫，代价是唤醒必须付 30–50 ms 重初始化）。
