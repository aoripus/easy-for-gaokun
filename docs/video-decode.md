# 视频硬件解码：现状、根因与可行路径

> 本文记录 GK-W76 上**视频硬件解码不可用**的完整归因分析。
> 所有结论均标注来源与置信度；【已核实】表示直读第一手源码或原作者邮件。

---

## 1. 结论摘要

1. **这台机器的视频解码单元是 Qualcomm IRIS（Gen1 IP），不是传统 Venus AR50。**
2. 上游主线**已经**在 `sc8280xp.dtsi` 里加了 `iris` 节点，但 **`sc8280xp-huawei-gaokun3.dts` 从未启用它**（默认 `status = "disabled"`）。
3. 社区镜像走的是**树外 Venus 补丁**（jhovold 方案），而 **Venus 驱动在这块 IRIS 硬件上设计上就不可能启动成功**。
4. 内核报的 `error -22 initializing firmware` **不代表固件文件有问题** —— 它是 `venus_boot()` 把任何失败无条件改写成的假象。
5. **可行路径**：改用主线 `iris` 驱动 + 板级 `&iris { status = "okay"; }`，**照抄 ThinkPad X13s 的写法**（同 SoC，风险最低）。

---

## 2. 实机现象

```text
qcom-venus aa00000.video-codec: non legacy binding
qcom-venus aa00000.video-codec: error -22 initializing firmware qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn
qcom-venus aa00000.video-codec: fail to load video firmware
qcom-venus aa00000.video-codec: probe with driver qcom-venus failed with error -22
```

| 观测 | 值 |
|------|-----|
| DTB 节点 | `/proc/device-tree/soc@0/video-codec@aa00000`，`compatible = qcom,sm8350-venus`，`status = okay` |
| 节点子节点 | `opp-table` / `video-decoder` / `video-encoder` —— **没有 `video-firmware`** |
| `iommus` | `0x2c 0x2e00 0x400`（`apps_smmu` SID `0x2e00`） |
| 内核配置 | `CONFIG_VIDEO_QCOM_VENUS=m`；**`# CONFIG_VIDEO_QCOM_IRIS is not set`** |
| 已加载模块 | `venus_core` |
| 设备节点 | **无 `/dev/video*`** |

---

## 3. 根因链

### 3.1 硬件是 IRIS，不是 Venus

| | SC8280XP（8cx Gen 3） | X1E80100（X Elite） |
|---|---|---|
| 节点 | `iris: video-codec@aa00000` | `iris: video-codec@aa00000` |
| 基地址 | `0x0aa00000` | `0x0aa00000` |
| 中断 | `GIC_SPI 174` | `GIC_SPI 174` |
| 主兼容串 | `qcom,sc8280xp-iris` | `qcom,x1e80100-iris` |
| 兜底兼容串 | `qcom,sm8250-venus` | `qcom,sm8550-iris` |
| 固件 blob | `qcvss8280.mbn` | `qcvss8380.mbn` |

【已核实】Konrad Dybcio（2023-08）：

> Both of these SoCs implement an **IRIS2 block**, with SC8280XP being able to clock it a bit higher.

【已核实】Dmitry Baryshkov（`media: iris: enable SM8350 and SC8280XP support` v7，2026-05）：

> Note, this has been tested only with the Iris driver.
> **Venus driver fails to boot the Iris core on SM8350 pointing out the UC_REGION error.**
>
> Note, the firmware for SM8250 isn't compatible with SM8350 (nor with SC8280XP).
> Please use corresponding firmware, extracted from the Windows / Android data.

→ **Venus 在这块硬件上不可能成功，这是作者的明确结论。**

### 3.2 上游 DTS 里 iris 已存在，但 gaokun3 没启用

【已核实】主线 `sc8280xp.dtsi`（DTS 部分已合并，commit `3a52eef16b979617156fa6e2ead24ca4d1336f0b`）：

```dts
pil_video_mem: video-region@86700000 {
	reg = <0 0x86700000 0 0x500000>;
	no-map;
};

iris: video-codec@aa00000 {
	compatible = "qcom,sc8280xp-iris", "qcom,sm8250-venus";
	reg = <0x0 0x0aa00000 0x0 0x100000>;
	interrupts = <GIC_SPI 174 IRQ_TYPE_LEVEL_HIGH>;
	...
	memory-region = <&pil_video_mem>;
	status = "disabled";      /* ← 默认关闭，必须板级 enable */
};
```

X13s 是这么启用的（commit `595eb4144f2ecc58e8e56e07ae94407b5a696031`）：

```dts
&iris {
	firmware-name = "qcom/sc8280xp/LENOVO/21BX/qcvss8280.mbn";
	status = "okay";
};
```

**而 `sc8280xp-huawei-gaokun3.dts` 里没有任何 `&iris` 或 `&venus` 引用**
（全文 grep `venus` / `video` / `qcvss` 零命中）。

### 3.3 社区镜像走的是树外 Venus 补丁，且与内核配置自相矛盾

【已核实】`KawaiiHachimi/linux-gaokun-buildbot` README：

> `media/*`: adapted from the **jhovold/linux** (`wip/sc8280xp-6.16`) **to add SC8280XP Venus support**

`patches/media/` 的 6 个补丁中，关键的两个：

- `0005-…-Add-SC8280XP-resource-struct.patch` → 给 venus 加 `qcom,sc8280xp-venus`，`.hfi_version = HFI_VERSION_6XX`、`.vpu_version = VPU_VERSION_IRIS2`
- `0006-arm64-dts-qcom-sc8280xp-Add-Venus.patch` → 建 `compatible = "qcom,sm8350-venus"` 的节点（**没有 `firmware-name`**）

**三方互相打架：**

| | 说的是什么 |
|---|---|
| DTS（补丁 0006） | venus 兼容串 |
| `defconfig/gaokun3_defconfig` | `CONFIG_VIDEO_QCOM_IRIS=m`（**只开 iris**） |
| **我们运行中的内核** | `CONFIG_VIDEO_QCOM_VENUS=m`、**IRIS 未编** ← 与 defconfig 相反 |
| 实际硬件 | **IRIS** |

> ⚠️ 上游 venus 的 `core.h` 里有 `#if (!IS_ENABLED(CONFIG_VIDEO_QCOM_IRIS))` 守卫：
> **一旦启用 iris，venus 的 IRIS2 / HFI-6XX 支持会被整体编译掉。** 两个驱动是互斥分工的。

### 3.4 `-22` 的真正含义（不要被它误导）

【已核实】`drivers/media/platform/qcom/venus/firmware.c`：

```c
int venus_boot(struct venus_core *core)
{
	...
	ret = venus_load_fw(core, fwpath, &mem_phys, &mem_size);
	if (ret) {
		dev_err(dev, "fail to load video firmware\n");
		return -EINVAL;          /* ← 无条件改写，真实错误码被吞掉 */
	}
```

而 `error -22 initializing firmware <path>` 来自别处（`__qcom_mdt_pas_init()` 中
`qcom_pas_init_image()` 失败）。**这两行是独立输出，不构成因果链。**

本机实测进一步确认：venus 节点**没有 `video-firmware` 子节点**，于是
`venus_firmware_init()` 会设 `core->use_tz = true`，走 **PAS 安全世界**路径，
元数据被安全世界拒绝 → `-EINVAL`。

> ★ 但**即便把这一段修好，Venus 在这块 IRIS 硬件上依然跑不起来**（见 §3.1）。
> 这条线索只是佐证，不是修复方向。

### 3.5 固件不是问题

用内核 `qcom_mdt_get_size()` 的精确规则（`p_type == PT_LOAD`、排除哈希段、`p_memsz != 0`）
实测两个 blob：

| 固件 | 大小 | `qcom_mdt_get_size` | 预留区 `0x500000` |
|------|------|--------------------|------------------|
| 华为原版（buildbot 提取） | 2,035,748 B | **5,242,880（0x500000）** | ✅ 正好放得下 |
| X13s 上游版 | 2,035,812 B | **5,242,880（0x500000）** | ✅ 正好放得下 |

两者结构一致（同 14 个可加载段、同样的 `min=0xf500000` / `max=0xfa00000`），
**实机互换后失败现象完全相同** → 排除"固件文件损坏/尺寸不符"。

> `VENUS_FW_MEM_SIZE` 上限是 6 MiB，两者都远低于上限。

---

## 4. 可行路径

| # | 路径 | 可行性 | 成本 | 说明 |
|:-:|------|:------:|:----:|------|
| **1** | **改用主线 `iris`，照抄 X13s** | **高** | 中 | 同 SoC；作者已在 X13s 实测解码通过 |
| 2 | 继续修树外 venus 方案 | **低** | 高 | 与上游设计方向对抗；需自写 VPU/HFI 平台支持 |
| 3 | 从 X Elite（X1E80100）反向移植 | 中 | 中 | IP 代次不同，**代码搬不动**，只能借 DT 结构与思路 |
| 4 | 放弃硬解，走 GPU / 软解 | 高 | 极低 | 可靠兜底，但 1080p60 软解 CPU 占用高、续航差 |

> 注：X1E80100 用 `sm8550` 平台数据、SC8280XP 用 `sm8250` 平台数据，两者**不是同一套 ops**。
> 真正该"偷"的是 **X13s 的写法**（同 SoC、同平台数据），而不是 X Elite 的代码。

### 路径 1 的具体动作

1. **内核**：启用 `CONFIG_VIDEO_QCOM_IRIS=m`，**并且不要**启用 `CONFIG_VIDEO_QCOM_VENUS`
   （两者声明同一个兼容串会抢 probe；且 iris 一旦启用，venus 的 IRIS2 支持会被 `#if` 编译掉）。
2. **补丁集**：**移除/不应用** `patches/media/0006-arm64-dts-qcom-sc8280xp-Add-Venus.patch`
   （否则它会建出一个 venus 节点，与上游 `iris` 节点在同一地址冲突）。
3. **设备树**：在 gaokun3 板级 DTS 加
   ```dts
   &iris {
   	firmware-name = "qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn";
   	status = "okay";
   };
   ```
4. **固件**：`qcvss8280.mbn` 已随镜像提供（`/lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/`）。
   若 HUAWEI 版不被接受，可试 X13s 的 `qcom/sc8280xp/LENOVO/21BX/qcvss8280.mbn`（同 SoC）。
5. **顺带**：把 `gpio174` 触屏修复（见 [`patches/`](../patches/)）一并编进同一份 DTB。

### 路径 4 的验证（几秒即可知道 GPU 到底有没有问题）

```bash
glxinfo -B | grep -iE 'renderer|OpenGL'    # 期望 FD690 / Mesa，而非 llvmpipe
vulkaninfo --summary 2>/dev/null | head -30
```

若 renderer 不是 `llvmpipe`，说明 **GPU 加速本来就在工作**，
"驱动不完整"的印象其实来自**视频解码**而非 GPU。

---

## 5. 实机判定命令

```bash
# ① 设备树里到底是哪个驱动在 probe
D=$(ls -d /proc/device-tree/soc@0/*video-codec* | head -1)
tr -d '\0' < "$D/compatible";  echo
tr -d '\0' < "$D/status";      echo
for c in "$D"/*/; do [ -d "$c" ] && echo "  子节点: $(basename "$c")"; done
ls -l /proc/device-tree/reserved-memory/*video*/reg

# ② 内核编了谁
grep -E 'VIDEO_QCOM_(IRIS|VENUS)' /boot/config-$(uname -r)
lsmod | grep -E 'venus|iris'

# ③ 谁绑定了
ls -l /sys/bus/platform/devices/aa00000.video-codec/driver

# ④ 修好之后应出现
v4l2-ctl --list-devices        # qcom-iris-decoder
dmesg | grep -i iris
vainfo
mpv --hwdec=v4l2m2m-copy file.mp4
```

---

## 6. 来源

| 内容 | 链接 |
|------|------|
| 主线 venus `of_device_id`（无 sc8280xp） | <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/drivers/media/platform/qcom/venus/core.c> |
| venus 固件加载与 `-EINVAL` 改写 | <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/drivers/media/platform/qcom/venus/firmware.c> |
| venus `core.h`（与 iris 互斥的 `#if`） | <https://raw.githubusercontent.com/torvalds/linux/master/drivers/media/platform/qcom/venus/core.h> |
| MDT 加载器（尺寸/元数据规则） | <https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/drivers/soc/qcom/mdt_loader.c> |
| QC 官方 bug：SC8280XP 掉 venus 固件 | <https://bugs.launchpad.net/ubuntu/+source/linux-firmware/+bug/2115199> |
| iris v7 系列（含 X13s 实测数据与合并确认） | <https://patchew.org/linux/20260515-iris-sc8280xp-v7-0-2e21f6db1897@oss.qualcomm.com/> |
| "SC8280XP 是 IRIS2 块" | <https://lkml.org/lkml/2023/8/7/848> |
| X13s venus 使能与固件路径（树外方案） | <https://lkml.org/lkml/2025/3/4/1194> |
| buildbot `media/*` 来源说明 | <https://github.com/KawaiiHachimi/linux-gaokun-buildbot> |
| Adreno 690 = `ADRENO_6XX_GEN4` | <https://raw.githubusercontent.com/torvalds/linux/master/drivers/gpu/drm/msm/adreno/adreno_gpu.h> |
