# 触屏基准原始数据：r0（FIFO）vs r1（GSI）— 2026-09-13

本文件是 [`docs/releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913.md`](../releases/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913.md)
与 [`docs/kernel-7.2.5-el1-build.md`](../kernel-7.2.5-el1-build.md) 中数值的**原始证据**。

## 1. 条件

| 项 | 值 |
|---|---|
| 工具 | `tools/gk-touch-bench.py`（仓库内同一支脚本） |
| 命令 | `python3 gk-touch-bench.py --seconds 45 --wait-timeout 900 --json <out>` |
| 设备 | `/dev/input/event11`（`Himax Capacitive TouchScreen`） |
| 环境 | 同一台 GK-W76、同一块内屏、室温；以 root 运行（否则无权读 `/dev/input/event11`） |
| 操作 | 用户按住屏幕**匀速来回划**；脚本从**检测到首个触摸帧**才开始计时 |
| r0 内核 | `7.2.5-aoripus-ml-gaokun-eog-el1+`（SPI 走 FIFO 模式） |
| r1 内核 | `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1`（SPI 走 GSI/DMA 模式） |

## 2. 原始 JSON（逐字节照抄工具输出）

**r0（FIFO）**

```json
{"label": "spi6", "device": "/dev/input/event11", "device_name": "Himax Capacitive TouchScreen", "seconds": 44.99852197400003, "requested_seconds": 45.0, "frames": 1413, "rate_hz": 31.4, "gap_ms": {"median": 8.328, "p95": 9.38, "p99": 32.808, "max": 29027.855}, "long_gaps": 22, "ev_abs": 5634, "ev_key_btn_touch": 19, "pts_per_frame": 3.99, "irq_delta": 21746, "irq_per_frame": 15.39, "cpu_busy_pct": 14.97}
```

**r1（GSI）**

```json
{"label": "r1-gsi", "device": "/dev/input/event11", "device_name": "Himax Capacitive TouchScreen", "seconds": 41.35617682399993, "requested_seconds": 45.0, "frames": 4017, "rate_hz": 97.13, "active_seconds": 33.663, "rate_active_hz": 119.3, "gap_ms": {"median": 8.329, "p95": 9.523, "p99": 10.267, "max": 5534.405}, "long_gaps": 15, "ev_abs": 15860, "ev_key_btn_touch": 12, "pts_per_frame": 3.95, "irq_delta": 14293, "irq_per_frame": 3.558, "cpu_busy_pct": 5.56}
```

> r0 那次用的是旧版脚本，**没有** `active_seconds` / `rate_active_hz` 字段（这两个字段是本项目
> 在发现"用户中途松手会污染统计"之后才加上的，见 `AGENTS.md` §7.11）。

## 3. r1 滑动窗口内的中断线增量（`/proc/interrupts` 前后各采样一次）

| 中断线 | 滑动前 | 滑动后 | 增量 |
|---|---|---|---|
| `209 gpi-dma`（GPI DMA 控制器） | 153,125 | 181,831 | **+28,706** |
| `237 998000.spi`（GENI SE） | 0 | 0 | **0** |
| `322 msmgpio 175`（触屏 IC `himax-spi-ts`） | 76,307 | 90,609 | **+14,302** |

⇒ **整个滑动过程中 GENI SE 中断恒为 0**，SPI 传输完成全部由 GPI DMA 报告；
DMA/触屏 ≈ 2.0（一次传输一对 TX/RX 完成中断）。**GSI 在负载下同样生效。**

## 4. 读数注意（两处相反的偏差，必须一起看）

r0 那次的 45 s 窗口内**含一段约 29 s 的松手停顿**（`gap_ms.max = 29027.855`，`long_gaps = 22`），
r1 那次的窗口内停顿只有约 7.7 s（`active_seconds = 33.663`）。这造成两处**方向相反**的偏差：

| 指标 | 偏差方向 | 影响 |
|---|---|---|
| `irq_per_frame` | r0 被**高估** | 空闲时触屏 IC 仍以约 120 次/秒触发中断（"幽灵中断"，r0/r1 皆有），这 29 s 的 3,000+ 次中断被算进了"每帧"分母不变、分子变大 |
| `cpu_busy_pct` | r0 被**低估** | 空闲段 CPU 占用仅约 1%，把 r0 的窗口平均值拉低了 |

**扣除空闲段的估算**【估算，非实测】：以空闲约 120 次/秒为基线扣除——

- r0：`(21,746 − 29.5 s × 120) / 1,413 ≈ **12.9**` 次中断/帧
- r1：`(14,293 − 7.7 s × 120) / 4,017 ≈ **3.33**` 次中断/帧
- ⇒ 更公平的降幅约 **−74%**（原始读数给出的是 −77%）
- CPU：r1 滑动段内约 `(5.56% × 41.36 − 7.7 × 1.17%) / 33.663 ≈ **6.6%**`；
  r0 的真实滑动段占用**高于**其窗口均值 14.97% ⇒ 保守地说，"CPU 占用至少降到 1/2.7"。

**报点率与帧间隔分位数不受此影响**（它们只看帧间隔），可直接比较：
中位 8.328 → 8.329 ms、p95 9.38 → 9.523 ms（持平）；p99 32.808 → 10.267 ms（−69%）。

## 5. 复现

```bash
# 在目标机上（root）
python3 tools/gk-touch-bench.py --seconds 45 --wait-timeout 900 --json /var/tmp/bench.jsonl
# 中途：/proc/interrupts 前后各取一次，关注 gpi-dma / 998000.spi / msmgpio 175 三行
```

若要做**完全对齐**的 A/B（两边窗口内的停顿长度一致），需要把 r0 条目用同一版脚本再跑一次 ——
本文件记录的是当前可得的最好数据，差异方向已在上表说明，不影响结论方向。
