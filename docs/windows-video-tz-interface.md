# Windows 侧视频核 TrustZone 接口的逆向社会（qcdxkm8280.sys）

> 本文记录从 Windows 驱动 `qcdxkm8280.sys`（Windows ARM64 PE，3,329,656 字节，
> ImageBase `0x140000000`）反汇编得到的**视频核 TrustZone 交互事实**，
> 以及用本项目探针模块 `tools/pas-probe/` 在本机（GK-W7X / SC8280XP）上做的对照验证。
>
> 置信度：【已核实】= 亲自从反汇编/实测读出；【推测】；【无法确定】。

## 1. 为什么值得记录

本机的视频硬解 **尚未打通**：Linux 侧 `qcom_scm_pas_auth_and_reset(9)` 返回 0，
但视频核从不执行（`CTRL_STATUS` 恒 0），而 Lenovo X13s（**同为 SC8280XP**）已在 EL2 下
被社区实测跑通。因此差异必然落在**设备专有的安全世界固件**上。

Linux 的 iris 驱动只走 **SIP SMC** 通路（`QCOM_SCM_SVC_MP` / `QCOM_SCM_MP_VIDEO_VAR`）。
本文的发现是：**Windows 走的是另一条通路 —— QTEE（TrEE）IOCTL**，并且它在视频核初始化时
调用了 **Linux 侧完全不存在**的 TZ 子系统状态函数。

## 2. TZ 传输层 ABI（8 个调用点共用）【已核实】

调用点形如 `ldr x19, [xCTX, #31448]`（+0x7AD8，TZ 接口发送函数指针），随后：

| 寄存器/槽位 | 含义 |
|---|---|
| `x0 = [ctx+31216]` | 句柄 |
| `x1 = [ctx+22888]` | 会话句柄 |
| `w2` | **TZ 函数 ID** |
| `w3` / `w4` | u32 标志 |
| `x5` / `w6` | 请求缓冲指针 / 字节数 |
| `x7` / `[sp]` | 应答缓冲指针 / 字节数 |

底层是 `IOCTL_TR_EXECUTE_FUNCTION`（日志串 `FATAL:IOCTL_TR_EXECUTE_FUNCTION failed…`）。

## 3. `TZ_MEM_PROTECT_VIDEO_VAR` —— 两个调用点【已核实】

| | 调用点 A | 调用点 B |
|---|---|---|
| TZ 调用指令 | `0x14039e7ac` | `0x1403a0690` |
| 所在函数 | `0x14039e640`–`0x14039e9a0` | `0x1403a0560`–`0x1403a0778` |
| `w2`（TZ 函数 ID） | **`0x00568004`** | **`0xC35140DC`** |
| `w3` / `w4` | 0 / 1 | 1 / 1 |
| 请求 / 应答字节数 | 48 / 16 | 88 / 32 |

请求负载（两处内容相同，仅存放位置不同）：

| 偏移 | 值 |
|---|---|
| `+0x00` | **`0x02000C08`**（操作码） |
| `+0x04` | `4`（仅 A 显式写入） |
| `+0x08` (u64) | CP 参数 1 |
| `+0x10` (u64) | CP 参数 2 |
| `+0x18` (u64) | CP 参数 3 |
| `+0x20` (u64) | CP 参数 4 |

应答：`[sp+0x50]` 必须 `== 1`（记为 `PRStatus`），`[sp+0x48]` 为 `BytesWritten`。

### 3.1 ★ 四个 CP 参数的真实常量（静态 `.data` 表，不是运行时未知量）【已核实】

分支条件 `[ctx+0x6160] == 0x20A`（代码 `0x14037c124`）。两组源表数值在同一分支内完全一致：

| 分支 | `cp_start` | `cp_size` | `cp_nonpixel_start` | `cp_nonpixel_size` | 自检 |
|---|---|---|---|---|---|
| `== 0x20A` | `0x00000000` | `0x25800000`（**600 MiB**） | `0x01000000`（**16 MiB**） | `0x24800000`（**584 MiB**） | `0x01000000+0x24800000 == 0x25800000` ✔ |
| 其它芯片 | `0x00000000` | `0x60000000`（**1.5 GiB**） | `0x01000000`（**16 MiB**） | `0x02800000`（**40 MiB**） | — |

`0x20A` 是否即 SC8280XP：`.sys` 内无映射依据 →【无法确定】。
四个值与 Linux `cp_start / cp_size / cp_nonpixel_start / cp_nonpixel_size` 的顺序对应：【推测】。

### 3.2 本机对照验证结果【已核实，实测】

用 `tools/pas-probe/` 在本机把两套表连同若干变体逐一打过：

```
mpvv(其它芯片表,  1.5 GiB, 16 MiB, 40 MiB)  = -5
mpvv(1.5 GiB + 尾部对齐)                    = -5
mpvv(0x60000000, 0, 0x60000000)             = -5
mpvv(0x40000000, 0x01000000, 0x3f000000)    = -5
mpvv(0x20A 表 = 上游 sm8250 表)              = -5
mpvv(0x25800000, 0, 0x25800000)             = -5
iommu_set_cp_pool_size(0, 0x60000000)       = -22
```

**结论：CP 参数取值不是原因。** 正反两个方向（Linux 侧枚举 + Windows 侧逆向取值）
得出同一结论；该命令在本机 TZ 上**根本不被接受**。

## 4. `VedTrEETzVenusRstrThrsh` = `TZ_SUBSYS_STATE_VENUS_RESTORE_THRESHOLD`【已核实】

发送函数 `0x14039eb30`–`0x14039ee44`，TZ 调用指令 `0x14039ec78`。

| 项 | 值 |
|---|---|
| `w2` | `0x00568004` |
| `w3` / `w4` | 0 / 1 |
| 负载 `+0x00` | **`0x0200010A`**（操作码） |
| `+0x04` | `2` |
| `+0x08` (u64) | `2`（状态：restore threshold） |
| `+0x10` (u64) | **`9`** ← 视频核的 **PAS ID** |

## 5. `TZ_VIDEO_STATE_RESUME`【已核实】

函数 `0x1403a0340`–`0x1403a0534`，TZ 调用指令 `0x1403a044c`。

| 项 | 值 |
|---|---|
| `w2` | `0xC35140DC` |
| `w3` / `w4` | 1 / 1 |
| 负载 `+0x00` | **`0x0200010A`** |
| `+0x08` (u64) | `1`（状态：resume） |
| 其余 88 字节 | 0 |
| 应答 | 32 字节，`+0` = `PRStatus` 必须 `== 1` |

**同族还有** `TZ_SUBSYS_STATE_RESUME`（函数 `0x14039e300`，负载 `+0x08=1`、`+0x10=9`）。
即：**`0x0200010A` 是一个"子系统状态"操作码，`+0x08` 是状态枚举，`+0x10` 是子系统号（9 = 视频核）。**

## 6. `VedInitVideoCore` 内的 TZ 接口调用序列【已核实】

`VedInitVideoCore = 0x140388a08`–`0x14038a7e0`。它不直接用 `[ctx+31448]`，
而是经上下文里的接口表 `[ctx+30096]` 间接调用，顺序为：

| # | 指令地址 | 表项偏移 | 对应函数 |
|---|---|---|---|
| 1 | `0x140389ec0` | `+0x18` | `TZ_SUBSYS_STATE_RESUME`（状态恢复） |
| 2 | `0x14038a0ac` | `+0x10` | **`TZ_MEM_PROTECT_VIDEO_VAR`** |
| 3 | `0x14038a254` | `+0x20` | **`TZ_SUBSYS_STATE_VENUS_RESTORE_THRESHOLD`**（仅当 `[ctx+0x7598]` bit11 置位且指针非空） |

两套接口表：表 A 基址 `0x140213e98`（`+0x10/+0x18/+0x20` 均有值）、
表 B 基址 `0x140214c08`（`+0x20 = NULL`）。运行期最终生效哪一套，线性数据流
无法定论（`0x14037b974` 的 `b.eq 0x14037bd60` 造成路径敏感）→【无法确定】。

## 7. 对本机的意义（为什么这条线索重要）

把第 6 节的序列与 Linux 对照即可看出差距：

| Windows 在视频核初始化时调用 | Linux iris 是否有对应 |
|---|---|
| `TZ_SUBSYS_STATE_RESUME`（恢复视频子系统状态，subsys=9） | **没有** |
| `TZ_MEM_PROTECT_VIDEO_VAR` | 有（`qcom_scm_mem_protect_video_var`，但本机 `-EIO`） |
| `TZ_SUBSYS_STATE_VENUS_RESTORE_THRESHOLD`（subsys=9） | **没有** |

**并且两边的通路不同**：Windows 走 QTEE（TrEE）IOCTL，Linux 走 SIP SMC。
本机实测 `qcomtee` 平台设备**存在**（见 `tools/pas-probe/README.md`），
说明本机 TrustZone 的 QTEE 通路是通的；而 SIP 通路的 `MP_VIDEO_VAR` 被拒。

**推断【推测】**：本机的 TZ 固件可能把视频子系统的状态机与内存保护功能实现在
**QTEE 侧**，而 Linux iris 依赖的 SIP SMC 路径并未实现 —— 这既能解释 `-EIO`，
也能解释"PAS 报告成功但核心不动"。要验证需通过 `qcomtee` 接口复刻第 3、4、5 节的调用。

## 8. 复现方式

反汇编与定位用的脚本位于虚拟机 `/root/wdrv/scratch/`（只读分析，未入库）。
关键手法：

1. 注意任务里给的 RVA 是**日志串内部子串**的位置，不是串首 —— 必须先在 PE 节表里
   做 file offset → RVA 映射并逐字节校验，再按**串首 VA** 检索 `adrp` + `add`。
2. 用 `.pdata`（ARM64 异常处理函数表，每项 8 字节）切分函数边界。
3. 该 `.sys` 内 **`smc`/`hvc` 指令数为 0**：所有 TZ 调用都经 IOCTL 转给闭源签名驱动，
   故 **SMC 功能号不在本文件内**，只能拿到上层 ABI（函数 ID、操作码、负载布局）。

本机对照验证见 [`../tools/pas-probe/README.md`](../tools/pas-probe/README.md)。
