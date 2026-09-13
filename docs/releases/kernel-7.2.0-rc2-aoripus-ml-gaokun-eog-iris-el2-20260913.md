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
| 视频硬解 | **不可用**，失败点已定位，见下节 |

本机是标准 UEFI 平台：有固件设置界面、可从 USB 启动、ESP 是普通 FAT32 分区。安装时保留原
默认条目即可；即使引导项写错，也能用 U 盘启动挂载 ESP 修复。

## 视频硬解的状态：已定位到 EL2 的复位语义

固件启动要跨过四道关卡，本产物停在第四道：

| 阶段 | 结果 | 说明 |
|---|---|---|
| `qcom_scm_pas_init_image` | 通过 | 需要 `patches/iris-el2/` 的 tzmem/ctx 修复，否则报 `-22` |
| `qcom_scm_pas_auth_and_reset` | 通过 | 需要改用 `qcom_scm_pas_prepare_and_auth_reset()`：EL2 下 SHM bridge 必须由 Linux 自建 |
| `qcom_scm_mem_protect_video_var` | `-5`（EIO） | 只服务于 DRM 内容保护；改为非致命后不影响后续步骤 |
| `iris_vpu_boot_firmware` | **`-62`（ETIME）** | 驱动写 `CTRL_INIT` 后轮询 1000 次（约 110 ms），`CTRL_STATUS` 恒为 `0` |

`iris_vpu_boot_firmware` 前后各读一次寄存器，读数完全一致：

```text
CTRL_STATUS=0x0
WRAPPER_CORE_POWER_STATUS=0x2          （wrapper 有电）
WRAPPER_TZ_CPU_STATUS=0x0              （WFI 位为 0：核心不在运行/空闲态）
WRAPPER_CORE_CLOCK_CONFIG=0x0
```

即 **wrapper 有电，但视频核心始终没有执行固件**。已排除的两个变量：

- **固件代次**：换用 X13s 的 `qcvss8280.mbn`（2,035,812 B，与华为那份 2,035,748 B 仅差 64
  字节）后结果逐字节相同 —— 同样的 `-62`、同样的寄存器读数；
- **固件内存可达性**：`video-region@86700000`（2.10 GiB，5 MiB）远低于驱动
  `sm8250_data.dma_mask`（`0xe0000000`）。

这与上游 EL2 补丁 `0018` 的原文一致：EL2 下可以认证并启动固件，但远程处理器不会真正脱离
复位。remoteproc 靠 `qcom,broken-reset` 跳过复位、接管引导固件已启动的实例来绕过；视频核心
必须由 Linux 自行启动，没有"在位接管"这条路，因此在 EL2 下不可用。要让视频硬解可用，需要
内核运行在 EL1（下面有 hypervisor 代管 PAS），而本机固件是把 Linux 直接投到 EL2。

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
