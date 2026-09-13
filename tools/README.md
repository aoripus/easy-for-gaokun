# `tools/` —— 只读分析工具与构建/打包脚本

分两类，**不要混用**：

| 类别 | 在哪跑 | 是否改目标机 |
|---|---|---|
| 分析工具（`*.py`） | 开发机（Windows/Linux）或目标机 | 否（只读；个别需要 root 才能读 `/dev/mem`） |
| 构建/打包脚本（`*.sh`） | **构建宿主**（x86_64 Linux 交叉编译机） | 否（只产出文件，不碰 ESP） |

## 工具索引

| 工具 | 用途 | 运行环境 | 依赖 |
|---|---|---|---|
| [`gk-touch-bench.py`](gk-touch-bench.py) | **触屏通路量化**：报点率、帧间隔分位数、抖动、IRQ 效率、CPU 占用；用于 i2c-hid 与 spi6 两条通路的可复现对比 | 目标机（读 `/proc/interrupts`、`/dev/input/*`） | Python 3，标准库 |
| [`win-acpi-hive.py`](win-acpi-hive.py) | **离线解析 Windows `SYSTEM` 注册表 hive**，读出本机实际枚举到的 ACPI 设备与资源分配 | 开发机（Linux/Windows） | Python 3，标准库 |
| [`acpi-devmem-dump.py`](acpi-devmem-dump.py) | 在"用设备树启动、内核未初始化 ACPI"的机器上从 `/dev/mem` 直接读固件 ACPI 表做取证 | 目标机（需 root） | Python 3；内核需允许读 `/dev/mem` |
| [`gaokun-iris-dts-prep.py`](gaokun-iris-dts-prep.py) | 把上游 SC8280XP 的 IRIS 设备树节点前置进基线内核源码树 | 构建宿主 | Python 3，标准库 |
| [`build-iris-x86.sh`](build-iris-x86.sh) | **x86_64 交叉编译 arm64 内核**（只编译，不安装；产物止步 `Image`/DTB/模块散件） | 构建宿主 | `aarch64-linux-gnu-` 工具链、`make` |
| [`mk-release.sh`](mk-release.sh) | 打包内核产物 + 生成构建溯源清单与 `sha256sums.txt` | 构建宿主 | `zstd`、`sha256sum` |
| [`pas-probe/`](pas-probe/README.md) | **独立探针模块**：向 TrustZone 直接问询视频核的 PAS 支持并逐项对比寄存器（IRIS 取证阶段产物） | 目标机（需编译内核模块） | 内核头文件、`make` |

## 两点必须知道的现状

- **`build-iris-x86.sh` 的名字是历史遗留**：它诞生于 IRIS 路线，当前用于 **venus 线**（EL1）内核的构建，
  默认内核串已按命名规范生成（`<上游>-aoripus-ml-gaokun3-eog-<级别>-<VPU>-r<n>`），并内建
  `CONFIG_LOCALVERSION_AUTO` 与"串尾不得有 `+`"两道断言。改名会牵动文档与 CI 引用，故暂保留旧名。
- **`mk-release.sh` 目前仍是"写死路径"的一次性脚本**（`BASE=/root/gaokun`、`VER=7.2-rc2`）。
  复现发布时请以 [`docs/releasing.md`](../docs/releasing.md) 的流程为准，或先把这两个变量参数化——
  这属于已知待办，不要在 CI 里依赖它。

## 与仓库其它部分的关系

- 结论与实测数据一律写进 [`docs/`](../docs/README.md)（单一事实来源）；工具只负责产出数字。
- 补丁序列在 [`patches/`](../patches/README.md)，用 `scripts/check-patches.sh` 自检。
- 面向用户的诊断/安装脚本在 [`scripts/`](../scripts/README.md)。
