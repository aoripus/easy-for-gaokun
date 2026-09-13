# [内核] 7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+

发布日期：2026-09-13
适用设备：HUAWEI MateBook E Go 2022 性能版（GK-W76 / GK-W7X-PCB / SC8280XP / gaokun3）

---

## 状态

编译通过，产物完整（校验值见下方 SHA256）。**未在目标设备上启动验证。**

本机没有 EDL / 9008 救援通道，安装前应保留一个可用的默认启动项，回滚方式见「安装」第 4 步。

## 已知风险

IRIS 与 Venus 使用同一套 PAS 调用序列（`qcom_scm_pas_auth_and_reset`、`qcom_scm_mem_protect_video_var`），而本机 `qcom_scm_pas_init_image()` 已确认会失败。若启动后 probe 仍报 `auth and reset failed`，失败点在 SCM/PAS，换 media 驱动不改变该通路是否可用。详见 `docs/build-kernel-iris.md` §7.1。

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

| 文件 | 说明 | 字节 |
|---|---|---:|
| `Image` | 内核映像（arm64，未压缩，供 systemd-boot 直接加载） | 24,730,112 |
| `sc8280xp-huawei-gaokun3.dtb` | 标准设备树 | 170,594 |
| `sc8280xp-huawei-gaokun3-el2.dtb` | EL2 叠加变体，与当前运行的基线内核同构 | 170,764 |
| `modules-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+.tar.zst` | 359 个内核模块，含 `qcom-iris.ko` | 4,982,268 |
| `config-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+` | 完整 `.config` | 209,244 |
| `System.map-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+` | 符号表 | 4,706,748 |
| `vmlinux-7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+` | 未压缩 ELF，供调试 | 31,092,856 |
| `modules.builtin` / `modules.order` | 模块拓扑 | 9,823 / 10,456 |
| `BUILD-PROVENANCE.md` | 构建溯源与复现步骤（GPL-2.0 源码提供要求） | 3,003 |
| `git-log-patched-tree.txt` | 打过补丁的源码树提交记录 | 1,300 |
| `sha256sums.txt` | 全部产物的 SHA-256 | 986 |

## 安装

产物未执行 `modules_install`，也未写入 ESP，需要手工放置。建议新增一个独立启动项，保留现有条目为默认值。

```bash
REL=7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+
MACHINE=8a29534fa802480d9fbb71aa18c01d7b      # /etc/machine-id
ESP=/boot/efi/$MACHINE/$REL

# 1) 内核与设备树
sudo mkdir -p "$ESP"
sudo cp Image "$ESP/linux"
sudo cp sc8280xp-huawei-gaokun3-el2.dtb "$ESP/sc8280xp-huawei-gaokun3-el2.dtb"

# 2) 模块（原有内核的模块目录保持不动）
sudo tar --zstd -xf modules-$REL.tar.zst -C /lib/modules/$REL/
sudo depmod -a "$REL"

# 3) 新增启动项，options 沿用现有条目，只改 devicetree 与 initrd 路径
sudo cp /boot/efi/loader/entries/$MACHINE-7.1.0-rc3-gaokun3-el2+.conf \
        /boot/efi/loader/entries/$MACHINE-$REL.conf
#   然后将条目内的 linux / devicetree / initrd / version 改为上面的路径

# 4) 回滚：把 loader.conf 的 default 改回原条目，或删除新条目
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
