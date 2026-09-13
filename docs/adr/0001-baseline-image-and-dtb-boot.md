# ADR-0001：以社区构建镜像为唯一基线，走 DTB 启动

- **状态**：已接受
- **日期**：2026-09-13
- **相关**：[`README.md`](../../README.md) §3、[`docs/install-dualboot.md`](../install-dualboot.md)

## 背景（Context）

目标设备是 HUAWEI MateBook E Go 2022 性能版（GK-W76 / SC8280XP / 设备树 `gaokun3`）。
这台机器**无法用官方 Ubuntu 26.04 ISO 启动**：安装介质在引导阶段就失败，无法进入安装器。
同时，该机的引导链依赖社区的两个 EFI driver（slbounce、qebspil）以及手工放行的设备树，
而不是 ACPI。也就是说，"用发行版安装器装一遍"这条路在本机不成立。

## 决策（Decision）

- 唯一受支持的基线是社区构建镜像：`KawaiiHachimi/linux-gaokun-buildbot` 的
  release `ubuntu26.04-7.1.0-rc3-gaokun3+el2-20260514004329`（Ubuntu 26.04 LTS / GNOME 50 / Wayland）。
- 一律**以设备树（DTB）启动**：`/etc/kernel/devicetree` 显式指定 DTB，开机由 systemd-boot 的 BLS 条目带 `devicetree` 行。
- 本项目的所有交付（脚本、补丁、文档、内核产物）都是**在该基线之上增量**，不重新发明安装器。

## 后果（Consequences）

- **正面**：装机路径可复现（分区级 `dd`，见 [`docs/install-dualboot.md`](../install-dualboot.md)）；
  与社区其他 gaokun3 用户的观察可互相对照；自研内核可以直接替换基线内核而不动根文件系统。
- **负面 / 代价**：基线一旦停止维护，本项目需要自行接管根文件系统层面的更新；
  基于官方 ISO 的用户反馈无法处理（[`SUPPORT.md`](../../SUPPORT.md) 已明确写出）。
- **风险**：换基线等于换根文件系统，装机脚本与设备鉴别判据都要重新验证；
  因此**基线变更是 ADR 级别的事件**，不是随手升级。

## 替代方案与放弃原因（Alternatives）

| 方案 | 为什么没采用 |
|---|---|
| 官方 Ubuntu 26.04 ISO + 手工引导修复 | 安装介质在本机根本无法启动，没有可修复的入口 |
| 用 ACPI 启动（不开设备树） | 本机固件提供的 ACPI 表不覆盖内屏/触屏/音频等关键路径，社区路线是 DTB |
| 自行打包一套根文件系统 | 维护成本远超本项目收益；本项目聚焦"让 Linux 在这台机器上可用"的适配层 |

## 证据与出处（Evidence）

- 基线说明与不可用原因：[`README.md`](../../README.md) §3「基线系统」
- 装机实测步骤：[`docs/install-dualboot.md`](../install-dualboot.md)
- 引导链事故与恢复（`slbounce`/`qebspil` 不可拿掉）：[`AGENTS.md`]（本地台账）与
  [`docs/kernel-7.2.5-el1-build.md`](../kernel-7.2.5-el1-build.md) 记录的镜像修复过程

## 回滚（Rollback）

不改动基线本身的任何文件；装机走 `scripts/10-install-dualboot.sh`（默认 `DRY_RUN`）。
若基线不可用，回退到本机原有的 Windows 引导项即可（双系统始终保留）。
