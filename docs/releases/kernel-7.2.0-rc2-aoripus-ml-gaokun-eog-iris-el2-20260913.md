# [内核] 7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+

发布日期：2026-09-13
适用设备：HUAWEI MateBook E Go 2022 性能版（GK-W76 / GK-W7X-PCB / SC8280XP / gaokun3）

---

## 状态

已在本机（GK-W7X）实测启动验证：

| 子系统 | 实测结果 |
|---|---|
| 启动 | one-shot 试启动通过，`uname -r` 即本产物的 release 串 |
| 音频 | 声卡 `SC8280XP-HUAWEI-GAOKUN3` 注册；`SpkrLeft/Right PA Volume = 17` |
| 触屏 | `gpio174 : out low`，Himax 中断计数持续增长 |
| remoteproc | slpi / adsp / cdsp 均为 `attached`：EL2 下不做复位，接管引导固件已启动的实例 |
| 视频硬解 | **不可用**（根因已定型：TZ 侧 QTEE + 签名 TA，Linux 够不到；**不是** EL2 的限制），见下节 |

本机是标准 UEFI 平台：有固件设置界面、可从 USB 启动、ESP 是普通 FAT32 分区。安装时保留原
默认条目即可；即使引导项写错，也能用 U 盘启动挂载 ESP 修复。

## 视频硬解：尚未打通（附结论更正）

> ### ⚠️ 更正（2026-09-13 第三轮）
>
> 本节此前写的是"**EL2 下不可用，且不可修复**"。该结论**已被推翻**。
>
> Steev Klimaszewski 在 **Lenovo ThinkPad X13s（同为 SC8280XP）** 上实测 iris 通过：
> `v4l2-compliance` 48/48、真实播放正常，**且明确包括 EL2**（"In el2, the device seems to be
> /dev/video33 … if I let the video play, it plays just fine"）。
>
> 同为该 SoC、同为 EL2，**X13s 能跑而本机不能** —— 这说明问题是**设备特有的，不是架构性的**。
> 下面保留原始证据链（逐寄存器验证部分仍然完全有效），但结论改为"**本机尚未打通、原因待查**"。

**本机是标准 UEFI 平台**，安装与回滚都很简单。

固件启动要跨过四道关卡，本产物停在第四道：

| 阶段 | 结果 | 说明 |
|---|---|---|
| `qcom_scm_pas_init_image` | 通过 | 需要 `patches/iris-el2/` 的 tzmem/ctx 修复，否则报 `-22` |
| `qcom_scm_pas_auth_and_reset` | 通过 | 需要改用 `qcom_scm_pas_prepare_and_auth_reset()`：EL2 下 SHM bridge 必须由 Linux 自建 |
| `qcom_scm_mem_protect_video_var` | `-5`（EIO） | 只服务于 DRM 内容保护；**上游在此处会直接 `pas_shutdown()` 并中止 probe**，本产物改为非致命后继续 |
| `iris_vpu_boot_firmware` | **`-62`（ETIME）** | 驱动写 `CTRL_INIT` 后轮询 1000 次（约 110 ms），`CTRL_STATUS` 恒为 `0` |

### 逐寄存器验证（2026-09-13 第二轮）

在驱动已完成上电与固件加载、并已写好 UC region 的 **90 秒上电窗口**内，从用户态经 `/dev/mem`
读取全部相关寄存器。**供电、时钟、复位、固件四项全部正常，核心就是不执行：**

| 检查项 | 地址 | 实测 | 判读 |
|---|---|---|---|
| `video_cc_mvs0c_clk` | `videocc+0xc34` | `0x221`，运行于 840 MHz | 时钟在跑 |
| `video_cc_mvs0_clk` | `videocc+0xd34` | `0x221`，运行于 560 MHz | 核心时钟在跑 |
| ARES 异步复位位 | 上述两处 bit2 | `0` / `0` | 不在复位 |
| `mvs0c_gdsc` / `mvs0_gdsc` | `videocc+0xbf8` / `+0xd18` | 均 `PWR_STATE=1`、`SW_COLLAPSE=0` | 两个电源域都已上电 |
| `GCC_VIDEO_AXI0_CLK` ARES | `gcc+0x28010` | `0x221` | AXI 时钟在跑、无复位 |
| 固件保留区 | `0x86700000` | 合法镜像头 `06 10 00 00 01 ff ff ff …` | 固件在内存里 |
| `CTRL_STATUS` | `iris+0xa004c` | 轮询 1000 次恒为 `0` | **固件从未应答** |
| `WRAPPER_TZ_CPU_STATUS` | `iris+0xc0010` | WFI 位 `= 0` | **CPU 不在运行** |

窗口内还穷举了全部可写路径，**无一奏效**：直接写 `CTRL_INIT`、撤销 AON/IRIS/调试桥三处 NOC
低功耗请求、清 TZ 侧时钟 halt、桥复位序列、TZ FIFO 复位、`mvs0`/`mvs0c` 两个 GDSC 各做一次
掉电→上电、以及写 `CPU_CS_X2RPMH` 的 `MSK_CORE_POWER_ON`（已回读确认寄存器可写）。

### 根因

上游 EL2 补丁集的作者对此有明确记载：

> *"It's possible to authenticate and start new firmware, but the remoteproc is never actually
> brought out of reset. … all the PAS related calls still succeed, it will just not release the
> remoteproc from reset."*

即：**EL2 下所有 PAS 调用都返回成功，但子系统永远不会真正脱离复位。** 这与本机现象逐字吻合。

DSP（adsp / cdsp / slpi）之所以没事，是因为它们**在开机时就已被引导固件启动**，驱动可以靠
`qcom,broken-reset` 跳过复位、直接接管运行中的实例；而**视频核必须由 Linux 亲自启动，没有
"在位接管"这条路**，因此无从绕过。要让视频硬解可用，需要内核运行在 EL1（下方由 hypervisor
代管 PAS），而本机固件是把 Linux 直接投到 EL2。

### 已无改进空间的旁证

- **设备树不是原因**：本产物生成的 iris 节点与上游 v7 系列（2026-05 最新）**逐属性一致**，
  含 `iommus = <&apps_smmu 0x2a00 0x400>`、`resets`、`power-domains`、`memory-region`。
- **上游也没有驱动支持**：该系列**只包含 DT 与 binding，不含任何驱动改动**，且 cover letter
  自述 *"The driver was very lightly tested on SC8280XP"* —— 即上游同样没有在这个平台上跑通。
- **固件不是原因**：换用 X13s 的 `qcvss8280.mbn`（2,035,812 B，与华为那份 2,035,748 B 仅差
  64 字节）后结果逐字节相同。

### 结论（更正后）

逐寄存器证据表明：**供电、时钟、复位、固件四项全部正常，而视频核从不执行。**
TrustZone 也**确实活着**（不存在的 PAS ID 一律返回 `-22`），并**声称**支持视频核
（`pas_supported(9)=yes`；镜像已加载时 `pas_auth_and_reset(9)=0`）。

与已知可用设备（X13s）最明确的差异是：**`qcom_scm_mem_protect_video_var` 被本机 TrustZone
以 `-EIO` 拒绝** —— 在 X13s 上这一步必须成功，否则上游 iris 会在此处直接
`pas_shutdown()` 并中止 probe。此外本机固件经上游 master 的判定算法确认为 **Gen1**
（`QC_IMAGE_VERSION_STRING=video-firmware.1.1-…`），因此"用错 HFI 代次"已被排除。

### 根因（2026-09-13 第四轮定型）

把 Windows 驱动 `qcdxkm8280.sys` 的 TrustZone 接口逆向出来之后，根因清楚了：

**该设备的 TrustZone 把视频子系统的安全世界支持（CP 内存保护 + 子系统状态机）实现在
QTEE + 签名 TA 之后，而 Linux 够不到那里。**

- Windows 驱动视频核走的是 **QTEE（TrEE）IOCTL**，不是 Linux iris 用的 SIP SMC；
  并且它在视频核初始化时调用了 **Linux 侧完全没有**的 TZ 子系统状态函数
  （`TZ_SUBSYS_STATE_RESUME`、`TZ_SUBSYS_STATE_VENUS_RESTORE_THRESHOLD`，subsys = 9）。
- Linux 的 SIP 路径上，`QCOM_SCM_MP_VIDEO_VAR` 对本机**无条件返回 `-EIO`**：
  6 组参数（含从 Windows 逆向出的两套静态表）全部一致，且"冷状态"下作为第一个 SCM
  调用同样失败 —— 与顺序、状态、取值都无关。
- 经 `qcomtee` 复刻这条路被**源码否决**：`drivers/tee/qcomtee/core.c` 把 `op` 掩到 16 位
  （`0x02000C08` 当场 `-EINVAL`），且"只能调用 QTEE 托管的对象"，即需要**签名 TA**。

**因此本机没有可走的 Linux 侧路径。** 需要强调的是：这**不是** EL2 的架构限制 ——
Lenovo ThinkPad X13s（同为 SC8280XP）已在 EL2 下把 iris 跑通。差异在设备专有的安全世界固件。

替代方案是软件解码：本机实测 1080p30 H.264 只吃约 **0.5 个大核**（14.2× 余量），
VP9 / AV1 分别为 6.3× / 7.5× —— 1080p 属"余量充足"。详见
[`../../docs/software-video-decode.md`](../../docs/software-video-decode.md)。

可复现的探针工具见 [`tools/pas-probe/`](../../tools/pas-probe/README.md)，
Windows 侧接口逆向记录见 [`docs/windows-video-tz-interface.md`](../../docs/windows-video-tz-interface.md)。

实验记录与复现步骤见 [`patches/iris-el2/README.md`](../../patches/iris-el2/README.md)。

## 变更

目标机的视频硬解单元是 Qualcomm IRIS (Gen1)，不是 Venus。基线内核以 `CONFIG_VIDEO_QCOM_VENUS=m` 配套一个 2023 年形态的 venus 设备树节点（`compatible = "qcom,sm8350-venus"`、`iommus = <&apps_smmu 0x2e00 0x400>`），启动时稳定报错：

```
qcom-venus aa00000.video-codec: error -22 initializing firmware qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn
qcom-venus aa00000.video-codec: fail to load video firmware
```

本构建改用上游的 iris 方案：

| 项 | 基线 | 本构建 |
|---|---|---|
| 视频驱动 | `CONFIG_VIDEO_QCOM_VENUS=m` | `CONFIG_VIDEO_QCOM_IRIS=m`，VENUS 关闭 |
| 视频设备树节点 | `venus: video-codec@aa00000`，`compatible = "qcom,sm8350-venus"`，`iommus = 0x2e00`，缺 `mmcx` 电源域 | `iris: video-codec@aa00000`，`compatible = "qcom,sc8280xp-iris", "qcom,sm8250-venus"`，`iommus = 0x2a00`，含 `mmcx` |
| 视频固件 | 设备树 `firmware-name = qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn` | 不变。IRIS 的 `sm8250_data.fwname` 指向已被 linux-firmware 删除的 `qcom/vpu-1.0/venus.mbn`，必须由设备树覆盖 |
| `LOCALVERSION` | `-gaokun3-el2` | `-aoripus-ml-gaokun-eog-iris-el2` |

其余部分与基线一致：补丁集、DTS、defconfig 与配置项均未改动，仅跳过了 `patches/media/`（该目录下 6 个补丁针对 venus 方案，与本构建冲突）。

## 产物

SHA-256 列为前 16 位，完整值见 `sha256sums.txt`。

| 文件 | 说明 | 字节 | SHA-256（前 16 位） |
|---|---|---:|---|
| `Image` | 内核映像（arm64，未压缩，供 systemd-boot 直接加载） | 24,730,112 | `ca54a5bdb4611170` |
| `sc8280xp-huawei-gaokun3.dtb` | 标准设备树 | 170,694 | `337902cea29fa0ce` |
| `sc8280xp-huawei-gaokun3-el2.dtb` | EL2 叠加变体，与当前运行的基线内核同构 | 170,967 | `b65aac1557a4198d` |
| `modules-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+.tar.zst` | 359 个内核模块，含 `qcom-iris.ko` | 4,998,787 | `c201a89c3765d51b` |
| `config-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+` | 完整 `.config` | 209,244 | `c37d7dc5083cda69` |
| `System.map-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+` | 符号表 | 4,706,864 | `e2947b981f627851` |
| `vmlinux-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+` | 未压缩 ELF，供调试 | 31,093,040 | `0b412ca788176c27` |
| `modules.builtin` / `modules.order` | 模块拓扑 | 9,823 / 10,456 | `e98dce0d217fe52e` / `e545381745c71052` |
| `modules.builtin.modinfo` | 内置模块元信息（供 `modinfo` 与内置模块固件查找使用） | 118,595 | `f6c3be1c72eed3bf` |
| `BUILD-PROVENANCE.md` | 构建溯源与复现步骤（GPL-2.0 源码提供要求） | 3,499 | `21c8ade36835b012` |
| `git-log-patched-tree.txt` | 打过补丁的源码树提交记录 | 1,269 | `97c43d106f7ea938` |
| `sha256sums.txt` | 全部产物的 SHA-256 | 1,076 | `bdd6602ee356f2d1` |

## 安装

产物未执行 `modules_install`，需要在目标机上手工落位。以下步骤在 GK-W7X 上实测通过。

基线镜像把内核交给 `kernel-install` 管理（`/etc/kernel/install.conf` 为 `layout=bls`，
条目名 `<machine-id>-<内核 release 串>.conf`），因此按同一机制生成条目最稳妥：

```bash
REL=7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+
MACHINE=$(cat /etc/machine-id)
SRC=/var/tmp/iris-install          # 产物所在目录

# 1) 模块：包内路径相对于模块根，解到 /lib/modules/$REL
sudo mkdir -p "/lib/modules/$REL"
sudo tar --zstd -xf "$SRC/modules-$REL.tar.zst" -C "/lib/modules/$REL/"
sudo depmod -a "$REL"

# 2) 内核与设备树
#    90-loaderentry.install 会在若干前缀下查找 /etc/kernel/devicetree 指定的相对路径，
#    因此 DTB 必须落到 /usr/lib/modules/$REL/dtb/<相对路径>
sudo cp "$SRC/Image" "/boot/vmlinuz-$REL"
sudo mkdir -p "/usr/lib/modules/$REL/dtb/qcom"
sudo cp "$SRC/sc8280xp-huawei-gaokun3-el2.dtb" \
        "/usr/lib/modules/$REL/dtb/qcom/sc8280xp-huawei-gaokun3-el2.dtb"
sudo cp "$SRC/sc8280xp-huawei-gaokun3-el2.dtb" "/boot/dtb-$REL"
sudo cp "$SRC/config-$REL" "$SRC/System.map-$REL" /boot/

# 3) initrd：55-initrd.install 只把已存在的 /boot/initrd.img-$REL 链接进暂存区，
#    所以必须先自行生成，否则生成的条目里不会有 initrd
sudo update-initramfs -c -k "$REL"

# 4) 生成启动项（不动 loader.conf 的 default）
sudo kernel-install add "$REL" "/boot/vmlinuz-$REL"

# 5) 两条条目默认同名，改成可辨识的名字
sudo sed -i "s|^title .*|title      Ubuntu 26.04 LTS (IRIS 7.2.0-rc2)|" \
        "/boot/efi/loader/entries/$MACHINE-$REL.conf"
```

## 试启动与回滚

systemd-boot 支持 one-shot 条目：只启动一次，失败则下次开机自动回到原默认条目。
`loader.conf` 全程不必修改。

```bash
sudo bootctl set-oneshot "$MACHINE-$REL.conf"
sudo systemctl reboot
```

启动后核对：`uname -r`、`dmesg | grep -iE 'iris|qcom_scm|q6v5_pas'`、`ls /dev/video*`，以及触摸是否可用。

回滚即删除新增的这几处，基线内核不受影响：

```bash
sudo rm -rf "/boot/efi/$MACHINE/$REL"
sudo rm -f  "/boot/efi/loader/entries/$MACHINE-$REL.conf"
sudo rm -rf "/lib/modules/$REL" "/usr/lib/modules/$REL/dtb"
sudo rm -f  /boot/vmlinuz-$REL /boot/dtb-$REL /boot/config-$REL /boot/System.map-$REL /boot/initrd.img-$REL
```

完整的构建与安装说明见 `docs/build-kernel-iris.md`。

## 校验

```bash
sha256sum -c sha256sums.txt
```

## 复现

源码来源、补丁集、设备树改动与完整构建命令记录在随包 `BUILD-PROVENANCE.md`，摘要如下：

- 上游源码：`torvalds/linux` tag `v7.2-rc2`（`git.kernel.org` 快照）
- 补丁集：`KawaiiHachimi/linux-gaokun-buildbot` 的 `patches/upstream`、`patches/others`、`patches/0099-*`、`patches/el2`（`patches/media` 跳过）
- 设备树前置处理：本仓库 `tools/gaokun-iris-dts-prep.py`
- 上游 IRIS 节点来源：`3a52eef16b979617156fa6e2ead24ca4d1336f0b`、`595eb4144f2ecc58e8e56e07ae94407b5a696031`（v7.3-rc1 起）
- 构建机：Debian 12 x86_64，`aarch64-linux-gnu-gcc 12.2.0`，`-j16`，耗时约 6 分钟

## 许可

内核为 GPL-2.0。本产物是 Linux 内核的二进制分发，对应源码可由上游 tag、公开补丁集与本仓库脚本完整复现，`BUILD-PROVENANCE.md` 给出逐条命令，满足 GPL-2.0 的源码提供要求。

本仓库自身以 GPL-2.0-only 发布。
