# Kernel 7.2.5 (EL1) VENUS r4 — `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r4`

> 目标设备：**HUAWEI MateBook E Go 2022 性能版（GK-W76 / SC8280XP / 设备树 `gaokun3`）**
> 发布标签：`kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r4-20260915`
> 基线：**kernel.org stable `v7.2.5`** + 本项目自有补丁（`gaokun3-7.2.5-el1.patch`）
> 上一版：[r3](https://github.com/aoripus/easy-for-gaokun/releases/tag/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3-20260913)

**本版主题：GPU 遥测。** 把 msm 驱动里**本来就有**的 GPU 数据（使用率 / 显存占用 / 时钟 / 温度）
暴露到系统监视器（GNOME Resources 等）真正去读的路径上，并修掉一个**应用侧 glob 缺陷**造成的连锁失效。
本版**不含**待机功耗修复（仍在查，见 §8）。

---

## 1. 问题：GPU 页四项全是"不可用"

用户看到的界面里，显卡的**使用率、频率、功耗、温度**全部不可用。查下来是**两层**原因，缺一层都修不好：

| 层 | 原因 |
|---|---|
| 内核侧 | msm 驱动从不注册 hwmon，也没有 `gpu_busy_percent`（全树只有 amdgpu 有）。数据都在驱动里，只是没有对外暴露。 |
| **应用侧** | `resources` 找 hwmon 用的是 glob **`card?/device/hwmon/hwmon?`** —— **单个 `?` 只匹配一个字符**，所以只能匹配 `hwmon0…hwmon9`。本机 hwmon 索引是 **15**（`/sys/class/hwmon` 共 26 个）⇒ `first_hwmon_path: None`，走 hwmon 的温度/时钟/功耗**永远拿不到**；只有走 `gpu_busy_percent` 的使用率是好的。 |

应用侧那条是**通用缺陷**：任何 hwmon 数量 ≥10 的机器（大量笔记本都是）都会踩到，**与 msm 无关**。
证据是应用自己的 trace（`RUST_LOG=trace`，注意它是单实例应用，必须先退出再启动才会打日志）：

```text
TRACE resources::utils::gpu > Gathered GPU data for 1: GpuData { usage_fraction: Some(0.1),
      used_vram: None, clock_speed: None, temperature: None, power_usage: None, ... }
TRACE resources::utils::gpu > OtherGpu { ..., first_hwmon_path: None }
```

## 2. 本版做了什么（`patches/gpu-telemetry/`，6 文件 / +346 行）

在 **`card?/device` 指向的那个设备**上（对 msm 就是支撑 DRM 实例的平台设备，与 amdgpu/i915/xe 的落点一致）：

| 新增 | 数据来源 | 说明 |
|---|---|---|
| `gpu_busy_percent` | devfreq **已经在算**的 GMU busy/total（a6xx 读 `POWER_COUNTER_XOCLK_0`，19.2 MHz 基准） | 累积到 **500 ms 窗口**再发布（devfreq 单次采样只有 50 ms，对 1 Hz 的消费者噪声太大）；**不在 sysfs 读路径上读寄存器**，GPU 挂起时归零 |
| `mem_info_vram_used` | `priv->total_mem` —— msm 为 `gpu_mem_total` tracepoint 维护的真实 GEM 计数器 | 纯计数器读取，不碰硬件 |
| hwmon `temp1_input` | thermal zone `gpu-thermal`（每次读时按名字解析，tsens 可能比 msm 晚 probe） | 走 `hwmon_temp` 正规通道 |
| hwmon `freq1_input` | GPU 核心时钟（devfreq，含 idle 影子频率），单位 **Hz** | 内核 hwmon **没有频率传感器类型**，只能走 `extra_groups` 的 `SENSOR_DEVICE_ATTR_RO`（amdgpu/radeon 同法） |
| `hwmon0 -> hwmonN` **兼容别名** | `sysfs_create_link(hwmon->kobj.parent, &hwmon->kobj, "hwmon0")` | 专门为绕开上面那个应用 glob 缺陷；由 `devres` 管理，在 hwmon 注销前自动删除；`/sys/class/hwmon/*` 与真实 `hwmonN` 条目都不受影响。**上游把 glob 改成 `hwmon*` 之后这一项应当删掉** |

**sysfs 不允许用户态创建符号链接**（`ln -s` 直接 `Permission denied`），所以这个别名只能在内核里做 —— udev 规则/启动脚本都做不到。

## 3. 实测（GK-W76 / SC8280XP / Adreno 690 / 真机装机复测）

```console
$ ls /sys/class/drm/card1/device/hwmon/
hwmon0 -> hwmon15
hwmon15

$ cat /sys/class/drm/card1/device/hwmon/hwmon0/{name,temp1_input,freq1_input}
msm_gpu
34200                      # 34.2 °C，与 thermal zone0 gpu-thermal 一致
270000000                  # 270 MHz，与 /sys/class/devfreq/3d00000.gpu/cur_freq 一致

$ cat /sys/class/drm/card1/device/{gpu_busy_percent,mem_info_vram_used}
0                          # 桌面空闲；施加 GPU 负载时上升（另一轮实测 1–2 → 8）
242061312                  # 230.8 MiB（GEM 当前占用）

$ cat /sys/class/devfreq/3d00000.gpu/trans_stat | head -3     # 270↔547↔690 MHz 正常调频
```

同一时刻应用的 trace：

```text
Found hwmon at "/sys/class/drm/card1/device/hwmon/hwmon0"
OtherGpu { ..., first_hwmon_path: Some("/sys/class/drm/card1/device/hwmon/hwmon0") }
GpuData { usage_fraction: Some(0.0), used_vram: Some(244924416),
          clock_speed: Some(547000000.0), temperature: Some(34.2), ... }
```

⇒ **使用率、显存占用、GPU 时钟、温度四项全部有值**（时钟那一刻是 547 MHz，说明拿到的是真实调频值而不是 OPP 下限）。

## 4. 仍然显示"不可用"的项目（照实说明，不伪造）

| 界面项 | 原因 |
|---|---|
| 功耗 / 最大功耗 | 本机**没有任何 GPU 功耗/电流传感器**：EC hwmon 只有 20 路温度，电池 hwmon 只有**整机**侧 `curr1_input`，PMIC ADC 只有温度通道，调节器只报电压；设备树 GPU OPP 用 `opp-level`（RPMH 档位）而非 `opp-microvolt`，也没有 `dynamic-power-coefficient` ⇒ **连上游 devfreq-cooling 的标准功率模型都无法估算**。编一个数字比显示 N/A 更糟 |
| 显存频率 | UMA，没有独立显存时钟（GPU 侧只有 `gfx-mem` interconnect 带宽投票） |
| 显存总量 | UMA 没有"显存容量"这个物理量；`mem_info_vram_used` 给的是**当前被 GEM 占用的内存** |
| 视频编码器/解码器占用 | `resources` 对非 AMD/Intel/NVIDIA 显卡未实现该读取（应用侧限制，非本机缺失） |
| 制造商 / PCI 插槽 / 接口 | msm 的卡设备是**平台设备**，没有 `PCI_ID`/`PCI_SLOT_NAME`；伪造一个出来属于造假，不做 |

## 5. 资产

| 文件 | 大小 (B) | SHA-256 |
|---|---|---|
| `Image` | 24,734,208 | `53fc53fcd1db4b620c84b0aa5a235f0d0334c58ae36a738494850e4c5172483a` |
| `modules-7.2.5-…-r4.tar.zst` | 6,506,204 | `950c629935ec98b900d860715d8d10ede100a3837733fc6adbaa4137df5bf80b` |
| `sc8280xp-huawei-gaokun3.dtb` | 170,672 | `b16eef32b7f6d10ea0a3161931f708c1916cf512d20575f48bdd07e148ab49e0` |
| `System.map-7.2.5-…-r4` | 4,711,073 | `564063e87743768ddde6e1cb9c8b4ca769365fb9cc923efcb785e8d3291b89da` |
| `config-7.2.5-…-r4` | 209,239 | `3749cf333d1a5b8751925b49d94fc2c89ee7dfcd4d2c13b1798c852f4bb9fea2` |
| `gaokun3-7.2.5-el1.patch` | 192,322 | `d53a86a4e83e50267db2fe0cfc826965d528b91a8b919d568cb6c2ced96f73e9` |
| `BUILD-PROVENANCE.md` | 3,287 | `effd3b96244566800db97bea7e08c5bef679dcf5ff415db4119760c4aaf52de4` |
| `sha256sums.txt` | 707 | — |

`sha256sum -c sha256sums.txt` 可一次校验全部资产。

## 6. 安装 / 回滚

用仓库脚本安装（**只新增 BLS 条目**，不动 `loader.conf` 默认项、不碰 EFI 变量）：

```sh
sudo ./scripts/gk-install-kernel.sh \
  --kver 7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r4 \
  --image ./Image --dtb ./sc8280xp-huawei-gaokun3.dtb \
  --modules ./modules-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r4.tar.zst \
  --oneshot
sudo ./scripts/gk-install-kernel.sh --kver 7.2.5-…-r4 --uninstall   # 回滚
```

> **本版顺带修掉一个真机踩坑**：模块包内含 `lib/modules/<ver>/…` 前缀（便于 `tar -C /` 手动展开），
> 而安装脚本此前只归一化 `<ver>/<ver>` 形态 ⇒ 展开后目录嵌套、`depmod` 找不到 `modules.order`、
> initrd 缺模块，脚本只打印一句警告就继续。现在**两种形态都归一化**，并在真机上用同一个 tar 包重跑验证过。

内核串**无尾部 `+`**（`CONFIG_LOCALVERSION_AUTO` 已关且构建时移开 `.git`）⇒ 一份逻辑源码只派生一个串。

## 7. 复现

源码、补丁集、配置、工具链与逐条命令见随包 **`BUILD-PROVENANCE.md`**；摘要：

```sh
tar xf linux-7.2.5.tar.xz && cd linux-7.2.5
patch -p1 < gaokun3-7.2.5-el1.patch
cp config-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r4 out/.config
make O=out ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig
make O=out ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j16 Image modules dtbs
```

工具链：`aarch64-linux-gnu-gcc (Debian 12.2.0-14) 12.2.0`、GNU Make 4.3、binutils 2.40。

## 8. 已知问题与下一步

- ★ **待机功耗仍未修**（本版不含）：实测挂起**根本留不住** —— ①VPU 被占用时挂起失败
  （`qcom-venus: wait for cpu and video core idle fail (-110)`，且失败会把 DPU 打死成黑屏）；
  ②VPU 空闲时挂起只活 2–3 秒就被 **PDC 上的唤醒 IRQ**（`dp_hs_phy_3` 等）拉醒。
  这解释了"待机一夜掉电 70%"：机器其实是**醒着、屏灭**。修复随 **r5**。
- **开机动画**（居中 LOGO + 左下角三行滚动启动输出）在做，做完随下一版发。
- **EL1 的固有权衡**：本版是 EL1（硬解 venus 需要），因此**没有 `/dev/kvm`**。
- 视频编解码器占用等 N/A 项的说明见 §4；GPU 页的功耗项**不会**在后续版本里出现，除非硬件有传感器。

## 9. 许可

内核为 **GPL-2.0**。本产物是 Linux 内核的二进制分发，对应源码可由上游 tag + 随包补丁 + 本仓库脚本完整复现
（见 `BUILD-PROVENANCE.md`），满足 GPL-2.0 的源码提供要求。本项目自有改动同以 GPL-2.0 发布。
