# 发布流程（内核产物）

本文件是**可照做的 checklist**。目标：任何一次内核发布都能被复现、被审计、可回滚。

> 术语：**构建宿主** = x86_64 Linux 交叉编译机（不是目标机）；**目标机** = GK-W76 平板。
> 内核串、tag 与标题的规范见 [`README.md`](../README.md#7-构建产物与发布) 与 [ADR-0005](adr/0005-kernel-version-naming-and-revisions.md)。

## 0. 前置

- 上游版本已确定（本项目只用 kernel.org **stable**，不用 RC）。
- 补丁集在构建宿主上**逐个**应用成功（`git apply` 传多个补丁是原子操作，一个失败则全不生效）。
- 需要纳入本轮的补丁已同时更新到 [`patches/`](../patches/README.md)（含 `series` 与元数据）。

## 1. 构建

```sh
# 在构建宿主上（脚本名 build-iris-x86.sh 属历史遗留，当前用于 venus 线）
tools/build-iris-x86.sh <参数见脚本 --help>
```

**构建配方与 §3 的完整步骤**记录在 [`docs/kernel-7.2.5-el1-build.md`](kernel-7.2.5-el1-build.md)：
以社区补丁集打底，叠加本项目增量（venus 节点、触屏驱动与引脚、GSI、空闲策略等）。

**构建时必须满足的两件事**（否则内核串会带 `+`，见 ADR-0005）：

1. `.config` 里 `# CONFIG_LOCALVERSION_AUTO is not set`；
2. 生成内核串时源码树**不带 `.git`**（发行版的标准做法：从 tarball 解包构建）。

## 2. 门禁断言（不过就不要打包）

```sh
# 配置侧
grep -q '^CONFIG_VIDEO_QCOM_VENUS=m$'            .config
grep -q '^# CONFIG_VIDEO_QCOM_IRIS is not set$'  .config

# 内核串：必须等于规范串，且不含 '+'
cat include/config/kernel.release     # 例：7.2.5-aoripus-ml-gaokun3-eog-el1-venus-r3

# 产物 DTB：含本项目增量，且不含 EL2 路线的标志
strings sc8280xp-huawei-gaokun3.dtb | grep -e gpio174 -e sm8350-venus -e qcvss8280.mbn
strings sc8280xp-huawei-gaokun3.dtb | grep -e shm-bridge-vmid -e broken-reset   # 应无输出

# 诊断节点默认关闭、只读节点在（见 ADR-0006）
```

`tools/build-iris-x86.sh` 已内建其中大部分断言（配置阶段查 `.config`，编译后查 `kernel.release`）。

## 3. 打包

```sh
tools/mk-release.sh
```

> ⚠️ `mk-release.sh` 目前仍是写死路径的一次性脚本（`BASE`/`VER` 需按当时构建改），
> 复现发布时请以上面的门禁与下方资产清单为准。

**资产清单（8 项）**：

| # | 资产 | 说明 |
|:-:|------|------|
| 1 | `Image` | 内核镜像 |
| 2 | `modules-<内核串>.tar.zst` | 模块包 |
| 3 | `sc8280xp-huawei-gaokun3.dtb` | EL1 设备树 |
| 4 | `config-<内核串>` | 构建配置 |
| 5 | `System.map-<内核串>` | 符号表 |
| 6 | `gaokun3-7.2.5-el1.patch` | 本项目相对上游的**合并补丁**（供审计与复现） |
| 7 | `sha256sums.txt` | 校验和 |
| 8 | `BUILD-PROVENANCE.md` | 构建溯源（工具链、命令、配置摘要） |

## 4. 发布

```sh
# 先写发布说明（模板见 docs/releases/TEMPLATE.md，文件名与 tag 同名）
$EDITOR docs/releases/kernel-<内核串>-<YYYYMMDD>.md

gh release create kernel-<内核串>-<YYYYMMDD> \
   --title 'Kernel <上游> (<级别>) <驱动大写> r<n>' \
   --notes-file docs/releases/kernel-<内核串>-<YYYYMMDD>.md \
   ./Image ./modules-<内核串>.tar.zst ./sc8280xp-huawei-gaokun3.dtb \
   ./config-<内核串> ./System.map-<内核串> ./gaokun3-7.2.5-el1.patch \
   ./sha256sums.txt ./BUILD-PROVENANCE.md
```

- CI 的 `verify-release` job 会在 `release: published` 时校验：tag 规范、`docs/releases/<tag>.md` 是否存在、
  资产是否齐全、`sha256sums.txt` 是否匹配。
- **发布说明可就地更新，tag 与标题不可动**：内核字节不变时，用
  `gh release edit <tag> --notes-file <file>`；**不要**为了改文案重新打 tag。

## 5. 装机

```sh
# 只新增 BLS 条目：不动 loader.conf 的默认项，也不动 EFI 变量
sudo scripts/gk-install-kernel.sh --kver <内核串> \
     --image Image --dtb sc8280xp-huawei-gaokun3.dtb \
     --modules modules-<内核串>.tar.zst --tag r<n> --oneshot
```

## 6. 装机复核（发布说明里要贴这些）

| 检查 | 期望 |
|---|---|
| `uname -r` | 与规范串**逐字符**一致，无 `+` |
| `dmesg \| grep 'CPU: All CPU'` | `All CPU(s) started at EL1`（venus 线） |
| `/dev/video32` `/dev/video33` | venus 解码器 / 编码器存在 |
| 触屏 | 输入设备在，`/proc/interrupts` 里 `himax-spi-ts` 计数持续增长 |
| 空闲策略 | `idle_enter_frames=7200`、`idle_poll_ms=30`；`idle_state` 可见 |
| 唤醒 | 点按屏幕后 `dmesg` 出现 `idle exit: touch after 30ms sampling` |

## 7. 发布后

- 更新 [`CHANGELOG.md`](../CHANGELOG.md)（`[未发布]` 下的对应章节）。
- 若复核数据与发布说明不符，**更正发布说明并留痕**（说明哪一条被更正、依据是什么）。

## 8. 回滚

```sh
sudo scripts/gk-install-kernel.sh --uninstall --kver <内核串>
```

只删除本项目新增的 BLS 条目与 ESP 目录；原厂/基线内核条目始终保留。
运行时若触屏异常，可先 `echo 1 | sudo tee /sys/bus/spi/devices/spi0.0/inplace_reset` 触发重初始化，
或关闭空闲策略：`echo 0 | sudo tee /sys/module/himax_hx83121a_spi/parameters/idle_enter_frames`。
