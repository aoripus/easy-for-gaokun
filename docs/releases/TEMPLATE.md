# Kernel <上游> (<级别>) <驱动大写>[ r<n>]

> 目标设备：**HUAWEI MateBook E Go 2022 性能版（GK-W76 / SC8280XP / 设备树 `gaokun3`）**
> 内核串（`uname -r`）：`<上游>-aoripus-ml-gaokun3-eog-<级别>-<VPU驱动>-r<n>`
> 发布标签：`kernel-<完整内核串>-<YYYYMMDD>`
> 基线：**kernel.org stable `<上游>`** + 本项目自有补丁
> 上一版：[<上一版内核串>](<上一版 Release 链接>)

**本版主题：<一句话>。**

---

## 1. 相对上一版改了什么

| # | 变更 | 说明 |
|:-:|------|------|
| 1 | <变更> | <为什么改、影响面、相关补丁链接> |

**未变的部分**：<列出为方便读者确认没动的关键路径，例如视频硬解路线、触屏引脚修复、
GSI 模式、板级补丁、启动级别、关键 Kconfig>。

## 2. 实机验证（<YYYY-MM-DD>）

装机方式：`scripts/gk-install-kernel.sh` **只新增一个 BLS 条目**，
`loader.conf` 的 `default` 与 EFI 变量均未改动。

| 项 | 结果 |
|---|---|
| 启动级别 | `CPU: All CPU(s) started at EL1` ✅ |
| 内核串 | `<内核串>`（**无 `+`**）✅ |
| 视频硬解 | <venus 解码/编码器节点与播放器实测> |
| 触屏 | <输入设备、中断计数、空闲策略参数> |
| KVM | <有/无 `/dev/kvm`，以及原因> |

### 2.1 <关键实测数据>

| 指标 | 上一版 | 本版 | 改善 |
|---|---:|---:|---|
| <指标> | <值> | <值> | <比例> |

<附上可复现的命令与口径说明；数据文件若已入仓，给出链接。>

### 2.2 已知取舍

- <本版有意不做的事，以及代价>

## 3. 产物（8 项）

| 文件 | 大小 |
|---|---|
| `Image` | <字节> |
| `modules-<内核串>.tar.zst` | <字节> |
| `sc8280xp-huawei-gaokun3.dtb` | <字节> |
| `config-<内核串>` | <字节> |
| `System.map-<内核串>` | <字节> |
| `gaokun3-7.2.5-el1.patch` | <字节> |
| `sha256sums.txt` / `BUILD-PROVENANCE.md` | — |

驱动增量另有独立可审阅补丁：<指向 `patches/<序列>/` 的链接>。

## 4. 安装与回滚

```sh
# 安装（只新增 BLS 条目，不动默认项）
sudo scripts/gk-install-kernel.sh --kver <内核串> --image Image \
     --dtb sc8280xp-huawei-gaokun3.dtb --modules modules-<内核串>.tar.zst \
     --tag r<n> --oneshot

# 回滚
sudo scripts/gk-install-kernel.sh --uninstall --kver <内核串>
```

## 5. 已知限制

- <尚未打通/未验证的项，以及下一步>

---

<!--
用法：
1. 复制本文件为 docs/releases/kernel-<完整内核串>-<YYYYMMDD>.md（文件名与 Release tag 同名）。
2. 替换所有 <...> 占位符；表格里不要留占位符。
3. 装机复核数据必须来自真实执行（见 docs/releasing.md §6），不得填写预期值。
4. tag 与标题一经发布不可更改；文案更新走 `gh release edit --notes-file`。
-->
