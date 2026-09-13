# tools/pas-probe —— 向 TrustZone 直接问询 IRIS 视频核的 PAS 支持

## 这个工具解决什么问题

目标机（HUAWEI MateBook E Go 2022 性能版 / GK-W7X / SC8280XP）的**视频硬解不可用**。
Linux 侧的观察是：`qcom_scm_pas_auth_and_reset(9)` 返回 **0**（成功），但视频核从不上电执行
（`CTRL_STATUS` 恒为 `0`）。

单看 Linux 侧，无法区分两种可能：

| 可能 | 含义 |
|---|---|
| A | 是我们这一侧（驱动/设备树/参数）有问题 |
| B | TrustZone 声称做了、实际没做 |

本工具用**独立的探针模块**把问题直接问到 TrustZone 面前，并通过逐项对比调用前后的寄存器，
证明这些调用在硬件上到底有没有留下痕迹。**结论是 B。**

## 构建

需要一台已构建过**同版本内核**的机器（`Module.symvers` 必须与该内核匹配，否则 vermagic 不符）。
本项目的作法是 x86_64 交叉编译：

```bash
make -C <内核源码目录> O=<构建输出目录> M=tools/pas-probe \
     ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules
```

## 运行

```bash
sudo cp gkpas.ko /var/tmp/
sudo dmesg -C
sudo insmod /var/tmp/gkpas.ko     # init 故意返回 -EIO，模块不驻留，这是预期行为
sudo dmesg | grep gkpas
```

模块只做查询类/幂等类 SCM 调用，并且 `pas_shutdown` **只对视频核(9)与必定不存在的 ID 调用**，
不碰 adsp/cdsp/slpi，因此在用的音频与传感子系统不受影响。

## 实测结果（2026-09-13，`7.2.0-rc2-aoripus-ml-gaokun-eog-iris-el2+`）

```text
gkpas pas_supported(1)  = yes        # adsp
gkpas pas_supported(9)  = yes        # ★ 视频核：TZ 明确声称【支持】
gkpas pas_supported(17) = NO         # slpi 报"不支持"，但 Linux 侧 attach 运行正常
gkpas pas_supported(18) = yes        # cdsp
gkpas pas_supported(63) = NO         # 不存在的 ID

gkpas pas_shutdown(9)                                   = 0
gkpas pas_auth_and_reset(9) [no image loaded]           = -22
gkpas pas_shutdown(0 / 63 / 100 / 200 / 0xffffffff)     = -22

gkpas mpvv(0x0, 0x25800000, 0x01000000, 0x24800000)     = -5
gkpas mpvv(0x0, 0x00000000, 0x00000000, 0x00000000)     = -5
gkpas mpvv(0x0, 0x25800000, 0x00000000, 0x00000000)     = -5
gkpas mpvv(0x0, 0x4b000000, 0x01000000, 0x4a000000)     = -5
gkpas mpvv(0x0, 0x10000000, 0x00000000, 0x10000000)     = -5
gkpas mpvv(0x0, 0x20000000, 0x00000000, 0x20000000)     = -5
gkpas iommu_set_cp_pool_size(0, 0x25800000)             = -22
gkpas mpvv(设池之后)                                     = -5
gkpas iommu_secure_ptbl_size(1)                         = 0
```

**调用前后 23 个视频核寄存器逐项完全一致**（`BASE` 与 `FINAL` 无差异）。

## 结论

1. **TrustZone 是活的，而且在认真校验。** 不存在的 PAS ID 一律 `-22`；未加载镜像就调
   `auth_and_reset` 也 `-22`。PAS 通路**不是盲桩**。
2. **TZ 对视频 PAS 回答"支持"**，`pas_auth_and_reset(9)` 在镜像已加载时返回 **0** ——
   **TZ 认为自己已经认证并复位了视频核。硬件却毫无反应。**
3. **矛盾点即答案**：`pas_supported(17)=NO`（slpi）而 slpi 工作正常；`pas_supported(9)=yes`
   而视频核完全不工作。在这台设备上，**"TZ 说支持"与"硬件真能跑"是两件互不相干的事** ——
   视频核的"支持"只存在于 TZ 的账面上。
4. **视频内容保护命令被逐条拒绝**：同一个 `QCOM_SCM_SVC_MP` 服务里
   `IOMMU_SECURE_PTBL_SIZE`(0x03) 返回 0，而 `IOMMU_SET_CP_POOL_SIZE`(0x05) 返回 `-22`、
   `MP_VIDEO_VAR`(0x08) 对所有参数组合都返回 `-5`。`-5` 是 TZ 自己的返回状态字
   （见 `qcom_scm_mem_protect_video_var()` 的 `return ret ?: res.result[0];`），
   说明该设备的 TZ 固件**没有实现视频 CP 相关命令**。
5. **一个容易误判的点**：`pas_shutdown(9)` 返回 0 且寄存器无变化是**预期的**，因为发布版
   iris 驱动在 `mem_protect_video_var` 失败时已经调用过一次 `pas_shutdown(9)`。
   不要据此得出"PAS 不碰硬件"的结论。
6. **`mpvv` 的失败与调用顺序/状态无关【已核实】**：把"冷状态"作为唯一变量复测 ——
   让 `mpvv` 成为模块发起的**第一个** SCM 调用（TZ 尚未见过任何视频请求），结果仍是 `-5`；
   之后再在查询后、`auth_and_reset` 后、`shutdown` 后各调一次，**全部 `-5`**。
   所以这不是状态被污染的假象，而是**该命令在本机 TZ 上不被接受**。

   反过来说：既然 `pas_supported(9)=yes` 且 `pas_auth_and_reset(9)` 能返回 0，而
   `MP_VIDEO_VAR` 无论如何都不通 —— 本机的视频安全世界通路是**"认账不干活"**的。
   这正是与已知可用设备（X13s）最明确的差异。

7. **CP 参数取值不是原因【已核实】**：连同从 Windows 驱动 `qcdxkm8280.sys` 逆向出的两套
   静态参数表一起测，共 6 组（`0x20A` 分支的 `0x25800000 / 0x01000000 / 0x24800000`、
   其它芯片的 `0x60000000 / 0x01000000 / 0x02800000`，以及若干变体）**全部返回 `-5`**。
   正反两个方向得出同一结论。参数表与 Windows 侧 ABI 详见
   [`../../docs/windows-video-tz-interface.md`](../../docs/windows-video-tz-interface.md)。

8. **本机存在 `qcomtee` 平台设备【已核实】—— 目前最有价值的待查方向。**
   `/sys/bus/platform/devices/qcomtee` **存在**（但没有 `/dev/qcomtee` 字符设备节点）。
   关键在于 `qcom_scm.c` 的 `qcom_scm_qtee_init()` 只在 `qcom_scm_qtee_invoke_smc()`
   **不返回 `-EIO`** 时才注册该设备 —— 所以**本机 TrustZone 的 QTEE 通路是通的**，
   而 Windows 恰恰是经 **QTEE（TrEE）IOCTL** 而不是 SIP SMC 去驱动视频核的，
   并且它在视频核初始化时调用了 **Linux 侧完全没有**的 TZ 子系统状态函数
   （`TZ_SUBSYS_STATE_RESUME`、`TZ_SUBSYS_STATE_VENUS_RESTORE_THRESHOLD`，subsys = 9）。
   下一步应尝试经 `qcomtee` 复刻这些调用。

完整背景、逐寄存器证据与排除性实验见
[`patches/iris-el2/README.md`](../../patches/iris-el2/README.md)。
