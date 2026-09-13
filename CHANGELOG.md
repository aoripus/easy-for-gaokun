# 更新日志

本文件记录 easy-for-gaokun 的所有重要变更。

格式遵循 [Keep a Changelog](https://keepachangelog.com/zh-CN/1.1.0/)，
版本号遵循 [语义化版本](https://semver.org/lang/zh-CN/)。

> **关于内核产物**：本项目的**二进制内核构建**使用独立的标签与 Release，
> 命名形如 `kernel-<内核 release 串>-<构建日期>`，与源码版本号解耦。
> 详见 [README 的「构建产物与发布」](README.md#7-构建产物与发布) 一节。

## [未发布]

## [0.1.0] - 2026-09-13

首个版本：设备鉴别、双系统安装、触屏修复、音频调优、外设调查与内核构建配方。

### 新增

- **设备鉴别前检** `scripts/00-preflight.sh`：校验设备树 `compatible`、大核最高频率、
  面板与触控设备，任一判据不符即中止；用于排除 2022 LTE 版（8cx Gen 2 / gaokun2）
  与 2023 降频版。
- **双系统安装** `scripts/10-install-dualboot.sh`：把社区整盘镜像按**分区级 `dd`**
  落到内置盘，保留 Windows；含 GPT 备份、UUID 硬校验、`resize2fs`、
  `loader.conf` 修复与 DTB 预编译。
- **触屏修复** `scripts/20-touchscreen.sh` + `patches/0001-*`：把接口模式脚
  `gpio174` 在触控固件重载前置低，使 Himax HX83121A 走 SPI 上报通路。
- **音频调优** `scripts/30-audio.sh` + `config/ucm2/Qualcomm/sc8280xp/HUAWEI-GK-W7X.conf`：
  gaokun3 专用 ALSA UCM2 profile，功放增益由 X13s profile 的 `12`（−3.00 dB）
  提到内核限幅上限 `17`（0.00 dB）。
- **指纹调查** `scripts/40-fingerprint.sh`：只读探针，含从 Windows 分区取
  `SYSTEM` 注册表 hive 的采集路径。
- **一键诊断报告** `scripts/90-report.sh`：提 issue 用的只读体检报告。
- **分析工具**：`tools/win-acpi-hive.py`（离线解析 Windows 注册表，读出本机真正
  枚举过的 ACPI 设备与资源分配）、`tools/acpi-devmem-dump.py`（从 `/dev/mem`
  读 ACPI 表）、`tools/gaokun-iris-dts-prep.py`（前置上游 IRIS 设备树节点）。

### 文档

- `docs/install-dualboot.md` —— 双系统安装完整步骤与实机踩坑。
- `docs/audio.md` —— 音频质量归因、量化与增益上限。
- `docs/video-decode.md` —— 视频硬解归因（IRIS 而非 Venus）与可行路径。
- `docs/build-kernel-iris.md` —— IRIS 内核构建配方（含实机构建验证后的修正）。
- `docs/fingerprint.md` —— 指纹可行性调查结论。

### 已核实的关键结论

- **触屏**：`gpio174` 为低 ⇒ SPI 上报；为高 ⇒ I²C-HID。引导固件把它留在高电平且
  无人接管，是触屏完全失效的根因。
- **音频**：音质差是三层叠加 —— 内核主动限幅、Linux 侧完全没有 Histen 逐机型调音、
  以及加载了双扬声器的 X13s profile。硬件尚余 21.00 dB 未使用，但主动扬声器保护
  缺失，本项目**只把增益提到内核限幅值，不取消内核限幅**。
- **视频**：本机是 Qualcomm IRIS(Gen1) 而非经典 Venus；v7.1-rc3/v7.2-rc2 的上游树里
  都没有 sc8280xp 视频节点（v7.3-rc1 才有），buildbot 的 `patches/media/0006` 是过时的
  venus 形态。
- **指纹**：FocalTech FTE7001，其 SPI **由 Qualcomm 安全世界独占**，非安全侧只拿到
  一个 GPIO 中断连接 —— Linux 走常规驱动路线不可达。
- **平板不适合作为编译机**：无风扇机型上 `make -j8` 会触发硬件级瞬间断电
  （日志无任何关机序列，温度仅 33 °C）。

### 已知问题

- 视频硬解尚未跑通；IRIS 与 Venus 走同一条 PAS/安全世界通路，而该机
  `qcom_scm_pas_init_image()` 已知失败 —— 换驱动不改变这条通路是否可用。
- 手写笔通道未实现。
- `qcom-apm` 开机报 `CMD timeout`（声卡仍能注册）。
- RTC 开机时间错误，依赖 NTP 纠正。

[未发布]: https://github.com/aoripus/easy-for-gaokun/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/aoripus/easy-for-gaokun/releases/tag/v0.1.0
