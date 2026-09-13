# Kernel 7.2.5 (EL1) VENUS r1 — `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1`

> 目标设备：**HUAWEI MateBook E Go 2022 性能版（GK-W76 / SC8280XP / 设备树 `gaokun3`）**
> 发布标签：`kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913`
> 基线：**kernel.org stable `v7.2.5`** + 本项目自有补丁（23 个文件，+4524 / −196）

**这是本仓库改名后的第一个内核产物（新命名规范自 `r1` 起生效）**，
也是第一个把「触屏 QUP-SPI 强制走 GSI（DMA）模式」合入的内核。

---

## 1. r1 相对 r0（`7.2.5-aoripus-ml-gaokun-eog-el1+`）改了什么

| # | 变更 | 说明 |
|:-:|------|------|
| 1 | **新增 2 条补丁：SPI 强制 GSI 模式** | Pengyu Luo 的 v1 系列（binding + driver），见 [`patches/spi-gsi/`](../../patches/spi-gsi/README.md)。本机 DTS **早已写了** `qcom,force-gsi-mode`，但 v7.2.5 的驱动不读它，因此此前一直静默退回 **FIFO 模式** |
| 2 | **内核串改用新命名规范** | `…-gaokun3-eog-el1-venus-r1`（新增设备树代号 `gaokun3`、启动级别、VPU 驱动线、修订号四个字段） |
| 3 | **内核串不再带尾部 `+`** | 构建时移开 `.git`（`scripts/setlocalversion` 在 git 树里必然追加 `+`，`CONFIG_LOCALVERSION_AUTO=n` **挡不住**）—— 这是 r0 串 `…-el1+` 那个 `+` 的来源，也是 r0 串**不可复现**的原因 |
| 4 | **移除 I²C-HID 变体产物** | 该路线在 GK-W76 上实测枚举不出来（见 r0 说明与 `AGENTS.md` §7.11），本版不再产出 `…-i2c.dtb` |

**未变的部分**：venus 硬解路径、触屏 SPI 驱动与 `gpio174` 拉低、DSC/面板/EC/音频等板级补丁、
EL1 启动级别、`CONFIG_VIDEO_QCOM_VENUS=m` + `# CONFIG_VIDEO_QCOM_IRIS is not set`。

---

## 2. 实机验证（2026-09-13）

装机方式：`scripts/gk-install-kernel.sh` **只新增一个 BLS 条目**，
`loader.conf` 的 `default` 与 EFI 变量均未改动（一次性 `bootctl set-oneshot`）。

| 项 | 结果 |
|---|---|
| 启动级别 | `CPU: All CPU(s) started at EL1` ✅ |
| 内核串 | `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1`（**无 `+`**）✅ |
| 视频硬解 | `Qualcomm Venus video decoder`（本次开机为 `/dev/video32`）+ encoder ✅ |
| 触屏 | `Himax Capacitive TouchScreen` on `event11`，驱动正常绑定，`gpio174` 输出低 ✅ |
| KVM | 无 `/dev/kvm`（**EL1 的固有代价**，与硬解互斥） |

### 2.1 ★ GSI 模式生效判据（空闲 20 s 窗口、无人触摸、两次采样取增量）

| 中断线 | r0（FIFO 模式） | **r1（GSI 模式）** |
|---|---|---|
| `998000.spi`（GENI SE） | +6,206 | **0** |
| `gpi-dma` | 无此行（= 0） | **+4,803** |
| `msmgpio 175`（触屏 IC） | +2,397 | +2,401 |

⇒ ① **GSI 确实生效**：GENI SE 中断恒为 0，传输完成改由 GPI DMA 中断报告
（约 2 次 DMA 中断 / 次触屏中断，即一次传输的 TX+RX 完成）；
② 每次触屏中断对应的 **SPI 完成中断数从 ≈2.59 降到 ≈2.00（约 −23%）**；
③ 逐字 FIFO 处理被 DMA 取代。

### 2.2 ★ 一处结论更正（重要，请与 r0 的说明一并阅读）

r0 的发布说明里把 `tools/gk-touch-bench.py` 报出的「**每帧 15.39 个触屏 IRQ**」
归因于"SPI 退回 FIFO 模式"。**这不成立。**

那条 IRQ 是**触屏 IC 的中断线**（`msmgpio 175 / himax-spi-ts`），
与 SPI 控制器的 GENI SE 中断是**两条完全不同的线**。实测已证明：
**触屏 IC 自身的中断速率在 r0 与 r1 上完全一致（约 120 次/秒）**。

⇒ **`irq_per_frame` 不会因为 GSI 而下降** —— 它是 IC/驱动交互的行为，不是 SPI 模式问题。
GSI 的真实收益是"减少 SPI 完成中断 + 改用 DMA"，**不是**解决上述那个 15.39。

### 2.3 顺带发现（r0 与 r1 皆有，**非本版引入**）

**无人触摸时，触屏 IC 仍以约 120 次/秒触发中断，却不产生任何输入事件**（"幽灵中断"）。
45 秒空闲窗口内实测：触屏 IRQ +10,788、输入事件 **0**。
这条已记入下一轮待办（怀疑与 `sense on` 常开或 INT 未正确清除有关）。

---

## 3. 未完成 / 未验证（请勿据此过度推断）

| # | 项 | 状态 |
|:-:|----|------|
| 1 | **滑动状态下的报点率 / 帧间隔分布 A/B**（r0 vs r1） | **未测**。测量时无人触摸屏幕，基准脚本等待首次触摸超时（0 帧）。r0 的基线数据仍有效：帧间隔中位 8.328 ms、p95 9.38 ms、每帧 3.99 个触点、CPU 忙 15% |
| 2 | GSI 对 CPU 占用与延迟的实际影响 | **未量化**（空闲时 CPU 忙仅 1.1%，两种模式无差别） |
| 3 | Chromium `V4L2VideoDecoder` 复核 | 未做 |
| 4 | 热管理（75 °C 节流）、音频 UCM | 仍未纳入本内核配套 |

---

## 4. 产物清单

| 文件 | 大小 (B) | SHA-256 |
|---|---|---|
| `Image` | 24,734,208 | `955153d431d6d4ab4faae1d5bf39c392ed4cd851226edb1635b1b92dc9f2abce` |
| `sc8280xp-huawei-gaokun3.dtb` | 170,672 | `b16eef32b7f6d10ea0a3161931f708c1916cf512d20575f48bdd07e148ab49e0` |
| `modules-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1.tar.zst` | 6,497,342 | `ea98f206313d2fe20f0e3bfc0b005bedc07a1770db8bda87c98d62263aeb5e36` |
| `config-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1` | 209,239 | `1413ba3f2bbec2a27b24d82ba0300eaf455ad9d0ee58792739bbd875ae5d731f` |
| `System.map-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1` | 4,711,028 | `17eee7e42c22376394321810f424b1acdfb8043d076d1b1f813c7d6e5e2418b7` |
| `gaokun3-7.2.5-el1.patch` | 160,550 | `72de3cefe2151cd1b95fb97d11e6bb7cf9a92709657c86a159c5c03f17877f5c` |
| `BUILD-PROVENANCE.md` | 1,410 | `0ebb25df57b54c47b25f94d88005984a5cb470351b55a38c687ec7105e018766` |
| `sha256sums.txt` | 700 | — |

- 模块包含 **360** 个 `.ko`。
- `gaokun3-7.2.5-el1.patch` 是**本项目相对 mainline v7.2.5 的完整自有补丁**
  （23 个文件，+4524 / −196），可直接 `git apply` 到 `linux-7.2.5` 复现。
- 上游源码：<https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.5.tar.xz>（160,133,944 B）。
- 完整配方与门禁：<https://github.com/aoripus/easy-for-gaokun/blob/main/docs/kernel-7.2.5-el1-build.md>。

---

## 5. 安装

```bash
# 在已装好本基线系统的 GK-W76 上（EL1 DTB，进入 EL1 启动级别）
sudo ./scripts/gk-install-kernel.sh \
  --kver 7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1 \
  --image Image \
  --dtb sc8280xp-huawei-gaokun3.dtb \
  --modules modules-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1.tar.zst \
  --oneshot
```

脚本只**新增** BLS 条目，不改 `loader.conf`、不动 EFI 变量；`--uninstall --kver …` 一键回滚。

> EL1 与 EL2 的差别**只是条目里 `devicetree` 指向哪一份 DTB**（`…-gaokun3.dtb` ↔ `…-gaokun3-el2.dtb`），
> `slbounce` 会按 DTB 嗅探自行决定。**切勿**通过移除 `EFI/systemd/drivers/` 下的
> slbounce/qebspil 来"切到 EL1"——那会破坏 Secure Launch 导致黑屏挂死（本项目已实测踩坑）。

---

## 6. 风险声明

- **EL1 下没有 `/dev/kvm`**：本版为硬解走 EL1，虚拟化加速不可用，二者当前互斥。
- **本机型没有 EDL / 9008 救援通道**：刷写前务必保留可用启动项。
- **GSI 模式的前置条件**：需要 `CONFIG_QCOM_GPI_DMA=m` 且 GPI DMA 节点 `status = "okay"`、
  SPI 节点有 `dmas`/`dma-names`。本机已满足；其他机型不保证。
- 上游补丁属 Pengyu Luo 的 v1 系列（**未被上游合入**，其 v2 已被作者本人撤回）。
- 内核源码为 GPL-2.0；本仓库为 GPL-2.0-only。
