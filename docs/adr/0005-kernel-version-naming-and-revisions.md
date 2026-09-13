# ADR-0005：内核版本串、Release tag 与修订号 `r<n>` 规范

- **状态**：已接受
- **日期**：2026-09-13
- **相关**：[`README.md`](../../README.md) §7「构建产物与发布」、[`docs/kernel-7.2.5-el1-build.md`](../kernel-7.2.5-el1-build.md)

## 背景（Context）

本项目会反复发布"同一上游 + 不同补丁/配置/设备树"的内核。`uname -r` 决定的不是显示名，
而是机器侧**全部落点**：`/lib/modules/<串>/`、`/boot/*-<串>`、systemd-boot 的 BLS 条目名、
ESP 目录名。若版本串不携带足够信息，多个内核会互相覆盖，回滚也无从下手。

同时实测发现一个会让版本串"看起来对、其实错"的陷阱：**只关掉 `CONFIG_LOCALVERSION_AUTO`
并不能去掉串尾的 `+`** —— `scripts/setlocalversion` 在源码树带 `.git` 且 HEAD 不在
`v$(KERNELVERSION)` 附注 tag 上时，照样打印 `+`。同一份逻辑源码因此会派生出两个不同的串。

## 决策（Decision）

```
uname -r = <上游>-aoripus-ml-gaokun3-eog-<级别>-<VPU驱动>-r<n>
tag      = kernel-<完整内核串>-<YYYYMMDD>
标题     = Kernel <上游> (<级别>) <驱动大写>[ r<n> ]
```

- `<级别>` ∈ `el1`/`el2`；`<VPU驱动>` ∈ `venus`/`iris`（VPU 是视频编解码单元，**不是 GPU**）。
- `ml` 明确指 kernel.org 的 **stable** 树（不是 mainline master，也不是发行版内核）。
- `r<n>` 作用域 = 同一上游 + 同级别 + 同 VPU 驱动；**上游升级则 `r` 归零**。
- **日期绝不进入内核串**（只出现在 Release tag 里），否则每天都会产生一个新的模块目录。
- **必须同时**满足：`# CONFIG_LOCALVERSION_AUTO is not set` **且** 构建时源码树不带 `.git`；
  构建脚本在配置阶段与编译后各有一道断言（后者查 `include/config/kernel.release`）。
- `r` 只在**产物语义变化**（补丁 / DTB / `.config`）时 +1；内核字节不变、只改说明时，
  **串与 `r` 都不动**，直接就地更新同一 Release 的说明。

## 后果（Consequences）

- **正面**：从 `uname -r` 就能判断"哪个上游、哪个启动级别、哪条 VPU 线、第几修订"；
  EL1/EL2 两个内核可共存而不会互相覆盖。
- **负面 / 代价**：改 `r` 必须重编（`r` 在 `LOCALVERSION` 里，不是标题里的装饰）；
  构建必须走"解包后不带 `.git`"的流程，本地开发树的临时构建会得到带 `+` 的串。
- **风险**：`utsname` 上限 64 字节（当前串 41 字符），继续加字段会超限。

## 替代方案与放弃原因（Alternatives）

| 方案 | 为什么没采用 |
|---|---|
| 版本号放标题，不进 `uname -r` | 机器侧落点（模块目录、BLS 条目）必须唯一；只改标题会导致互相覆盖 |
| 用日期标识修订 | 日期进串会让每天产生新模块目录；且无法表达"同一上游的第几次修订" |
| 沿用旧串 `…-gaokun-eog-el1-venus+` | `gaokun` 与 `gaokun2`（8cx Gen 2 / SC8180X）极易混淆；`+` 表示"源码树不干净"，会污染落点 |

## 证据与出处（Evidence）

- 字段定义、机器侧派生表与 `r` 裁决规则：[`README.md`](../../README.md) §7
- `+` 的根因与两道断言的实测记录：[`docs/kernel-7.2.5-el1-build.md`](../kernel-7.2.5-el1-build.md) §0
- 已发布产物的命名实例：[`docs/releases/`](../releases/)（r1、r3 为规范命名）

## 回滚（Rollback）

命名规范本身不需要回滚；若某个内核串写错，唯一正确的补救是**重编并发布新的 `r<n>`**，
而不是在 Release 上改标题（历史记录不可改写）。
