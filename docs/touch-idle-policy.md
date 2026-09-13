# 触屏空闲中断（"幽灵中断"）治理笔记

> 设备：HUAWEI MateBook E Go 2022 性能版（GK-W76，SC8280XP，DT `gaokun3`）
> 触屏：Himax **HX83121A** 级联 IC，SPI（`spi0.0`），树外驱动 `himax-spi-core.c`
> 内核：`7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3`（mainline stable 7.2.5 + 本项目补丁）
> 标注约定：**【已核实】** = 本项目在本机实测或读到一手源码；**【推测】** = 尚未验证。
> 原始数据：`docs/bench/touch-bench-20260913.md`

---

## 0. 结论摘要（TL;DR）

1. **空闲时触屏中断 119 Hz、每帧一次、占单核 1.8–2.0% CPU**，不是固件配错，而是**架构必然**：
   HX83121A 在本驱动里**只当传感器**（上报 40×60 原始电容网格），**触控判定全部在主机**，
   IC 不可能知道"有没有手指"，因此必须每帧都上报。【已核实】
2. **治理方案（r3）＝中断门控采样**：连续 N 帧无触点后**屏蔽主机中断**，
   之后每 `idle_poll_ms`（默认 30 ms）**放行一帧**走正常中断路径判断有无触点；有触点即刻恢复中断模式。
   实测：**119.2 Hz → 22.9 Hz，单核 CPU 2.00% → 0.50%**。【已核实】
3. 本机 IC **不需要**任何 AFE 命令参与该策略；屏蔽中断**不会**让 IC 停扫，**解除屏蔽也不会 storm**，
   更**不需要重初始化**（首触延迟 ≈ 采样周期，而不是 30–50 ms 的重初始化）。【已核实】
4. ★ 排障过程中发现**我们自己驱动里的一个真实缺陷**（继承自社区驱动）：
   `himax_lock()` 屏蔽中断而 `himax_unlock()` **从不恢复** ⇒ 任何一次 sysfs 访问都会把触屏中断"打死"。
   这个缺陷先是**污染了两轮空闲模式实验**（把"写 sysfs"误判成"AFE 命令让 IC 停流"），
   现在已在 r3 中修复（保存/恢复中断使能状态）。**r0 / r1 / r2 三个已发布内核都带这个缺陷。**【已核实】

---

## 1. 现象与量化

| 观测 | 数据 |
|---|---|
| 空闲（面板点亮、无触摸）IRQ 速率 | **119.2 Hz**（5 s 窗口 596 次） |
| 空闲 IRQ 间隔 | 中位 **8.323 ms**（p10 8.051 / p90 8.656） |
| 每帧 CPU（kthread） | **149.8 µs**（10 s / 1202 帧，= 单核 1.80%） |
| `gpio175` 电平占空比 | 高 **99.1%**（2 s / 1882 次采样）⇒ INT 是干净脉冲，不是电平常低 |
| 面板熄灭（`dpms=Off`） | IRQ **0**（面板 follower 已正确 `himax_power_down()`） |
| 输入事件 | **0**（驱动每帧跑完整算法，输出空触点） |

⇒ 排除"电平中断自激"（间隔严格锁定 IC 帧周期，而不是线程耗时）。【已核实】

## 2. 根因：IC 只做传感器，触控判定全在主机

- `hx-algo.h` 定义 `HX_ROWS 40` / `HX_COLS 60` / `HX_PIXELS 2400`，注释写明
  *"must match the firmware raw frame layout"*；`hx_preprocess_frame(algo, const u16 *raw)`
  直接吃**原始电容网格**，其后的 baseline / CMF / edge-boost / IIR → 宏区 BFS → 拒掌 → 峰值 →
  质心 → 跟踪 → 去抖**全部由主机 CPU 完成**。
- 驱动每次中断从 `HIMAX_AHB_ADDR_EVENT_STACK` 读 5132 B（`FULL_STACK_SZ`），
  并把 `sorting mode` 写 **0**（关闭 IC 侧排序）⇒ IC 不参与触点判定。

⇒ **"无触点也每帧上报"是该架构的必然结果**，这也解释了为什么社区（`chiyuki0325`、`pgs666`、
`awarson2233` 三个仓库）从未讨论过这个问题。

## 3. ★ 测量陷阱：驱动自身的 IRQ 屏蔽缺陷（两次结论被推翻的记录）

**症状**：在诊断内核上，**任何 sysfs 访问之后触屏 IRQ 恒为 0**，
而写 `inplace_reset=1`（完整重初始化）后立刻恢复 118–120 Hz；
与此同时，我们新增的 `frame` 节点（直接读一帧、返回校验和）显示
**帧数据一直在变化**（`bytes_sum` 550863 → 171224 → 595608 → 524462 → 652472 …）
⇒ **IC 一直在扫描，从未停流**。

**根因（一行代码级）**：

```c
static void himax_lock(struct himax_ts_data *ts)
{
        himax_quiesce_irq(ts);      /* disable_irq_nosync() + synchronize_irq() */
        mutex_lock(&ts->op_lock);
}

static void himax_unlock(struct himax_ts_data *ts)
{
        mutex_unlock(&ts->op_lock); /* ← 从不 enable_irq() */
}
```

⇒ 任何 `himax_lock()`（面板回调、`inplace_reset`、`afe_cmd`、`algo/*` 全部走它）
都会把触屏中断**永久屏蔽**，直到下一次 `himax_hw_reinit()` 里的 `himax_int_enable(true)`。

**为什么前两轮实验被它骗过**：TLMM GPIO 中断控制器（`drivers/pinctrl/qcom/pinctrl-msm.c`）
对**电平**中断在 mask 时会清 `intr_raw_status_bit`，因此屏蔽期间**不会积压**、解屏蔽也**不会 storm**
——"写 sysfs → IRQ 变 0 → 再写一次恢复 118 Hz"这条假象看起来严丝合缝，
于是被误读成"AFE 命令 `0x0A` 让 IC 进空闲、`0x0E` 不能唤醒"。

**修复（r3）**：`himax_lock()` 记录进入前的中断使能状态，`himax_unlock()` 按
`irq_resume && panel_enabled && !idle_active && !shutting_down` 恢复。

**方法教训**：**测量工具本身必须是可信的**。凡"操作 A 之后现象 B 消失"，必须先证明 A 只做了它声称的事；
本轮靠新增的 `frame` 节点（**不依赖中断**的直接读帧通道）才拆穿了假象。

## 4. AFE 邮箱语义实测（r3-dev，面板点亮、无触摸、每段 3–5 s）

前提：AFE 传输层此前**缺少 Windows 同款的队列初始化**（清零 5 个 slot + 写指针 `0x1000753C = 0`），
r3 已补上；下表是补上之后的实测。

| 操作 | IRQ 速率 | 帧数据 | 结论 |
|---|---|---|---|
| 基线 | 120.0 Hz | 持续变化 | 正常流式 |
| **屏蔽主机中断**（`irq_gate`） | 0.0 Hz | **持续变化** | ★ 屏蔽中断**不**影响 IC 扫描 |
| 解除屏蔽 | 118.7 Hz | — | ★ 干净恢复，无 storm、无需重初始化 |
| AFE `0x0E/0x00`（ForceToScanRate） | 119.0 Hz | 持续变化 | **无可观测效果**（IC 本来就是 120 Hz） |
| AFE `0x01/0x00`（StartCalibration） | 119.7 Hz | 持续变化 | 无可观测效果 |
| AFE `0x0A/0x00`（EnterIdle） | **0.3 Hz** | **全 0** | ★ **IC 真的停扫了** |
| 停扫后再发 `0x0E/0x00` | **120.0 Hz** | 恢复变化 | ★ 这才**是真唤醒**（`0x0E` 是"强制扫描率"= 让 IC 重新开扫） |

补充【已核实】：
- AFE 协议**没有 ack**（两个公开实现都直接丢弃 16 B 回读）。本机回读末两字节随命令变化
  （`0x0e`→`4a 75`、`0x0a`→`4e 75`、`0x01`→`57 75`），其余为 0；触发字（`a8 8a cmd 00`）
  有时被固件消费（回读为 0）、有时还在。
- `0x10007088[0]=0x17/0x1f`（FW idle 关/开）等寄存器级候选来自 Google GPL-2.0 vendor 驱动与
  Windows clean-room 两处逐字节一致的常量，但**本机尚未实测**（`regs` 节点当时被门控关闭）。【推测】

## 5. r3 空闲策略：中断门控采样（interrupt-gated sampling）

```
连续 idle_enter_frames 帧（默认 7200 ≈ 60 s）无"已上报触点"
        ↓
idle_active = 1；disable_irq()；每 idle_poll_ms（默认 30 ms）排一次 delayed_work
        ↓
work：idle_sampling = 1；enable_irq()   ← 只放行"一帧"
        ↓
中断线程（正常帧边界读帧 + 完整算法）
        ├─ 检出触点（algo->touch_active）→ idle_active = 0，保持中断模式（结束空闲）
        └─ 无触点 → 再次 disable_irq() + 重排 work
```

**默认值与时序**：`idle_enter_frames = 7200`（≈60 s @120 Hz）、`idle_poll_ms = 30`。
初始版本用 240 帧（≈2 s），**实机体验"不跟手"**——正常阅读/思考的停顿就会让策略进入空闲，
下一次触摸要等一个采样周期；60 s 远超任何交互间隔，因此定为默认。

**★ 计时器复位条件：必须用"已上报触点"，不能用原始稳定触点数。**
第一版把复位写成 `stable_cnt > 0`，结果 **60 s 阈值永远到不了**：实测模块加载后
**111 s 内 7200 帧都没累积满**（`idle_state` 显示计数反复清零），因为偶发的单帧噪声
会不断重启计时。改成只由 `algo->touch_active`（通过去抖、真正上报给输入子系统的触点）复位后，
计数单调增长、60 s 准时进入空闲。**教训：判据要跟"用户看得见的事件"对齐，而不是跟内部中间量对齐。**

**为什么不是"在 work 里直接读帧轮询"**（这是我们的第一版实现，实测失败）：
离开中断上下文读 event stack **与 IC 的帧边界无关**，读到的是撕裂帧，
算法把撕裂帧判成触点 ⇒ 策略在"屏蔽 → 误判触点 → 解除 → 再屏蔽"之间**每 ~2 s 振荡一次**
（实测 IRQ 62 Hz、日志里反复出现 `idle exit: contact`）。改成中断门控后振荡消失。【已核实】

**实测收益**（同一台机器、面板点亮、无触摸、8–20 s 窗口）：

| 指标 | 中断模式（r2 行为） | r3 空闲策略 | 改善 |
|---|---|---|---|
| 触屏 IRQ 速率 | **120.0 Hz** | **22.9 Hz** | −81% |
| 触屏 kthread CPU | **2.00%**（单核） | **0.50%**（单核） | −75% |
| IC 是否继续扫描 | 是 | 是（未改变） | — |
| 首触延迟 | 一帧（≈8.3 ms） | ≈ 采样周期（默认 30 ms）+ 一帧 | **真手指实测通过** |

> 实测 22.9 Hz 而非理论的 33 Hz：work 处理完一帧后才重排下一次，实际周期 ≈ 43 ms。

**唤醒路径已用真手指验证**【已核实】：策略开启（`idle_enter_frames=240`、`idle_poll_ms=30`）后，
用户实际点按屏幕时 `dmesg` 出现

```
himax-spi spi0.0: idle exit: touch after 30ms sampling
…
himax-spi spi0.0: idle: one frame every 30ms after 240 contact-free frames
```

即：采样帧上检出真实触点 → 结束空闲并保持中断模式（触点由正常中断路径上报）→
松手 240 帧（≈2 s）后重新进入空闲。**全程无需 AFE 命令、无需芯片重初始化。**

**边界与回滚**：面板熄灭/点亮、`inplace_reset`、驱动卸载都会取消 work 并清状态；
策略默认关闭（`idle_enter_frames=0`），`idle_poll_ms` 可调；安装/回滚走 `scripts/gk-install-kernel.sh`。

## 6. 未采纳的方案与理由

| 方案 | 为什么没采用 |
|---|---|
| 用 AFE `0x0A` 让 IC 进空闲 | IC 停扫后**帧全 0**，主机轮询**看不见触点**，无法判断何时该唤醒；若要唤醒必须付完整重初始化（30–50 ms） |
| AFE `0x0E/0x00` 作为唤醒手段 | 它**确实**是真唤醒（见 §4），但配合 `0x0A` 使用时仍然解决不了"看不见触点"的问题；且 AFE 传输层无 ack，风险高 |
| 长期 `disable_irq()` | 不轮询就永远收不到触点；且电平中断的解屏蔽语义必须实测（本机已实测：干净，无 storm） |
| 直接降低主机算法开销（跳帧等） | 只能省 CPU 不能省 IC 功耗与中断数，收益小于门控采样 |

## 7. 复现方法

诊断内核（`r3-dev`）新增这些节点，都在 `/sys/bus/spi/devices/spi0.0/`：

| 节点 | 用途 |
|---|---|
| `frame`（RO） | 直接读一帧并返回 `bytes_sum`/`grid16_sum`/前 32 B ⇒ **判断 IC 是否在扫描**（不依赖中断） |
| `idle_state`（RO） | 空闲策略状态：`active` / `sampling` / 已累积的 `frames` / 阈值 / 采样周期 ⇒ **判断"为何还没进空闲"** |
| `irq_gate`（WO） | `echo 1 > irq_gate` 屏蔽中断、`echo 0` 恢复 ⇒ 验证"屏蔽不影响 IC 扫描" |
| `afe_cmd`（WO） | `echo "0a 00" > afe_cmd` 等；`allow_any_afe_cmd=1` 可放开任意 cmd |
| `regs`（WO） | 裸 AHB 读写（`echo "r 10007088 4"` / `echo "w 10007088 17 00 00 00"`），受 `allow_raw_ahb=0` 门控 |
| 模块参数 | `idle_enter_frames`（默认 7200）、`idle_poll_ms`（默认 30）、`afe_log_response`、`afe_skip_trigger`、`afe_skip_readback` |

**注意**：实验期间必须保持面板点亮——`inplace_reset` 在面板熄灭时返回 `-EHOSTDOWN`，
且熄灭本身就会关掉触屏 IRQ，会让所有测量失真。

## 8. 上游化建议

1. **`himax_lock/unlock` 的不对称是一个独立可提交的 bug 修复**，与空闲策略无关，适合单独上游化。
2. 空闲策略本身是通用模式（`disable_irq` + delayed work 采样 + 首帧判定），
   但"是否值得"取决于 IC 是否在屏蔽期间继续扫描——建议在提交信息里写清本机实测数据。
3. AFE 邮箱协议（队列初始化 + 无 ack + `0x0A`/`0x0E` 的实测语义）可以作为
   "HX83121A 空闲模式"的一手资料公开，社区目前没有这份材料。
