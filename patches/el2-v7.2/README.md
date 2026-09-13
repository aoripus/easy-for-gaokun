# patches/el2-v7.2 —— EL2 补丁集在 v7.2-rc2 上的适配

> **元数据**（字段定义见 [`patches/README.md`](../README.md)）
>
> - **用途**：社区 EL2 补丁集在 v7.2-rc2 上的适配（补丁发布于 2025-07，其目标基线是
>   `struct rproc.auto_boot` 仍为 `bool` 的内核树）
> - **基线 / Base**：`v7.2-rc2`（原补丁集的目标基线更旧；本目录的 3 个文件是为该基线重写的版本）
> - **序列 / Order**：见同目录 [`series`](series)（`0006` 必须先落地，`0006z`、`0011` 随后）
> - **上游状态**：社区补丁集（`KawaiiHachimi/linux-gaokun-buildbot`）的**适配版**，未投稿上游
> - **是否用于当前发布内核**：❌ **否**。当前发布内核走 **EL1 + venus**，不套用 EL2 补丁集；
>   本目录只参与历史 EL2/IRIS 构建，保留以可追溯
> - **验证**：由 `tools/build-iris-x86.sh` 第 3b/4 步以 buildbot 原集为底、用本目录覆盖同名文件，
>   组装后**逐个** `git apply`（构建脚本会统计失败数，失败过多即中止）
> - **回滚**：本序列不进入发布内核；删除构建目录即可，目标机不受影响

上游补丁集 `patches/el2/*` 来自 `KawaiiHachimi/linux-gaokun-buildbot`，发布于 2025-07。
在 v7.2-rc2 上直接应用时有 4 个补丁失败，其中 3 个是同一个根因的级联：

| 补丁 | 失败原因 | 处理 |
|---|---|---|
| `0006` | 该补丁把 `struct rproc.auto_boot` 由 bool 改成 `enum rproc_auto_boot`；其中 `xlnx_r5_remoteproc.c` 的 hunk 撞上上游后加的 `if (fw_name) r5_rproc->auto_boot = true;` 代码块 | 本目录的 `0006-*.patch` 为重写版，xlnx 处改为 `RPROC_AUTO_BOOT_DISABLED` |
| `0010`、`0016` | 两者使用 `RPROC_AUTO_BOOT_*`，而该枚举由 `0006` 引入；`0006` 不成功则必然级联失败 | 无需改动，`0006` 打上后即可干净应用 |
| `0011` | `include/dt-bindings/firmware/qcom,scm.h` 的 hunk 撞上上游后加的 `QCOM_SCM_VMID_CP_ADSP_SHARED` | 本目录的 `0011-*.patch` 为重写版，两部分改动（binding 与头文件）完整保留 |
| 新增 | 上游在 2025-07 之后又新增了两处 `auto_boot = true` 赋值，原系列未覆盖 | `0006z-xlnx-auto-boot-completion.patch` 把这两处一并枚举化 |

使用方式见 `tools/build-iris-x86.sh` 的第 3b 与第 4 步：以 buildbot 原集为底，用本目录
覆盖同名文件，组装出 23 个可逐个干净应用的补丁目录（`$BASE/el2-patches`）。

## 两点值得记住的结论

1. **补丁的日期不代表它适用的基线。** 这一组补丁的目标基线是 `struct rproc.auto_boot`
   仍为 bool 的内核；把它改成枚举的正是 `0006` 本身，所以 v7.2-rc2 并不是"比系列更新"，
   而是系列尚未适配的树。
2. **`git apply` 一次传多个补丁是原子操作。** 只要有一个失败，整组都不会被应用。
   构建脚本因此改为逐个应用并统计失败数，且失败过多时直接中止——否则会静默产出一个
   PAS 不可用的内核（表现为 adsp/cdsp/slpi/venus 固件加载全部报 `-22`，音频与视频一起失效）。
