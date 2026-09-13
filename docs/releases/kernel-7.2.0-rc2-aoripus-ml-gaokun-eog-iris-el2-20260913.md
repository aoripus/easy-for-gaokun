# 内核构建 `7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+`

面向 **HUAWEI MateBook E Go 2022 性能版（GK-W76 / GK-W7X / SC8280XP / gaokun3�?* �?**IRIS 视频硬解试验内核**�?
> ## ⚠️ 状态：**已成功编译，但未经启动验�?*
>
> 这个构建**只保证编译通过、产物齐�?*�?*没有在真机上启动�?*�?> 本机�?*没有 EDL / 9008 救援通道**，刷写前务必保留可用启动项�?>
> 而且有一�?*已知的、换驱动解决不了的风�?*：IRIS �?Venus 走的�?*同一�?> PAS / 安全世界通路**（`qcom_scm_pas_auth_and_reset` + `qcom_scm_mem_protect_video_var`），
> 而该�?`qcom_scm_pas_init_image()` 已确知会失败�?*如果启动�?probe 仍报
> `auth and reset failed`，问题在 SCM/PAS 而不�?media 驱动�?*
> 详见 [`docs/build-kernel-iris.md` §7.1](https://github.com/aoripus/easy-for-gaokun/blob/main/docs/build-kernel-iris.md)�?
---

## 这是什�?
目标机的视频硬解单元�?**Qualcomm IRIS (Gen1)**，不是经�?Venus。而基线内�?（`linux-gaokun-buildbot` �?release）用 `CONFIG_VIDEO_QCOM_VENUS=m` 配一�?**2023 年形态的 venus 设备树节�?*（`compatible = "qcom,sm8350-venus"`�?`iommus = <&apps_smmu 0x2e00 0x400>`），启动时稳定报�?
```
qcom-venus aa00000.video-codec: error -22 initializing firmware qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn
qcom-venus aa00000.video-codec: fail to load video firmware
```

本构建把它换成上游的 **iris** 方案�?
## 与基线内核的差异

| �?| 基线 | 本构�?|
|---|---|---|
| 视频驱动 | `CONFIG_VIDEO_QCOM_VENUS=m` | **`CONFIG_VIDEO_QCOM_IRIS=m`**，VENUS 关闭 |
| 视频设备树节�?| `venus: video-codec@aa00000`，`compatible = "qcom,sm8350-venus"`，`iommus = 0x2e00`，缺 `mmcx` 电源�?| **`iris: video-codec@aa00000`**，`compatible = "qcom,sc8280xp-iris", "qcom,sm8250-venus"`，`iommus = 0x2a00`，含 `mmcx` |
| 视频固件 | 设备�?`firmware-name = qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn` | **不变**（IRIS �?`sm8250_data.fwname` 指向已被 linux-firmware 删除�?`qcom/vpu-1.0/venus.mbn`，必须靠设备树覆盖） |
| `LOCALVERSION` | `-gaokun3-el2` | **`-aoripus-ml-gaokun-eog-iris-el2`** |

**其余一切不�?*：补丁集、dts、defconfig 与配置项都与基线一致，只是
`patches/media/` 整目录被跳过（那 6 个补丁是 venus 方案，与本构建冲突）�?
## 产物

| 文件 | 说明 |
|---|---|
| `Image` | 内核映像（arm64�?*未压�?*，供 systemd-boot 直接加载�?|
| `sc8280xp-huawei-gaokun3.dtb` | 标准设备�?|
| `sc8280xp-huawei-gaokun3-el2.dtb` | **EL2 叠加变体**（与当前运行的内核同构） |
| `modules-*.tar.zst` | 359 个内核模块（�?`qcom-iris.ko`�?|
| `config-*` | 完整 `.config` |
| `System.map-*` | 符号�?|
| `vmlinux-*` | 未压�?ELF（供调试�?|
| `BUILD-PROVENANCE.md` | **GPL-2.0 合规的构建溯源清单与复现步骤** |
| `sha256sums.txt` | 全部产物�?SHA-256 |

## 装法�?*不要**直接覆盖现有内核�?
产物**没有** `modules_install`、没有写 ESP，需要手工放置。保守做法是**新增一�?独立启动�?*、保留现有条目为默认�?
```bash
REL=7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+
MACHINE=8a29534fa802480d9fbb71aa18c01d7b      # /etc/machine-id
ESP=/boot/efi/$MACHINE/$REL

# 1) 放内核与设备�?sudo mkdir -p "$ESP"
sudo cp Image "$ESP/linux"
sudo cp sc8280xp-huawei-gaokun3-el2.dtb "$ESP/sc8280xp-huawei-gaokun3-el2.dtb"

# 2) 放模块（保留原有内核的模块目录不动）
sudo tar --zstd -xf modules-$REL.tar.zst -C /lib/modules/$REL/
sudo depmod -a "$REL"

# 3) 建启动项，options 抄现有条目的，只�?devicetree �?initrd 路径
sudo cp /boot/efi/loader/entries/$MACHINE-7.1.0-rc3-gaokun3-el2+.conf \
        /boot/efi/loader/entries/$MACHINE-$REL.conf
#   然后手工把里面的 linux / devicetree / initrd / version 换成上面三个路径

# 4) 回滚：把 loader.conf �?default 改回原条目，或删掉新条目
```

> 更完整的构建与安装说明见
> [`docs/build-kernel-iris.md`](https://github.com/aoripus/easy-for-gaokun/blob/main/docs/build-kernel-iris.md)�?
## 复现

源码来源、补丁集、设备树改动、构建命令全部写在随包的 `BUILD-PROVENANCE.md`�?摘要�?
- 上游源码：`torvalds/linux` tag **`v7.2-rc2`**（`git.kernel.org` 快照�?- 补丁集：[`KawaiiHachimi/linux-gaokun-buildbot`](https://github.com/KawaiiHachimi/linux-gaokun-buildbot)
  �?`patches/upstream`、`patches/others`、`patches/0099-*`、`patches/el2`（`media/` 跳过�?- 设备树前置：本仓库的 [`tools/gaokun-iris-dts-prep.py`](https://github.com/aoripus/easy-for-gaokun/blob/main/tools/gaokun-iris-dts-prep.py)
- 上游 IRIS 节点来源：`3a52eef16b979617156fa6e2ead24ca4d1336f0b`、`595eb4144f2ecc58e8e56e07ae94407b5a696031`（v7.3-rc1 起）
- 构建机：Debian 12 x86_64，`aarch64-linux-gnu-gcc 12.2.0`，`-j16`，耗时�?6 分钟

## 许可

内核�?**GPL-2.0**。本产物�?Linux 内核的二进制分发，对应源码可由上�?上游 tag + 公开补丁�?+ 本仓库脚本完整复现，`BUILD-PROVENANCE.md` 给出了逐条命令�?满足 GPL-2.0 的源码提供要求�?
本仓库自身以 **GPL-2.0-only** 发布�?