# Kernel 7.2.5 (EL1) VENUS r3 — `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3`

> 目标设备：**HUAWEI MateBook E Go 2022 性能版（GK-W76 / SC8280XP / 设备树 `gaokun3`）**
> 发布标签：`kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3-20260913`
> 基线：**kernel.org stable `v7.2.5`** + 本项目自有补丁
> 上一版：[r1](https://github.com/aoripus/easy-for-gaokun/releases/tag/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913)

**本版主题：触屏"幽灵中断"治理 + 一个真实驱动缺陷的修复。**
修完缺陷后重新实测，才发现此前一轮（内部 r2）的结论是**测量假象**——详情见
[`docs/touch-idle-policy.md`](../touch-idle-policy.md)。

---

## 1. r3 相对 r1 改了什么

| # | 变更 | 说明 |
|:-:|------|------|
| 1 | ★ **修复 `himax_lock()`/`himax_unlock()` 中断使能不对称** | `himax_lock()` 会 `disable_irq_nosync()` + `synchronize_irq()`，而 `himax_unlock()` **从不 `enable_irq()`** ⇒ **任何一次 sysfs 访问都会把触屏中断永久屏蔽**，直到下一次完整重初始化。修复：进入临界区记录使能状态，退出时按 `irq_resume && panel_enabled && !idle_active && !shutting_down` 恢复。**该缺陷继承自社区驱动，r1 也带**（日常使用不易察觉：面板 enabled 之后必然跟一次重初始化会把它重新打开；但一次 `inplace_reset`/算法参数写入就会让触屏"死掉"） |
| 2 | ★ **新增可选空闲策略：中断门控采样** | 连续 **7200 帧（≈60 s @120 Hz）** 无**已上报**触点后 `disable_irq()`，随后每 **30 ms** 只放行**一帧**走正常中断路径判断有无触点；检出触点立刻恢复中断模式。默认启用，`idle_enter_frames=0` 可关闭 |
| 3 | **诊断节点**（供排障/复现） | `frame`（不依赖中断地读一帧并返回校验和）、`idle_state`（空闲策略状态）、`irq_gate`、`regs`（裸 AHB 读写，受 `allow_raw_ahb` 门控、默认关闭）、AFE 回读日志 |
| 4 | **AFE 邮箱队列初始化** | 按 Windows 运行时的做法，芯片初始化后清零 5 个命令槽并把 host 写指针 `0x1000753C` 置 0 |

**未变的部分**：venus 硬解路径、`qcom,force-gsi-mode`（GSI/DMA）、触屏 SPI 驱动与 `gpio174` 拉低、
DSC/面板/EC/音频等板级补丁、EL1 启动级别、`CONFIG_VIDEO_QCOM_VENUS=m` + `# CONFIG_VIDEO_QCOM_IRIS is not set`。

---

## 2. 实机验证（2026-09-13）

装机方式：`scripts/gk-install-kernel.sh` **只新增一个 BLS 条目**，
`loader.conf` 的 `default` 与 EFI 变量均未改动（一次性 `bootctl set-oneshot`）。

| 项 | 结果 |
|---|---|
| 启动级别 | `CPU: All CPU(s) started at EL1` ✅ |
| 内核串 | `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3`（**无 `+`**）✅ |
| 视频硬解 | venus decoder + encoder ✅ |
| 触屏 | `Himax Capacitive TouchScreen`，驱动正常绑定 ✅ |
| KVM | 无 `/dev/kvm`（**EL1 的固有代价**，与硬解互斥） |

### 2.1 ★ 空闲策略实测（面板点亮、无人触摸）

| 指标 | r1 行为 | **r3** | 改善 |
|---|---:|---:|---|
| 触屏 IRQ 速率 | **120.0 Hz** | **22.9 Hz** | **−81%** |
| 触屏 kthread CPU | **2.00%**（单核） | **0.50%**（单核） | **−75%** |
| 空闲时 IC 是否仍扫描 | 是 | 是（未改变） | — |
| 首触延迟 | 一帧 ≈8.3 ms | ≈ 采样周期 30 ms + 一帧 | **真手指实测通过** |

**触发时序已用 `idle_state` 逐秒核对**：模块加载后计数单调增长（≈120 帧/秒），
**60 s 时准时进入空闲**并稳定保持（`active=1`，采样按 30 ms 节奏开合，无振荡）。

**唤醒路径已用真手指验证**（在携带同一退出路径的 r3-dev 构建上）：点按屏幕后 `dmesg` 出现
`idle exit: touch after 30ms sampling`，触点由正常中断路径上报；松手 7200 帧后重新进入空闲。
r3 装机后的复核结果见 §2.4。

### 2.4 r3 装机复核（2026-09-13）

（装机后填写：`uname -r` / EL1 / venus / 触屏绑定 / `idle_state` 60 s 进入空闲 / 触摸唤醒）

### 2.2 ★ 为什么不采用"让 IC 自己睡"（AFE `0x0A`）

修好中断屏蔽缺陷后，AFE 邮箱语义第一次被测准（详见 `docs/touch-idle-policy.md` §4）：
`0x0A/0x00` **确实**让 IC 停扫（帧数据全 0、IRQ 0.3 Hz），`0x0E/0x00` **确实**能把它重新唤醒；
但 IC 停扫期间主机**读不到帧**，也就无从判断"手指来了没有"，唤醒只能靠定时盲发或完整重初始化
（30–50 ms）。因此本版选择**只屏蔽主机中断、让 IC 继续扫描**：
收益是撤销了 81% 的中断与 75% 的空闲 CPU，代价只有约一个采样周期，**不需要任何芯片重初始化**。

### 2.3 已知取舍

- 空闲时 IC 自身仍在以 120 Hz 扫描（**IC 侧功耗未降低**）；若要压这部分功耗，需要另行设计
  "AFE 深睡 + 盲唤醒"策略并接受 30–50 ms 首触延迟，本版有意不做。
- `regs`（裸 AHB 读写）是取证用节点，默认关闭且不建议在正常使用中打开。

---

## 3. 产物（8 项，与 r1 同名同结构）

| 文件 | 大小 |
|---|---|
| `Image` | 24,734,208 B |
| `modules-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3.tar.zst` | 6,502,281 B |
| `sc8280xp-huawei-gaokun3.dtb`（EL1 用） | 170,672 B |
| `config-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3` | 209,239 B |
| `System.map-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3` | 4,711,028 B |
| `gaokun3-7.2.5-el1.patch`（本项目相对 mainline v7.2.5 的完整补丁） | 178,960 B |
| `sha256sums.txt` / `BUILD-PROVENANCE.md` | — |

驱动增量部分另有独立可审阅补丁：
[`patches/touch-idle/`](../../patches/touch-idle/README.md)（+481 / −92 行）。

## 4. 安装与回滚

```sh
# 安装（只新增 BLS 条目，不动默认项）
sudo scripts/gk-install-kernel.sh --image Image --dtb sc8280xp-huawei-gaokun3.dtb \
     --modules modules-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3.tar.zst --tag r3 --oneshot
# 回滚
sudo scripts/gk-install-kernel.sh --uninstall --tag r3
```

运行时若需临时关闭空闲策略：`echo 0 | sudo tee /sys/module/himax_hx83121a_spi/parameters/idle_enter_frames`
（采样周期可调：`idle_poll_ms`）。
