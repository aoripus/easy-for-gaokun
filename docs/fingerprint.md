# 指纹识别：可行性调查与结论

> **一句话结论**：本机指纹是 **FocalTech FTE7001**，挂在 **SPI** 上，但那条 SPI 由
> **Qualcomm 安全世界（QSEE/TEE）独占**：Windows 的非安全侧驱动只拿到一个
> **GPIO 中断连接**，没有任何 SPI/I²C 总线资源；传感器取图、特征提取与模板比对
> 全部在签名 trustlet `fingerpr.mbn` 内完成。
> 因此在 Linux 上**无法通过常规内核驱动路线使用这颗指纹**——这不是"还没人写驱动"，
> 而是**非安全世界根本拿不到那条总线**，且算法在 TEE 里。

---

## 0. 结论速览

| # | 问题 | 结论 | 证据等级 |
|:-:|------|------|:--------:|
| 1 | 本机指纹型号是什么？ | **FocalTech FTE7001**（ACPI HID `ACPI\FTE7001`），`ACPI\GDIX5125` / `ACPI\ELAN7001` / `ACPI\GXFP5130` **在本机一个都没有** | 【已核实】 |
| 2 | 它挂在哪条总线上？ | **SPI**（安全世界侧）；非安全侧只暴露 **GPIO 中断连接**（`Class=GPIO / Type=GPIO_INT`） | 【已核实】 |
| 3 | Linux 为什么看不到它？ | `lsusb` / `lspci` / `/sys/bus/spi` / `/sys/bus/i2c` 上都没有它；设备树里也**没有任何指纹节点**，24 个 GENI SPI 只有触摸屏那个是 `okay` | 【已核实】 |
| 4 | 能不能像 X13s 那样"使能 USB multiport"就出来？ | **不能**。本机 `usb_2` 多端口控制器已经使能，4 个 HS 端口在线，但**没有任何指纹 USB 设备枚举**（只有 `12d1:10b8` 华为键盘） | 【已核实】 |
| 5 | 能不能写个 SPI 驱动读图？ | **不能**。总线资源不在非安全世界；即使拿到了，算法与模板存储也在 TEE 内 | 【已核实（资源分配）/ 推测（因果关系）】 |
| 6 | 短期可交付什么？ | 一份**可复现的取证结论** + 一个只读探针脚本（`scripts/40-fingerprint.sh`）+ 一个离线 hive 取证工具（`tools/win-acpi-hive.py`） | — |
| 7 | 什么条件下可以重启这项工作？ | 见 §7：拿到 DSDT 里 `\_SB.SPBA` 的 `_CRS`、或上游出现 SC8280XP 的 TEE 客户端与可加载 TA 的通路 | — |

> **置信度标记**：【已核实】直读第一手文件、注册表、固件或本机实测 ·【社区报告】论坛 / 邮件列表 / 第三方 ·【推测】本项目推断。

---

## 1. 为什么这件事值得先做一次取证

社区（`right-0903/linux-gaokun` 的 README 特性表）对指纹只有一行：

```
| Fingerprint reader | x | FTE7001, gpio185 |        ← 【社区报告】
```

既没有说总线类型，也没有说清 `gpio185` 是复位、中断还是电源使能。而**驱动转储
`Drv/` 里同时存在 FocalTech 与 Goodix 两套指纹驱动**，看上去两可。第 3、4 节的取证
就是要把这两点一次钉死，避免在错误的前提下投入数月。

---

## 2. 取证方法：为什么不能直接读 DSDT，以及怎么绕开

### 2.1 直接读 DSDT 在本机行不通【已核实】

| 途径 | 实测结果 |
|------|----------|
| `/sys/firmware/acpi/` | **不存在**（DTB 启动，内核未初始化 ACPI） |
| `/proc/kcore` | **不存在**（`CONFIG_PROC_KCORE` 未启用） |
| `acpidump` / `iasl` | 未安装，且没有 ACPI 子系统可读 |
| `/dev/mem` 读 RSDP | `PermissionError: Operation not permitted`（`CONFIG_STRICT_DEVMEM=y`） |

dmesg 里其实给出了 RSDP 的物理地址，说明 ACPI 表仍在内存中：

```
[    0.000000] efi: ACPI 2.0=0xffffd000 MEMATTR=... ESRT=... SMBIOS=... INITRD=...
```

内核配置实测：`CONFIG_DEVMEM=y`、`CONFIG_STRICT_DEVMEM=y`、`CONFIG_QCOM_QSEECOM=y`、
`CONFIG_QCOM_QCEECOM_UEFISECAPP=y`、**`# CONFIG_TEE is not set`**、`CONFIG_PROC_KCORE` 未启用。

### 2.2 绕开办法：读 Windows 的注册表 hive【已核实】

Windows 装在同一块硬盘（`nvme0n1p3`）上，**并且确实启动过**。它的
`SYSTEM` hive 里：

```
HKLM\SYSTEM\CurrentControlSet\Enum\ACPI\<ACPI HID>\<实例序号>
```

记录的是**这台机器真正枚举过的 ACPI 设备**——不是驱动包里"可能支持"的设备。
更关键的是每个实例下的：

```
LogConf\BootConfig          REG_BINARY   ← Windows 为它分配的 CM_RESOURCE_LIST
LogConf\BasicConfigVector   REG_BINARY   ← 它向系统申请的资源（需求列表）
```

于是不需要重启、不需要改内核 cmdline、也不需要进 Windows：

```bash
# 在 Linux 上只读挂载 Windows 分区（本机实测 ntfs-3g 可挂载）
sudo mount -t ntfs-3g -o ro /dev/nvme0n1p3 /mnt/win
sudo cp /mnt/win/Windows/System32/config/SYSTEM /tmp/SYSTEM
sudo apt-get install -y python3-hivex
python3 tools/win-acpi-hive.py /tmp/SYSTEM --find FTE7001 GDIX5125 ELAN7001
python3 tools/win-acpi-hive.py /tmp/SYSTEM --resources FTE7001
python3 tools/win-acpi-hive.py /tmp/SYSTEM --connections
```

> 顺带取出的 `Windows/INF/setupapi.dev.log`（2.5 MB）在本机**没有**任何
> FTE7001 / GDIX / fingerprint 记录——设备是随镜像预装的，不走安装日志。

---

## 3. 硬件身份：FocalTech FTE7001

### 3.1 注册表枚举实例（决定性）【已核实】

在本机 SYSTEM hive 的 `Enum\ACPI` 子树中：

| ACPI HID | 枚举实例数 |
|----------|:----------:|
| `FTE7001` | **1** |
| `GDIX5125`（Goodix） | **0** |
| `ELAN7001`（Elan） | **0** |
| `GXFP5130`（Goodix eSPI/EC 方案） | **0** |

FTE7001 的实例键内容：

```
DeviceDesc    @oem117.inf%2C%25devicename%25;FocalTech Fingerprint reader
Mfg           FocalTech Electronics(ShenZhen)Co.,Ltd
HardwareID    ACPI\VEN_FTE&DEV_7001 | ACPI\FTE7001 | *FTE7001
CompatibleIDs ACPI\FTE7001 | FTE7001
Service       WUDFRd                       ← UMDF 反射服务
ClassGUID     {53d29ef7-377c-4d14-864b-eb3a85769359}   ← 生物识别类
Exclusive     DWORD 0x00000001
Device Characteristics  DWORD 0x00000100
父设备        ACPI(_SB_)#ACPI(SPBA)        ← DEVPKEY_Device_Parent
Device Parameters\WUDF\DriverList        FtWbioDriverUmdf
Device Parameters\WUDF\DirectHardwareAccess  DWORD 0x00000001
Device Parameters\WinBio\Configurations\0\EngineAdapterBinary   ftWbioEngineAdapter.DLL
Device Parameters\WinBio\Configurations\0\SensorMode            0x1
```

> **结论**：**本机真的只有 FocalTech 这一颗**。`Drv/` 里出现 Goodix 的 INF
> **不能**作为"本机有 Goodix"的证据（见 §3.3）。

### 3.2 驱动包内容（一手，`Drv/` 只读）【已核实】

| 路径 | 内容 |
|------|------|
| `Drv/生物识别设备/ftwbiodriverumdf.inf_arm64_2679f6399fdbb04a/ftwbiodriverumdf.inf` | UTF-16LE；唯一硬件 ID `ACPI\FTE7001`；Provider `FocalTech Electronics(ShenZhen)Co.,Ltd`；`DriverVer 03/17/2023,1.2.0.31`；UMDF + `UmdfDirectHardwareAccess` |
| 同目录 `FtWbioDriverUmdf.dll` | UMDF 驱动本体；含 `Set power button do nothing` / `recover power button policy`（印证指纹在电源键上） |
| `Drv/生物识别设备/gfspi.../gfspi.inf` | Goodix；唯一硬件 ID `ACPI\GDIX5125`；**没有** QcTrEE Secure App 注册段 |
| `Drv/扩展/qctreeextoem8280.inf_arm64_671465aeb0edf1b8/fingerpr.mbn` | **3,669,575 字节**，ELF64/AArch64 `ET_DYN` —— Qualcomm TEE 的可信应用（TA） |

**只有 FocalTech 的 INF 把 `fingerpr.mbn` 注册为 QcTrEE Secure App（`AppName="fingerpr"`）**；
Goodix 那份没有这个注册段。这是"本机 TA 属于 FocalTech 实现"的第一条独立证据。

### 3.3 `Drv/` 不是"本机硬件清单"，而是"家族主镜像驱动库"【已核实】

`Recovery/OEM/Customization/Product/Dirvers2PE/PAR_install.cmd` 里：

```
DISM /image:w:\ /add-driver /driver:%AR_path%\PlatformDriver /recurse
```

而 `PlatformDriver` 目录下**同时**预置了：

- `FocalTechdriver1.2.0.27/`
- `Goodix1.1.143.622/`
- `QcTreeExtOem8280/`

即两套指纹驱动被**无差别注入同一镜像**，由**运行时 ACPI 枚举**决定谁绑定。
恢复镜像里也没有任何机型/SKU 级指纹分支（`machine_check/Check.vbs` 只校验
`BaseBoard Manufacturer = HUAWEI` 且 `Product = GK-W7X / -PCB`；
`RecoveryTool/product.ini` 只有 `product=GK-W7X`）。

> **方法论修正（本项目记录在案）**：判断本机硬件**必须看运行时枚举结果**
> （注册表 `Enum` 子树 / DSDT），**不能**看驱动包里有没有某个 INF。
> 本报告早期草稿曾把 `ACPI\ELAN7001` 当作证据，实际上它在整个转储里根本无法复现，
> 已删除该论断。

### 3.4 社区说法【社区报告】

`right-0903/linux-gaokun` 的 README 特性表：`| Fingerprint reader | x | FTE7001, gpio185 |`。
其 `dts/sc8280xp-huawei-gaokun3.dts` 全文 grep `finger|focal|fte` **零命中**，
与本机"设备树里没有指纹节点"的观察一致。

---

## 4. 总线归属：SPI，且 SPI 属于安全世界

### 4.1 先建立"连接描述符字节语义"的标尺

Windows 分配给设备的资源存在 `BootConfig`（`CM_RESOURCE_LIST`）。其中的连接资源
（`Type = 0x84`，`CmResourceTypeConnection`）固定为 **4 + 16 = 20 字节**，
union 的**前两字节是 `Class` 与 `Type`**：

```
Class: 0x01 = GPIO        0x02 = SERIAL（SPB）      0x03 = FUNCTION
Type : GPIO   0x01 = IO   0x02 = INT
       SERIAL 0x01 = I2C  0x02 = SPI  0x03 = UART
```

**这条语义不是猜的**，而是用同一台机器上的已知设备标定出来的
（`tools/win-acpi-hive.py --connections` 可复现）：

```
连接类型   ACPI ID     DeviceDesc                                    Class  Type  Id1
GPIO_INT   QCOM0696    Qualcomm(R) PCIe Platform Extension Plugin   0x01   0x02   2..8
GPIO_INT   QCOM2466    Qualcomm SoC Secure Digital host controller  0x01   0x02   41
GPIO_INT   VEN_QCOM&DEV_0636  Qualcomm(R) Adreno(TM) 8cx Gen 3      0x01   0x02   46
GPIO_INT   HIMX0001    THP SPI Device Driver                        0x01   0x02   34
SPI        HIMX0001    THP SPI Device Driver                        0x02   0x02   37
SPI        HIMX0002    THP SPI Device Driver                        0x02   0x02   39
UART       QCOM066B    Qualcomm(R) Bluetooth UART Transport Driver  0x02   0x03   44
★ GPIO_INT FTE7001     FocalTech Fingerprint reader                 0x01   0x02   10

Class/Type 分布：0x01/0x02 (GPIO_INT) 14 个 · 0x02/0x02 (SPI) 2 个 · 0x02/0x03 (UART) 1 个
```

- `HIMX0002` 是本机**已知走 SPI** 的 Himax 触屏（Linux 侧 `spi0.0` 就是它），它的连接是 `02 02` ⇒ **`02 02` = SPI**。
- `QCOM066B` 是蓝牙 UART 传输驱动，它的连接是 `02 03` ⇒ **`02 03` = UART**。
- `HIMX0001` 同时有 `01 02` 与 `02 02` ⇒ 它有一个**中断 GPIO** 和一个 **SPI**，完全符合一颗触控 IC 的需要。
- PCIe / SD / GPU / ISP 这些不需要 SPB 的设备，清一色只有 `01 02`（GPIO 中断）。

⇒ **`02 02` 与 `01 02` 的语义被本机数据钉死，不存在混淆空间。**

### 4.2 FTE7001 的资源分配（决定性）【已核实】

```
$ python3 tools/win-acpi-hive.py /tmp/SYSTEM --resources FTE7001
FTE7001\1  ->  FocalTech Fingerprint reader
  父设备: ACPI(_SB_)#ACPI(SPBA)
  --- BootConfig（60 字节）---
  01 00 00 00 0f 00 00 00 00 00 00 00 01 00 01 00   ← CM_RESOURCE_LIST 头
  02 00 00 00                                       ← 描述符数 = 2
  02 01 31 00 01 80 00 00 01 80 00 00 ff ff ff ff 00 00 00 00
      Type=0x02(Interrupt) Flags=0x0031
      Level=Vector=32769(0x8001)  ← ≥0x8000 ⇒ GPIO 触发
  84 00 00 00 01 02 00 00 0a 00 00 00 00 00 00 00 00 00 00 00
      Type=0x84(Connection)
      Class=0x01(GPIO) Type=0x02(GPIO_INT) Id1=10 Id2=0
```

**非安全世界拿到的全部资源 = 1 个 GPIO 中断 + 1 个 GPIO 中断连接。**
`BasicConfigVector`（需求列表，104 字节）里的两个描述符与之一致，
**同样没有任何 `02 02`**。

对照：**已知 SPI 的触屏 `HIMX0002` 的 `BootConfig` 里有 `84 00 00 00 02 02 00 00 27 ...`**
—— 如果 FTE7001 的 SPI 是交给操作系统的，这里必然出现同样的 `02 02`。

> 换句话说：**在 ACPI 层面，这颗指纹的 SPI 总线根本没有交给 Windows。**
> 操作系统只被允许"知道有中断来了"。

### 4.3 TEE trustlet 内部的证据【已核实】

对 `Drv/扩展/qctreeextoem8280.inf_arm64_671465aeb0edf1b8/fingerpr.mbn`
（3,669,575 B，ELF64/AArch64）做字符串提取，SPI 相关符号密集且成体系：

```
../src/focal_fp_spi.c
[ta_spi]qsee_spi_close1: retval=%d
[ta_spi]spi open %d success / failed, ret %d
qsee_spi_open Success. id:%d, open flag:%d
error at %s[%s:%d]: qsee_spi_full_duplex(.., r:%d) != %u.
attaching to QSEE_SPI_DEVICE_%u (QUP%u SE %u)...
attaching to SENSOR SPI_%u...
driver.spi_bus_num / driver.spi_c_s_num
device.spi_default_bps / device.spi_mode
error ...: invalid spi speed %d(bps), reset to default 2Mbps.
__open_spi / __close_spi / __ensure_spi / change_spi_mode
E:\work\TZ\trustzone_images\ssg\securemsm\trustzone\qsapps\sampleapp\src\spi.c
```

同一文件内的 I²C 相关字符串：**0 条**。同时可见完整算法侧符号
（`focal_EnrollNonFingerPredict`、`focal_SildeIdentify_V1..V7`、`FtFocalTemplateToData`、
`focal_GetImgQualityByFw`、`FT_CNN` 层等）。

> `attaching to QSEE_SPI_DEVICE_%u (QUP%u SE %u)` 里的 **QUP / SE** 正是
> Qualcomm 串行引擎的命名，说明 **TEE 直接以"设备号 + QUP + SE"打开那条 SPI**，
> 而不是经由操作系统。

### 4.4 综合判断

| 事实 | 等级 |
|------|:----:|
| 指纹是 FocalTech FTE7001，UMDF 非安全侧驱动 | 【已核实】 |
| 非安全侧只被分配 GPIO 中断连接，**没有 SPB 总线资源** | 【已核实】 |
| TEE trustlet `fingerpr.mbn` 用 `qsee_spi_*` 走 QUP/SE 驱动 SPI，且无 I²C 代码 | 【已核实】 |
| ⇒ **传感器 SPI 归安全世界所有**，操作系统只收到中断 | 【推测】（两条一手事实的直接推论；标为推测是因为尚未读到 DSDT 里 `\_SB.SPBA` 的 `_CRS`） |

**若要让这条推论被证伪**，只需证明 DSDT 中 FTE7001 的 `_CRS` 含 `SpiSerialBus(...)`
—— 那将说明 Windows 只是没把该资源写进 `LogConf`。§8.3 给出了取证方法。

> **附**：`DEVPKEY_Device_Parent = ACPI(_SB_)#ACPI(SPBA)`，即设备在 ACPI 命名空间里
> 挂在 `\_SB.SPBA` 之下。`SPB` 是 Microsoft 对"简单外设总线"的统称；
> 结合 §4.2 的"无总线资源"，合理读法是：`\_SB.SPBA` 就是**那条被交给 TEE 的串行总线控制器**，
> 非安全侧只能看到父子关系、拿不到总线本身。【推测】

### 4.5 顺带确认：不是 USB，也不是 I²C

| 途径 | 实测 | 结论 |
|------|------|------|
| USB multiport（X13s / X Elite 的做法） | `usb_2` 已使能，4 个 HS 端口在线；`lsusb` 只有 root hub 与 `12d1:10b8`（华为键盘） | **USB 路线排除** |
| I²C | Linux 只有 `i2c-4`（空）与 `i2c-15`（`15-0038 = gaokun3-ec`）；Windows 侧 FTE7001 也无 I²C 连接 | **I²C 排除** |
| SPI（非安全侧） | 设备树 24 个 GENI SPI 只有 `spi@998000`（触屏）是 `okay`；`/sys/bus/spi/devices` 只有 `spi0.0` | 非安全侧**没有**它的 SPI 控制器 |
| 设备树节点 | `/proc/device-tree` 中 grep `finger/focal/fte/goodix` 零命中 | 内核**根本不知道**这颗设备 |

---

## 5. Linux 侧现状（实机实测，只读）

```
$ lsusb                       → 只有 12d1:10b8 + root hub
$ ls /sys/bus/spi/devices/    → spi0.0（himax-spi 触屏）
$ ls /sys/bus/i2c/devices/    → 15-0038（gaokun3-ec）、i2c-4/16/17
$ ls /sys/class/gpio 等       → gpio185 在 pinmux-pins 中为 UNCLAIMED
$ grep -iE 'FINGER|GOODIX|FOCAL|FPC' /boot/config-$(uname -r)
   # CONFIG_TOUCHSCREEN_GOODIX is not set
   # CONFIG_TOUCHSCREEN_GOODIX_BERLIN_SPI is not set
   # CONFIG_HID_GOODIX_SPI is not set
   # CONFIG_I2C_HID_OF_GOODIX is not set
   （没有任何 FocalTech 指纹相关项 —— 主线也没有该驱动）
$ ls /dev/qseecom /dev/tee0 /dev/teepriv0   → 都不存在
$ ls /sys/bus/platform/drivers/ | grep -i qsee → qcom_qseecom（驱动在，设备不在）
```

**关于 `gpio185`**：社区记的 `gpio185` 在本机 `pinmux-pins` 中确实是 `UNCLAIMED`，
但 144–199 号里绝大多数引脚都是 `UNCLAIMED`（包括与指纹无关的），
**所以"`gpio185` 未被占用"不能证明它属于指纹**。它更可能是中断线或电源使能；
由于 §4.2 已经给出中断号是 GPIO 触发（GSI 0x8001），这颗引脚的用途需要在
DSDT 侧确认。【推测】

**关于 TEE 通路**：内核**启用了** `CONFIG_QCOM_QSEECOM=y` 与
`CONFIG_QCOM_QSEECOM_UEFISECAPP=y`，但 **`/dev/qseecom` 不存在** ——
因为 gaokun3 走 DTB 启动，设备树里没有 QSEECOM 节点，驱动不会被实例化；
内核也未启用通用 `CONFIG_TEE`。

---

## 6. 为什么短期不可行（三条独立障碍）

1. **总线不可达**：SPI 由 TEE 持有，非安全世界没有该 QUP/SE 的资源。
   要改这一点，需要固件/ACPI 层面的配合，而不是写一个 Linux 驱动。【已核实（资源分配）】
2. **算法与模板在 TEE 内**：`fingerpr.mbn` 内含完整的取图、质量评估、特征提取、
   模板生成与匹配（含 CNN）。即便拿到裸 SPI，Linux 侧也只能做**图像采集**，
   无法完成注册/比对。【已核实（符号表）】
3. **TEE 通路在 Linux 上不存在**：`/dev/qseecom` 未实例化，通用 TEE 子系统未启用；
   要让 trustlet 跑起来，需要"能加载 Qualcomm 签名 TA 的 TEE 客户端"，
   这在 SC8280XP + DTB 启动的平台上目前**没有上游支持**。【已核实】

> **因此本项目的立场是：如实记录结论与取证方法，不产出"看起来能跑"的半成品驱动。**
> 上游把指纹标为 `x`（不支持）与本次取证结论一致。

---

## 7. 若要推进，需要满足什么

按投入产出排序：

| 阶段 | 目标 | 前置条件 | 现实性 |
|:----:|------|----------|:------:|
| **P0** | **把结论钉死**：读 DSDT 中 `FTE7001` 的 `_CRS` 与 `\_SB.SPBA` 的 `_HID`/`_CRS` | 临时在 systemd-boot 条目加 `iomem=relaxed` 内核参数并重启一次，即可用 `/dev/mem` 按 RSDP 解析 ACPI 表；或用 UEFI Shell 跑 `acpidump`；或启动一次 Windows 取 `acpidump -b` 输出 | **高**（一次性重启） |
| **P1** | 确认 SPI 是否可被非安全世界接管 | P0 的 `_CRS`；以及固件是否把该 QUP 划给 TEE（需 Qualcomm 文档或实测） | 低 |
| **P2** | 实现 TEE 客户端，加载并调用 `fingerpr.mbn` | P1；SC8280XP 的 TEE 客户端上游支持；签名 TA 的加载通路 | 很低 |
| **P3** | 用户态接入 libfprint | P2 完成取图通路 | 依赖 P2 |

**明确不做的事**：
- 不写"裸 SPI 读图"的驱动去赌总线可达（会浪费大量时间，且即使成功也不能注册/比对）。
- 不把 Goodix GXFP5130（eSPI-over-EC，ACPI ID `GXFP5130:00`，目标机型是 MateBook D16 2024 / MCLF-XX）
  的现成成果套到本机 —— 本机没有这颗芯片。【已核实】

---

## 8. 复现步骤

### 8.1 Linux 侧只读探针

```bash
sudo ./scripts/40-fingerprint.sh            # 一键跑完下面全部检查
```

### 8.2 从 Windows 注册表取证（不需要进 Windows）

```bash
# 1) 找 Windows 分区并只读挂载
lsblk -o NAME,SIZE,FSTYPE,LABEL
sudo mkdir -p /mnt/win
sudo mount -t ntfs-3g -o ro /dev/nvme0n1p3 /mnt/win      # 分区号按实际调整

# 2) 取 hive
sudo cp /mnt/win/Windows/System32/config/SYSTEM /tmp/SYSTEM
sudo chown "$(id -u):$(id -g)" /tmp/SYSTEM
sudo apt-get install -y python3-hivex

# 3) 三条查询
python3 tools/win-acpi-hive.py /tmp/SYSTEM --find FTE7001 GDIX5125 ELAN7001 GXFP5130
python3 tools/win-acpi-hive.py /tmp/SYSTEM --resources FTE7001
python3 tools/win-acpi-hive.py /tmp/SYSTEM --connections        # Class/Type 标尺

# 4) 收尾
sudo umount /mnt/win
```

预期结果：`--find FTE7001` 为 1，其余为 0；`--resources FTE7001` 中出现
`Class=0x01(GPIO) Type=0x02(GPIO_INT)` 且**没有** `0x02/0x02`。

### 8.3 读 ACPI 表（P0，需要一次重启）——**尚未在本机执行**

```bash
# 临时在启动项里加 iomem=relaxed（systemd-boot，可随时删掉）
sudo cp /boot/efi/loader/entries/<entry>.conf /root/entry.conf.bak      # 先备份
sudo sed -i 's/^options /options iomem=relaxed /' /boot/efi/loader/entries/<entry>.conf
sudo reboot
# 重启后：
sudo python3 <按 RSDP=0xffffd000 解析 /dev/mem 的脚本>     # 见 tools/ 的用法说明
# 关注 DSDT 中 Device(FTE7)/_CRS 是否含 SpiSerialBus(...)，以及 Device(SPBA) 的 _HID/_CRS
# 验证完删除 iomem=relaxed 并再次重启
```

> 本步骤**尚未执行**。它是把 §4.4 的【推测】升级为【已核实】的唯一途径。

### 8.4 驱动包侧核对（`Drv/` 只读，注意编码）

```powershell
# INF 是 UTF-16LE，用 -Encoding Unicode 读；hidinjectorthp.inf 是 UTF-8，用 -Encoding UTF8
Get-Content -Encoding Unicode 'Drv\生物识别设备\ftwbiodriverumdf.inf_arm64_*\ftwbiodriverumdf.inf' |
  Select-String 'ACPI\\|Umdf|QcTrEE|fingerpr'
```

---

## 9. 置信度与未解问题

| # | 问题 | 现状 | 如何解决 |
|:-:|------|------|----------|
| Q1 | `\_SB.SPBA` 的 `_HID` 是什么？`_CRS` 里是 `SpiSerialBus` 还是纯 GPIO？ | 未读到 DSDT | §8.3 |
| Q2 | `gpio185` 到底是中断、复位还是电源使能？ | 社区单点说法，未证实 | §8.3 |
| Q3 | `_CRS` 中若存在 `SpiSerialBus`，其 QUP/SE 号是否与 trustlet 的 `QUP%u SE %u` 对应？ | 未证实 | §8.3 |
| Q4 | 固件是否把该 QUP 划归 TEE？（可由 TEE 侧能否 `qsee_spi_open` 成功反推，但需要能跑 TA） | 未证实 | 需 TEE 通路 |
| Q5 | `fingerpr.mbn` 的签名链与加载条件 | 未分析 | 需 Qualcomm 侧资料 |

**本报告明确的能力边界**：本文给出的是**"当前不可行"的、可复现的证据链**，
不是"指纹不可用"的绝对断言 —— 若将来 SC8280XP 上出现可用的 TEE 客户端通路，
P2/P3 仍有可能。本项目选择如实记录这一边界。

---

## 附录 A：参考与文件索引

| 主题 | 位置 / 链接 |
|------|-------------|
| 本机离线 hive 取证工具 | `tools/win-acpi-hive.py` |
| Linux 侧只读探针 | `scripts/40-fingerprint.sh` |
| FocalTech UMDF 驱动 INF | `Drv/生物识别设备/ftwbiodriverumdf.inf_arm64_*/ftwbiodriverumdf.inf`（本地，不入库） |
| Goodix eSPI 驱动 INF | `Drv/生物识别设备/gfspi.../gfspi.inf`（本地，不入库） |
| TEE 可信应用 | `Drv/扩展/qctreeextoem8280.inf_arm64_671465aeb0edf1b8/fingerpr.mbn`（本地，不入库） |
| 家族镜像驱动注入脚本 | `Recovery/OEM/Customization/Product/Dirvers2PE/PAR_install.cmd`（本地，不入库） |
| 社区特性表 | [right-0903/linux-gaokun README.MD](https://github.com/right-0903/linux-gaokun/blob/main/README.MD) |
| gaokun3 上游设备树 | [sc8280xp-huawei-gaokun3.dts](https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts) |
| `CM_RESOURCE_CONNECTION` 常量 | [windows-docs-rs: CM_RESOURCE_CONNECTION_TYPE_SERIAL_SPI](https://microsoft.github.io/windows-docs-rs/doc/windows/Wdk/System/SystemServices/constant.CM_RESOURCE_CONNECTION_TYPE_SERIAL_SPI.html) |
| `DEVPKEY_*` 定义 | [MicrosoftDocs: devpropkey.md](https://raw.githubusercontent.com/MicrosoftDocs/windows-driver-docs/staging/windows-driver-docs-pr/install/devpropkey.md) |
