# [内核] 7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+

发布日期：2026-09-13
适用设备：HUAWEI MateBook E Go 2022 性能版（GK-W76 / GK-W7X-PCB / SC8280XP / gaokun3）

---

## 状态

编译通过，产物完整（校验值见下方 SHA256）。**未在目标设备上启动验证。**

本机没有 EDL / 9008 救援通道，安装前应保留一个可用的默认启动项，回滚方式见「安装」第 4 步。

## 已知风险

IRIS 与 Venus 使用同一套 PAS 调用序列（`qcom_scm_pas_auth_and_reset`、`qcom_scm_mem_protect_video_var`），而该通路在 EL2 下的可用性取决于 `patches/el2/*` 中的 self-owner 与 `qcom,broken-reset` 改动，本产物已包含该组补丁。若启动后 probe 仍报 `auth and reset failed`，失败点即在 SCM/PAS。详见 `docs/build-kernel-iris.md` §7.1。

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
