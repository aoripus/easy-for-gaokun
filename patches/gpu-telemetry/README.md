# `gpu-telemetry` —— msm 驱动暴露 GPU 遥测（使用率 / 时钟 / 温度）

> **元数据**（字段定义见 [`patches/README.md`](../README.md)）
>
> - **用途**：给 `drivers/gpu/drm/msm/` 补上系统监视器约定要读的三个遥测节点
>   （`gpu_busy_percent`、`hwmon?/temp1_input`、`hwmon?/freq1_input`）
> - **基线 / Base**：**mainline stable v7.2.5 的 `drivers/gpu/drm/msm/`**，不依赖本项目其他补丁
> - **序列 / Order**：见同目录 [`series`](series)（单条补丁）
> - **上游状态**：未投稿。**上游目前没有等价物**（`gpu_busy_percent` 只存在于 amdgpu；
>   `drivers/gpu/drm/msm/` 无 hwmon、无该属性），所以这是真实增量而不是重复实现
> - **是否用于当前发布内核**：✅ 是（自 r4 起；r4-dev 装机验证）
> - **验证**：在 r4-dev 内核树上 `git apply --check -R` 干净反应用；实机取值见下「实测」
> - **回滚**：移除补丁即可；不改变任何既有行为（只新增只读 sysfs/hwmon 节点）
> - **文档**：[`docs/gpu-telemetry.md`](../../docs/gpu-telemetry.md)

本目录收录本项目对 **msm DRM 驱动**的一处增量：把驱动里**本来就有**的 GPU 数据
暴露到系统监视器（GNOME Resources 等）实际去读的路径上。

## 文件

| 文件 | 说明 |
|---|---|
| `0001-drm-msm-expose-gpu-utilization-clock-temperature.patch` | 6 个文件，+281 行（新增 `msm_telemetry.c` 188 行） |

## 为什么要读这几个节点（契约来自应用源码，而不是猜的）

`resources 1.10.2`（`net.nokyan.Resources`）的 GPU 页按如下路径取值
（源码：`src/utils/gpu/mod.rs`、`src/ui/pages/gpu.rs`、`src/utils/units.rs`）：

| 界面项 | 读的路径 | 单位约定 |
|---|---|---|
| 使用率 | `card?/device/gpu_busy_percent` | 0–100 整数 |
| 温度 | `card?/device/hwmon/hwmon?/temp1_input` | 毫摄氏度（应用 ÷1000） |
| GPU 时钟 | 同一个 hwmon 的 `freq1_input` | **Hz**（应用直接按 Hz 换算） |
| 功耗 | `power1_average`，回退 `power1_input` | 微瓦（应用 ÷1e6） |
| 显存频率 / 功耗墙 / 显存用量 | `freq2_input` / `power1_cap(_max)` / `mem_info_vram_*` | —— |

关键点：**`card?/device` 是 DRM 卡设备**。对 msm 来说它指向**支撑该 DRM 实例的平台设备**
（`struct drm_device::dev` 就是父设备），所以遥测节点必须注册在那里 ——
这也正是 amdgpu / i915 / xe 注册 hwmon 的位置。

## 补丁内容（6 个文件）

1. **`msm_telemetry.c`（新增）**
   - 在卡设备上注册属性组 `gpu_busy_percent`；
   - 注册一个 hwmon（name = `msm_gpu`）：`temp1_input` 走 **`hwmon_temp` 正规通道**，
     `freq1_input` 走 **`extra_groups` 里的 `SENSOR_DEVICE_ATTR_RO`** —— 因为内核 hwmon
     **没有频率传感器类型**（`enum hwmon_sensor_types` 里没有 freq），amdgpu/radeon 也是这么做的；
   - 温度按名字取 thermal zone `gpu-thermal`（**每次读时解析**：tsens 驱动可能比 msm 晚 probe）；
   - `priv->gpu` 是惰性加载的，为 NULL 时读值返回 0，不强行触发 GPU 加载。
2. **`msm_gpu_devfreq.c`**
   - 在 `msm_devfreq_get_dev_status()` 里把既有的 busy/total 累积到 **500 ms 窗口**再发布百分比
     （devfreq 单次采样只有 50 ms，对 1 Hz 的消费者噪声太大）；
   - GPU 挂起路径把百分比与窗口清零；
   - 新增 `msm_devfreq_get_busy_percent()` 与 `msm_devfreq_get_freq()`
     （后者复用文件内既有的 `get_freq()`，含 idle 影子频率；**不碰硬件**，挂起时也安全）。
3. **`msm_gpu.h`**：`struct msm_gpu_devfreq` 增加 3 个字段 + 两个原型。
4. **`msm_drv.h`**：声明 `msm_telemetry_init()`。
5. **`msm_drv.c`**：在 `msm_drm_init()` 末尾（`drm_dev_register()` 成功之后）调用，
   **失败不影响驱动加载**（`(void)` 调用）。
6. **`Makefile`**：把 `msm_telemetry.o` 加进 `msm-y`。

## 刻意不做的事

| 项 | 原因 |
|---|---|
| GPU 功耗 `power1_input` / `power_average` | **本机没有任何 GPU 功耗/电流传感器**：EC hwmon 只有 20 路温度、电池 hwmon 只有整机 `curr1_input`、PMIC ADC 只有温度通道、调节器只报电压；DT 的 GPU OPP 用 `opp-level`（RPMH 档位）而非 `opp-microvolt`，也没有 `dynamic-power-coefficient`/`opp-microwatt` ⇒ 连上游 devfreq-cooling 的标准功率模型都无法估。**编一个数字比显示 N/A 更糟** |
| 功耗墙 `power1_cap(_max)` | 同上，本机无该能力 |
| 显存频率 `freq2_input` | 本机是 UMA，没有独立显存时钟；GPU 侧只有 `gfx-mem` interconnect 带宽投票，不是时钟 |
| 显存用量 `mem_info_vram_*` | UMA，无独立显存 |

应用会把缺失的属性渲染成 **N/A**，所以这三项的界面表现是"不可用"，属于**如实反映硬件能力**。

## 实测（GK-W76 / SC8280XP / Adreno 690 / Linux 7.2.5 / r4-dev）

```console
/sys/class/drm/card1/device/gpu_busy_percent      -> 1..2（桌面空闲）
/sys/class/drm/card1/device/hwmon/hwmon15/name    -> msm_gpu
/sys/class/drm/card1/device/hwmon/hwmon15/temp1_input -> 35200..35900（35.2–35.9 °C）
/sys/class/drm/card1/device/hwmon/hwmon15/freq1_input -> 270000000（与 devfreq cur_freq 一致）
```

- 使用率**随负载变化**（同一窗口内 1→2、加载 GPU 渲染时升到 8），不是常数；
- 频率与 `/sys/class/devfreq/3d00000.gpu/cur_freq` 一致，`trans_stat` 显示 270↔547↔690 MHz 正常调频；
- 温度与 thermal zone0（`gpu-thermal`）一致。

## 上游化建议

- 上游**偏好**的"全设备使用率"接口其实还没有：标准只有 **per-process fdinfo**
  （`drm-engine-<key>`、`drm-cycles-<key>`，见 `Documentation/gpu/drm-usage-stats.rst`），
  而 **msm 早已实现**（`msm_gpu_show_fdinfo()`）。本补丁补的是**卡设备级的 sysfs/hwmon**，
  与 fdinfo 互补（系统监视器要的是"整卡占用率"）。
- 若投稿，建议拆成两个提交：① sysfs `gpu_busy_percent`；② hwmon（温度/频率）。
  提交信息里应说明"hwmon 没有频率通道类型"这一约束，以及为何**不**提供功耗项。
