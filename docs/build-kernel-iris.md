# 用 IRIS 驱动编译内核（gaokun3 / SC8280XP）构建配方

> 目标机：HUAWEI MateBook E Go 2022 性能版（GK-W76 / SC8280XP / 设备树代号 `gaokun3`）。
> 目的：用 **`CONFIG_VIDEO_QCOM_IRIS`**（而非 `CONFIG_VIDEO_QCOM_VENUS`）编译内核，尝试驱动视频硬解单元。
> **只编译，不安装进 ESP。** `buildbot` = 本机克隆 `D:\_gaokun-refs\linux-gaokun-buildbot`。
> 标注：【已核实】= 直读一手源码/官方 API/内核邮件列表原文；【社区报告】= 参与者自述实测；【推测】= 推断。

---

> ## ⚠️ 实机验证后的两条修正（2026-09-13）
>
> 本文档的结论已在目标机上实际构建验证，其中两条与下文原稿不同，**以本框为准**：
>
> 1. **基线必须用 `v7.2-rc2`，不能用 `v7.1-rc3`。** 原稿据 release body 推断基线应取
>    `v7.1-rc3`（运行中的内核确实是它编出来的）。但把 buildbot **当前**的补丁集打到
>    `v7.1-rc3` 上时，`upstream` / `others` / `0099` **三组全部应用失败**
>    （`git am` 与 `git apply --3way` 都失败），直接导致 `gaokun3_defconfig` 缺失。
>    原因：补丁集是随 buildbot 仓库演进的，当前版本面向 `v7.2-rc2`
>    （`scripts/local/build_kernel.sh` 与构建指南的默认值也是它）。改到 `v7.2-rc2` 后
>    **三组补丁一次全过**。
>    ⇒ 本配方产出的是「**v7.2-rc2 + buildbot 当前补丁集 + 前置 IRIS 节点**」的内核，
>    **不是**在产内核的逐字节复刻。
> 2. **`patches/media/` 整目录跳过是对的**，但 §4.4.1 的 include 必须加**三个**（含
>    `dt-bindings/reset/qcom,sm8350-videocc.h`）；只加 clock 那份会得到
>    `Lexical error: ... Unexpected 'VIDEO_CC_MVS0C_CLK_ARES'`。详见 §4.4.1。
>
> 另注：`patches/el2/` 中有 **1 个补丁**（`drivers/soc/qcom/smp2p.c`）在 `v7.2-rc2` 上
> 打不上，其余 21 个正常；这不影响 `Image`/`modules`/`dtbs` 的构建，但会影响 EL2
> 下 DSP/remoteproc 的行为，需启动验证时留意。

## 1. 三条与既有认知相反、且会改变做法的核实结果

**1.1 源码是纯上游 `torvalds/linux`，没有 gaokun 内核分支。**
【已核实】`buildbot/.github/workflows/gaokun3-package-debs.yml` 用 `repository: torvalds/linux` +
`ref: ${{ env.KERNEL_TAG }}`（`actions/checkout@v6`）。`https://api.github.com/repos/KawaiiHachimi/linux`
→ **404**；`KawaiiHachimi/linux-gaokun` 存在但**无任何 workflow 引用**；`right-0903/linux-gaokun`
是补丁/DTS 来源，不是可编译内核树。

**1.2 基线 tag 是 `v7.1-rc3`，不是克隆里默认的 `v7.2-rc2`。**
【已核实】`https://api.github.com/repos/KawaiiHachimi/linux-gaokun-buildbot/releases?per_page=100` 给出
`tag_name = ubuntu26.04-7.1.0-rc3-gaokun3+-el2-20260514004329`、`published = 2026-05-14T00:45:11Z`，
release body 原文即 `- Kernel Tag: v7.1-rc3`、`EL2 Kernel Release: 7.1.0-rc3-gaokun3-el2+`。
tag 对象 `bb1459368dd795c43380057523f571d5eb0ddded` → 提交 `5d6919055dec134de3c40167a490f33c74c12581`
（Linus 打 tag 于 2026-05-10）。该 tag 的 `Makefile` 为 `VERSION=7 / PATCHLEVEL=1 / SUBLEVEL=0 /
EXTRAVERSION=-rc3`，故 `make kernelversion` = **`7.1.0-rc3`**；叠加 `CONFIG_LOCALVERSION="-gaokun3"`
得 `7.1.0-rc3-gaokun3`，与实机 `uname -r` 吻合。
⚠️ `buildbot/scripts/local/build_kernel.sh:4` 默认 `KERNEL_TAG="${KERNEL_TAG:-v7.2-rc2}"`，
`buildbot/docs/matebook_ego_build_guide_ubuntu26.04_en.md` 亦用 `--branch v7.2-rc2` —— **都不是基线**。

**1.3 基线树里 `CONFIG_VIDEO_QCOM_IRIS` 存在，但 SC8280XP 的 IRIS 设备树节点不存在。**
【已核实】该符号自 **mainline v6.15** 引入（`iris/Kconfig` 在 `v6.14` 为 404、`v6.15` 为 200；首个提交
`38506cb7e8d25ae9604f8e6af96ea19bc3eadaf1`）→ `v7.1-rc3` 里**可被选中**。但抓取
`.../v7.1-rc3/arch/arm64/boot/dts/qcom/sc8280xp.dtsi` 后检索 `iris`/`aa00000`/`videocc`/`pil_video`
→ **全部零命中**；`v7.2-rc1`～`v7.2` 亦零命中。该节点由 Dmitry Baryshkov 系列
`[PATCH v7 0/6] media: iris: enable SM8350 and SC8280XP support`（2026-05-15）带入，关键 commit
**`3a52eef16b979617156fa6e2ead24ca4d1336f0b`**（`sc8280xp: Add Iris core`）与
`595eb4144f2ecc58e8e56e07ae94407b5a696031`（`x13s: Enable Iris`）。首个含该节点的**发布版**是
**`v7.3-rc1`**。**本配方的核心工作即把它手工前置到 `v7.1-rc3`。**

---

## 2. 关键约束

### 2.1 IRIS 与 VENUS 在 7.1 上互斥

【已核实】`v7.1-rc3` `iris/iris_probe.c:350-378`：

```c
static const struct of_device_id iris_dt_match[] = {
	{ .compatible = "qcom,qcs8300-iris", .data = &qcs8300_data, },
#if (!IS_ENABLED(CONFIG_VIDEO_QCOM_VENUS))
	{ .compatible = "qcom,sc7280-venus", .data = &sc7280_data, },
	{ .compatible = "qcom,sm8250-venus", .data = &sm8250_data, },
#endif
```

【已核实】`v7.1-rc3` `venus/core.h:57` 的 `VPU_VERSION_IRIS2` **无** `#if` 守卫（守卫来自
`8f100f5896e1ccec3802dafd0f719627733c8183` "flip the venus/iris switch"，committed 2026-05-10，
**未进入该 tag**）。⇒ 若 VENUS 为 `y/m`，**IRIS 不注册 `qcom,sm8250-venus`**；而 SC8280XP 唯一能被匹配的
兼容串就是它（`qcom,sc8280xp-iris` 在 7.1 的 `iris_dt_match` 里**不存在**）⇒ **两者同开谁都绑不上，
必须显式关掉 VENUS。**

### 2.2 `fwname` 是 Venus 的名字，必须靠 DTS 覆盖

【已核实】`v7.1-rc3` `iris/iris_platform_gen1.c:340-363`：`sm8250_data.fwname = "qcom/vpu-1.0/venus.mbn"`；
`iris/iris_firmware.c` 先读设备树 `firmware-name`（`of_property_read_string_index(..., "firmware-name", ...)`），
读不到才回退 `fwpath = core->iris_platform_data->fwname;`。而 `qcom/vpu-1.0/` 已被 linux-firmware
commit `36db650dae038be945fb04def591fc726255b09f` 删除（并入 `qcom/vpu/`，无兼容软链）。
⇒ **`&iris { firmware-name = ...; }` 必需，不写必然 `firmware download failed`。**

### 2.3 固件候选与配置事实

| 候选固件 | 路径 | 说明 |
|---|---|---|
| gaokun3 原生 | `qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn` | 【已核实】`buildbot/firmware/qcom/sc8280xp/HUAWEI/gaokun3/` 下有，由 `linux-firmware-gaokun3` 包装到 `/lib/firmware/`。**首选。** |
| X13s 上游版（同 SoC） | `qcom/sc8280xp/LENOVO/21BX/qcvss8280.mbn` | 【已核实】上游 linux-firmware 存在，`WHENCE` 版本串 `video-firmware.1.1-b158087140355883dc40b004032856a8feb5d565`。**回退项。** |

**不要**指向 `qcom/vpu/vpu20_p4.mbn`。【已核实】Dmitry Baryshkov：*"the firmware for SM8250 isn't
compatible with SM8350 (nor with SC8280XP). Please use corresponding firmware, extracted from the
Windows / Android data."*

【已核实】`buildbot/defconfig/gaokun3_defconfig:283-293` 含 `CONFIG_MEDIA_SUPPORT=m`、
`CONFIG_MEDIA_CAMERA_SUPPORT=y`、`CONFIG_MEDIA_PLATFORM_SUPPORT=y`、`CONFIG_V4L_MEM2MEM_DRIVERS=y`、
`CONFIG_VIDEO_QCOM_CAMSS=m`、**`CONFIG_VIDEO_QCOM_IRIS=m`**，且**全文无 `CONFIG_VIDEO_QCOM_VENUS`**。
`make gaokun3_defconfig` 是**独立配置**，不继承 `arch/arm64/configs/defconfig`（后者两侧都设 `=m`），
故 Venus 缺省即 `not set`。⚠️ 但实机运行内核却是 `VENUS=m` + `IRIS is not set`，与当前 defconfig **相反**
（buildbot 有 commit `9c28aa7279199576d9a52a6ff29a991fce393ffb` "VPU driver back to use venus"，2026-04-12）
⇒ **不要依赖 defconfig 现状，按 §4.3 显式双向下手。**

【已核实】`iris/Kconfig` 依赖（v7.1 版比 master 少 `QCOM_PAS`/`QCOM_SMEM`/`QCOM_UBWC_CONFIG`）：
`depends on VIDEO_DEV`、`depends on ARCH_QCOM || COMPILE_TEST`、`select V4L2_MEM2MEM_DEV`、
`select QCOM_MDT_LOADER`、`select QCOM_SCM`、`select VIDEOBUF2_DMA_CONTIG`。

---

## 3. 改动清单

| # | 文件（源码树内） | 改动 |
|---|---|---|
| 1 | `arch/arm64/boot/dts/qcom/sc8280xp.dtsi` | 加 3 个 `#include`；加 `pil_video_mem`；加 `iris` 与 `videocc` 节点 |
| 2 | `arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts` | 加板级 `&iris` 使能块 |
| 3 | `.config`（生成物） | 显式 `IRIS=m`、`VENUS` 关闭 |
| 4 | 补丁集 | 应用 `patches/upstream/*`、`others/*`、`0099-*`；**跳过整个 `patches/media/`** |

**为什么跳过 `patches/media/`**：`0006-...-Add-Venus.patch` 会在 `0xaa00000` 建
`compatible = "qcom,sm8350-venus"` 的 `venus:` 节点，与本配方 `iris:` 节点**同单元地址**（DTC 重复节点），
其 `videocc` 节点亦重复，且它写的 `iommus = <&apps_smmu 0x2e00 0x400>` 在上游最终版里是 **`0x2a00`**（错的）。
`0005` 给 venus 加 `sc8280xp_res`，而 VENUS 已关闭，毫无用处。⇒ 跳过整个目录。

---

## 4. 完整构建命令序列（目标机 aarch64 原生编译）

> 普通用户执行，`sudo` 仅用于装依赖。**无任何写 ESP / efibootmgr / dkms / kernel-install 的步骤。**

### 4.1 构建依赖

```bash
sudo apt-get update
sudo apt-get install -y git make gcc bc bison flex cpio rsync kmod pkg-config \
  libssl-dev libelf-dev dwarves ccache python3 zstd xz-utils
```

【已核实】来源：`buildbot/.github/workflows/gaokun3-package-debs.yml` 与
`buildbot/docs/matebook_ego_build_guide_ubuntu26.04_en.md`；上游最低版本见
`Documentation/process/changes.rst`（`pahole` 表列 1.26；`pkg-config` 自 4.18 起必需）。
【已核实】`gaokun3_defconfig` **未开** `CONFIG_MODULE_SIG`/`CONFIG_SYSTEM_TRUSTED_KEYS`，
故不会遇到发行版配置常见的 `canonical-certs.pem` 缺失报错。

### 4.2 获取源码并打补丁

```bash
export GAOKUN_DIR="$HOME/gaokun/linux-gaokun-buildbot"
export KERN_SRC="$HOME/gaokun/mainline-linux"
export KERNEL_TAG=v7.1-rc3

mkdir -p "$(dirname "$GAOKUN_DIR")"
[ -d "$GAOKUN_DIR" ] || git clone https://github.com/KawaiiHachimi/linux-gaokun-buildbot "$GAOKUN_DIR"
git clone --depth=1 --branch "$KERNEL_TAG" \
  https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git "$KERN_SRC"
cd "$KERN_SRC"
git config user.name "gaokun builder"; git config user.email "builder@example.com"

# 顺序取自 buildbot/scripts/ci/20_build_kernel_variants.sh:65-68；刻意跳过 patches/media/*
git am "$GAOKUN_DIR"/patches/upstream/*.patch
git am "$GAOKUN_DIR"/patches/others/*.patch
git am "$GAOKUN_DIR"/patches/0099-arm64-gaokun3-import-local-dts-and-defconfig.patch

test -f arch/arm64/configs/gaokun3_defconfig && echo "defconfig OK"
git rev-parse HEAD && git log --oneline -5
```

**若 `git am` 冲突**：`git am --show-current-patch=diff` 看冲突 → `git am --abort` 回退 →
`git apply --3way` 逐文件手工处理 → `git add -A && git commit`。不要猜着 `--skip`。

### 4.3 生成 `.config` 并显式指定 IRIS

```bash
export ARCH=arm64 CROSS_COMPILE=""
export KERN_OUT="$HOME/gaokun/kernel-out-iris"
make O="$KERN_OUT" ARCH=arm64 gaokun3_defconfig

# 关键两行：开 IRIS、关 VENUS（§2.1 的互斥约束）；后三行兜底 IRIS 硬依赖
"$KERN_SRC"/scripts/config --file "$KERN_OUT/.config" --module  VIDEO_QCOM_IRIS
"$KERN_SRC"/scripts/config --file "$KERN_OUT/.config" --disable VIDEO_QCOM_VENUS
"$KERN_SRC"/scripts/config --file "$KERN_OUT/.config" --module  MEDIA_SUPPORT
"$KERN_SRC"/scripts/config --file "$KERN_OUT/.config" --enable  MEDIA_PLATFORM_SUPPORT
"$KERN_SRC"/scripts/config --file "$KERN_OUT/.config" --enable  VIDEO_DEV
make O="$KERN_OUT" ARCH=arm64 olddefconfig
```

### 4.4 前置上游 IRIS 设备树节点（核心改动）

**4.4.1 Include**：`arch/arm64/boot/dts/qcom/sc8280xp.dtsi` 需要补 **3 个** `#include`，
**必须写全路径**——reset 定义与 clock 定义在两个不同的头文件里，只加 clock 那份会在
DTC 阶段报 `Lexical error: ... Unexpected 'VIDEO_CC_MVS0C_CLK_ARES'`（实机已验证）：

```dts
#include <dt-bindings/clock/qcom,sm8350-videocc.h>     /* VIDEO_CC_MVS0C_CLK / VIDEO_CC_MVS0_CLK / MVS0C_GDSC / MVS0_GDSC */
#include <dt-bindings/interconnect/qcom,icc.h>          /* QCOM_ICC_TAG_ACTIVE_ONLY / QCOM_ICC_TAG_ALWAYS */
#include <dt-bindings/reset/qcom,sm8350-videocc.h>      /* VIDEO_CC_MVS0C_CLK_ARES ← 极易漏掉 */
```

第 13 行 `#include <dt-bindings/clock/qcom,sc8280xp-lpasscc.h>` 之后插入前两个，
第 20 行 `#include <dt-bindings/power/qcom-rpmpd.h>` 之后插入第三个。
【已核实】所需常量在 v7.1-rc3/v7.2-rc2 均已存在：`qcom,rpmhpd.h`（经 `qcom-rpmpd.h` 引入）含
`SC8280XP_MX`(10)/`SC8280XP_MMCX`(7)；`dt-bindings/clock/qcom,sm8350-videocc.h` 含
`VIDEO_CC_MVS0C_CLK`(4)/`VIDEO_CC_MVS0_CLK`(1)/`MVS0C_GDSC`(0)/`MVS0_GDSC`(2)；
`dt-bindings/reset/qcom,sm8350-videocc.h` 含 `VIDEO_CC_MVS0C_CLK_ARES`(2)；
`qcom,icc.h` 含 `QCOM_ICC_TAG_ACTIVE_ONLY`/`QCOM_ICC_TAG_ALWAYS`。

> 本节已固化为可执行工具：[`tools/gaokun-iris-dts-prep.py`](../tools/gaokun-iris-dts-prep.py)
> （`python3 tools/gaokun-iris-dts-prep.py <内核源码根>`），它按锚点插入上述全部改动。

**4.4.2 保留内存**：同文件，在 `reserved-region@85b00000 { ... };`（第 690–693 行）**之后**、
`pil_gpu_mem: gpu-mem@8bf00000`（第 695 行）**之前**插入：

```dts
		pil_video_mem: video-region@86700000 {
			reg = <0 0x86700000 0 0x500000>;
			no-map;
		};
```

**4.4.3 IRIS 与 VIDECOCC 节点**：同文件，在 `usb_1_dwc3_ss: endpoint` 所在块结束处
（第 4183 行的 `		};`，紧邻第 4185 行 `cci0: cci@ac4a000`）**之前**插入：

```dts
		iris: video-codec@aa00000 {
			compatible = "qcom,sc8280xp-iris", "qcom,sm8250-venus";
			reg = <0x0 0x0aa00000 0x0 0x100000>;
			interrupts = <GIC_SPI 174 IRQ_TYPE_LEVEL_HIGH>;

			clocks = <&gcc GCC_VIDEO_AXI0_CLK>,
				 <&videocc VIDEO_CC_MVS0C_CLK>,
				 <&videocc VIDEO_CC_MVS0_CLK>;
			clock-names = "iface", "core", "vcodec0_core";

			power-domains = <&videocc MVS0C_GDSC>,
					<&videocc MVS0_GDSC>,
					<&rpmhpd SC8280XP_MX>,
					<&rpmhpd SC8280XP_MMCX>;
			power-domain-names = "venus", "vcodec0", "mx", "mmcx";

			resets = <&gcc GCC_VIDEO_AXI0_CLK_ARES>,
				 <&videocc VIDEO_CC_MVS0C_CLK_ARES>;
			reset-names = "bus", "core";

			interconnects = <&gem_noc MASTER_APPSS_PROC QCOM_ICC_TAG_ACTIVE_ONLY
					 &config_noc SLAVE_VENUS_CFG QCOM_ICC_TAG_ACTIVE_ONLY>,
					<&mmss_noc MASTER_VIDEO_P0 QCOM_ICC_TAG_ALWAYS
					 &mc_virt SLAVE_EBI1 QCOM_ICC_TAG_ALWAYS>;
			interconnect-names = "cpu-cfg", "video-mem";

			operating-points-v2 = <&iris_opp_table>;
			iommus = <&apps_smmu 0x2a00 0x400>;
			memory-region = <&pil_video_mem>;
			status = "disabled";

			iris_opp_table: opp-table {
				compatible = "operating-points-v2";
				opp-240000000 { opp-hz = /bits/ 64 <240000000>;
					required-opps = <&rpmhpd_opp_svs>, <&rpmhpd_opp_low_svs>; };
				opp-338000000 { opp-hz = /bits/ 64 <338000000>;
					required-opps = <&rpmhpd_opp_svs>, <&rpmhpd_opp_svs>; };
				opp-366000000 { opp-hz = /bits/ 64 <366000000>;
					required-opps = <&rpmhpd_opp_svs_l1>, <&rpmhpd_opp_svs_l1>; };
				opp-444000000 { opp-hz = /bits/ 64 <444000000>;
					required-opps = <&rpmhpd_opp_svs_l1>, <&rpmhpd_opp_nom>; };
				opp-533000000 { opp-hz = /bits/ 64 <533000000>;
					required-opps = <&rpmhpd_opp_nom>, <&rpmhpd_opp_turbo>; };
				opp-560000000 { opp-hz = /bits/ 64 <560000000>;
					required-opps = <&rpmhpd_opp_nom>, <&rpmhpd_opp_turbo_l1>; };
			};
		};

		videocc: clock-controller@abf0000 {
			compatible = "qcom,sc8280xp-videocc";
			reg = <0 0x0abf0000 0 0x10000>;
			clocks = <&rpmhcc RPMH_CXO_CLK>,
				 <&rpmhcc RPMH_CXO_CLK_A>,
				 <&sleep_clk>;
			power-domains = <&rpmhpd SC8280XP_MMCX>;
			required-opps = <&rpmhpd_opp_low_svs>;
			#clock-cells = <1>;
			#reset-cells = <1>;
			#power-domain-cells = <1>;
		};
```

> **属性名必须逐字照抄**：`v7.1-rc3` 的 `iris/iris_platform_gen1.c:268-295` 对 `sm8250_data` 声明
> `icc_table = { "cpu-cfg", "video-mem" }`、`clk_reset_table = { "bus", "core" }`、
> `pmdomain_table = { "venus", "vcodec0" }`、`opp_pd_table = { "mx" }`、
> `clk_table = { "iface", "core", "vcodec0_core" }`、`opp_clk_tbl = { "vcodec0_core" }`，均【已核实】。
> 另：`qcom,sc8280xp-videocc` 在 v7.1-rc3 **已有驱动**（`drivers/clk/qcom/videocc-sm8350.c` 的
> `of_device_id` 即含该串），**无需任何 clk 逆向移植**；`CONFIG_SM_VIDEOCC_8350` 在
> `gaokun3_defconfig:376` 已设 `=m`。

**4.4.4 板级使能**：`arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts`，在 `&gpu { ... };` 块结束处
（buildbot 克隆第 633 行 `};`，其下一段是第 636 行 `&i2c4 {`）**之后**插入：

```dts
&iris {
	firmware-name = "qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn";

	status = "okay";
};
```

【已核实】上游 X13s 写法（commit `595eb4144f2e`）结构相同，只是路径换成
`qcom/sc8280xp/LENOVO/21BX/qcvss8280.mbn`。gaokun3 板级 DTS 的 `reserved-memory` 只声明
`gpu_mem: gpu-mem@8bf00000`，与新增的 `video-region@86700000` **地址不冲突**。

### 4.5 编译

```bash
cd "$KERN_SRC"
NPROC="$(nproc)"; echo "并行度: -j$NPROC"
export CCACHE_DIR="$HOME/gaokun/.ccache" CCACHE_BASEDIR="$HOME/gaokun"
export CCACHE_NOHASHDIR=true CCACHE_COMPILERCHECK=content
export PATH="/usr/lib/ccache:$PATH"
time make O="$KERN_OUT" ARCH=arm64 -j"$NPROC" Image modules dtbs
```

【已核实】buildbot 用 `-j"$(nproc)"` 后接 `modules_prepare`
（`scripts/ci/20_build_kernel_variants.sh:49-50`）。本配方把目标写全为 `Image modules dtbs`，
因为**不安装 ESP，DTB 必须显式产出**。
**耗时**【社区报告+推测】：ccache 热、单变体 ≈ **5.5 分钟**（buildbot CI `ubuntu-24.04-arm` 原生实测）；
半热、两变体 ≈ 9.7 分钟；**本机冷缓存首次 ≈ 15–30 分钟**（8 核 aarch64，【推测】）。
**资源**【推测】：源码树 1.5–2 GB，`O=` 目录 3–6 GB，`modules` 另需约 1 GB
⇒ **开建前预留 ≥15 GB，建议 25 GB**。defconfig 设了 `CONFIG_DEBUG_INFO_REDUCED=y` 且未开
`CONFIG_DEBUG_INFO_BTF`，构建目录远小于发行版配置。内存 `-j8` 峰值约 4–6 GB；8 GB 机器建议降到 `-j4`。

### 4.6 产出物（配方到此为止）

```bash
echo "内核版本 : $(cat "$KERN_OUT/include/config/kernel.release")"
ls -lh "$KERN_OUT/arch/arm64/boot/Image" \
       "$KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb"
find "$KERN_OUT" -name 'qcom-iris.ko*' | sort
```

**不要**执行 `modules_install`（那会写 `/lib/modules/`，属于安装动作）。
**本配方不写 `/boot`、不写 ESP、不跑 `efibootmgr`、不碰 `dkms`、不调用 `kernel-install`。**

### 4.7 交叉编译替代（x86_64 主机）

```bash
sudo apt-get install -y gcc-aarch64-linux-gnu
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
# 其余命令与 §4.3–4.5 完全一致
```

【已核实】buildbot CI 逻辑相同：aarch64 上 `CROSS_COMPILE=""`，否则 `aarch64-linux-gnu-`
（`scripts/ci/20_build_kernel_variants.sh:14-18`）。

---

## 5. 不改 ESP 的产物验证

### 5.1 静态检查（零风险）

```bash
KREL="$(cat "$KERN_OUT/include/config/kernel.release")"; echo "$KREL"   # 期望 7.1.0-rc3-gaokun3
grep -E 'VIDEO_QCOM_(IRIS|VENUS)|CONFIG_VIDEO_DEV|MEDIA_PLATFORM_SUPPORT' "$KERN_OUT/.config"

IRIS_KO="$(find "$KERN_OUT" -name 'qcom-iris.ko' | head -1)"; echo "$IRIS_KO"
modinfo "$IRIS_KO" | grep -E 'filename|description|license|vermagic'
modinfo -F alias "$IRIS_KO" | grep -i 'of:N'
strings "$IRIS_KO" | grep -E 'qcom,sm8250-venus|qcom,sc8280xp-iris|qcom/vpu'

DTS_BLOB="$KERN_OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb"
dtc -I dtb -O dts "$DTS_BLOB" 2>/dev/null | grep -A3 'video-codec@aa00000'
dtc -I dtb -O dts "$DTS_BLOB" 2>/dev/null | grep -A6 'clock-controller@abf0000'
dtc -I dtb -O dts "$DTS_BLOB" 2>/dev/null | grep -B2 -A4 'video-region@86700000'
```

| 属性 | 期望值 |
|---|---|
| `compatible` | `"qcom,sc8280xp-iris", "qcom,sm8250-venus"` |
| `status` | `"okay"`（板级 `&iris` 覆盖 SoC 的 `"disabled"`） |
| `firmware-name` | `"qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn"` |
| `iommus` | `0x2a00` 段（**不是** `0x2e00`） |

### 5.2 不重启的运行时验证

**不能用 `insmod` 插当前内核的模块** —— 构建出的 `vermagic` 属于 `7.1.0-rc3-gaokun3`，
与运行中的 `7.1.0-rc3-gaokun3-el2+` 不匹配，必然 `-EINVAL`。安全的替代：

```bash
IRIS_KO="$(find "$KERN_OUT" -name 'qcom-iris.ko' | head -1)"
modprobe --dry-run --show-depends --set-version "$KREL" qcom-iris 2>&1 | head -20
modinfo -F alias "$IRIS_KO" | grep -i 'of:N'
ls -l /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn
sha256sum /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn
dpkg -L linux-firmware-gaokun3 | grep -i 'qcvss\|gaokun3/'
```

真正判定 probe 是否成功**必须启动到新内核**（属回退项操作，见 §6）。启动后：

```bash
tr -d '\0' < /proc/device-tree/soc@0/video-codec@aa00000/compatible; echo
readlink -f /sys/bus/platform/devices/aa00000.video-codec/driver || echo "未绑定任何驱动"
grep -E 'VIDEO_QCOM_(IRIS|VENUS)' "/boot/config-$(uname -r)"
lsmod | grep -E 'iris|venus'
sudo dmesg | grep -iE 'iris|qcom-iris|vpu|pas|firmware'
v4l2-ctl --list-devices          # 期望出现 Iris Decoder
```

| dmesg 关键字 | 含义 |
|---|---|
| `qcom-iris aa00000.video-codec: ...` | IRIS 驱动已接管该节点（**先看到这行才有戏**） |
| `Iris Decoder`（`v4l2-ctl --list-devices`） | probe 成功，V4L2 设备已注册 |
| `firmware download failed` | 固件路径错/缺失 → 核对 §4.4.4 与 §2.3 |
| `auth and reset failed` / `mem_protect_video_var failed` | **PAS 安全世界拒绝** —— 见 §7.1 |
| 完全无 `qcom-iris` 字样 | 驱动没起：`.config` 没编进去，或 `modalias` 不匹配 |

---

## 6. 安全回退

**本配方未改 ESP，回退即"什么都不做"** —— 重启回原条目即可。若后续自行安装并出问题：

1. ESP 条目 `/boot/efi/loader/entries/8a29534fa802480d9fbb71aa18c01d7b-7.1.0-rc3-gaokun3-el2+.conf`
   是**当前可用**条目，不要覆盖；新内核应生成**新的独立条目**。
2. 另一个 `...-gaokun3+.conf`（非 el2）会在 GUI 阶段卡住，**正好当最后回退项** —— 不要删、不要改。
3. 在 systemd-boot 菜单选旧条目即可；必要时在固件里改 BootOrder。
4. **不要**清理 ESP 上旧内核文件，直到新条目连续启动成功两次以上。
5. 编译侧：`KERN_SRC` 是 git 树，打补丁后已 commit，可用 `git reset --hard <记录的 SHA>` 复位；
   未完成的 `git am` 用 `git am --abort` 撤销。

---

## 7. 风险与不确定项

### 7.1 头号风险：PAS / 安全世界（未解决，且换驱动解决不了）

【已核实】IRIS 与 Venus 走**同一条** PAS 通路（`iris/iris_firmware.c`）：驱动调用
`qcom_scm_pas_auth_and_reset(core->iris_platform_data->pas_id)`，失败时打印 `"auth and reset failed: %d"`；
随后 `qcom_scm_mem_protect_video_var()` 失败时打印 `"qcom_scm_mem_protect_video_var failed: %d"`。
既有诊断已确认本机 `__qcom_mdt_pas_init()` → `qcom_pas_init_image()` 失败
（见 [`docs/video-decode.md`](video-decode.md)）。**IRIS 是否踩同一个坑，本配方无法预先证明**；
这不是配置问题，而是 SCM/PAS 在 EL2 环境下能否工作的问题。
【推测】若失败，应往 `qcom_scm` / `qcom_pas` / `patches/el2/*` 方向查，而非在 media 驱动里查。

> **变体提示**：§4 生成的是标准 `7.1.0-rc3-gaokun3`，与实机运行的 `-gaokun3-el2` **版本串不同**。
> 若要直接替换，需在 §4.5 前追加应用 `patches/el2/*` 并把 `LOCALVERSION` 设为 `-gaokun3-el2`。

### 7.2 未能用一手来源闭环的项

| # | 项 | 置信度与说明 |
|---|---|---|
| 1 | 本机 `qcvss8280.mbn` 与 IRIS Gen1 的兼容性 | 【推测】同 SoC 的 X13s blob（版本串 `video-firmware.1.1-b158…`）被【社区报告】确认可用；gaokun3 原厂 blob 是否同代次**未验证**。失败先换 §2.3 的 X13s 版。 |
| 2 | 手改 DTS 后 DTC 是否零警告 | 【推测】节点照抄已合并的上游 commit，属性名/常量已逐个核验存在；但**未在真实 v7.1-rc3 树上编译过**。报错先看 DTC 行号。 |
| 3 | `patches/upstream/*`、`others/*`、`0099` 是否全部干净应用 | 【推测】属 v7.1-rc3 时代补丁，理论干净；**未实机验证**。冲突按 §4.2 处理。 |
| 4 | `CONFIG_VIDEO_DEV` 经 `olddefconfig` 后是否确为 `y` | 【已核实】Kconfig `default` 由 `MEDIA_PLATFORM_SUPPORT` 触发，§4.3 亦已显式 `--enable` 兜底；**编译后务必按 §5.1 复核**。 |
| 5 | 冷缓存耗时与磁盘占用 | 【推测】15–30 分钟 / 3–6 GB 构建目录。无该配置的公开实测；CI 热缓存数据见 §4.5。 |
| 6 | Ubuntu 26.04 的 GCC / binutils / OpenSSL 具体版本号 | 【未核实】未查证。上游最低要求见 `Documentation/process/changes.rst`（GNU C 8.1、binutils 2.30、pahole 1.26）。 |
| 7 | 是否有 SC8280XP 上 IRIS 失败的报告 | 【已核实-否定】未找到 gaokun3 或 Windows Dev Kit 2023 的任何 IRIS 报告；已找到的 SC8280XP 实测均成功（X13s，fluster H.264/H.265/VP9）。"没有失败报告" ≠ "不会失败"。 |

### 7.3 现场可能需要调试的点

| 症状 | 首选排查 |
|---|---|
| `git am` 冲突 | `git am --show-current-patch=diff`；`git am --abort` 后 `git apply --3way` 手工处理 |
| DTC 报 `duplicate node name` / `Label or path not found` | 确认 `patches/media/0006` **确实未被应用**（§3）；确认 §4.4.1 的 include 已加 |
| DTC 报未定义常量 | 对照 §4.4.1 的常量清单，确认头文件名是 `qcom,sm8350-videocc.h`（**带逗号**） |
| `qcom-iris` 未构建 | 复核 §5.1；VENUS 若为 `y/m` 会连带把 IRIS 的匹配表项 `#if` 编掉（§2.1） |
| probe 时 `devm_clk_get` 失败 | `videocc` 节点没生效 → 查 `CONFIG_SM_VIDEOCC_8350=m` 与模块加载 |
| `-ENODEV` / 未绑定任何驱动 | `cat /sys/bus/platform/devices/aa00000.video-codec/modalias`，与 `modinfo -F alias` 对比 |

---

## 8. 来源索引

基线 release/tag 与内核版本串 = `https://api.github.com/repos/KawaiiHachimi/linux-gaokun-buildbot/releases?per_page=100`；
构建流程与补丁顺序 = `buildbot/.github/workflows/gaokun3-package-debs.yml`、
`buildbot/scripts/ci/20_build_kernel_variants.sh`、`buildbot/scripts/local/build_kernel.sh`；
defconfig = `buildbot/defconfig/gaokun3_defconfig` 与 `buildbot/patches/0099-*.patch`；
`v7.1-rc3` = `https://api.github.com/repos/torvalds/linux/git/refs/tags/v7.1-rc3`；
IRIS 节点原文与合并 commit = <https://patchew.org/linux/20260515-iris-sc8280xp-v7-0-2e21f6db1897@oss.qualcomm.com/>
（v7 补丁 2/3/4）及 `https://raw.githubusercontent.com/torvalds/linux/master/arch/arm64/boot/dts/qcom/sc8280xp.dtsi`；
IRIS Kconfig 与 7.1 互斥 `#if` = `.../master/drivers/media/platform/qcom/iris/Kconfig`、
`.../v7.1-rc3/drivers/media/platform/qcom/iris/iris_probe.c`；
驱动侧表项与固件取值 = `.../v7.1-rc3/drivers/media/platform/qcom/iris/` 下 `iris_platform_gen1.c`、`iris_firmware.c`；
`qcom,sc8280xp-videocc` 驱动 = `.../v7.1-rc3/drivers/clk/qcom/videocc-sm8350.c`；
SC8280XP 固件版本串与 `qcom/vpu/` 布局 = linux-firmware commit
`0c4cd60597a009169e5f2fc24c39a0f7767b52f9`、`36db650dae038be945fb04def591fc726255b09f`；
既有归因分析（Venus 失败链、`-22` 语义）= [`docs/video-decode.md`](video-decode.md)。
