# GPU 遥测（使用率 / 时钟 / 温度）

> 本文说明：**为什么系统监视器的 GPU 页会是"全部不可用"**、本项目怎么修、
> 修完的实测取值，以及**为什么功耗一项永远只能是 N/A**。
>
> 相关：[`patches/gpu-telemetry/`](../patches/gpu-telemetry/README.md) ·
> [`docs/kernel-7.2.5-el1-build.md`](kernel-7.2.5-el1-build.md) ·
> [`docs/architecture.md`](architecture.md)

## 1. 现象

在 GK-W76 上打开 **Resources**（`net.nokyan.Resources`，Ubuntu 26.04 自带 `resources 1.10.2`），
显卡页面里 **使用率 / 频率 / 功耗 / 温度** 全部显示为**不可用**。

## 2. 根因：不是"没数据"，而是"数据没在应用读的那条路径上"【已核实】

把该版本应用的源码读完（`src/utils/gpu/mod.rs`、`src/utils/gpu/other.rs`、
`src/ui/pages/gpu.rs`、`src/utils/units.rs`）后，接口契约是确定的：

| 应用要什么 | 读的路径 | 单位约定 |
|---|---|---|
| GPU 枚举 | `glob("/sys/class/drm/card?")` → 读 `card?/device/uevent` 判 `DRIVER` | —— |
| 使用率 | `card?/device/gpu_busy_percent` | 0–100 整数 |
| 温度 | `card?/device/hwmon/hwmon?/temp1_input` | 毫摄氏度（应用 ÷1000） |
| GPU 时钟 | 同一个 hwmon 的 `freq1_input` | **Hz** |
| 功耗 | `power1_average` → 回退 `power1_input` | 微瓦（应用 ÷1e6） |
| 显存频率 / 功耗墙 / 显存用量 | `freq2_input` / `power1_cap(_max)` / `mem_info_vram_*` | —— |

而本机（修之前）的实际情况：

| 检查 | 结果 |
|---|---|
| `/sys/class/drm/` | 只有 **`card1`**（无 `card0`） |
| `readlink -f /sys/class/drm/card1/device` | `.../ae01000.display-controller` —— **`card?/device` 就是支撑该 DRM 实例的平台设备** |
| `card1/device/uevent` | `DRIVER=msm_dpu`（不在应用的黑名单 `simple-framebuffer`/`evdi` 里 ⇒ 归类 Other） |
| `find /sys/devices -name gpu_busy_percent` | **空** —— 上游只有 `amdgpu` 提供该属性，msm 没有 |
| `grep -rn hwmon drivers/gpu/drm/msm/` | **零命中** —— msm 不注册 hwmon，`card1/device/hwmon/` 不存在 |

⇒ 应用读的**两类接口（卡设备下的 `gpu_busy_percent`、GPU hwmon）在 msm 上都不存在**，
四项自然全部不可用。

**但数据本身一直都在驱动里**：

| 数据 | 驱动里的真实来源 |
|---|---|
| 使用率 | `msm_gpu_funcs::gpu_busy()`（a6xx：读 GMU `POWER_COUNTER_XOCLK_0`，19.2 MHz 基准），devfreq 每 50 ms 用它算 busy/total 调频 |
| 时钟 | devfreq 设备 `3d00000.gpu`（OPP 270/410/500/547/606/640/655/690 MHz，`simple_ondemand`） |
| 温度 | thermal zone0 `gpu-thermal` |

## 3. 修复：把数据搬到一个只读的、约定俗成的位置

见 [`patches/gpu-telemetry/`](../patches/gpu-telemetry/README.md)。要点：

- 在 **`card?/device` 指向的那个设备**上同时注册属性组 `gpu_busy_percent` 与一个 hwmon
  （name = `msm_gpu`）——与 amdgpu/i915/xe 的做法一致（`struct drm_device::dev` 就是父设备）；
- `temp1_input` 走 `hwmon_temp` 正规通道；`freq1_input` 只能走 `extra_groups` 里的
  `SENSOR_DEVICE_ATTR_RO`，因为**内核 hwmon 没有频率传感器类型**
  （`enum hwmon_sensor_types` = chip/temp/in/curr/power/energy/humidity/fan/pwm/intrusion）；
- `gpu_busy_percent` 复用 devfreq **已经在算**的 busy/total，累积到 **500 ms 窗口**再发布
  （单次采样 50 ms，对 1 Hz 的消费者噪声太大）；**不在 sysfs 读路径上读 GMU 寄存器**，
  避免 GPU/GMU 掉电时访问硬件；
- GPU 惰性加载（`priv->gpu` 可能为 NULL）时读值返回 0，**不**从读操作里强行触发加载，失败也不影响驱动加载。

## 4. 实测（GK-W76 / SC8280XP / Adreno 690 / 7.2.5 r4-dev）【已核实】

```console
$ ls -l /sys/class/drm/card1/device/gpu_busy_percent
-r--r--r-- 1 root root 4096 ... /sys/class/drm/card1/device/gpu_busy_percent

$ cat /sys/class/drm/card1/device/hwmon/hwmon15/name
msm_gpu

$ cat /sys/class/drm/card1/device/hwmon/hwmon15/freq1_input
270000000                      # 与 /sys/class/devfreq/3d00000.gpu/cur_freq 一致

$ cat /sys/class/drm/card1/device/hwmon/hwmon15/temp1_input
35200                          # 35.2 °C，与 thermal zone0 gpu-thermal 一致

$ cat /sys/class/drm/card1/device/gpu_busy_percent
2                              # 桌面空闲持续读到 1–2
```

使用率**随负载变化**：同一台机器在施加 GPU 渲染负载时读到 **8**（空闲 1–2），
`/sys/class/devfreq/3d00000.gpu/trans_stat` 显示 270↔547↔690 MHz 正常调频
⇒ 数值来自真实计数器，不是常数、也不是伪造值。

## 5. 功耗项为什么永远是 N/A【已核实】

**这台机器没有任何 GPU 功耗/电流传感器。** 逐一排除：

| 候选来源 | 实际内容 |
|---|---|
| EC hwmon（`hwmon14` `gaokun_ec_hwmon`） | 只有 **20 路温度** |
| 电池 hwmon（`hwmon13` `gaokun_ec_battery`） | 只有 `curr1_input` + `in0_input` —— **整机**电池侧 |
| PMIC ADC（`iio:device0`） | 只有 `in_temp_*` 温度通道 |
| 调节器 | 只报**电压**，无电流 |
| 设备树 GPU OPP 表 | 用 `opp-level`（RPMH 档位），**没有** `opp-microvolt`、没有 `dynamic-power-coefficient`、没有 `opp-microwatt` |

最后一条尤其关键：上游 `devfreq_cooling` 的标准功率模型依赖 `dynamic-power-coefficient` +
各档电压，本机 DT 两者都没有 ⇒ **连"标准估算"都做不出来**。
因此本项目**不提供** `power1_input`/`power1_average`/`power1_cap`：
编一个数字比显示 N/A 更糟（用户会以为那是测量值）。

> 需要"整机功耗"时，真实数据在电池 hwmon 里：`curr1_input`（µA）× `in0_input`（µV）。
> 那是整机，不是 GPU。

## 6. 验证方法（可复现）

```sh
# 1) 节点是否存在、是否挂在卡设备下（应用读的就是这条路径）
ls -l /sys/class/drm/card1/device/gpu_busy_percent
ls -l /sys/class/drm/card1/device/hwmon/hwmon*/

# 2) 取值与"权威来源"交叉核对
cat /sys/class/drm/card1/device/hwmon/hwmon*/freq1_input
cat /sys/class/devfreq/3d00000.gpu/cur_freq          # 应一致
cat /sys/class/drm/card1/device/hwmon/hwmon*/temp1_input
for z in /sys/class/thermal/thermal_zone*; do
  [ "$(cat $z/type)" = gpu-thermal ] && cat $z/temp  # 应一致
done

# 3) 使用率是否随负载变化（空闲 1–2；施加 GPU 负载应上升）
cat /sys/class/drm/card1/device/gpu_busy_percent
cat /sys/class/devfreq/3d00000.gpu/trans_stat | head
```

## ★ 追加修复（真机验证后）：显存占用 + 单数字 hwmon 别名

首轮 r4-dev 装机只让**使用率**有了数据，温度/时钟/功耗仍然 N/A。抓应用 trace 才确认
这不是内核没暴露（`hwmon15` 一直在，root 与普通用户都能读），而是**应用的 glob 缺陷**：

> `resources` 找 hwmon 用的是 `card?/device/hwmon/hwmon?` —— **单个 `?`**，只匹配
> `hwmon0…hwmon9`。本机 hwmon 索引是 **15**（`/sys/class/hwmon` 共 26 个），于是
> `first_hwmon_path: None`，走 hwmon 的三项全部 N/A；而走 `gpu_busy_percent` 的使用率正常。

任何 hwmon 数量 ≥10 的机器都会踩到，**与 msm 无关**。因此补丁追加两项：

| 追加项 | 做法 | 结果 |
|---|---|---|
| `mem_info_vram_used` | 读 `priv->total_mem`（msm 为 `gpu_mem_total` tracepoint 维护的真实 GEM 计数器），**不碰硬件** | 应用「显存占用」有值（实测 230.8 MiB → 233.6 MiB，随桌面 ±几 MiB） |
| `hwmon0 -> hwmonN` 别名 | `sysfs_create_link(hwmon->kobj.parent, &hwmon->kobj, "hwmon0")`，并用 `devm_add_action_or_reset()` 保证在 hwmon 注销之前删除 | `first_hwmon_path: Some(…/hwmon0)`，时钟与温度立刻有值 |

**为什么必须在核心里做**：sysfs 不接受用户态创建符号链接（`ln -s` 直接 `Permission denied`），
所以 udev 规则/启动脚本都做不到这件事。该别名是**为绕过应用缺陷而存在的兼容层**，
上游把 glob 改成 `hwmon*` 之后应当删除（也不投稿，见 §7）。

### 追加修复后的实测（2026-09-15 装机复测）

```console
$ ls /sys/class/drm/card1/device/hwmon/
hwmon0 -> hwmon15
hwmon15

$ cat /sys/class/drm/card1/device/hwmon/hwmon0/name
msm_gpu
$ cat /sys/class/drm/card1/device/hwmon/hwmon0/temp1_input
34200                          # 34.2 °C
$ cat /sys/class/drm/card1/device/hwmon/hwmon0/freq1_input
270000000                      # 270 MHz，与 devfreq cur_freq 一致
$ cat /sys/class/drm/card1/device/mem_info_vram_used
242061312                      # 230.8 MiB
```

同一时刻应用自己的 trace：

```text
TRACE resources::utils::gpu > Found hwmon at "/sys/class/drm/card1/device/hwmon/hwmon0"
TRACE resources::utils::gpu > Created GPU object of "/sys/class/drm/card1":
      OtherGpu { ..., first_hwmon_path: Some("/sys/class/drm/card1/device/hwmon/hwmon0") }
TRACE resources::utils::gpu > Gathered GPU data for 1: GpuData { usage_fraction: Some(0.0),
      used_vram: Some(244924416), clock_speed: Some(547000000.0), temperature: Some(34.2),
      encode_fraction: None, decode_fraction: None, total_vram: None, vram_speed: None,
      power_usage: None, power_cap: None, power_cap_max: None, link: None, nvidia: false }
```

⇒ **使用率、显存占用、GPU 时钟、温度四项全部到位**（时钟那一刻是 547 MHz，说明拿到了
真实调频值而不是 OPP 下限）。仍然 N/A 的只剩"本机确实没有该传感器/该物理量"的几项。

### 取证方法（`resources` 是单实例应用，必须这样抓日志）

```sh
pkill -f /usr/bin/resources; sleep 2   # 直接再启动只会激活已有窗口、不打印日志
sudo -u user env XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-0 \
    RUST_LOG=trace timeout 12 /usr/bin/resources > /tmp/resources-trace.log 2>&1
grep 'utils::gpu' /tmp/resources-trace.log
```

## 7. 上游状态与差异说明

- **上游 msm 既没有 hwmon，也没有 `gpu_busy_percent`**；`gpu_busy_percent` 全树只出现在
  `drivers/gpu/drm/amd/pm/amdgpu_pm.c`。`panfrost`/`v3d`/`lima`/`etnaviv`/`imagination` 也都没有 hwmon。
- 上游**偏好**的"使用率"接口是 **per-process fdinfo**（`Documentation/gpu/drm-usage-stats.rst` 里的
  `drm-engine-<key>`、`drm-cycles-<key>`），而 **msm 早已实现**（`msm_gpu_show_fdinfo()`，2022 年合入）。
  本补丁补的是**卡设备级**的 sysfs/hwmon，与 fdinfo **互补**：系统监视器要的是"整卡占用率"，
  fdinfo 是"某个进程用了多少"。
- 因此本补丁是**真实增量**，不是重复实现；若投稿建议拆成两个提交（sysfs / hwmon），
  并在提交信息里说明"hwmon 无频率通道类型"与"为何不提供功耗项"。

## 8. 溯源

| 项 | 值 |
|---|---|
| 首次落地内核 | `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r4-dev`（2026-09-14 首次装机，2026-09-15 补齐显存占用与 hwmon 别名后复测通过） |
| 补丁 | [`patches/gpu-telemetry/0001-…`](../patches/gpu-telemetry/)（6 文件 / +346 行） |
| 应用侧依据 | `resources 1.10.2` 上游源码（`nokyan/resources`），**不是**靠 `strings` 猜的 |
| 应用侧缺陷 | `hwmon?` 单字符 glob 只匹配 `hwmon0…hwmon9`（任何 hwmon ≥10 的机器都会踩到），本项目用内核侧兼容别名绕开 |
