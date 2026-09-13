# `scripts/` —— 面向目标机的诊断与安装脚本

这些脚本**在目标机（HUAWEI MateBook E Go 2022 性能版 / GK-W76）上运行**，不是构建脚本。
编号只表示**推荐的执行顺序**，不表示依赖关系；每个脚本都能单独跑。

## 公共约定

- Bash 5，开头 `set -euo pipefail`，日志/root 检查/`DRY_RUN`/结果表一律复用
  [`lib/common.sh`](lib/common.sh)，不要另起输出风格。
- **涉及系统写入的脚本必须支持 `DRY_RUN`**：默认只打印将要执行的动作，确认后才真正落盘。
- 只读脚本不修改任何系统状态。
- 面向用户的输出使用简体中文；本文档与脚本注释保持一致。

## 脚本索引

| 脚本 | 用途 | 是否写系统 | `DRY_RUN` | 顺序 |
|---|---|:--:|:--:|:--:|
| [`lib/common.sh`](lib/common.sh) | 公共库：日志、root 检查、`DRY_RUN`、结果表、设备判据 | — | — | 被 source |
| [`00-preflight.sh`](00-preflight.sh) | **设备鉴别与前检**：校验设备树 `compatible`、大核最高频率、面板与触控设备；任一判据不符即中止 | 否（只读） | 不适用 | ① 必须先跑 |
| [`10-install-dualboot.sh`](10-install-dualboot.sh) | **双系统安装**：分区级 `dd` 把社区整盘镜像落到内置盘，保留 Windows；含 GPT 备份、UUID 校验、`resize2fs`、`loader.conf` 修复、DTB 预编译 | **是（高危）** | 是 | ② |
| [`20-touchscreen.sh`](20-touchscreen.sh) | 触屏诊断与修复：接口模式脚 `gpio174` 的处理与验证 | 是 | 是 | ③ |
| [`30-audio.sh`](30-audio.sh) | 音频诊断与调优：安装 gaokun3 专用 ALSA UCM2 profile | 是 | 是 | ④ |
| [`40-fingerprint.sh`](40-fingerprint.sh) | 指纹识别器调查（结论：SPI 由安全世界独占，非安全侧不可达） | 否（只读） | 不适用 | ⑤ |
| [`90-report.sh`](90-report.sh) | **一键诊断报告**：把关键状态输出到 stdout，便于重定向成文件附在 issue 里 | 否（只读） | 不适用 | 随时 |
| [`gk-install-kernel.sh`](gk-install-kernel.sh) | 把本项目自编内核装进 ESP（systemd-boot BLS），**只新增条目**、支持 `--oneshot` / `--uninstall` | 是 | 是 | 安装自研内核时 |
| [`check-patches.sh`](check-patches.sh) | **补丁序列自检**：`patches/*/series` 与补丁文件一一对应、补丁非空且是补丁格式 | 否（只读） | 不适用 | 提交前 / CI |

## 高危操作与红线

**本机型没有 EDL / 9008 救援通道**：分区表、ESP 或引导项一旦破坏，没有刷机工具能救回。
下列操作必须由设备所有者显式确认，且脚本**默认不得启用**：修改分区表、覆盖 ESP、改写引导项、
`dd` 到内置存储。细节见 [`SECURITY.md`](../SECURITY.md) 与
[`CONTRIBUTING.md`](../CONTRIBUTING.md) 的「安全约束」。

## 内核安装与回滚

```sh
# 安装（只新增 BLS 条目；不动 loader.conf 的默认项，也不动 EFI 变量）
sudo scripts/gk-install-kernel.sh --image Image --dtb sc8280xp-huawei-gaokun3.dtb \
     --modules modules-<内核串>.tar.zst --tag r3 --oneshot

# 回滚
sudo scripts/gk-install-kernel.sh --uninstall --tag r3
```

机器侧的落点见 [`README.md` 的「构建产物与发布」](../README.md#7-构建产物与发布)：
BLS 条目 `loader/entries/<machine-id>-<内核串>[-<tag>].conf`，ESP 目录 `<machine-id>/<内核串>[-<tag>]/`。

## 本地检查

```sh
scripts/check-patches.sh     # 补丁序列自检（CI 的 patches job 与 make patches 都调用它）
make check                   # 全部静态检查（需要 shellcheck / ruff / yamllint / node）
```
