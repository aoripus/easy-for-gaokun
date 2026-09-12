# 音频质量：诊断与调优

> **一句话结论**：GK-W76 上"音质不像四扬声器 HUAWEI SOUND"不是故障，而是**三层叠加的必然结果**——内核主动把功放增益锁在 0.00 dB（注释原文 `until we have active speaker protection in place`）、Linux 侧完全不存在 Windows 那套 Histen APO + ADSP 逐机型调音、且加载的是为双扬声器 ThinkPad X13s 编写的 UCM profile。本项目处置立场：**只把 PA Volume 从 UCM 默认的 12 提到内核上限 17，绝不取消内核限幅。**

> **置信度标记**：【已核实】直读第一手源码、固件、上游 API 或本机实测 ·【社区报告】论坛 / 邮件列表 / 第三方 ·【推测】本项目推断。
> **实测基线**：Ubuntu 26.04 + `7.1.0-rc3-gaokun3-el2+`，声卡名 `SC8280XP-HUAWEI-GAOKUN3`（`/proc/asound/cards` 可见），`audioreach-tplg.bin` 已加载且**能正常出声**。
> **本机 Windows 侧驱动转储 `Drv/` 仅作只读参考，永不入库**（专有软件，体积 1153.6 MB）。

---

## 0. 结论速览

| # | 现象 | 成因 | 证据等级 | 本项目处置 |
|:-:|------|------|:--------:|-----------|
| 1 | 声音偏小、无力度 | 内核 `snd_soc_limit_volume(card, "SpkrLeft PA Volume", 17)` 把 PA 上限压到 **0.00 dB**；数字侧再限 **−3.00 dB** | 【已核实】 | 已把 PA Volume 由 UCM 的 `12`（−3.00 dB）提到内核上限 `17`（0.00 dB），**+3.00 dB** |
| 2 | 低频缺失、动态发闷 | 完全没有 Windows 侧 Histen APO 的 EQ / DRC / 低频扩展；ADSP Speaker Protection 与 VI 反馈模块默认关闭；无 ACDB 校准数据 | 【已核实】 | **明确不做**替代式软件 EQ（无公开字段语义，无法还原） |
| 3 | 无包围感、声场与双扬声器无异 | 硬件是 **2 个 WSA8830 功放**（各单声道）驱动四只单元，每侧 2 只共用一路；跑的是 X13s 双扬声器 profile；Windows 的四扬声器空间音效（`SWS_HP_3D*_MULTI` / `_MULTI9`）在 Linux 无对应物 | 【已核实】 | 记录为已知能力边界；不做无依据的虚拟空间化 |
| 4 | 期待上游 PR #715 救场 | PR #715 新增的 `HUAWEI-MateBook-E-Go.conf` 与 `LENOVO-X13s.conf` **逐字节相同**，即便合并也不改变任何行为 | 【已核实】 | **不依赖**上游 PR |
| 5 | 是否可以把音量继续调大 | UCM 把 `VISENSE Switch` 显式设为 `0`（保护环路传感器关闭）；ADSP Speaker Protection 默认关闭；社区有多起"调错控件烧掉 X13s 扬声器"的警告 | 【已核实】 | **安全红线：不超过 17**，不碰限幅代码 |

**关键澄清**：能出声证明 `audioreach-tplg.bin` 已由 ALSA topology 加载器读入并经 `q6apm` 下发到 ADSP，**链路是通的**。问题不是"缺 DSP"，而是"DSP 之上没有人给它调音参数"。用户 dmesg 中的 `qcom-apm gprsvc:service:2:1: CMD timeout for [1001021] opcode` 说明 GPR 通信通道已建立、仅某条命令超时。【推测】

---

## 1. 硬件拓扑

### 1.1 功放与扬声器：2 个 WSA8830，不是 4 个

【已核实】`sc8280xp-huawei-gaokun3.dts`（`&swr0` 段；buildbot 与本仓库基线一致，上游主线同段逐字节相同）：

```dts
&swr0 {
	status = "okay";

	left_spkr: wsa8830-left@0,1 {
		compatible = "sdw10217020200";
		reg = <0 1>;
		pinctrl-0 = <&spkr_1_sd_n_default>;
		pinctrl-names = "default";
		powerdown-gpios = <&tlmm 178 GPIO_ACTIVE_LOW>;
		#thermal-sensor-cells = <0>;
		sound-name-prefix = "SpkrLeft";
		#sound-dai-cells = <0>;
		vdd-supply = <&vreg_s10b>;
	};

	right_spkr: wsa8830-right@0,2 {
		compatible = "sdw10217020200";
		reg = <0 2>;
		pinctrl-0 = <&spkr_2_sd_n_default>;
		pinctrl-names = "default";
		powerdown-gpios = <&tlmm 179 GPIO_ACTIVE_LOW>;
		#thermal-sensor-cells = <0>;
		sound-name-prefix = "SpkrRight";
		#sound-dai-cells = <0>;
		vdd-supply = <&vreg_s10b>;
	};
};
```

**【已核实】本机实测**：`gpio178` / `gpio179`（WSA8830 功放 enable）均为 `out high` —— **功放已使能，不是没打开**。链路 `lpass` / `wsa-macro` / `swr0` 亦正常。

【已核实】DTS 中 `audio-routing` **只有两项**、`wsa-dai-link` codec 列表为 4 项：

```dts
	audio-routing = "SpkrLeft IN", "WSA_SPK1 OUT",
			"SpkrRight IN", "WSA_SPK2 OUT";
```

```dts
	wsa-dai-link {
		link-name = "WSA Playback";
		cpu      { sound-dai = <&q6apmbedai WSA_CODEC_DMA_RX_0>; };
		codec    { sound-dai = <&left_spkr>, <&right_spkr>, <&swr0 0>, <&wsamacro 0>; };
		platform { sound-dai = <&q6apm>; };
	};
```

【已核实】`sound/soc/codecs/wsa883x.c` 中每个 DAI 为**单声道**：

```c
static struct snd_soc_dai_driver wsa883x_dais[] = {
	{
		.name = "SPKR",
		.playback = {
			.stream_name = "SPKR Playback",
			.channels_min = 1,
			.channels_max = 1,
		},
	},
};
```

→ **2 个通道 = 2 路功放输出驱动 4 只物理单元**，物理上必然是**每侧 2 只单元无源并联/分频共用一路功放**（典型 2-way：高音 + 中低音）。【推测：DTS 与驱动只能证明"2 路功放输出"，分频拓扑无一手来源】

**Windows 侧的证据方向一致但模型不同**：本机调音数据库**明确按多扬声器建模**（`SWS_SPK_VOICE4`、`SWS_HP_3D*_MULTI` / `_MULTI9`，详见 §4）。**这四扬声器空间处理在 Linux 上没有对应物。**

### 1.2 与 X13s 逐字段对比

【已核实】与 `sc8280xp-lenovo-thinkpad-x13s.dts` 对比，扬声器相关字段**只有一个不同**：

| 字段 | gaokun3 | X13s | 差异 |
|---|---|---|---|
| `audio-routing` 扬声器项 | `SpkrLeft IN`←`WSA_SPK1 OUT`；`SpkrRight IN`←`WSA_SPK2 OUT` | 完全相同 | 无 |
| `wsa-dai-link` codec | `<&left_spkr>, <&right_spkr>, <&swr0 0>, <&wsamacro 0>` | 完全相同 | 无 |
| amp 节点名 / `reg` | `wsa8830-left@0,1` / `wsa8830-right@0,2` | 完全相同 | 无 |
| `compatible` | `sdw10217020200` | 完全相同 | 无 |
| `sound-name-prefix` | `SpkrLeft` / `SpkrRight` | 完全相同 | 无 |
| `powerdown-gpios` | `&tlmm 178` / `&tlmm 179`，`GPIO_ACTIVE_LOW` | 完全相同 | 无 |
| `vdd-supply` | `vreg_s10b` | 完全相同 | 无 |
| `pinctrl-0` | `spkr_1_sd_n_default` / `spkr_2_sd_n_default` | 完全相同 | 无 |
| **`model`** | **`"SC8280XP-HUAWEI-GAOKUN3"`** | **`"SC8280XP-LENOVO-X13S"`** | **唯一差异** |

**这张表是全文最重要的一张**：它解释了"为什么能出声"（codec / 功放 / 拓扑三方完全同构）与"为什么音质不对"（增益与路由曲线不是为四扬声器机型设计的）可以同时成立。

### 1.3 硬件能力并不缺

【已核实】`qcom,wsa883x.yaml` 绑定自述：`Qualcomm WSA8830/WSA8832/WSA8835 smart speaker amplifier` / `WSA883X is the Qualcomm Aqstic smart speaker amplifier`。
寄存器映射中存在完整的保护/检测硬件模块：`WSA883X_ISENSE1/2`、`WSA883X_VSENSE1`、`WSA883X_VBAT_SNS`、`WSA883X_TADC_VALUE_CTL`、`WSA883X_CLSH_*`（Class-H 升压）、`WSA883X_DRE_*`、`WSA883X_VAGC_*` / `WSA883X_TAGC_*`、`WSA883X_SPKR_OCP_CTL`、`WSA883X_PA_FSM_BYP_SPKR_PROT_EN_MASK`。

**但** `WSA883X_PA_FSM_BYP_SPKR_PROT_EN_MASK` 在驱动中**只在一处使用** —— `wsa883x_get_temp()` 里临时打开模拟块读温度、读完即清。**它不是保护算法。**【已核实】

> **结论**：WSA8830 是**固定功能模拟功放 + 数字控制/系数层**，片内**没有**运行厂商保护程序的通用 DSP。smart amp 的"smart"在 **Hexagon ADSP** 上。因此"做对 ALSA 路由"只保证"声音到得了功放"，不提供任何音质修正。【已核实】

---

## 2. 为什么 Linux 上听起来不对：三层叠加成因

### 2.1 第一层 —— 内核**主动**限幅（有代码注释承认）

【已核实】`sound/soc/qcom/sc8280xp.c` 的 `sc8280xp_snd_init()`：

```c
	switch (cpu_dai->id) {
	case WSA_CODEC_DMA_RX_0:
	case WSA_CODEC_DMA_RX_1:
		/*
		 * Set limit of -3 dB on Digital Volume and 0 dB on PA Volume
		 * to reduce the risk of speaker damage until we have active
		 * speaker protection in place.
		 */
		snd_soc_limit_volume(card, "WSA_RX0 Digital Volume", 81);
		snd_soc_limit_volume(card, "WSA_RX1 Digital Volume", 81);
		snd_soc_limit_volume(card, "SpkrLeft PA Volume", 17);
		snd_soc_limit_volume(card, "SpkrRight PA Volume", 17);
		break;
	}
```

**本机实测坐实**：`WSA_RX0 Digital Volume` 当前 `values=81`（UCM 原本写 84，被内核钳到 81）；`SpkrLeft PA Volume` 的 `Limits: Playback 0 - 17`。

**这是设计，不是 bug。** 注释原文 `until we have active speaker protection in place` 就是完整理由。

### 2.2 第二层 —— 驱动侧只有 7 个控件，没有任何 EQ / DRC / 保护

【已核实】`sound/soc/codecs/wsa883x.c` 暴露给用户态的**全部**控制面：

```c
static const struct snd_kcontrol_new wsa883x_snd_controls[] = {
	SOC_SINGLE_RANGE_TLV("PA Volume", WSA883X_DRE_CTL_1, 1, 0x0, 0x1f, 1, pa_gain),
	SOC_ENUM_EXT("WSA MODE", wsa_dev_mode_enum, wsa_dev_mode_get, wsa_dev_mode_put),
	SOC_SINGLE_EXT("COMP Offset", SND_SOC_NOPM, 0, 4, 0, ...),
	SOC_SINGLE_EXT("DAC Switch",    WSA883X_PORT_DAC,     0, 1, 0, ...),
	SOC_SINGLE_EXT("COMP Switch",   WSA883X_PORT_COMP,    0, 1, 0, ...),
	SOC_SINGLE_EXT("BOOST Switch",  WSA883X_PORT_BOOST,   0, 1, 0, ...),
	SOC_SINGLE_EXT("VISENSE Switch",WSA883X_PORT_VISENSE, 0, 1, 0, ...),
};
```

DAPM 仅两个 widget（`SND_SOC_DAPM_INPUT("IN")` / `SND_SOC_DAPM_SPK("SPKR")`）。

**没有**：EQ、DRC、限幅器、逐扬声器增益/延时、THD 补偿、扬声器冲程建模。
驱动**不加载任何固件**（grep `request_firmware` 零命中；`Kconfig` 中 `SND_SOC_WSA883X` 无 firmware 依赖）——对比 `SND_SOC_TAS2781_I2C` 显式 `select SND_SOC_TAS2781_FMWLIB`。【已核实】

**【已核实】本机实测**：混音器中匹配 `eq|drc|bass|limiter|protect` 的控件数量 = **0**。

### 2.3 第三层 —— 真正的智能在 ADSP，而 Linux 没有把它打开

【已核实】上游已合并的能力（2025-12-17，Mark Brown 树）：

> "Speaker Protection is capability of **ADSP** to adjust the gain during playback to different speakers and their temperature. This allows good playback without blowing the speakers up. Implement parsing `MODULE_ID_SPEAKER_PROTECTION` from Audioreach topology and sending it as command to the ADSP."
> — commit `0db76f5b2235ab456814ee8e4e2cdf0cef09dd6b`

> "VI Sense module in ADSP is responsible for feedback loop for measuring current and voltage of amplifiers, **necessary for proper calibration of Speaker Protection algorithms**."
> — commit `3e43a8c033c3187e0f441ed5570a0fb5dcc9dafb`

**但这两个模块默认关闭**【已核实】：

> "Speaker protection and VI feedback modules are **disabled by default**. Explicitly enable them when configuring speaker protection."
> — commit `b481eabe5a193ba8499f446c2ab7e0ac042f8776`

而且 **UCM 把保护环路的传感器显式关掉了**【已核实，见 §2.4 引文】：

```text
cset "name='SpkrLeft VISENSE Switch' 0"
cset "name='SpkrRight VISENSE Switch' 0"
```

**并且 Linux 不消费 ACDB**（Qualcomm 的逐机型调音数据库）【已核实】：

> "**AudioReach Creator(ARC), also known as Qualcomm Audio Calibration Tool (QACT)**, is PC-based software providing GUI to audio system designer for composing, configuring, and storing audio graphs into **audio calibration database(ACDB)**… **tuning engineer can tune the audio processing blocks through ARC and store the calibration into the same ACDB on the embedded device**."
> — [AudioReach 架构文档](https://audioreach.github.io/design/arch_overview.html)

**Linux 侧没有 ACDB、没有 QACT、没有任何逐机型扬声器校准数据。**

### 2.4 第三层的直接后果：跑的是 X13s 双扬声器 profile

【已核实】本机 UCM 绑定：

```text
/usr/share/alsa/ucm2/conf.d/sc8280xp/sc8280xp.conf -> ../../Qualcomm/sc8280xp/sc8280xp.conf
```

而 `/usr/share/alsa/ucm2/Qualcomm/sc8280xp/sc8280xp.conf` 把 HUAWEI 机型**显式 Include 到 `LENOVO-X13s.conf`**：

```text
If.HUAWEI {
	Condition {
		Type RegexMatch
		String "${sys:devices/virtual/dmi/id/board_vendor}-${sys:devices/virtual/dmi/id/product_family}"
		Regex "HUAWEI.*MateBook E.*"
	}
	True.Include.huawei.File "/Qualcomm/sc8280xp/LENOVO-X13s.conf"
	False { ... Error "SC8280XP - ... model not supported" }
}
```

**【已核实】本机 DMI 实测**（决定了上面这段正则必定命中）：

| 键 | 值 |
|---|---|
| `sys_vendor` | `HUAWEI` |
| `board_vendor` | `HUAWEI` |
| `board_name` | `GK-W7X-PCB` |
| `product_name` | `GK-W7X` |
| `product_family` | `MateBook E` |
| `product_version` | `M1010` |
| `chassis_type` | `32` |

→ `board_vendor-product_family` = `HUAWEI-MateBook E`，与 `HUAWEI.*MateBook E.*` 匹配成功，**加载的确实是 X13s profile**。

**这解释了"能出声但音质不对"为何同时成立** —— 而且 `Speakers` 这个控件名**只可能来自 UCM 的 `ctl.default.map` 合成**（裸内核只提供 `SpkrLeft PA Volume` / `SpkrRight PA Volume` 两个单声道控件）：

```text
LibraryConfig.remap.Config {
	ctl.default.map {
		"name='Speakers Volume'" {
			"name='SpkrLeft PA Volume'".vindex.0 0
			"name='SpkrRight PA Volume'".vindex.1 0
		}
	}
}
```

→ **UCM profile 加载成功，"缺 UCM"不是本次问题的原因；问题是加载了另一台机器的 profile。**

**X13s UCM 的关键初值**（`Qualcomm/sc8280xp/LENOVO-X13s.conf`，602 B，节选）【已核实】：

```text
BootSequence [
	cset "name='SpkrLeft PA Volume' 12"
	cset "name='SpkrRight PA Volume' 12"
	cset "name='HPHL Volume' 2"
	cset "name='HPHR Volume' 2"
	cset "name='ADC2 Volume' 10"
]
```

配套的 `codecs/qcom-lpass/wsa-macro/init.conf` 又把数字音量写到 **84**（> 内核上限 81，故实际被钳到 81）：

```text
BootSequence [
	cset "name='WSA_RX0 Digital Volume' 84"
	cset "name='WSA_RX1 Digital Volume' 84"
	cset "name='WSA_COMP1 Switch' 0"
	cset "name='WSA_COMP2 Switch' 0"
]
```

> **一处必须实机核验的隐患**：`Qualcomm/sc8280xp/HiFi.conf` 的 `EnableSequence` 依赖 AudioReach 拓扑生成的控件（`RX_CODEC_DMA_RX_0 Audio Mixer MultiMedia1`、`WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2`、`MultiMedia4 Mixer VA_CODEC_DMA_TX_0`、`MultiMedia3 Mixer TX_CODEC_DMA_TX_3`）。若这些控件在本机不存在，对应 `cset` 会**静默失败**。核验命令见 §7。【推测】

---

## 3. 量化：被放弃的动态余量

【已核实】`wsa883x.c` 中 PA 增益的 TLV 曲线：

```c
static const SNDRV_CTL_TLVD_DECLARE_DB_RANGE(pa_gain,
	0, 14, TLV_DB_SCALE_ITEM(-300, 0, 0),
	15, 29, TLV_DB_SCALE_ITEM(-300, 150, 0),
	30, 31, TLV_DB_SCALE_ITEM(1800, 0, 0),
);
```

| 控件值 | 实际增益 | 说明 |
|:-:|---|---|
| 0 – 14 | **−3.00 dB**（平台段） | UCM 默认写入 `12` 落在这里 |
| 15 | −3.00 dB | 平台段终点；自此每级 +1.50 dB |
| 16 | −1.50 dB | |
| **17** | **0.00 dB** | **内核硬性上限（本项目当前值）** |
| 18 – 28 | 每级 +1.50 dB | Linux 无法企及 |
| **29 – 31** | **+18.00 dB** | 硬件最高档（29 已到顶，30/31 同值） |

> **dB 换算规则（本机实测校准）**：`SNDRV_CTL_TLVT_DB_RANGE` 中每段
> `{min_index, max_index, TLV_DB_SCALE(min_dB, step, mute)}` 的换算公式是
> `dB = min_dB + (value − min_index) × step`，**不是** `min_dB + value × step`。
> 因此 `17` 落在 `15..29` 段的第 3 个点：`−300 + (17 − 15) × 150 = 0`（0.00 dB）。
> 【已核实】本机用 alsa-lib 公共 API `snd_mixer_selem_get_playback_dB()` 直读得到
> `SpkrLeft PA`（范围 0–17）= **+0.00 dB**，与 `alsamixer` 界面显示的
> `Speakers [dB gain: 0.00, 0.00]` 完全一致，交叉验证通过。

**本机实测**：`amixer -c 0 cget name='SpkrLeft PA Volume'` → `Limits: Playback 0 - 17`，当前 `values=17`（**已由手工从 UCM 默认的 12 改为 17**）。

### 3.1 账要分开算

下表的每一项都用 alsa-lib 的 dB 换算直读校验过：

| 项 | 数值 | 状态 |
|---|---|---|
| PA Volume `12`（UCM 默认） | **−3.00 dB** | 原始基线 |
| PA Volume `17`（内核上限，本项目当前值） | **0.00 dB** | **本项目已完成，净收益 +3.00 dB** |
| PA Volume `29`/`30`/`31`（硬件最高档） | **+18.00 dB** | 被内核限幅阻止，**缺口 18.00 dB** |
| `WSA_RX0/RX1 Digital Volume`（上游 UCM 意图 `84`） | **0.00 dB** | 内核限幅 81，**实际 −3.00 dB** |
| 数字侧被内核吃掉的部分 | **−3.00 dB** | 未解除 |
| **本机当前链路总增益** | **−3.00 dB**（PA 0.00 + 数字 −3.00） | 已是内核允许范围内的最高值 |
| **硬件可达总增益** | **+18.00 dB**（PA +18.00 + 数字 0.00） | **合计仍被放弃 21.00 dB** |

> **口径说明**：以 **UCM 原始默认**（PA `12` = −3.00 dB + 数字 `84` = 0.00 dB，合计 −3.00 dB）
> 为起点、以**硬件可达**（+18.00 dB）为终点，缺口是 **21.00 dB**；若再算上内核把数字侧
> 从 `84` 钳到 `81` 的那 3.00 dB，从"UCM 本可写出的状态"到"硬件可达"的保守口径是
> **24.00 dB**。两个数字描述同一件事，**本文档统一采用"本机当前仍被放弃 21.00 dB"**，
> 24.00 dB 作为含数字侧限幅的保守口径并列记录。

**因此准确表述是**：

> **这是"被刻意调小"，不是"音质差"。** 声学性能一直都在，只是内核为了在没有保护的前提下避免损坏扬声器，主动把它锁住了。

### 3.2 限幅的历史与现状

【社区报告】LKML v5 cover（[lkml.org/lkml/2024/1/22/1305](https://lkml.org/lkml/2024/1/22/1305)）：

> "To reduce the risk of speaker damage the PA gain needs to be limited on machines like the Lenovo Thinkpad X13s until we have active speaker protection in place. Limit the gain to the current default setting provided by the UCM configuration … The wsa883x PA volume control also turned out to be broken, which meant that the default setting used by UCM configuration is actually the lowest level (−3 dB)."

【社区报告】Srinivas Kandagatla 的原始 0 dB 数字限幅（[lkml.org/lkml/2023/12/4/568](https://lkml.org/lkml/2023/12/4/568)）：

> "Limit the speaker digital gains to 0dB so that the users will not damage them. Currently there is a limit in UCM, but this does not stop the user form changing the digital gains from command line. So limit this in driver which makes the speakers more safer **without active speaker protection in place**."

【已核实】**截至 2026 年 9 月，主线 `sc8280xp.c` 仍带着这段注释** —— 两年半过去，限幅没有解除。

---

## 4. Windows 侧那层"丢失的调音"

### 4.1 本机一手证据（`Drv/` 只读引用，不入库）

| 类别目录 | 关键文件 | 作用 |
|---|---|---|
| `Drv\音频处理对象(APO)\histenapo.inf_arm64_964ebf522147d270\` | `HistenAPO.dll` (4,363,640 B)、`histen.dll`、**`reb_config.bin` (344,736 B)**、`sur_config.bin`、`tws_config.bin`、`lph_config.bin`、`teh_config.bin`、`ten_config.bin` | **Huawei Histen 音效 APO**（Windows 侧 EQ / DRC / 环绕处理） |
| `Drv\扩展\oemxaudioext_histen.inf_arm64_946d759c58e84313\` | **`histen_config_GaoKunGen3.xml` (202,341 B)**、`act_config_Common.bin` | **★ gaokun3 专属调音参数（34 个 NV 块）** |
| `Drv\软件组件\hwaudioservice.inf_arm64_397c208947a60902\` | `HWVEAudioService.exe` (4,604,280 B)、`HWVEAudioSession.exe`、`HWAudioEventMsg.dll`、`device_config.xml`、`operator_settings.xml` | Huawei 音频服务（模式 / 策略 / 会话） |

`histenapo.inf`（UTF-16）注册项【已核实】：

```text
HKCR,CLSID\%HISTEN_MFX_CLSID%,,0,"HISTEN Render MFX Class"
HKCR,AudioEngine\AudioProcessingObjects\%HISTEN_MFX_CLSID%,FriendlyName,0,HistenPostMFX
HKCR,AudioEngine\AudioProcessingObjects\%HISTEN_MFX_CLSID%,Copyright,0,"Copyright (c) Huawei Inc."
HISTEN_OMFX_CLSID = "{3616B959-A965-37BE-1056-ADF8FC7713C0}"
HISTEN_MFX_CLSID  = "{72B099B1-88FE-4D7F-A3C2-F418AF25AA0E}"
```

`oemxaudioext_histen.inf` 中 **gaokun3 的绑定**（说明这份 XML 是**逐机型**投放的）【已核实】：

```text
;;GaokunGen3
%Device.ExtensionDesc% = DeviceExtension_Install_GaoKunGen3,AUCD\VEN_QCOM&DEV_0629&SUBSYS_QRD08280

[histen_config_GaoKunGen3.CopyList]
histen_config_GaoKunGen3.xml
act_config_Common.bin

histen_config_GaoKunGen3.CopyList = 10, System32\HWAudioDriver
```

→ Windows 把 `histen_config_GaoKunGen3.xml` 拷入 `System32\HWAudioDriver`，由 Histen APO 加载。

### 4.2 `histen_config_GaoKunGen3.xml` 的 34 个 NV 块

文件头：项目组 `ID="24" PRODUCT="Morgan" VERSION="002.01"`。【已核实】

| NV ID | NAME | 语义 |
|---|---|---|
| 30160 | `SWS_SYSTEM_CFG` | 系统级配置 |
| 30161 / 30163 / 30165 / **30181** / **30183** | `SWS_SPK_LANDSCAPE_ONE` / `_TWO` / `_THREE` / **`_FOUR`** / **`_FIVE`** | 笔记本形态下 5 档扬声器音效 |
| 30185 | **`SWS_SPK_VOICE4`** | **四扬声器语音模式** |
| 30195 / 30197 / 30199 / 30201 / 30203 | `SWS_HP_3DOFF` / `_3DLISTEN` / `_3DFRONT` / `_3DWIDE` / `_3DGRAND` | 3D 空间音效开关与四种预设 |
| 30207 – 30235 | `SWS_SPK_LANDSCAPE_*_MOVIE` / `_GAME` / `_EDUCATION` | 场景化档位（各 3 档） |
| 30243 | `SWS_RING_PARA` | 铃声参数 |
| 30245 – 30251 | `SWS_HP_3DLISTEN_MULTI` / `_3DFRONT_MULTI` / `_3DWIDE_MULTI` / `_3DGRAND_MULTI` | **多扬声器专用空间音效** |
| 30253 – 30259 | `SWS_HP_3D*_MULTI_MOVIE` | 多扬声器 + 影音场景 |
| 30261 – 30267 | `SWS_HP_3D*_MULTI9` | **多扬声器扩展空间音效** |

**读法**：`_MULTI` / `_MULTI9` 即**四扬声器专用的空间音效参数集**，正是"HUAWEI SOUND 四扬声器体验"的参数来源；`SWS_SPK_VOICE4` 为四扬声器语音模式。

`SWS_SYSTEM_CFG`（NV 30160）实际参数值【已核实】：

```text
{0x40c,0xccc,0x2413,0x47fa,0x3,0x3,0x3,0x3,0x3,0x3}
```

末 6 个 `0x3` 与多通道 / 多扬声器配置相关，**具体字段语义无公开文档，本文档不作断言**。【推测】

### 4.3 逐层对比

| 层 | Windows（这台机器） | Linux（当前基线） |
|---|---|---|
| 扬声器效果链 | **Histen APO**（MFX + OMFX + EFX） | **无**（Linux 无 APO 概念）【已核实】 |
| Qualcomm 代理 APO | `qcasd_apo8380.inf`（`SWC\VEN_QCOM&DEV_ASDAPO_8380`，arm64） | 无【社区报告】 |
| **逐机型调音参数** | **`histen_config_GaoKunGen3.xml`，34 个 NV 块** | **无**【已核实】 |
| ADSP 音效算法 | 有，ACDB 校准 | 有（拓扑已加载），**模块默认关闭、无 ACDB 数据** |
| 模式化音效 | Music / Movie / Game / Education + 4 种 3D 预设 | 无 |
| 四扬声器空间处理 | `SWS_HP_3D*_MULTI` / `_MULTI9` | 无 |
| 扬声器保护 / 温漂补偿 | 有（IV sense + 出厂校准） | **无** → 内核只好把音量砍掉 |
| codec 寄存器 bring-up | 有 | **有**（`wsa883x.c`） |

### 4.4 听感上"失去了什么"

- **响度**：仍被放弃 **21.00 dB** 可达动态余量（内核 PA 限幅 18 dB + 数字侧限幅 3 dB）。【已核实（限幅值与 alsa-lib 直读 dB）/ 推测（整体听感折算）】
- **低频**：小扬声器要靠建模与 EQ 才能安全下潜。TI 的应用文档说明了这一点【已核实】：

  > "**A limiter implementation does not use any advanced modeling of the speaker displacement … and cannot protect from overexcursion.** The limiter relies on proper equalization to prevent overexcursion of the speaker. **The Smart Amp protection solution uses models of the speaker excursion updated in real time to protect the speaker from overexcursion.**"
  >
  > "To push the speaker closer to its actual limits and drive louder audio, you will need to take advantage of an **IV-sense Class-D amplifier or a Smart Amp**… With a Smart Amp, you can remove the headroom in the feedforward-limiter solution and **deliver peak power to the speaker until it reaches its actual thermal limit**."
  > — [TI SSZT848](https://www.ti.com.cn/document-viewer/cn/lit/html/SSZT848/GUID-27E3C581-A61B-4BFE-AB84-CE29D404C047)

- **最贴近的类比** —— Cirrus CS35L56 内核文档描述了"没有 OEM 调音参数时"的硬件缺省行为【已核实】：

  > "On most SoundWire systems the amplifier has a default minimum capability to produce audio. **However this will be** — **at low volume, to protect the speakers, since the speaker specifications and power supply voltages are unknown.** — **a mono mix of left and right channels.**"
  >
  > "Each amplifier requires two firmware files… **The firmware is customized by the OEM to match the hardware of each laptop, and the firmware is specific to that laptop.** … **Firmware files are not interchangeable between laptops.**"
  > — [CS35L56 内核文档](https://origin.kernel.org/doc/html/v6.15/sound/codecs/cs35l56.html)

> ### 一处必要的诚实限定
> 社区文档**没有**说"缺保护会引入失真"。相反，TI 指出是**廉价的 limiter 替代方案**才引入 artifact；KLIPPEL 类的 smart amp 算法**降低**谐波 / 互调失真。因此准确表述是：
>
> **缺少调音 ⇒ 保守、偏小、低频缺失、动态余量被放弃；缺少保护 ⇒ 大音量下有热 / 冲程损坏风险。**
> **不得**写成"缺保护导致失真"。

---

## 5. 上游与社区现状

### 5.1 内核侧

| 项 | 状态 | 等级 |
|---|---|---|
| `sc8280xp.c` 音量限幅（17 / 81） | **仍在主线**，注释 `until we have active speaker protection in place` 未改 | 【已核实】 |
| `MODULE_ID_SPEAKER_PROTECTION` 解析 | **已上游**（`0db76f5b2235`），但模块**默认关闭**（`b481eabe5a19`） | 【已核实】 |
| ADSP VI Sense（电流/电压反馈） | **已上游**（`3e43a8c033c3`），同样**默认关闭** | 【已核实】 |
| AudioReach / `q6apm` | 已上游（`sound/soc/qcom/qdsp6/`） | 【已核实】 |
| AudioReach TDM backend 系列 | 仍在 review：v4（2026-07）被 Mark Brown 以 *"Please resend this once there are enough dependencies in to allow it to be applied."* 退回 | 【社区报告】 |
| `audioreach-conf` 参考数据库 | 在 Raspberry Pi 4 上验证，模块列表**不含 speaker protection** | 【已核实】 |
| Windows Dev Kit 2023 / QRD（`blackrock`） | 唯一音频工作是 **DisplayPort 音频**（`sc8280xp-microsoft-blackrock: DP audio + 4-lane altmode` v2，2026-08-25），**无** WSA883x / 扬声器 / UCM 报告 | 【社区报告】 |

### 5.2 UCM 侧

【已核实】上游 `alsa-ucm-conf` 的 `ucm2/Qualcomm/sc8280xp/` **只有 3 个文件**：

| 文件 | 大小 |
|---|---|
| `HiFi.conf` | 2,349 B |
| `LENOVO-X13s.conf` | 602 B |
| `sc8280xp.conf` | 391 B |

`ucm2/conf.d/sc8280xp/` 只有 1 个 37 B 的转发文件，内容为 `../../Qualcomm/sc8280xp/sc8280xp.conf`。上游 `sc8280xp.conf` 分发器**只匹配 X13s**，其他机型直接 `Error "… model not supported"`。

> **结论：上游 UCM 不覆盖 gaokun3，只覆盖 Lenovo X13s。**【已核实】
> **本机三份文件与上游一一对应**，说明本机 UCM 就是上游内容 + buildbot 的分发改写。**【已核实】**

### 5.3 PR #715：即便合并也无用

> **PR #715 — "UCM2: Qualcomm: sc8280xp: add Huawei MateBook E Go support"**
> [alsa-project/alsa-ucm-conf#715](https://github.com/alsa-project/alsa-ucm-conf/pull/715)，作者 `whitelewi1-ctrl`，开于 2026-03-08，状态 `open` / `merged:false` / `mergeable:true` / `mergeable_state:"clean"`，1 commit，2 文件，+40 / −1。【已核实】

- 新增的 `ucm2/Qualcomm/sc8280xp/HUAWEI-MateBook-E-Go.conf`，其 blob sha `de6d9c6cb59fe83e2ab98392275dfbeb80f9f78f` 与 master 的 `LENOVO-X13s.conf` **逐字节相同** —— 即"官方的 Huawei profile"在内容上**就等于社区那个 symlink hack**。
- 同时改写 `sc8280xp.conf`，增加 `If.HUAWEIMateBookEGo`（`Regex "HUAWEI.*MateBook E.*"`）。
- 唯一阻碍是 **DCO `Signed-off-by` 格式**（维护者 perexg 2026-03-27：*"Not valid signed-off-by line."*；bot 2026-03-30：`whitelewis@users.noreply.github.com` 属 noreply 邮箱不被接受）。**没有任何技术性反对意见。**

→ **即便 PR #715 合并，本项目这台机器的音频行为不会有任何改变。** 不应把它当作解决方案。

> 顺带核验：PR #715 依赖 `product_family == "MateBook E"`。**本机实测 `product_family = MateBook E`，会命中。**

### 5.4 社区对 gaokun3 音频的处理

【已核实】`right-0903/linux-gaokun` 的 `README.MD`：

```text
| Audio  | works | see [below](#audio) |
```

```text
## Audio
Recently, use the X13s' profile. \
`ln -sf ../../Qualcomm/sc8280xp/LENOVO-X13s.conf /usr/share/alsa/ucm2/conf.d/sc8280xp/HUAWEI-GK_W7X-M1010-GK_W7X_PCB.conf`
```

同仓库 `Virtualisation` 章节明确 audio 依赖 DSP / remoteproc：使用 [`qebspil`](https://github.com/stephan-gh/qebspil) 并在 Linux 启动前应用 `patch sets/el2`，*"if you want DSP / remoteproc-dependent functions (such as audio) to work in EL2"*。`Remoteproc` 行标注 `adsp, cdsp, sdsp` 可用。

【已核实】唯一与该 symlink 相关的 PR 是 **#8「Make UCM workaround survive package update」**（merged 2026-06-14，dantmnf）。其 diff 只做了一件事 —— 把脆弱的 `sed` 改写换成稳定 symlink：

```diff
- sed -i 's/LENOVO.*ThinkPad X13s.*/LENOVO.*ThinkPad X13s.*|HUAWEI.*MateBook E.*"/' /usr/share/alsa/ucm2/Qualcomm/sc8280xp/sc8280xp.conf
+ ln -sf ../../Qualcomm/sc8280xp/LENOVO-X13s.conf /usr/share/alsa/ucm2/conf.d/sc8280xp/HUAWEI-GK_W7X-M1010-GK_W7X_PCB.conf
```

评论要点：right-0903 询问 `${CardLongName}` 的构成规则与"是否所有单元的 `product_version` 都是 M1010"；dantmnf 指出 `${CardLongName}` 来自 `SNDRV_CTL_IOCTL_CARD_INFO`，也可见于 `/proc/asound/cards`，并建议 `strace alsaucm dump text`。【已核实】

【已核实】`KawaiiHachimi/linux-gaokun-buildbot` 的音频相关 issue / PR 数量为 **0**；`docs/` 下无任何音频章节（grep `音频|声音|扬声器|audio|Audio|UCM` 零命中）。仓库音频资产清单：

| 路径 | 大小 |
|---|---|
| `tools/audio/sc8280xp.conf` | 783 B（即 §2.4 的分发文件） |
| `tools/image-assets/etc/modprobe.d/audio-deps.conf` | 57 B（`softdep pinctrl_sc8280xp_lpass_lpi pre: lpasscc_sc8280xp`） |
| `tools/image-assets/etc/modules-load.d/audio.conf` | 34 B |
| `firmware/qcom/sc8280xp/HUAWEI/gaokun3/audioreach-tplg.bin` | 24,296 B |
| `firmware/qcom/sc8280xp/HUAWEI/gaokun3/{adspr,adspua,batspr,cdspr}.jsn` | 670 / 703 / 516 / 513 B |
| `firmware/qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin` | symlink（mode 120000，34 B）→ 把 ALSA card name 映射到拓扑文件【推测：映射机制】 |

> **上游 `linux-firmware` 根本没有 `qcom/sc8280xp/HUAWEI/` 目录**（只有 `LENOVO/21BX` 与 `radxa/dragon-q8b`）【社区报告】→ 换内核包会丢固件。本机当前能出声，故与本议题无关。

### 5.5 同平台（X13s）用户的抱怨 —— 与 gaokun3 的关键区别

【社区报告】[Ubuntu Discourse：Status of Ubuntu support for Lenovo ThinkPad X13s](https://discourse.ubuntu.com/t/status-of-ubuntu-support-for-lenovo-thinkpad-x13s/44652)（348 帖，32.5k 浏览）：

> #6：*"'Audio volume is very low.' Well, it is low because the speaker hardware is set to low levels in the mixer … set them [SpkrRight/SpkrLeft PA Volume] to like 80…90."*

> #8（juergh）：*"…SpkrLeft PA Volume all the way up but it doesn't change the volume. I'm also a little reluctant since there are reports that **you can blow your X13s speakers if you're not careful**."*

> #14：*"At about 80% the audio is just barely usable, but anything beyond 80% and the audio becomes distorted. Its not the speaker system. The same distortion can be heard through headphones."*

> **#97（juergh，Canonical）—— 最权威的一条**：*"And yes, the sound level is still **deliberately set to low because HW audio protection is not enabled** and **you can blow your speakers if you fiddle with the wrong control**."*

> #104：*"The sound is not super quiet as it was, but it is **still significantly quieter than under Windows**, so the alsamixer controls to bring it up to normal levels are still needed."*

【社区报告】[Launchpad #2115898「Audio broken on ThinkPad X13s」](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2115898)：自 `6.14.0-17-generic` 起音频损坏，Ubuntu 自有 SAUCE 补丁名为 *"Change: cracking sound fix"*；Juerg 指出 *"Both mainline 6.14.4 and 6.14.6 work just fine, so this is Ubuntu breakage."* 修法是 revert 该 SAUCE commit。

【社区报告】爆音/咔哒声由 Johan Hovold 回移 `0220575e65a` + `805ce81826c8` 修复（[lkml.org/lkml/2023/11/23/496](https://lkml.org/lkml/2023/11/23/496)）：*"which specifically fix a loud crackling noise when starting a stream on the Lenovo ThinkPad X13s"*。

参考平台 X13s 的官方已知问题清单（[jhovold X13s wiki](https://raw.githubusercontent.com/wiki/jhovold/linux/X13s.md)）中，音质相关只有两条：

```text
### Audio
* Active speaker protection not enabled, volume limited for now
* Pops and clicks
```

并注明用户态依赖 `alsa-ucm-conf 1.2.11`；`1.2.14` 有**麦克风回归**（回退到 `1.2.13` 作临时方案）。

> **★ 关键区别**：X13s 用户的抱怨是 **"音量小 + 爆音"**，**没有**任何"音质/音色差"的记录 —— 因为 X13s 只有双扬声器，本来就没有"四扬声器体验"可对比。
> **GK-W76 的"音质差"在社区中没有任何先例报告，本项目是第一次系统性地面对并归因这个问题。**【已核实（无报告）/ 推测（原因）】

---

## 6. 本项目的处置方案

### 6.1 立即可做（已实施，零风险）

| 动作 | 内容 | 依据 | 状态 |
|---|---|---|---|
| **A1** | 把 `SpkrLeft/Right PA Volume` 由 UCM 默认的 `12`（−3.00 dB）提到内核上限 **`17`（0.00 dB）**，净收益 **+3.00 dB** | 内核 TLV 曲线 + `Limits: Playback 0 - 17` + alsa-lib 直读 dB | **已实施**：`scripts/30-audio.sh --apply` 安装 gaokun3 专用 profile，并在重启音频栈后写入增益 + `alsactl store`（顺序与原因见 §6.5） |

`17` 是**内核硬性上限**，不是"我们认为安全的经验值" —— 内核已经替用户把这个界限划好了。当前状态即"在不触碰限幅代码的前提下能达到的最大音量"。

> **关于"还能不能再响一点"**：GNOME 音量菜单里可以打开 **超音量（over-amplification）**，把音量推到 100% 以上。那是
> **PipeWire 软件域的数字放大**，会直接在已渲染的 PCM 上做乘法、**可能削波**，也不属于内核限幅所要保护的那一段
> 增益链。本项目**不修改、不推荐、也不把它算作调优成果**：它是一个用户可见的通用桌面功能，不是本机的适配点。
> 另外本机实测：空闲时 ADSP 侧的 `stream1.vol_ctrl1 MultiMedia2 Playback Volume` 恒为 `8192`，
> 不随 `wpctl set-volume` 变化（该控件只在 PCM 被打开时由驱动下发），因此它与桌面音量是两个独立的域。

### 6.2 需评估（有收益，但必须先取证）

| 编号 | 候选动作 | 前置条件 | 风险 |
|:-:|---|---|---|
| **B1** | ~~产出真正属于 gaokun3 的 UCM profile~~ —— **已完成**：项目产出 `config/ucm2/Qualcomm/sc8280xp/HUAWEI-GK-W7X.conf`，以 `${CardLongName}.conf` 形式挂进 `conf.d/sc8280xp/`，BootSequence 的 PA Volume 写 17；安装/撤销由 `scripts/30-audio.sh --apply / --revert` 负责 | 已在本机验证 DMI 正则与 `CardLongName` 稳定性（`HUAWEI-GK_W7X-M1010-GK_W7X_PCB`） | 低。仅改用户态配置，`--revert` 可精确还原 |
| **B2** | 向 `alsa-ucm-conf` 提交独立 PR：**在 X13s profile 之外单独维护 Huawei 分支**，即使当前内容相同也保留分化点 | 需先完成 B1；提交须带合规 `Signed-off-by`（PR #715 正是卡在这里） | 低 |
| **B3** | 核验 `HiFi.conf` `EnableSequence` 依赖的 AudioReach 控件（`* Audio Mixer MultiMedia*`、`* Mixer VA_CODEC*`）在本机是否全部存在 | 见 §7 命令；若缺失则 `cset` 静默失败，应记录为独立缺陷 | 无（只读） |
| **B4** | 调查关闭内核限幅之外的**上游路径**：向上游提出 "gaokun3/X13s 主动扬声器保护 enablement"（把 `MODULE_ID_SPEAKER_PROTECTION` 与 VI Sense 打开） | 需要 topology 侧提供 `MODULE_ID_SPEAKER_PROTECTION` 实例与 ACDB 校准数据 —— **当前 `audioreach-tplg.bin` 与 `audioreach-conf` 都不包含 speaker protection 模块** | **高**：这是"恢复 21.00 dB"的唯一正路，但短期不可得 |

### 6.3 明确不做（附理由）

| 编号 | 不做的事 | 理由 |
|:-:|---|---|
| **C1** | **不取消、不改写内核音量限幅**（不 patch `snd_soc_limit_volume`，不使用 `snd_soc_limit_volume` 之外的手段绕过） | UCM 明确把 `SpkrLeft/Right VISENSE Switch` 设为 `0`（**保护环路的电流/电压反馈传感器是关闭的**）；ADSP Speaker Protection 模块**默认关闭**；Linux 上**没有任何主动扬声器保护**。社区有多起"调错控件烧掉 X13s 扬声器"的警告（[Discourse #8 / #97](https://discourse.ubuntu.com/t/status-of-ubuntu-support-for-lenovo-thinkpad-x13s/44652)）。**超出 17 需要真正的保护，而 Linux 上没有。** |
| **C2** | 不把 `SpkrLeft/Right VISENSE Switch` 打开"试试" | 反馈传感器开启会引入额外的模拟通路行为，而**没有配套的保护算法消费这些数据**（模块默认关闭、无 ACDB 校准），徒增不确定性 |
| **C3** | 不做基于 `histen_config_GaoKunGen3.xml` 的软件 EQ / DRC 复刻（PipeWire filter-chain、LADSPA、LV2） | 该 XML 是**不透明的参数 blob**（形如 `PARAM_VALUE="{0x40c,0xccc,...}"`），**没有公开的字段语义**，无法直接反推 EQ 曲线；真正的还原需要逆向 `HistenAPO.dll`（4.3 MB）或做实测频响测量 + 手工调参。**在没有测量设备与验证手段前不产出猜测性曲线。**【推测】 |
| **C4** | 不做无依据的"四扬声器虚拟空间化" | 硬件只有 2 路功放输出（`channels_max = 1`），每侧 2 只单元共用一路；Windows 的 `SWS_HP_3D*_MULTI` / `_MULTI9` 参数集是私有格式，无公开语义 |
| **C5** | 不把 `Drv/` 下的任何二进制 / 参数文件复制进仓库 | 专有软件，版权风险；`.gitignore` 已排除 `Drv/` |
| **C6** | **不利用未被内核限幅的 `WSA_RX0/RX1_MIX Digital Volume`** 来"补回"音量 | 本机实测该控件范围 **0–124**，`84 = 0.00 dB`、`124 = +40.00 dB`，**没有任何内核限幅**。它与被限到 `81`（−3.00 dB）的 `WSA_RX0/RX1 Digital Volume` 同属 WSA macro 的数字增益级（【推测】：两者都在 RX0/RX1 数字通路上）。内核注释写明限幅目的是 `to reduce the risk of speaker damage until we have active speaker protection in place`；利用 MIX 级把总数字增益推回正值，**在效果上等同于取消该保护决策**，属于 C1 的同一类行为，因此明确不做，并在此记录以免后来者误用 |
| **C7** | 不把 `SpkrLeft/Right COMP Switch`、`COMP Offset` 当作"音质调节旋钮"来试参数 | 这是 WSA8830 内建压缩器（compander）的使能与偏置，属于**扬声器保护/响度整形**的一部分，当前值（`on` / offset `2`）来自 wsa883x 驱动默认与上游 UCM 行为。在不知道扬声器热/冲程模型的前提下调整它，与 C1 同类风险 |

### 6.4 安全红线（一句话版）

> **只把 PA Volume 从 12 提到内核上限 17。绝不取消内核限幅。**

---

## 7. 复现与验证命令

> 以下命令在目标机（`gaokun3`、Ubuntu 26.04、`7.1.0-rc3-gaokun3-el2+`）上执行。**§7.1 / §7.2 / §7.3 全部只读**；§7.4 含写操作，**先备份**。

### 7.1 确认身份与 UCM 绑定

```bash
# 声卡名 / 卡号
cat /proc/asound/cards

# DMI —— 决定 UCM 分发器命中哪个分支
cat /sys/devices/virtual/dmi/id/sys_vendor
cat /sys/devices/virtual/dmi/id/board_vendor
cat /sys/devices/virtual/dmi/id/board_name
cat /sys/devices/virtual/dmi/id/product_name
cat /sys/devices/virtual/dmi/id/product_family
cat /sys/devices/virtual/dmi/id/product_version
cat /sys/devices/virtual/dmi/id/chassis_type

# UCM 实际绑定了哪个 profile
ls -l /usr/share/alsa/ucm2/conf.d/sc8280xp/
readlink -f /usr/share/alsa/ucm2/conf.d/sc8280xp/*.conf
grep -rn "HUAWEI\|LENOVO" /usr/share/alsa/ucm2/Qualcomm/sc8280xp/ 2>/dev/null
ls -l /usr/share/alsa/ucm2/Qualcomm/sc8280xp/

# UCM 展开结果（确认 profile 加载成功）
alsaucm -c SC8280XP-HUAWEI-GAOKUN3 listcards 2>&1 | head -20
alsaucm -c SC8280XP-HUAWEI-GAOKUN3 dump text 2>&1 | head -80

# 版本（X13s wiki 建议 1.2.11；1.2.14 有麦克风回归）
dpkg -l | grep -i alsa-ucm
```

### 7.2 确认限幅与控件状态（★ 最关键）

```bash
# 功放音量：期望 Limits 上限 = 17，当前值 = 17（本项目已调整）
amixer -c 0 cget name='SpkrLeft PA Volume'
amixer -c 0 cget name='SpkrRight PA Volume'

# 数字音量：期望 81（= 内核限幅值；UCM 原本写 84 被钳）
amixer -c 0 cget name='WSA_RX0 Digital Volume'
amixer -c 0 cget name='WSA_RX1 Digital Volume'

# UCM 合成的立体声控件是否存在（存在 ⇒ UCM profile 已加载）
amixer -c 0 cget name='Speakers Volume' 2>&1 | head -5

# EQ / DRC / 保护类控件数量（注意：**不是** 0，但名字里都不含 eq/drc/limiter）
amixer -c 0 controls | grep -ciE 'eq|drc|bass|limiter|protect'   # 计数为 0 属"命名巧合"

# 全部"音质 / 限幅"相关控件的**原始名**与本机实测值（原始名必须带 Volume/Switch 后缀）
for c in 'IIR1 Band1' 'IIR1 Band1 Switch' 'IIR2 Band1 Switch' \
         'WSA_COMP1 Switch' 'WSA_COMP2 Switch' 'RX_COMP1 Switch' 'RX_COMP2 Switch' \
         'WSA_Softclip0 Enable' 'WSA_Softclip1 Enable' 'RX_Softclip Switch' 'CLSH Switch' \
         'WSA_RX0_MIX Digital Volume' 'WSA_RX1_MIX Digital Volume' 'EAR_PA Volume'; do
  printf '%-30s : ' "$c"; amixer -c 0 cget name="$c" 2>&1 | grep -E ': values' | head -1
done
# 本机实测值：WSA_COMP1/2 = on，RX_COMP1/2 = off，WSA_Softclip0/1 = off，
#   WSA_RX0/RX1_MIX Digital Volume = 84（= 0.00 dB），EAR_PA Volume = 0（= -18.00 dB）

# 判读：IIR0/IIR1/IIR2 属 WCD9385 codec 侧的 IIR 滤波器（耳机与录音通路），
#       **不是扬声器 EQ**；WSA_Softclip* 是 WSA macro 的软限幅，当前 off；
#       WSA_RX0/RX1_MIX Digital Volume（范围 0-124，84 = 0.00 dB，124 = +40.00 dB）
#       **未被内核限幅** —— 本项目明确不利用它，理由见 §6.3 C6。

# 注意：`amixer cget name=` 用的是**原始**控件名，简单混音器名会少掉尾部 "Volume"，
#       例如简单名 `SpkrLeft PA` ↔ 原始名 `SpkrLeft PA Volume`；`amixer scontrols` 列的是简单名。

# 保护环路传感器 —— 期望 0（关闭）
amixer -c 0 cget name='SpkrLeft VISENSE Switch' 2>&1
amixer -c 0 cget name='SpkrRight VISENSE Switch' 2>&1

# 功放使能开关 —— 期望全为 1
for c in 'SpkrLeft DAC Switch' 'SpkrLeft COMP Switch' 'SpkrLeft BOOST Switch' \
         'SpkrRight DAC Switch' 'SpkrRight COMP Switch' 'SpkrRight BOOST Switch'; do
  echo "--- $c"; amixer -c 0 cget name="$c" 2>&1 | grep -E ': values'
done

# WSA macro 路由 —— 期望 WSA RX0/RX1 MUX = AIF1_PB；WSA_RX0/RX1 INP0 = RX0/RX1
for c in 'WSA RX0 MUX' 'WSA RX1 MUX' 'WSA_RX0 INP0' 'WSA_RX1 INP0'; do
  echo "--- $c"; amixer -c 0 cget name="$c" 2>&1 | grep -E ': values|Items'
done

# HiFi.conf EnableSequence 依赖的 AudioReach 控件是否存在（B3 核验）
amixer -c 0 controls | grep -E 'Audio Mixer MultiMedia|Mixer VA_CODEC|Mixer TX_CODEC'
```

### 7.3 确认 DSP 链路与 SoundWire

```bash
# 拓扑固件与 card name → tplg 的 symlink
ls -l /lib/firmware/qcom/sc8280xp/ | grep -iE 'tplg|HUAWEI'
ls -l /lib/firmware/qcom/sc8280xp/HUAWEI/gaokun3/
ls -l /lib/firmware/qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin

# 拓扑是否真的加载
sudo dmesg | grep -iE 'tplg|topology|q6apm|q6prm|audioreach|gprsvc'
sudo dmesg | grep -iE 'qcom-apm|CMD timeout'

# ADSP remoteproc 状态
cat /sys/class/remoteproc/remoteproc*/name
cat /sys/class/remoteproc/remoteproc*/state

# SoundWire：期望看到两个 WSA8830（各 1 路）
ls /sys/bus/soundwire/devices/
for d in /sys/bus/soundwire/devices/*; do echo "== $d"; cat "$d/status" 2>/dev/null; done
sudo dmesg | grep -iE 'soundwire|sdw|swr'
```

> **关于 dmesg 中的 `din-ports (X) mismatch with controller (Y)`**：出自 `drivers/soundwire/qcom.c` 的 `qcom_swrm_get_port_config()`，读 `qcom,din-ports` 后**紧接一行就用 DT 值覆盖硬件读取值**（`ctrl->num_din_ports = val;`），随后流程继续。播放路径是 **dout**（`swr0` 的 dout 两侧均为 6，**匹配**），故该告警**属良性/装饰性，不必修**。【推测：代码路径已核实，"所有 X13s 均如此"未直接验证】

### 7.4 音质实验与回滚（含写操作）

```bash
# ① 先备份当前混音器状态（务必先做）
sudo alsactl store -f /tmp/gaokun3-mixer-before.state

# ② 左右 / 频率分离测试（硬件只暴露 2 通道，只能测 L/R，不能单独测 4 只单元）
speaker-test -D hw:0,1 -c 2 -t wav -l 1
for f in 60 100 200 400 800 1600 3200 6400 12000; do
  echo "=== ${f} Hz ==="; speaker-test -D hw:0,1 -c 2 -t sine -f "$f" -l 1
done

# ③ 播放时的实际硬件参数 —— 期望 48000 Hz / S16_LE / 2ch
cat /proc/asound/card0/pcm1p/sub0/hw_params

# ④ 安全范围内的音量调整（17 = 内核上限，不得更高）
amixer -c 0 cset name='SpkrLeft PA Volume' 17
amixer -c 0 cset name='SpkrRight PA Volume' 17
amixer -c 0 cget name='SpkrLeft PA Volume' | grep -E 'Limits|: values'

# ⑤ 回滚（任一步出问题立刻执行）
sudo alsactl restore -f /tmp/gaokun3-mixer-before.state

# ⑥ 软件层是否额外改动了路由/音量
wpctl status
pactl list sinks short
pactl info | grep -iE 'server name|default sink'
```

**★ 绝对不要执行**（会失去内核保护）：

```bash
# 以下均为禁止操作：不修改内核音量限幅、不把 PA Volume 设到 17 以上
# amixer -c 0 cset name='SpkrLeft PA Volume' 31      # ← 禁止
# 修改 sound/soc/qcom/sc8280xp.c 去掉 snd_soc_limit_volume   # ← 禁止
```

### 6.5 实现细节：UCM 的执行时机（本项目实测，容易踩坑）

把增益写进 UCM 的 `BootSequence` **并不等于它立刻生效**。本机实测的行为是：

| 观测 | 结果 |
|------|------|
| 安装 profile 后直接读 `SpkrLeft PA Volume` | 仍是旧值 |
| 重启 `wireplumber` / `pipewire` 后逐秒读取 | 第 1 秒仍是旧值，**第 2 秒变成 17** |
| 之后再重启音频栈 | 每次都会重新执行并写回 17 |
| 把值手工压到 3 后**不做任何重启** | 一直是 3，UCM 不会自己重跑 |
| 通过 PipeWire 播放 1 秒静音 | **不会**触发 UCM 重跑 |
| 音效卡空闲掉电复位后 | 控件回到**驱动默认值 0**，UCM 也不会重跑 |

⇒ **结论**：`BootSequence` 只在音频栈启动、由它打开声卡时执行**一次**（约 1–2 秒后）。
因此正确的操作顺序是 **「安装配置 → 重启音频栈 → 等它跑完 → 再写最终值」**；
反过来（先写值再重启）会被随后的 UCM 序列覆盖。`scripts/30-audio.sh` 已按此顺序实现。

**跨重启持久化**：本机 `alsa-restore.service` 处于 active，会从
`/var/lib/alsa/asound.state` 恢复混音器状态。所以脚本在写完增益后额外执行
`alsactl store`，让增益在**下次开机**也确定生效，而不依赖 UCM 的执行时机
（已验证 `alsactl store` → `alsactl restore` 往返有效）。

**另一个容易误判的点**：UCM 的 `wsa883x/init.conf` 会把 `SpkrLeft/Right PA Volume`
合成为虚拟立体声控件 `Speakers`（`HiFi.conf` 里 `PlaybackMixerElem "Speakers"`）。
看上去像是"桌面音量就是功放增益"，但**实测并非如此** —— 把 PipeWire 的 sink 音量从
100% 一路降到 20%，`Speakers` 与两个 PA 控件**始终停在 17 不动**。桌面音量走的是
数字域，功放增益由 UCM 独立设定。

### 6.6 永久生效的 UCM 改动（不要直接改上游文件）

正式做法就是本项目已经实现的 `scripts/30-audio.sh --apply`：新建 gaokun3 专属
profile 并以 `${CardLongName}.conf` 挂进 `conf.d/`，**不改动上游文件**。

```bash
sudo ./scripts/30-audio.sh --apply     # 安装 profile + 重启音频栈 + 写增益 + 持久化
sudo ./scripts/30-audio.sh --revert    # 移除 profile 并把增益还原为基线值 12
```

> ⚠️ **不要**直接 `sed` 改 `/usr/share/alsa/ucm2/Qualcomm/sc8280xp/LENOVO-X13s.conf`：
> 那会在 `alsa-ucm-conf` 包升级时被覆盖（这正是 right-0903 PR #8 要解决的问题），
> 而且会把 X13s 机型的配置改坏。正式方案见 §6.2 的 **B1**（已由本项目落地）。

---

## 8. 置信度与未解问题

### 8.1 高置信度结论

| 结论 | 依据 |
|---|---|
| 内核限幅 17 / 81 是**有意为之**，原因写明是缺少主动扬声器保护 | 主线源码注释原文 |
| 硬件可达 +18 dB、Linux 只用到 0.00 dB | TLV 表 + `Limits: Playback 0 - 17` 实测 + alsa-lib 直读 dB |
| UCM 的 `BootSequence` 只在音频栈启动打开声卡时执行一次（约 1–2 秒后），不会因播放或控件被改而重跑；音效卡空闲复位会把控件打回驱动默认值 0 | 本机逐秒实测 + 播放静音无效 + `alsactl store`/`restore` 往返验证（§6.5） |
| 桌面（PipeWire sink）音量**不驱动**功放增益：sink 从 100% 降到 20%，`Speakers` 与两个 PA 控件恒为 17 | 本机逐档实测（§6.5） |
| 跑的是 X13s 双扬声器 profile | 本机 UCM symlink + 分发文件正则 + 本机 DMI 实测 |
| 上游 PR #715 与本机现状**行为等价** | 两文件 blob sha 逐字节相同 |
| Linux 侧**不存在**任何 EQ / DRC / 保护控件 | `wsa883x.c` 全部 7 个控件 + 本机 grep 计数 = 0 |
| Windows 侧存在 34 个 NV 块的**逐机型**调音数据 | 本机 `histen_config_GaoKunGen3.xml` 直读 |

### 8.2 未解问题

| # | 问题 | 影响 | 下一步 |
|:-:|---|---|---|
| Q1 | `histen_config_GaoKunGen3.xml` 的参数字段语义 | 决定软件 EQ 近似是否**根本可行** | 需逆向 Histen APO 或做实测频响 + 参数拟合。**本项目暂不投入。** |
| Q2 | 四只物理单元的分频拓扑（每侧 2 只如何分工） | 影响任何频响修正的正确性 | 需拆机或频响扫频实测（§7.4 的扫频只能看整体，不能分离单元） |
| Q3 | `HiFi.conf` `EnableSequence` 的 AudioReach 控件在本机是否齐全 | 若缺失则部分 `cset` **静默失败**，可能隐藏独立缺陷 | 执行 §7.2 最后一条命令核验 |
| Q4 | `audioreach-tplg.bin` 是否包含 `MODULE_ID_SPEAKER_PROTECTION` 实例 | 决定"打开保护"是否有路可走 | 需解析 tplg 二进制（`snd_soc_tplg` 格式）核对模块列表 |
| Q5 | `qcom-apm ... CMD timeout for [1001021]` 的确切语义 | 目前判定为**良性**（链路通、能出声），但未证实 | 需对照 `q6apm` 的 opcode 表 |
| Q6 | SoundWire `din-ports` mismatch 的良性判断 | 播放路径是 dout 且匹配，故判良性 | 与上游 `sc8280xp.dtsi` 逐字节比对确认是"DT 保守值"而非本机硬件差异 |

### 8.3 明确的能力边界（写给用户）

> 在本项目当前的技术路线上，GK-W76 在 Linux 下的扬声器**可以做到"比默认更响"（+3.00 dB，且已到内核允许的上限）**，
> 但**做不到"像 Windows 那样"** —— 因为差别不是音量，而是一整套**逐机型的 DSP 调音与保护**，
> 它依赖 Qualcomm 的私有 ACDB 数据与 ADSP 校准流程，Linux 侧目前既无数据也无工具链。
> **本项目选择如实记录这一边界，而不是用猜测性的软件 EQ 掩盖它。**

---

## 附录 A：参考链接汇总

### A.1 内核与设备树

| 主题 | 链接 |
|---|---|
| **内核音量限幅（关键）** | [sound/soc/qcom/sc8280xp.c](https://raw.githubusercontent.com/torvalds/linux/master/sound/soc/qcom/sc8280xp.c) |
| **WSA883x 驱动（关键）** | [sound/soc/codecs/wsa883x.c](https://raw.githubusercontent.com/torvalds/linux/master/sound/soc/codecs/wsa883x.c) |
| WSA883x 绑定文档 | [qcom,wsa883x.yaml](https://raw.githubusercontent.com/torvalds/linux/master/Documentation/devicetree/bindings/sound/qcom,wsa883x.yaml) |
| 上游 gaokun3 DTS | [sc8280xp-huawei-gaokun3.dts](https://raw.githubusercontent.com/torvalds/linux/master/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts) |
| X13s DTS（参考平台） | [sc8280xp-lenovo-thinkpad-x13s.dts](https://raw.githubusercontent.com/torvalds/linux/master/arch/arm64/boot/dts/qcom/sc8280xp-lenovo-thinkpad-x13s.dts) |
| SC8280XP SoC dtsi（端口数） | [sc8280xp.dtsi](https://raw.githubusercontent.com/torvalds/linux/master/arch/arm64/boot/dts/qcom/sc8280xp.dtsi) |
| SoundWire qcom 驱动（mismatch 出处） | [drivers/soundwire/qcom.c](https://raw.githubusercontent.com/torvalds/linux/master/drivers/soundwire/qcom.c) |
| ADSP Speaker Protection 支持 | [commit 0db76f5b2235](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/sound/soc/qcom/qdsp6?id=0db76f5b2235ab456814ee8e4e2cdf0cef09dd6b) |
| VI Sense 反馈回路 | [commit 3e43a8c033c3](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/sound/soc/qcom/qdsp6?id=3e43a8c033c3187e0f441ed5570a0fb5dcc9dafb) |
| 保护模块默认关闭 | [commit b481eabe5a19](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/commit/sound/soc/qcom/qdsp6?id=b481eabe5a193ba8499f446c2ab7e0ac042f8776) |
| CS35L56 文档（无调音时的行为） | [CS35L56](https://origin.kernel.org/doc/html/v6.15/sound/codecs/cs35l56.html) |
| TI smart amp vs limiter | [TI SSZT848](https://www.ti.com.cn/document-viewer/cn/lit/html/SSZT848/GUID-27E3C581-A61B-4BFE-AB84-CE29D404C047) |

### A.2 UCM 与社区

| 主题 | 链接 |
|---|---|
| 上游 UCM SC8280XP | [ucm2/Qualcomm/sc8280xp/](https://raw.githubusercontent.com/alsa-project/alsa-ucm-conf/master/ucm2/Qualcomm/sc8280xp/) |
| 上游 UCM wsa883x codec | [ucm2/codecs/wsa883x/](https://raw.githubusercontent.com/alsa-project/alsa-ucm-conf/master/ucm2/codecs/wsa883x/) |
| **上游 Huawei UCM PR #715** | [alsa-ucm-conf#715](https://github.com/alsa-project/alsa-ucm-conf/pull/715) |
| buildbot UCM 分发文件 | [tools/audio/sc8280xp.conf](https://raw.githubusercontent.com/KawaiiHachimi/linux-gaokun-buildbot/main/tools/audio/sc8280xp.conf) |
| right-0903 README.MD（Audio 章节） | [README.MD](https://raw.githubusercontent.com/right-0903/linux-gaokun/main/README.MD) |
| right-0903 UCM workaround PR #8 | [pulls/8/files](https://api.github.com/repos/right-0903/linux-gaokun/pulls/8/files) |
| **jhovold X13s wiki（Known issues → Audio）** | [X13s.md](https://raw.githubusercontent.com/wiki/jhovold/linux/X13s.md) |
| X13s 音量/音质讨论（尤见 #8 / #97 / #104） | [Ubuntu Discourse](https://discourse.ubuntu.com/t/status-of-ubuntu-support-for-lenovo-thinkpad-x13s/44652) |
| Launchpad X13s 音频 bug | [LP #2115898](https://bugs.launchpad.net/ubuntu/+source/linux/+bug/2115898) |
| LKML v5 cover（PA 限幅动机） | [lkml.org/lkml/2024/1/22/1305](https://lkml.org/lkml/2024/1/22/1305) |
| LKML 0 dB 数字限幅 | [lkml.org/lkml/2023/12/4/568](https://lkml.org/lkml/2023/12/4/568) |
| 爆音修复回移 | [lkml.org/lkml/2023/11/23/496](https://lkml.org/lkml/2023/11/23/496) |
| AudioReach TDM backend（review 中） | [patchew v4](https://patchew.org/linux/20260712134110.3306763-1-prasad.kumpatla@oss.qualcomm.com/) |

### A.3 AudioReach / Qualcomm 与 Windows 侧本机资料

| 主题 | 链接 / 路径 |
|---|---|
| AudioReach 架构（ACDB / QACT） | [audioreach.github.io](https://audioreach.github.io/design/arch_overview.html) |
| AudioReach Linux ASoC 架构 | [audioreach.github.io](https://audioreach.github.io/design/linux_asoc_arch.html) |
| 本机 Windows 调音数据（34 NV 块） | `Drv\扩展\oemxaudioext_histen.inf_arm64_946d759c58e84313\histen_config_GaoKunGen3.xml` |
| 本机 Histen APO | `Drv\音频处理对象(APO)\histenapo.inf_arm64_964ebf522147d270\histenapo.inf` |
| 本机 Huawei 音频服务 | `Drv\软件组件\hwaudioservice.inf_arm64_397c208947a60902\` |

> **说明**：`Drv/` 属华为 / 高通专有驱动转储，**永不入库**。上表仅记录文件名与用途，供后续逆向参考定位。
