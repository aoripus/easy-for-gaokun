# 安装到内置盘：Windows + Ubuntu 双系统

> 本文记录在 **HUAWEI MateBook E Go 2022 性能版（GK-W76）** 的内置盘上，
> 与出厂 Windows 共存安装 Ubuntu 的可复现流程。文中命令均取自实机验证过的操作记录。
>
> 适用范围：仅 §1 三条判据全部通过的机器（见 [README §1](../README.md)）。

---

## 0. 核心思路

社区镜像是**整盘镜像**，内部结构固定为两个分区：

| 分区 | 范围 | 大小 | 文件系统 | UUID（本基线） |
|:----:|------|:----:|----------|----------------|
| 1 | 1 – 1025 MiB | 1024 MiB | FAT32 **ESP** | `9146-7FE9` |
| 2 | 1025 – 12287 MiB | 11262 MiB | ext4 **rootfs** | `a2447957-fc4d-40d4-ab64-faf74f697471` |

因此**不能**把整盘镜像 `dd` 到一个分区里。正确做法是**分区级 `dd`**：
在目标盘上新建两个分区，再把镜像里的 `p1`、`p2` 分别 `dd` 进去。

这样做的附带效果是：

> **`dd` 会原样保留文件系统 UUID。**
> 镜像的 `/etc/fstab` 用的是 `UUID=9146-7FE9 /boot/efi` 与 `UUID=a2447957-… /`，
> BLS 条目的 cmdline 用的是 `root=UUID=a2447957-…`。
> 因为 UUID 被完整保留，**这两处配置一个字都不用改**。

---

## 1. 准备

### 1.1 记录 BitLocker 恢复密钥

如果 Windows 的 C: 开了 BitLocker，操作前先导出恢复密钥并抄到别处：

```powershell
manage-bde -status
manage-bde -protectors -get C: -type recoverypassword
```

### 1.2 确认可用空间

内置盘出厂时通常没有任何空闲空间，需要腾出：

- **至少 1 GiB + 12 GiB**
- **rootfs 建议给 64 GiB 以上**，装完再扩容

腾空间的三条路（按推荐度）：

| 方式 | 说明 |
|------|------|
| **复用空的数据分区** | 最干净。若 D: 之类的数据分区是空的，直接拿来重建 |
| 压缩 C: | 需先 `Suspend-BitLocker` 并 `powercfg /h off`；Windows 可能因不可移动文件压不动 |
| 删除原厂恢复分区 | **不推荐**，会永久失去一键恢复 |

> **操作前需确认目标分区里没有要保留的数据。**
> 本项目的实机操作中，一个"空的"D: 分区里实际有 993 MB 数据（含 Telegram 登录态）。
> 可先只读挂载查看：

```bash
sudo mkdir -p /mnt/probe && sudo mount -o ro /dev/nvme0n1p4 /mnt/probe
sudo find /mnt/probe -mindepth 1 | wc -l
sudo umount /mnt/probe
```

### 1.3 备份分区表（建议执行）

```bash
sudo sgdisk --backup=/root/nvme0n1-gpt-backup.bin /dev/nvme0n1
sudo sgdisk -p /dev/nvme0n1 > /root/nvme0n1-gpt-before.txt
```

还原方式：`sudo sgdisk --load-backup=/root/nvme0n1-gpt-backup.bin /dev/nvme0n1`

---

## 2. 获取并检查镜像

```bash
# 从 buildbot release 下载，并核对官方公布的 sha256
EXPECT=c3c151e6f9890a1c64b60596b633e7ffc5c90aba199cdc1fe579c1bdc7105e59
sha256sum ubuntu-26.04-gaokun3.img.zst

# 解压（12 GiB，需要足够空间；放外置盘即可）
zstd -d -k -f ubuntu-26.04-gaokun3.img.zst -o ubuntu-26.04-gaokun3.img

# 挂成 loop，认清两个分区并记下 UUID
LOOP=$(losetup --show -fP ubuntu-26.04-gaokun3.img)
sudo parted -s $LOOP unit MiB print
sudo blkid ${LOOP}p1 ${LOOP}p2 | tee /root/src-uuid.txt
```

**记下这两个 UUID**，第 5 步要逐字核对。

---

## 3. 在目标盘上建分区

假设空闲空间位于某个已有分区的范围内（例如要重建 `nvme0n1p4`），
**先读出它原有的起止扇区**，在其范围内切出两个新分区：

```bash
read START END < <(sgdisk -p /dev/nvme0n1 | awk '$1==4 {print $2, $3}')
ESP_START=$START
ESP_END=$((START + 1024*2048 - 1))      # 1 GiB = 1024 MiB = 2097152 扇区
ROOT_START=$((ESP_END + 1))
ROOT_END=$END

sudo sgdisk -d 4 /dev/nvme0n1
sudo sgdisk -n 4:${ESP_START}:${ESP_END}   -t 4:ef00 -c 4:"LINUX-ESP" /dev/nvme0n1
sudo sgdisk -n 8:${ROOT_START}:${ROOT_END} -t 8:8300 -c 8:"rootfs"    /dev/nvme0n1
sudo partprobe /dev/nvme0n1
sudo wipefs -a /dev/nvme0n1p4 /dev/nvme0n1p8     # 清掉残留文件系统签名
```

也可以用交互式工具：`sudo cfdisk /dev/nvme0n1`
（新建 1 GiB 选 `EFI System`，其余选 `Linux filesystem`）。

> **不要动** Windows 的 ESP、MSR、C:、WINPE、Onekey、WinRE 这几个分区。

---

## 4. 分区级 dd

```bash
# ESP（1 GiB，约 25 秒）
sudo dd if=${LOOP}p1 of=/dev/nvme0n1p4 bs=4M  status=progress conv=fsync

# rootfs（11 GiB，约 4 分钟）
sudo dd if=${LOOP}p2 of=/dev/nvme0n1p8 bs=16M status=progress conv=fsync
sync
```

---

## 5. 核对 UUID（**这一步不能跳**）

```bash
sudo blkid /dev/nvme0n1p4 /dev/nvme0n1p8
```

必须与第 2 步记录的**逐字一致**：

```
/dev/nvme0n1p4: ... UUID="9146-7FE9"                              TYPE="vfat"
/dev/nvme0n1p8: ... UUID="a2447957-fc4d-40d4-ab64-faf74f697471"   TYPE="ext4"
```

**不一致就停下**：说明 `dd` 出错，此时 `fstab` 和 `root=UUID=` 都会失效，系统起不来。

---

## 6. 扩容 rootfs

```bash
sudo e2fsck -f -y /dev/nvme0n1p8
sudo resize2fs /dev/nvme0n1p8
sudo dumpe2fs -h /dev/nvme0n1p8 | grep -E '^Block count|^Block size'
```

---

## 7. 修掉镜像自带的两处缺陷

### 7.1 `loader.conf` 的默认项指向会卡住的内核

镜像自带的 `default` 指向**非 `el2`** 条目，该内核在 GUI 阶段卡住：

```bash
sudo mkdir -p /mnt/newesp && sudo mount /dev/nvme0n1p4 /mnt/newesp
ls /mnt/newesp/loader/entries/          # 确认两个条目文件名

sudo tee /mnt/newesp/loader/loader.conf > /dev/null <<'EOF'
default 8a29534fa802480d9fbb71aa18c01d7b-7.1.0-rc3-gaokun3-el2+.conf
timeout 5
console-mode keep
editor no
EOF
```

> `<machine-id>` 就是 `/mnt/newesp/` 下的那个目录名，也是 `loader/entries/` 里条目的前缀。

### 7.2 把触屏修复编译进 DTB

默认状态下触控 IC 的接口模式脚 `gpio174` 无人管理、停在固件遗留的高电平，
触屏**完全不可用**（详见 [README §2.1](../README.md)）。补丁在
[`patches/`](../patches/)，安装时直接编译进 ESP 上的 DTB：

```bash
sudo apt-get install -y device-tree-compiler     # 需要 dtc

MID=8a29534fa802480d9fbb71aa18c01d7b
KREL=7.1.0-rc3-gaokun3-el2+
DTB="/mnt/newesp/${MID}/${KREL}/sc8280xp-huawei-gaokun3-el2.dtb"

cp -a "$DTB" "${DTB}.orig"                       # 先备份
dtc -I dtb -O dts -o /tmp/el2.dts "$DTB"

python3 - <<'PY'
p = "/tmp/el2.dts"
s = open(p, encoding="utf-8", errors="surrogateescape").read()
anchor = 'pins = "gpio99";'
i = s.index(anchor); j = s.index("};", i) + 2
block = '''

			mode-n-pins {
				pins = "gpio174";
				function = "gpio";
				drive-strength = <2>;
				bias-disable;
				output-low;
			};'''
open(p, "w", encoding="utf-8", errors="surrogateescape").write(s[:j] + block + s[j:])
PY

dtc -I dts -O dtb -o /tmp/el2-new.dtb /tmp/el2.dts
dtc -I dtb -O dts -o /dev/null /tmp/el2-new.dtb && echo "DTB 合法"
cp /tmp/el2-new.dtb "$DTB"
```

> `dtc` 会刷出大量 `duplicate unit-address` 之类告警 —— 那是**内核原版 DTS 固有**的，
> 原始 DTB 反编译时同样存在，**无害**。

---

## 8. 建立 UEFI 引导项

```bash
sudo umount /mnt/newesp

sudo efibootmgr -c -d /dev/nvme0n1 -p 4 \
     -L "Ubuntu (gaokun3)" -l '\EFI\systemd\systemd-bootaa64.efi'

sudo efibootmgr -v
```

然后把顺序调到第一位（`0001` = Ubuntu，`0003` = Windows，`0000` = 固件菜单应用）：

```bash
sudo efibootmgr -o 1,3,0
```

---

## 9. 首次启动后

```bash
sudo chown root:root /          # 修镜像缺陷：根目录属主被错设为 uid 1001
```

触屏应当**开箱可用**，不需要任何脚本或常驻服务。验证：

```bash
grep -E '^ ?gpio174 ' /sys/kernel/debug/gpio     # 期望 out low … 2mA no pull
grep himax-spi-ts /proc/interrupts               # 触摸时计数应持续增长
```

---

## 10. 踩坑记录（都是实机踩出来的）

### 10.1 固件会把引导项重命名成 "Windows Boot Manager"

用 `efibootmgr -c` 建的项，重启后描述会被固件改成
`Windows Boot Manager(PCIe-8 SSD <型号>)`，**与真正的 Windows 项同名**。
`efibootmgr -b N -L "..."` **改不动**（不报错但无效）。

**后果**：开机按 F12 会看到两条一模一样的 "Windows Boot Manager"。
**识别方法**：在 `efibootmgr -v` 里看设备路径 ——

```
Boot0001  …/HD(4,GPT,522cc1ee-…)/\EFI\systemd\systemd-bootaa64.efi     ← Linux
Boot0003  …/HD(1,GPT,de14ce25-…)/\EFI\Microsoft\Boot\bootmgfw.efi      ← Windows
```

**只要 `BootOrder` 把 Linux 那条排前面，平时就完全不需要 F12。**

> Windows 的 `bcdedit /enum firmware` 不一定会列出 `efibootmgr` 建的项，
> 所以"BCD 里看不到"**不等于**固件里没有。

### 10.2 ⚠️ 同一镜像 dd 出的两块盘 UUID 完全相同，**不可同时接入**

`fstab` 写的是 `UUID=9146-7FE9 /boot/efi`。如果外置盘和内置换出的系统**都接着**，
udev 为同一个 UUID 生成的 `/dev/disk/by-uuid/…` 只会指向其中一个，
系统**可能把另一块盘的 ESP 当成 `/boot/efi`**。

**规避方式（任选其一）**：

- 只保留一块启动盘，另一块不接（最简单）
- 改掉其中一块盘的 UUID，并同步修改它的 `fstab` 与 BLS cmdline
- 改掉其中一块 ESP 的 FAT 卷序列号（需直接编辑引导扇区，不推荐）

### 10.3 外置盘会在移动中掉盘导致系统崩溃

USB SSD 被碰一下就可能断开，运行中的系统随即崩溃（表现为 SSH 直接被拒、
`kex_exchange_identification: Connection closed`）。这也是**最终要装到内置盘**的原因之一。

### 10.4 含中文/空格的挂载路径会让 `scp` 出错

若目标目录形如 `/run/media/user/新加卷/`，改用一个 ASCII 路径的 bind mount：

```bash
sudo mkdir -p /mnt/gaokun
sudo mount --bind "/run/media/user/新加卷/gaokun" /mnt/gaokun
sudo chown user:user /mnt/gaokun
# 之后 scp 到 /mnt/gaokun/ 即可
```

### 10.5 镜像 ESP 只有 133 MB 的实际占用

即使分到 1 GiB，实际内容（2 内核 + 2 initrd + 2 DTB + EL2 驱动 + 3 个 DSP 固件）
也只有 **133 MB**。所以 **300 MB 的 Windows ESP 理论上也装得下** ——
但本项目仍推荐**独立 ESP**，因为完全不碰 Windows 引导文件、风险最低。

### 10.6 本机固件似乎只从"第一个 ESP"引导

这是我们最初用独立 ESP 时 F12 需手动选择的可能原因之一。
无论如何，**独立 ESP + `efibootmgr -o` 调顺序**已实机验证可用。

---

## 11. 回滚

| 层级 | 方式 |
|------|------|
| 只撤销引导项 | `sudo efibootmgr -b 1 -B`（删除该项），再把 Windows 排到第一 |
| 恢复 GPT 分区表 | `sudo sgdisk --load-backup=/root/nvme0n1-gpt-backup.bin /dev/nvme0n1` |
| 恢复原 DTB | ESP 上保留了 `*.dtb.orig`，直接覆盖回去 |
| 恢复 Windows 引导 | 用 WinPE / 外置 Linux 挂载 `nvme0n1p1`，把备份的 `BOOTAA64.EFI.bak` 还原为 `BOOTAA64.EFI` |
| 完全放弃 Linux | 删除 `nvme0n1p8` 与 `nvme0n1p4`，把空间还给 Windows |

> ⚠️ **本机型没有 EDL / 9008 救援通道。** 任何改动前请先做备份，
> 并确保手上有一个可启动的备用介质。
