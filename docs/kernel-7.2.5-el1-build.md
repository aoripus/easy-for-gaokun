# 自研内核：Linux stable v7.2.5 + EL1（gaokun3 / SC8280XP）

> 本文记录 **easy-for-gaokun 项目自己构建内核**的完整配方与依据。
> 基线是 **mainline 的 stable 版本**（**不用 RC**），目标是**以 EL1（标准启动级别）运行**，
> 视频硬解走 **venus**（EL1 下唯一可行路径）。
> 结论标注：【已核实】=有实机或源码证据；【推测】=推理。

---

## 0. 命名规范与历史构建的关系（★ 务必先读）

### 0.1 内核串命名规范（2026-09-13 定稿生效）

```
uname -r = <上游>-aoripus-ml-gaokun3-eog-<级别>-<VPU驱动>-r<n>
本内核   = 7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1          （41 字符）
tag      = kernel-<完整内核串>-<YYYYMMDD>
标题     = Kernel <上游> (<级别>) <VPU大写>[ r<n>]
```

| 字段 | 含义 |
|---|---|
| `ml` | 源码树是 **kernel.org stable 树**（**不是** mainline master、**不是**发行版内核） |
| `gaokun3` | 设备树代号，**不用 `gaokun`** —— `gaokun2` = 8cx Gen 2 / SC8180X，极易混淆 |
| `eog` | MateBook E Go |
| `<级别>` | `el1` / `el2` |
| `<VPU驱动>` | `venus` / `iris` —— **VPU 视频编解码单元，不是 GPU**（GPU 是 Adreno 690 / freedreno / Turnip） |
| `r<n>` | 修订号，从 `r1` 起；作用域 = **同一上游版本 + 同一级别 + 同一 VPU 驱动** |

**日期只进 Release tag，不进内核串**——内核串决定机器侧的全部落点名：
`/lib/modules/<内核串>/`、`/boot/*-<内核串>`、systemd-boot 条目名与 ESP 目录名
（见 `scripts/gk-install-kernel.sh:76-77`）；日期若进内核串，每天都会产生一个新模块目录。

### 0.2 ★ 本文实测记录使用**旧串**，自 `r1` 起才用新串（不改写历史）

本文**已经实机验证的那一次构建**，其真实 `uname -r` 是：

```
7.2.5-aoripus-ml-gaokun-eog-el1+          ← 旧命名，按新规范追溯记为 r0
```

该串与本文的实测数据（`Image` 大小、venus 解码器、触屏 IRQ 计数等）**逐字对应，不作改写**，
以保证可追溯。旧串相对新规范有三处差异：`gaokun` 应为 `gaokun3`；缺 VPU 驱动字段；缺 `r<n>` 修订号。

| | 旧命名（**已实测的那次构建，r0**） | 新规范（自 `r1` 起） |
|---|---|---|
| 内核串 | `7.2.5-aoripus-ml-gaokun-eog-el1+` | `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1` |
| `CONFIG_LOCALVERSION` | `-aoripus-ml-gaokun-eog-el1` | `-aoripus-ml-gaokun3-eog-el1-venus-r1` |

> ⇒ **§3 的配方与 §6 的配置表自本规范起使用新串**；照 §3 复现得到的是
> `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1`，与 r0 那次的实测记录**不同串**，
> 属预期（修订号已推进），不是文档矛盾。r0 的产物与实测结论仍然有效，
> 但**不要**指望用旧串复现出逐字节相同的产物 —— 旧串是 `CONFIG_LOCALVERSION_AUTO` 尚未关闭时的产物，
> 已不可再生（见 §0.3）。

### 0.3 ★★ 内核串尾部的 `+`：**两个条件，缺一不可**（复现性红线）

**第一版认知（已被实测更正）**：曾以为只要 `CONFIG_LOCALVERSION_AUTO=n` 就不会有 `+`。**不对。**

内核串由 `scripts/setlocalversion` 生成（`Makefile:1388` 的 `filechk_kernel.release`）。
当 `CONFIG_LOCALVERSION_AUTO≠y` 时走 `else` 分支，仍会调用 `scm_version --short`；
只要源码树**是一个 git 仓库、且 HEAD 不恰好落在名为 `v$(KERNELVERSION)` 的附注（annotated）tag 上**，
它就会打印 `+`：

```sh
if [ -z "${count}" ] || [ "${count}" -gt 0 ]; then
	if $short; then echo "+"; return; fi
```

**实测对照**（VM 上直接跑 `KERNELVERSION=7.2.5 sh scripts/setlocalversion $SRC`，
两种情况下 `.config` 都已是 `# CONFIG_LOCALVERSION_AUTO is not set`）【已核实】：

| 源码树状态 | `setlocalversion` 输出 |
|---|---|
| `.git` 存在、HEAD 无附注 tag | `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1`**`+`** |
| `.git` 移开 | `7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1` ✅ |

**⇒ 必须同时满足两条**：

1. `scripts/config --disable LOCALVERSION_AUTO`，最终 `.config` 必须是
   `# CONFIG_LOCALVERSION_AUTO is not set`；
2. **生成内核串时源码树不得带 git 元数据** —— 即**发行版的标准做法：从 tarball 解包、
   不带 `.git` 构建**。本项目的做法是在 `make` 前把 `.git` 移开、构建后再移回
   （`build-el1-phase2.sh` 用 `trap … EXIT` 保证一定恢复）；**补丁管理**与**合并补丁的生成**
   都在移开之前完成。

**为何要较真**：`+` 会进入 `uname -r`，进而派生出 `/lib/modules/<串>+/`、initrd 名、
systemd-boot 条目名与 ESP 目录名；同一份逻辑源码在"带 `.git`"与"不带 `.git`"两种状态下会得到
**两个不同的模块目录**，发布串不可复现、装机与模块加载会踩空。

**门禁**：编译完成后断言 `include/config/kernel.release` 不含 `+`（`build-el1-phase2.sh`
已内建；命中即中止）。

---

## 1. 为什么是这个组合

| 决策 | 理由 |
|---|---|
| 基线用 **v7.2.5（stable）** | 用户明确要求"不要 RC，只要 mainline 的 stable"；7.1.13 已 **EOL** |
| 启动级别用 **EL1** | venus/iris 上游都按 EL1 写（`qcom_mdt_load(..., NULL)` + 裸 `auth_and_reset`）；bare-metal EL2 下 PAS reset 不可靠，且**视频核没有 attach 兜底**（见 `patches/iris-el2/README.md`） |
| 视频驱动用 **venus** 而非 iris | v7.3-rc1 才有 iris 的 sc8280xp DT 节点，且 iris/venus 节点**同地址不可共存**；社区（pgs666，内核 7.1.8）实测可用的就是 venus 【已核实：社区 defconfig `VENUS=m`、板级 `&venus{status=okay}`、`tools/mpv/mpv.conf` 用 `v4l2m2m-copy`】 |
| 补丁集自己维护 | 上游 buildbot 的补丁集是为 `v7.2-rc2` 生成的，对 7.2.5 **全部落不上**（见 §4）；本项目的补丁集已按 7.2.5 重做并快照为单一补丁 |

**代价（必须写清楚）**：EL1 下**没有 `/dev/kvm`**（EL2 才有虚拟化）；EL1 的 DSP 由固件里的 QHEE 代管，
EL2 则需要 `qebspil` 预启动 DSP。**硬解与 KVM 目前互斥。**

---

## 2. 构建宿主与工具链

| 项 | 值 |
|---|---|
| 宿主 | VMware Debian 12 虚拟机（x86_64，16 vCPU，17 GB RAM） |
| 交叉工具链 | `aarch64-linux-gnu-gcc` 12.2.0 |
| 加速 | ccache（`CCACHE_BASEDIR=/root/gaokun`）；`-j16` |
| 平板能否自编译 | **不能**：ARM64 原生编译实测 30 s 后硬断电（项目早期结论，勿重试） |

```bash
# 宿主机准备
apt-get install -y gcc-aarch64-linux-gnu ccache bison flex libssl-dev bc \
                   libelf-dev python3 device-tree-compiler
```

---

## 3. 配方（可复现步骤）

```bash
BASE=/root/gaokun
VER=7.2.5

# 1) 取 stable 源码（kernel.org 直连可用；GitHub 需代理）
cd $BASE
curl -sSLO https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-$VER.tar.xz
mkdir -p linux-el1-$VER && tar -xf linux-$VER.tar.xz -C linux-el1-$VER --strip-components=1
cd linux-el1-$VER && git init -q -b main && git add -A && git commit -qm "linux-$VER pristine"

# 2) 施加补丁集（见 §4；此处用带 fuzz 的强制应用，因为补丁为 7.2-rc2 生成）
#    —— 详见 §4.2 的逐条命令
# 3) 追加板级 venus 使能 + 触屏模式脚（见 §4.3）

# 4) 配置
export ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-
make O=$BASE/out-el1-$VER ARCH=arm64 gaokun3_defconfig
CFG=scripts/config
$CFG --file $BASE/out-el1-$VER/.config --set-str LOCALVERSION "-aoripus-ml-gaokun3-eog-el1-venus-r1"
$CFG --file $BASE/out-el1-$VER/.config --disable LOCALVERSION_AUTO  # ★ 否则内核串尾会多出 "+"，见 §0.3
$CFG --file $BASE/out-el1-$VER/.config --disable VIDEO_QCOM_IRIS   # ★ 见 §5 的静默陷阱
$CFG --file $BASE/out-el1-$VER/.config --module  VIDEO_QCOM_VENUS
$CFG --file $BASE/out-el1-$VER/.config --module  SM_VIDEOCC_8350
$CFG --file $BASE/out-el1-$VER/.config --module  DRM_PANEL_HIMAX_HX83121A
$CFG --file $BASE/out-el1-$VER/.config --module  I2C_HID_OF
$CFG --file $BASE/out-el1-$VER/.config --disable MODULE_SIG
$CFG --file $BASE/out-el1-$VER/.config --disable MODULE_SIG_ALL
$CFG --file $BASE/out-el1-$VER/.config --disable SYSTEM_TRUSTED_KEYS
$CFG --file $BASE/out-el1-$VER/.config --disable SYSTEM_REVOCATION_KEYS
make O=$BASE/out-el1-$VER ARCH=arm64 olddefconfig

# 5) 编译（★ 先把 .git 移开，否则内核串尾会多出 "+"，见 §0.3）
mv $BASE/linux-el1-$VER/.git $BASE/linux-el1-$VER/.git.hidden-for-build
make O=$BASE/out-el1-$VER ARCH=arm64 -j16 Image modules dtbs
mv $BASE/linux-el1-$VER/.git.hidden-for-build $BASE/linux-el1-$VER/.git
```

现成脚本：`/root/gaokun/build-el1-x86.sh`（阶段 1：解包 + 补丁 + 配置 + 编译）
与 `/root/gaokun/build-el1-phase2.sh`（阶段 2：仅配置 + 编译，用于补丁已就位时）。

---

## 4. 补丁集

### 4.1 来源与必要性

| 组 | 来源 | 作用 | 必要性 |
|---|---|---|---|
| `upstream/*` | 上游化补丁（多位作者） | gaokun3 板级基础、显示 DSI 稳定性、EC、EC 温度、音频内存区、摄像头 | 部分必需；其中 `0017`（PDC map）**已在 7.2.5 上游**（`96f65d01f313`），`0001`（ADSP FastRPC）**已上游**（`1825ac5e2ad2`） |
| `others/0002,0005,0006` | 社区 | 面板驱动默认开 DSC；DPU DSC timing 宽度取整；面板 `bl` 供电表 | **内屏点亮必需**（2560×1600 双 DSI 走 DSC） |
| `others/0003` | `chiyuki0325/EGoTouchRev-Linux` 系 | Himax HX83121A **SPI** 触屏驱动（12 个文件） | 触屏必需（走 SPI 路线时） |
| `others/0007` | 社区 | q6apm 流内存映射修复 | 音频 |
| `0099` | 社区板级 DTS + defconfig 导入 | 内屏 DSI/面板/背光、SPI 触屏、EC、热区等**全部板级描述** | **必需**（上游 7.2.5 的板级 DTS 内屏是空的，只有 `simple-framebuffer`） |
| `media/0002–0006` | `jhovold/linux` `wip/sc8280xp-6.16`（Konrad Dybcio 原作） | venus 资源结构 `sm8350_res`/`sc8280xp_res` + `sc8280xp.dtsi` 的 `venus`/`videocc`/`pil_video_mem` | **硬解必需**，且是**本项目的真实增量**（mainline 里这些都不存在） |
| `patches/el2/*` | TravMurav | EL2 的 SCM/SHM/remoteproc 接管 | **本内核一律不套**（我们要 EL1） |

### 4.2 施加上，7.2-rc2 补丁集对 7.2.5 **全部落不上**（已核实）

`git apply` 全失败；`git apply --3way` 也不行（3-way 需要补丁的 pre-image blob 在对象库里，
而补丁来自 buildbot 的 7.2-rc2 树）。失败的连锁原因：

1. `0099` 落不上 → 社区板级 DTS 没进树 → 依赖它的补丁（`gpio174`、SPI 触屏节点等）全部连坐；
2. 7.2.5 的 `drivers/media/platform/qcom/venus/core.c` 多了
   `#if (!IS_ENABLED(CONFIG_VIDEO_QCOM_IRIS))` 守卫（第 998、1183 行），把 `media/0004/0005` 的插入点整体移位。

**解决办法：带 fuzz 强制应用 + 逐个判定"是否已在树中"**

```bash
P=/root/gaokun/buildbot-patches
ALL="$P/upstream/*.patch $P/others/*.patch $P/0099-*.patch \
     $P/media/0002*.patch $P/media/0003*.patch $P/media/0004*.patch \
     $P/media/0005*.patch $P/media/0006*.patch /root/gaokun/0001-touchscreen-gpio174.patch"
for f in $ALL; do
  if patch -p1 --dry-run -F3 -R -i "$f" >/dev/null 2>&1; then echo "ALREADY $f"; continue; fi
  if patch -p1 --dry-run -F3 -i "$f" >/dev/null 2>&1; then patch -p1 -F3 -i "$f"; echo "OK $f"; continue; fi
  patch -p1 -F3 --no-backup-if-mismatch -r "/tmp/rej/$(basename $f).rej" -i "$f"
  echo "PARTIAL $f (rejects: $(grep -c '^@@' /tmp/rej/$(basename $f).rej 2>/dev/null || echo 0))"
done
```

**结果：只有 2 个 hunk 被拒**，手工收敛如下（两处都已写进最终补丁）：

| 文件 | 手工改动 |
|---|---|
| `drivers/pinctrl/qcom/pinctrl-sc8280xp.c` | `sc8280xp_pdc_map[]` 删除 `{ 175, 237 }`（让触屏 gpio175 不被映射到 PDC，避免唤醒 IRQ 干扰） |
| `arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts` | EC 节点：上游 7.2.5 为 `interrupts-extended = <&tlmm 103 …>`，改为 `<&pdc 215 …>`，并补 `enable-gpios = <&tlmm 173>`、`bat-gpios = <&tlmm 41>`、`#thermal-sensor-cells = <1>`、`pinctrl-0 = <&ec_default>` |

**快照产物**：`/root/gaokun/gaokun3-7.2.5-el1.patch`
（**159,047 B，21 个文件，+4512/−196**）—— 这是本项目相对 mainline v7.2.5 的**自有补丁**。

### 4.3 追加的板级改动（我们自己写的）

```dts
&venus {
	firmware-name = "qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn";
	status = "okay";
};
```

`media/0006` 在 `sc8280xp.dtsi` 里加的 venus 节点是 `status = "disabled"`，必须由板级覆写为 `okay`；
`firmware-name` 大小写敏感（`HUAWEI` 全大写）。

---

## 5. ★ 必须钉死的静默陷阱：`CONFIG_VIDEO_QCOM_IRIS` 必须为 `n`

`drivers/media/platform/qcom/venus/core.c` 里，`sm8250_res` / `sc7280_res` 及其 of_match 条目
**整段包在 `#if (!IS_ENABLED(CONFIG_VIDEO_QCOM_IRIS))` 内**（7.2.5 第 998、1183 行）；
`media/0004`/`0005` 的插入点正在这段里。而 **arm64 上游 defconfig 默认同时开着**
`CONFIG_VIDEO_QCOM_IRIS=m` 与 `CONFIG_VIDEO_QCOM_VENUS=m`（v7.2.5 `arch/arm64/configs/defconfig` 第 929/930 行）。

⇒ 若直接 `make defconfig`，预处理器会**删掉** `qcom,sm8350-venus` / `qcom,sc8280xp-venus`，
**venus 永不 probe，而且没有任何编译错误**。表现为：装完机、`/dev/video*` 里一个解码器都没有。

**构建后必须断言**：

```bash
grep -q '^CONFIG_VIDEO_QCOM_VENUS=m' out/.config
grep -q '^# CONFIG_VIDEO_QCOM_IRIS is not set' out/.config
grep -c 'qcom,sm8350-venus' drivers/media/platform/qcom/venus/core.c   # 应为 1
grep -q '^# CONFIG_LOCALVERSION_AUTO is not set' out/.config           # ★ 见 §0.3
case "$(cat out/include/config/kernel.release)" in *"+"*)              # ★ 串尾不得有 "+"
  echo "内核串含 +，不可复现";; esac
```

**产物 DTB 断言**（EL1 DTB 必须干净）：

```bash
DTB=out/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb
for k in gpio174 sm8350-venus qcvss8280.mbn; do grep -aq "$k" $DTB || echo "缺 $k"; done
grep -aq 'shm-bridge-vmid' $DTB && echo "不该有（EL2 专属）"
grep -aq 'broken-reset'    $DTB && echo "不该有（EL2 专属）"
```

---

## 6. defconfig 关键项

| 配置 | 值 | 说明 |
|---|---|---|
| `CONFIG_VIDEO_QCOM_VENUS` | `m` | EL1 硬解路径 |
| `CONFIG_VIDEO_QCOM_IRIS` | **必须 not set** | 见 §5 |
| `CONFIG_SM_VIDEOCC_8350` | `m` | venus 的 `videocc`（上游有驱动，但 arm64 defconfig 未开） |
| `CONFIG_DRM_PANEL_HIMAX_HX83121A` | `m` | 内屏面板驱动（上游有驱动，defconfig 未开） |
| `CONFIG_I2C_HID_OF` | `m` | 触屏"路线 A"（上游 I²C-HID 描述）时需要 |
| `CONFIG_VIDEO_QCOM_CAMSS` | `m` | 摄像头（板级 DTS 里已启用） |
| `CONFIG_QCOM_TZMEM_MODE_SHMBRIDGE` | `y` | SHM bridge；EL1 下由 hypervisor 代管，但仍需编入 |
| `CONFIG_LOCALVERSION` | `-aoripus-ml-gaokun3-eog-el1-venus-r1` | 见 §0.1 命名规范（r1 起）；r0 那次的实测产物用的是旧串 `-aoripus-ml-gaokun-eog-el1` |
| `CONFIG_LOCALVERSION_AUTO` | **必须 not set** | 见 §0.3；否则内核串尾多出 `+`，模块目录随源码树 clean/dirty 漂移 |

---

## 7. 已知缺口 / 下一轮迭代

| 缺口 | 影响 | 处理 |
|---|---|---|
| ~~`qcom,force-gsi-mode` 无人读取~~ ✅ **已在 r1 解决** | 7.2.5 的 `spi-geni-qcom.c`**不读**该属性（binding 亦无）⇒ SPI 退回 **FIFO 模式**。r1 补上 Pengyu Luo 的 **v1 两个补丁**（binding + driver，见 `patches/spi-gsi/`）；其 **v2 已被作者本人撤回**（2026-07-14：「keep using the fifo_disabled variable」），故 DT 属性路线是唯一可行解 | 已合入 r1 并实测生效（见下方更正） |
| 触屏两条路线未做 A/B | 上游 I²C-HID（零补丁）vs 社区 SPI（`gpio174` 拉低） | 两版 DTB 各实测一次，见 `AGENTS.md` §7.9.4 |
| 热管理补丁未纳入 | 无 75 °C 主动节流 | 社区 `patches/gaokun3/0002,0004` 可移植 |
| 音频 UCM | `alsa-ucm-gaokun3` 是独立包 | 从社区 release 取，或自行编写 |

> ### ★★ 滑动实测：每帧 IRQ **15.39 → 3.56**（含一次自我更正的记录）
>
> **第一版判断是错的**：曾依据**空闲**数据断言"GSI 不会改变 `irq_per_frame`，因为那条 IRQ 是
> 触屏 IC 的线、与 SPI 模式无关"。**用户的真实滑动实测推翻了它** —— 空闲时两版确实一样，
> 滑动时却差 **4.3 倍**。留此记录作为教训：**空闲数据不能用来推断负载下的行为。**
>
> **① 空闲（20 s 窗口、无触摸，两次采样取增量）**【已核实】：
>
> | 中断线 | r0（FIFO） | r1（GSI） |
> |---|---|---|
> | `998000.spi`（GENI SE） | **+6,206** | **0** |
> | `gpi-dma` | 无此行（= 0） | **+4,803** |
> | `msmgpio 175`（触屏 IC） | **+2,397** | **+2,401** |
>
> **② 滑动（`tools/gk-touch-bench.py`，用户匀速划屏，45 s 窗口）**【已核实】：
>
> | 指标 | r0 | **r1** | 变化 |
> |---|---|---|---|
> | 每帧触屏 IRQ | **15.39** | **3.558** | **−77%** |
> | CPU 忙 | 14.97 % | **5.56 %** | **−63%** |
> | 帧间隔 p99 | 32.8 ms | **10.267 ms** | **−69%** |
> | 帧间隔 中位 / p95 | 8.328 / 9.38 ms | 8.329 / 9.523 ms | 持平 |
> | 每帧触点事件 | 3.99 | 3.95 | 持平 |
>
> ⇒ ① **GSI 确实生效**：**整个滑动过程中** GENI SE 中断恒为 0（前后两次采样都是 0），
> 传输完成改由 GPI DMA 报告（`gpi-dma` +28,706 对 触屏 IC +14,302，约 2 次 DMA 中断/次触屏中断）。
> ② **每帧中断 −77%、CPU 占用 −63%、p99 抖动 −69%**；报点率与中位帧间隔不变（由 IC 决定）。
> ③ 折算到每次触点事件：r0 ≈ **3.9** 次中断、r1 ≈ **0.9** 次，已接近"每次报点一次中断"的物理下限。
> ④ 机制【**推测**】：FIFO 模式下逐字中断、排空慢，level-low 的 INT 在数据被读完前反复触发；
> DMA 快速排空后每帧只需少数几次中断。现象为实测，机制待进一步取证。
> ⑤ 顺带发现（**r0 与 r1 皆有，非 r1 引入**）：**空闲时 IC 仍以约 120 次/秒中断，
> 却不产生任何输入事件**（"幽灵中断"）。已列入下一轮待办。

---

## 8. 产物

| 文件 | 说明 |
|---|---|
| `Image` | ARM64 内核镜像 |
| `sc8280xp-huawei-gaokun3.dtb` | **EL1** 用（本文件） |
| `sc8280xp-huawei-gaokun3-el2.dtb` | EL2 用（同一构建顺带产出，本内核不推荐） |
| `modules.tar.zst` | `/lib/modules/<release>/` 全量模块树 |
| `config-<release>` | 供审计的完整 `.config` |
| `gaokun3-7.2.5-el1.patch` | **我们的补丁**（相对 mainline v7.2.5） |

安装/回滚：`scripts/gk-install-kernel.sh`（只新增 BLS 条目，默认不动 `loader.conf`，支持 `--uninstall`）。

---

## 9. 修订记录（每次重编一行，便于对照产物）

| 内核串 | 日期 | 本修订的实质变化 | 产物 |
|---|---|---|---|
| `…-el1+`（追溯 r0） | 2026-09-13 | 首个自研 EL1 内核：gaokun3 板级 DTS + venus + 社区 SPI 触屏 | 见 §7 |
| `…-el1-venus-r1` | 2026-09-13 | 引入 **Pengyu Luo v1** 的 `qcom,force-gsi-mode`（两条补丁），触屏改走 **GSI/DMA** | [release r1](https://github.com/aoripus/easy-for-gaokun/releases/tag/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r1-20260913) |
| `…-el1-venus-r2` | 2026-09-13 | AFE 命令邮箱传输层 + `afe_cmd` 节点 + 默认关闭的空闲策略（**该版本的策略已废弃**，见下） | 内部构建，未发布 |
| **`…-el1-venus-r3`** | 2026-09-13 | **修复 `himax_lock/unlock` 中断使能不对称**；改为**中断门控采样**空闲策略（默认 7200 帧≈60 s / 30 ms），诊断节点 `frame`/`irq_gate`/`regs`/`idle_state` | [release r3](https://github.com/aoripus/easy-for-gaokun/releases/tag/kernel-7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3-20260913) |

**r2 为什么没发布**：r2 的空闲策略建立在"AFE 命令 `0x0A` 让 IC 停流"这一实测结论上，
而该结论后来被证明是 **`himax_lock()` 屏蔽中断后从不恢复**造成的假象（写 sysfs 这个动作本身
改变了被测对象）。r3 修掉缺陷后重新实测，得到完全不同的结论与策略。
过程与数据见 [`docs/touch-idle-policy.md`](touch-idle-policy.md)，驱动增量见
[`patches/touch-idle/`](../patches/touch-idle/README.md)。

### 9.1 r3 构建与产物（2026-09-13）

- 配方**与 §3 完全相同**，只把 `CONFIG_LOCALVERSION` 换成 `-aoripus-ml-gaokun3-eog-el1-venus-r3`；
- 构建机 VM（x86_64 Debian，局域网地址不记录在本公开仓库）（`build-el1-phase2.sh`，ccache 命中时约 3 分钟，360 个模块）；
- 门禁全通过：`uname -r` 无尾部 `+`、EL1 DTB 含 `gpio174`/`sm8350-venus`/`qcvss8280.mbn`/`hx83121a`
  且不含 `shm-bridge-vmid`/`broken-reset`；
- 产物（8 项，与 r1 同名同结构）：`Image` 24,734,208 B、`modules-…-r3.tar.zst` 6,502,281 B、
  `sc8280xp-huawei-gaokun3.dtb` 170,672 B、`config-…-r3`、`System.map-…-r3`、
  `gaokun3-7.2.5-el1.patch` 178,960 B、`sha256sums.txt`、`BUILD-PROVENANCE.md`。
