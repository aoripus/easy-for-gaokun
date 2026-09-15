# WSL2 与 Android 在 ARM64 上的可行性（Windows 可行性报告 · 工作包 (d)）

> 目标设备：**HUAWEI MateBook E Go 2022 性能版（GK-W76 / Snapdragon 8cx Gen 3 / SC8280XP / Adreno 690）**，
> 出厂 Windows 11 ARM64。本文是 `easy-for-gaokun-win` 可行性报告的**工作包 (d)：装 Linux 与 Android**。
> 范围：只回答"能不能做、代价多大、风险在哪"，**不含实现**，不覆盖 (a)(b)(c) 三个工作包。
> 结论口径：与仓库文档规范一致，三档置信度 **【已核实】/【社区报告】/【推测】**；
> **本机未知的一律标【未核实】**。

## 0. 取证环境边界（先读这一节，否则会误读全文）

| 项 | 值 |
|---|---|
| 调研宿主 | **开发台式机**，`Microsoft Windows 10 企业版 LTSC Build 19044` / `AMD64` |
| 宿主 WSL 状态 | `wsl.exe` 存在，但 `Microsoft-Windows-Subsystem-Linux = Disabled`、`VirtualMachinePlatform = Disabled`；VBS 未启用、Secure Boot = False**【未核实】**（原始调研报告只记了这两项的取值、没有对应的取证命令与输出，不作对外引用；真机状态见 §8 第 8 项） |
| 平板（GK-W76） | **未安装、未下载、未改动任何东西** |

⇒ 本文凡涉及**真机行为**（`/dev/dri` 是否出现、WSLg 实际性能、WSABuilds 是否可装）的条目，
**一律标【未核实】**，不用台式机状态推断平板。§8 是完整的未核实清单。

---

## 1. 结论摘要（10 行内）

1. **WSL2 本体在 Windows 11 ARM64 上完全可用**【已核实】：`wsl --install`、离线 MSIX/MSI、`wsl --import` 自定义 rootfs、
   `wsl.conf`/`.wslconfig`、systemd、WSLg 全部是官方支持路径，"预装 WSL 并调好"是真能交付的部分。
2. ★ **但 WSL2 在 ARM64 上的 GPU 加速当前不可用（已回归）**【社区报告，多条独立来源】：`dxgkrnl` 不创建
   `/dev/dri/renderD128`，Mesa 只能回落 **llvmpipe 软件渲染**，上游 issue 仍 open。
   **对照语义**：**同一 SoC（8cx Gen 3）在 2023 年曾有成功记录、但在当前版本上已不可复现** ——
   `microsoft/WSL#9154` 的 2023-06-29 评论显示 `glxinfo -B` 报 `D3D12 (Qualcomm(R) Adreno(TM) 8cx Gen 3)`、
   `Accelerated: Yes`；而 2025-08 之后的报告（`#13370`）显示加速丢失。【见 §4.2】
3. ⇒ **x64 上成熟的 GPU 方案（d3d12 + Mesa、OpenCL、DirectML、CUDA）在 ARM64 上没有对等保证**；
   官方 GPU 教程**通篇 x86-64、全文无 arm64 字样**【已核实：官方文档无 arm64 表述；能力本身未核实】。
4. **Android 没有官方路径**【已核实】：WSA 与 Amazon Appstore 已于 **2025-03-05** 停止支持并从 Microsoft Store 下架。
5. **ARM64 无嵌套虚拟化**（WSL 维护者原话）⇒ WSL2 内**没有 `/dev/kvm`**；叠加 Android Studio 官方
   "不支持 ARM CPU 主机"的原文 ⇒ **AVD / redroid / crosvm / docker-android 全部出局**。
6. WSL2 里跑 Waydroid **技术上【推测】可行**（自建内核开 binder，issue 原文只证明"有人用自建 6.6 内核跑通
   并给出 CONFIG"，可行性本身是调研推断），但上游**明确 not planned**，且
   `/mnt/wslg` 只读挂载会打死 LXC、又没有 GPU ⇒ **不建议投主线资源**。
7. 纯 Windows 单系统下唯一像样的替代是社区 **WSABuilds arm64**（仍活跃），但它**不可长期依赖、不可公开分发**。
8. **技术与许可双优的是"本机 Linux 分区跑 Waydroid"**（原生 arm64 + Turnip + `v4l2m2m` 硬解），
   代价是与"全盘 Windows"目标**直接互斥**。
9. **"一条命令装好"可做到"一次 UAC + 一次重启 + 后续全自动"**，配合预置 rootfs 与预置内核即可做成安装器。
10. **最大不确定性**：GK-W76 的 `/dev/dri` 能否出现 —— 2023 年同 SoC 有**成功**报告，2026 年有**失败**报告；
    §8 的 priority #1 四条只读探针拿到之前，**所有图形结论都是条件性的**。

---

## 2. Android 路径对比

### 2.1 前置事实（决定整张表的两条硬约束）

| 事实 | 结论 | 置信度 |
|---|---|---|
| **WSA 已 EOL** | 微软 Learn（last updated **2025-03-05**）：*"Starting March 5, 2025, Windows Subsystem for Android and the Amazon Appstore are no longer available in the Microsoft Store."*；Amazon 公告（2024-03-05）确认终止日同为 2025-03-05；`microsoft/WSA` 仓库 **archived** | 【已核实：双源】 |
| **ARM64 无嵌套虚拟化** | `microsoft/WSL#13796`（closed，2025-12-04），维护者 `benhillis` 原话 *"This is a hardware limitation of most ARM64 chips"* ⇒ WSL2 内 `/dev/kvm` 不可得 | 【已核实】issue 原文 |
| **Android Studio 不支持 Windows ARM64** | 官方系统需求原文："Note: Windows machines with ARM-based CPUs aren't currently supported."；模拟器加速文档的 Supported processors 只列 Intel / AMD / Apple silicon（`ARM64 + arm64-v8a system image` 指**镜像架构**，不是主机支持） | 【已核实】官方文档原文 |

### 2.2 对比表

| 路径 | 原理 | 图形性能 | 虚拟化依赖 | 上游可持续性 | 许可与分发 | 结论 |
|---|---|---|---|---|---|---|
| **① WSABuilds arm64**（社区 WSA 魔改） | 复用微软 WSA 运行时（Hyper-V 容器 + Android **arm64 原生**） | **最好的一条**：WSA 自带 vGPU 通路（与 WSL2 不同），理论上有 GPU 直通【推测：需实测】 | 需 Hyper-V 平台与"开发人员模式"（安装手册要求） | **差**：GApps 崩溃主 issue `#593` **open**（2025-07-13 / 2026-09-09，272 条评论）；上游 `MagiskOnWSALocal` 末次提交 **2025-09-20**，已停更 | **AGPL-3.0** + 文档 **CC-BY-NC-ND**，但捆绑的 WSA 二进制来自微软且已 EOL ⇒ **再分发合法性存疑，只本地自用** | **当下可用、不可长期依赖、不可公开分发** |
| **② WSL2 + Waydroid** | 自建 WSL 内核开 binder/binderfs，在 WSL2 里跑 Waydroid 容器 | **差**：无 `/dev/dri` ⇒ 退化到 SwiftShader / 软件渲染 | 需自建内核（可做）；Waydroid 不是 KVM 型，不受嵌套虚拟化限制 | **差**：上游 `#712` 以 **not planned** 关闭；`#1217`（open）`/mnt/wslg` 只读挂载导致 `lxc-start: Read-only file system` | Waydroid 开源；WSL 属 Windows 组件（见 §7.1） | **技术可行但脆弱，不建议投主线** |
| **③ 本机 Linux 分区跑 Waydroid**（`dragon-waydroid`） | 原生 Linux 启动，内核开 binder/ashmem，Wayland 下跑容器 | **最好**：原生 arm64 + **真 GPU（Turnip）** + `v4l2m2m` 硬解 | 无需嵌套虚拟化 | 本项目自有基线与补丁体系；对 SC8280XP 笔记本机型的支持面【未核实】 | 全部开源组件，许可最干净 | **技术与许可最优，但与"全盘 Windows"互斥** |
| ④ AVD（Android Studio 模拟器） | 官方模拟器 | 不可用级（只能软件模拟） | **官方不支持 Windows ARM64**；即使绕过也无 KVM/WHPX | 官方明确不支持 | — | **否决** |
| ⑤ redroid / crosvm / docker-android | 容器化 Android，依赖 binder + **KVM** | — | **需要 `/dev/kvm`** ⇒ ARM64 无嵌套虚拟化 | redroid README 自称支持 arm64，但前提是宿主有 KVM | — | **否决**（前提不成立） |
| ⑥ Genymotion / 云手机 | 商业模拟器 / 远程实例 | 取决于链路 | 未核实是否有 arm64 Windows 宿主版 | — | 云手机涉隐私、成本、数据出机 | **【未核实】** |

---

## 3. WSL2 本体：ARM64 上的可用性

### 3.1 安装与自动化能力【已核实】

来源：微软 Learn <https://learn.microsoft.com/en-us/windows/wsl/install>（页脚 last updated 2025-08-06）。

| 能力 | 备注 |
|---|---|
| `wsl --install` / `-d <Distro>` / `--list --online` | 需 Windows 10 2004+ / Win11；**仅当 WSL 完全没装过时才生效**，已装过会打印帮助文本 |
| `wsl --install --web-download -d <Distro>` | 官方给出的"卡在 0.0%"解法 —— **企业镜像 / WSUS 环境的重要逃生门** |
| `wsl --install --no-launch` | 安装后不进交互；官方文档**未逐字描述**该参数 ⇒ 参数级行为标【未核实】 |
| 离线安装 | 官方 "Offline install" 节：下载 **WSL MSI**（GitHub releases）→ `dism /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart` → 用 `.wsl` 文件装发行版 |
| `wsl --import <Distro> <Location> <tar>` | 官方 "Import any Linux distribution"：任意 tar rootfs，**默认以 root 启动**，用 `/etc/wsl.conf` 的 `[user] default=` 设默认用户 |
| `wsl --update [--pre-release]`、MSIX / 企业部署 | 官方 release 提供 MSIX/MSI；winget 亦有 `Microsoft.WSL` manifest |

**注意两点**：① `wsl --import` **不做架构转换**，arm64 主机必须用 arm64 rootfs；
② **WSL2 不需要开发者模式** —— "开发人员模式"是 WSA / WSABuilds 安装手册的要求，与 WSL2 无关。

### 3.2 配置项与自建内核入口【已核实】

来源：微软 Learn <https://learn.microsoft.com/en-us/windows/wsl/wsl-config>（last updated 2026-04-15）。

- **`/etc/wsl.conf`（每发行版）**：`[automount]`、`[network]`、`[interop]`、**`[user] default=`**、
  **`[boot] systemd=true`**（较新的商店版 WSL 才识别；`wsl --version` 不识别即为旧的内置版）、`[gpu] enabled`、`[time]`。
- **`%UserProfile%\.wslconfig`（全局，仅 WSL2）**：**`kernel=`**（自定义内核的绝对 Windows 路径）、
  **`kernelModules=`**（模块 VHD）、**`kernelCommandLine=`**、`memory`、`processors`、`swap`、`guiApplications`、
  `nestedVirtualization`、`networkingMode`、`firewall`、`dnsTunneling`、**`vmIdleTimeout`（默认 60000 ms）**。
- **"8 秒规则"**：配置改动必须等 WSL 子系统完全停止才生效，`wsl --shutdown` 是快路径。
- **★ 自建内核的推荐底座**：基于 **`microsoft/WSL2-Linux-Kernel` 的 WSL 分支（只改 config、打最小补丁）**；
  **不要**把本项目的 mainline stable 树反向补 WSL 驱动 —— 微软树里有整套 WSL 专用驱动
  （`dxgkrnl`、`hv_*`、`9p`、`virtio`、`vsock`），反向移植工作量远超收益（微软树是独立 fork，
  验证方式：克隆后做一次树级 diff）。【推测】
- **官方示例路径是 x86**（`arch/x86/boot/bzImage`）⇒ arm64 换成 `arch/arm64/boot/Image`；
  `Microsoft/config-wsl` 在较新树里的位置【未核实，克隆后确认】。**所有 distro 共用一个内核**（官方 Warning）
  ⇒ 自建内核对所有发行版生效，回滚必须保留原内核路径。
- **与本项目 Linux 线的边界**：我们的基线是**裸机 UEFI + DTB + BLS 条目**体系，WSL2 是**无 DTB、Hyper-V
  虚拟平台**体系，**两者不通用**；WSL2 里只能用内核源码与 config 裁剪经验，不能用我们的 DTB 与 BLS 条目。
  【推测，需实测确认 DTB 在 WSL2 下被忽略】

### 3.3 自动化形态：一次 UAC + 一次重启 + 后续全自动【已核实，除注明外】

自动化路径（管理员 PowerShell，唯一强交互是 UAC）：`dism` 启用 `VirtualMachinePlatform`（可选加启用
`Microsoft-Windows-Subsystem-Linux`）→ **重启**（`/norestart` 后由脚本 `Restart-Computer` + RunOnce 续跑）→
装 WSL（离线 MSI 或 `winget install --id Microsoft.WSL`）→ `wsl --install -d Ubuntu --no-launch`
（卡在 0.0% 时用 `--web-download` 兜底）→ 预置 rootfs 路线 `wsl --import Ubuntu-24.04 D:\wsl\Ubuntu
.\ubuntu-arm64-rootfs.tar --version 2`（rootfs 内预置 `[boot] systemd=true` 与 `[user] default=<user>`）→
在 `%UserProfile%\.wslconfig` 里配置自建内核与模块盘 → `wsl --shutdown`。

| 步骤 | 需要交互 | 需要联网 | 说明 |
|---|---|---|---|
| 启用 `VirtualMachinePlatform` | **管理员** | 否 | `dism` 幂等，可先用 `Get-WindowsOptionalFeature` 判断 |
| **重启** | 通常需要 | 否 | **不可绕过**；可做成"第二次开机自动续跑" |
| 获取 WSL MSIX/MSI、发行版 rootfs | 否 | **需要**（或预置离线包 / tar） | 官方 offline install 路径；`DistributionInfo.json` 有 URL |
| 首次创建 Linux 用户 | **需要**（除非走 `--import` + 预置 `wsl.conf`） | 否 | `--import` 路线彻底消除此交互 |
| **开发者模式** | **不需要** | — | 那是 WSA / WSABuilds 的坑 |
| 自建内核替换 | 否 | 否 | 纯文件 + `.wslconfig` |

⇒ 结论：**"一条命令"可做到"一次 UAC + 一次重启 + 后续全自动"**，配合预置 rootfs 与预置内核，
可复现性足以做成安装器。

---

## 4. ★ 头号发现：ARM64 上 WSL 的 GPU 加速当前不可用

> 这一节是本工作包**最重要的结论**，也是最需要谨慎的一节。**x64 上成熟的方案不要在 ARM64 上默认成立。**

### 4.1 能力矩阵

| 能力 | ARM64 WSL2 状态 | 证据 | 置信度 |
|---|---|---|---|
| `/dev/dxg`、`libd3d12.so` / `libd3d12core.so` / `libdxcore.so` | 在位（用户态已就绪） | `microsoft/wslg#1470`：`crw-rw-rw- /dev/dxg` 存在、`/usr/lib/wsl/lib/` 三个文件齐全 | 【已核实】 |
| **`/dev/dri/renderD128`（GPU 被 Mesa 真正识别）** | ❌ **不可用（当前）** | `microsoft/wslg#1470`（open，2026-06-13 创建 / 2026-09-08 更新）：Adreno **680** 上 `ls /dev/dri/` **为空**，`glxinfo` → `llvmpipe`，`GALLIUM_DRIVER=d3d12 glxinfo` → `glx: failed to create drisw screen`；评论追加 **Surface Pro 11 / Adreno X1-85 同症**，且该报告者称"用的就是 WDDM 3.1" | 【社区报告】（多条独立） |
| Mesa d3d12 Gallium（OpenGL → D3D12）、Vulkan | ❌ 均不可用（回落 llvmpipe） | 同上；`d3d12_dri.so` 已安装但无法初始化、`vulkaninfo` → llvmpipe | 【社区报告】 |
| **CUDA** | ❌ 不可用 | CUDA-on-WSL 是 **NVIDIA 专有栈**（本机 Qualcomm ⇒ 无 CUDA）；官方 GPU 教程 `MicrosoftDocs/WSL` 仓库 **`WSL/tutorials/gpu-compute.md`**（`ms.date 2024-11-19`）**只给 x86-64 流程**（`Miniconda3-latest-Linux-x86_64.sh`），**全文无 arm64 字样** ⇒ 官方未背书 | 【已核实：官方文档无 arm64；CUDA 属 NVIDIA 专有栈】 |
| **OpenCL / DirectML** | ❓ 未核实 | 同一教程未覆盖 arm64（无 arm64 安装/运行时说明）；ARM64 WSL2 无 `/dev/dri/renderD128` ⇒ OpenCL / DirectML 的前置条件本身缺失 | 【未核实】 |
| WSLg GUI 显示 / 性能 | 可用但**只能软件渲染 + copy 模式** | `wslg#143` 原文：*"Qualcomm platform don't have vGPU driver available, resulting in all WSLg graphics running in copy mode"*，**1440p 视频播放烧 50% CPU**；`#303`（open）arm64 刷新率低 | 【已核实：显示可用】；性能为【社区报告】 |
| **历史成功记录（同 SoC）** | ⚠️ **曾可用** | `microsoft/WSL#9154` 评论（**2023-06-29**，作者 `mannkeithc`）：Microsoft Dev Kit 2023（**同为 Snapdragon 8cx Gen 3**）在 2023-06-28 固件更新后，`glxinfo -B` 报 **`Device: D3D12 (Qualcomm(R) Adreno(TM) 8cx Gen 3)`**、**Accelerated: Yes** | 【社区报告】 |
| **回归点** | ⚠️ 2025-08 起大量报告坏掉 | `microsoft/WSL#13370`（open，2025-08-10 / 2026-05-17）：**WSL 2.5.9 → 2.5.10 之后 ARM64（Surface Pro 11）GPU 加速丢失**，`GALLIUM_DRIVER` 不再被自动设置；**同一报告者称 x64 机器未受影响**。该版本 release note 仅记一条 CVE 修复、**无 GPU 相关条目** ⇒ 疑似**无意回归** | 【社区报告】 |

相关未修 issue：`microsoft/WSL` **#14033**（open，OpenGL 硬件加速损坏并影响整个 Windows）、
**#12702**（open，2.5.1 breaks `/dev/dri` detection）。【已核实：issue 存活状态】

### 4.2 证据链与不确定性（必须一起读）

- **失败证据是"当前状态"，成功证据是"三年前的同 SoC"**：`#1470` 与 `#13370` 都是 open 的进行时报告，
  而 `#9154` 的成功发生在 2023-06-29 ⇒ **同一 SoC 曾可用、现在坏了**，这是本结论最关键的张力。
- **`/dev/dxg` 与用户态库在位，并不等于拿到 render 节点**：内核侧 `dxgkrnl` **没有创建**
  `/dev/dri/renderD128`，Mesa 只能回落 llvmpipe ⇒ 判断 GPU 是否可用**不能看文件是否存在**，只能看渲染节点
  与 `glxinfo -B` 的实际后端。**"驱动版本够了就行"也不成立**：`#1470` 的评论里有人明确报告用 **WDDM 3.1**
  驱动仍无 `/dev/dri`，机制尚未查清。【社区报告】
- 【推测】根因是 WSL 侧回归 + 厂商驱动/固件组合叠加，不是单一因素；反面对照是**本项目在裸机 Linux 侧
  已有 Turnip / venus 的成功经验**（见 [`video-decode.md`](video-decode.md)、[`gpu-telemetry.md`](gpu-telemetry.md)）
  ⇒ **硬件本身没问题，问题在 WSL 的虚拟化通路**。⇒ **一切图形结论都是条件性的**：GK-W76 真机探针
  （§8 第 1 项）跑完之前，本节每一条都不能外推到目标机。

### 4.3 对工作包 (d) 的直接含义

- **WSLg ARM64 能显示、可日常用**，但那是**软件渲染 + copy 模式** ⇒ **不能当 GPU 加速环境**，也不能用它
  评估这台机器的图形能力；Waydroid 在无 `/dev/dri` 时同样退化到 SwiftShader / 软件渲染。
- 【推测】ARM64 上 GUI 负载因软件渲染更耗 CPU，这与工作包 (c) 的省电目标直接冲突。

---

## 5. ★ 被连坐否决的一整类方案（嵌套虚拟化缺失）

- **ARM64 无嵌套虚拟化**【已核实：`microsoft/WSL#13796`】⇒ WSL2 内**没有 `/dev/kvm`**；
  **Windows 上的 Hyper-V 虚拟机也不能在 ARM64 客户机里再嵌套**。
- **AVD 出局**【已核实：Android Studio 官方系统需求原文 "Windows machines with ARM-based CPUs aren't
  currently supported."】。
- **redroid / crosvm / docker-android 出局**【已核实】：三者都依赖 **binder + KVM**；redroid README 虽自称
  *"redroid supports both arm64 and amd64 architectures"*，但那说的是**客户机镜像架构**，宿主仍需 `/dev/kvm`。
- **WSL2 + Waydroid 不被连坐**【已核实】：Waydroid 是 LXC 型容器、**不需要 KVM**；它卡在 binder 模块
  与 `/mnt/wslg` 挂载冲突（见 §6.2）。

⇒ ARM64 上"要虚拟化的 Android"全部否决，剩下的只有**容器型**（Waydroid）与
**微软自家虚拟化运行时**（WSA 系，已 EOL 或转社区维护）两条。

---

## 6. Android 三条路线逐条评估

### 6.1 ① WSABuilds（社区 WSA 魔改，arm64）

| 维度 | 事实 | 置信度 |
|---|---|---|
| 活跃度 | arm64 release `Windows_11_2407.40000.4.0_LTS_8_arm64`（Android 13 + GApps + Magisk），**published 2026-09-04** | 【已核实：release 元数据】 |
| 安装前提 | Windows 11 **arm64**；**必须先完全卸载官方 WSA**；管理员 PowerShell 跑 `Install.ps1`；**安装目录不能删** | 【已核实：安装手册】 |
| 图形 | WSA 自带 vGPU 通路（与 WSL2 不同），理论上能拿到 GPU 直通 ⇒ **性能最好的一条** | 【推测，需实测】 |
| 稳定性与上游 | GApps 构建**自 2025-06 起在所有 Windows 11 build 上崩溃**（主 issue `#593` **open**，2025-07-13 / 2026-09-09，**272 条评论**）；**workaround = 改用 `NoGApps` 构建，或回退到 2211 / 2210**；上游 `MagiskOnWSALocal` 已停更（末次提交 **2025-09-20**）；`microsoft/WSA` 仓库 **archived** | 【已核实：issue 与 README】 |
| 许可与安全 | **AGPL-3.0** + 文档 **CC-BY-NC-ND**，但捆绑的 WSA 二进制来自微软且已 EOL ⇒ 再分发合法性存疑；带 root（Magisk）+ 长期无上游补丁，且微软官方 WSA 文档写明 Windows 内核态驱动与中完整性应用**可以检视 Android 容器与 App 内存** ⇒ **不要在里面登录银行 / 主力账号** | 【已核实：仓库许可与官方文档原文】 |

⇒ **结论**：**可用，但不可长期依赖、不可公开分发**。
可行窗口是"现在装一次、只跑不需要账号信任的 App、视为易碎品"。

### 6.2 ② WSL2 + Waydroid

| 维度 | 事实 | 置信度 |
|---|---|---|
| 技术可行性 | issue 原文已核实；**可行性为【推测】**，依据 `waydroid/waydroid#1561`（2025-08-30 答复，给出所需 CONFIG）与 `microsoft/WSL#12601` 的答复（原文 *"Works with 6.6. self-built kernel as per guidelines"*，只证明有人用自建 6.6 内核跑通） | 【推测】（issue 原文【已核实】） |
| 所需内核配置 | `CONFIG_ANDROID_BINDER_IPC=y`、`CONFIG_ANDROID_BINDERFS=y`、`CONFIG_ANDROID_BINDER_DEVICES="binder,hwbinder,vndbinder"`；`CONFIG_ASHMEM=y`【推测：原报告注明新内核可改用 memfd 替代】；`CONFIG_ANDROID_BINDER_IPC_32BIT`【按需，未核实】 | 三条 `CONFIG_ANDROID_BINDER_*` 为【已核实】；其余为【推测】/【按需，未核实】 |
| 最大坑 | **binder 做成模块就需要模块盘**；stock WSL 内核**不含这些模块**，`modprobe binder_linux` 必失败 | 【已核实：`#712`/`#801`/`#1544`】 |
| 上游态度与 LXC 冲突 | `#712` 以 **not planned** 关闭（维护者原话 *"can't force Microsoft to add those modules"*）；`#1217`（open）报 `lxc-start: … lxc_mkdir_p: 236 Read-only file system - Failed to create directory "/usr/lib/x86_64-linux-gnu/lxc/rootfs/mnt/wslg/"`（再往下是 `…/rootfs/mnt/wslg/runtime-dir/wayland-0`；arm64 上该前缀为 `aarch64-linux-gnu`）⇒ **容器起不来** | 【已核实：issue 原文】 |
| 图形 | 无 `/dev/dri` ⇒ 退化到 SwiftShader / 软件渲染 | 【社区报告】 |

另需注意：`CONFIG_LOCALVERSION_AUTO` 必须关闭并在构建时移开 `.git`（本项目在 Linux 侧已踩过同一坑）。

⇒ **结论**：三重负担（自建内核 + LXC 挂载冲突 + 无 GPU）叠加，**不建议为它投入主线资源**。
**检查点**：若真机探针证明 WSL2 的 `/dev/dri` 可用，本路线的性价比会显著上升，值得回头看。

### 6.3 ③ 本机 Linux 分区跑 Waydroid（`dragon-waydroid`）

- **性能**：原生 arm64 + **真 GPU（Turnip）** + `v4l2m2m` 硬解；`dragon-waydroid` 是
  **LineageOS 23.2 / Android 16 QPR2**，明确带 `v4l2m2m`。【已核实：项目内资产索引】
- **许可**：全部开源组件，最干净；**代价**：需要原生 Linux 启动 ⇒ **与"全盘 Windows"目标直接互斥**。
- **【未核实】**：`dragon-waydroid` 对 SC8280XP 笔记本机型（`gaokun3`）的实际支持面需查其 releases/设备列表
  并与本项目 `patches/` 对比。本条（含上面"带 `v4l2m2m`"的判断）依据的是**本项目的内部台账**，
  属**项目内依据、不作为对外来源**。

⇒ **结论**：技术上与许可上都是最优解；是否选用取决于用户对"Linux 分区去留"的最终决定。

---

## 7. 许可、安全与功耗边界

### 7.1 许可与分发

- **改过的 Windows 镜像不能公开分发**（Windows EULA）；`Drv/` 厂商驱动也不可入库。【已核实：与主报告 §3 一致】
- **WSL 组件本身**：微软工程回应（`microsoft/WSL#4837`，`craigloewen-msft`）原文 *"WSL is part of Windows and
  covered by the Microsoft Windows EULA (just like any other Windows component). Products from the Microsoft
  store (like WSL distros) are governed by the licenses of those respective products."* ⇒ **WSL 不能单独再分发**。
  【已核实：issue 原文】
- **Ubuntu WSL rootfs 的再分发条款**：官方条款原文**本轮未取到** ⇒ **【未核实】**，**不得引用、不得据以分发**；
  需逐发行版查证 Canonical 的镜像再分发政策。【未核实】
- **WSABuilds**：见 §6.1 —— AGPL-3.0 + CC-BY-NC-ND，但 WSA 二进制已 EOL，**只本地自用**。【已核实】

⇒ **可公开交付的只有脚本与配置**：`unattend.xml`、DISM/winget 清单、`.wslconfig` / `wsl.conf`、驱动注入脚本、
自建内核的构建脚本与补丁 —— **不含任何原厂 / 厂商二进制**。这与主报告 §3 的发布红线一致。

### 7.2 Secure Boot / 内存完整性（HVCI）

- **WSL2 依赖 Hyper-V 虚拟化平台，与 Secure Boot、VBS/HVCI 兼容**（HVCI 与 Hyper-V 同源，非互斥）。【推测，基于架构；
  未见 arm64 专属反例；**建议真机验证**】
- **本节没有权威结论**：本轮**未核实到"WSL2 与 Memory Integrity 冲突"的权威结论** ⇒ 该说法**【未核实】**，
  不得当作事实引用，也不得据此建议关闭内存完整性。
- **HVCI / 驱动阻止列表可能拦第三方未签名驱动** —— 与 WSL 无关，但会影响本项目后续注入自编驱动的路线。
  本项目纪律在 Windows 侧同样适用：不动 Secure Boot 状态、不动原厂引导配置。

### 7.3 功耗与待机

| 观测 | 结论 | 置信度 |
|---|---|---|
| `vmIdleTimeout` | 默认 **60000 ms**：VM 空闲 60 s 后自动关闭 ⇒ **"WSL2 常驻"本身不会自动持续耗电**，除非有进程持续活动或端口转发维持 | 【已核实：官方 `.wslconfig` 文档】 |
| "睡着还在跑" | `microsoft/WSL#13291`（**closed as completed**，2025-07-26 创建 / 2025-07-30 关闭，最后更新 2026-08-30）：`vmIdleTimeout=-1` 下 Ollama / SSHD 等服务仍被挂起 ⇒ 属配置 / 行为差异 | 【社区报告】 |
| **本机（GK-W76）** | 本项目在 Linux 侧已量到"表面挂起、实际整夜空转 ≈2 W ⇒ 掉电 70%"的教训 ⇒ **Windows 侧必须同样实测**（`powercfg /sleepstudy`、`/batteryreport`、`vmIdleTimeout` 对照 A/B）。ARM64 上 GPU 走 llvmpipe，GUI 负载更耗电【推测】 | 【未核实】 |

---

## 8. 未核实清单（必须在真机上验证后才可下结论）

| # | 未核实项 | 建议的验证方法 |
|:-:|---|---|
| **1** | ★ **GK-W76（8cx Gen 3 / Adreno 690）在 WSL2 里能否拿到 `/dev/dri/renderD128`** —— **这一项决定"WSL2 + Waydroid 值不值得投入"** | 四条**只读**探针：`ls -l /dev/dri/`、`glxinfo -B`、`GALLIUM_DRIVER=d3d12 glxinfo -B`、`vulkaninfo`；同时记录 WSL 版本与 Qualcomm Windows 驱动版本 / WDDM 等级 |
| 2 | OpenCL / DirectML / NPU（QNN）在 ARM64 WSL2 的可用性 | `clinfo`；`pip install torch-directml` 是否有 arm64 wheel；ONNX Runtime 的 QNN EP 走 Windows 宿主而非 WSL |
| 3 | WSL2 在 ARM64 上对 Modern Standby / 续航的实际影响 | 电池供电 + `powercfg /sleepstudy` + `vmIdleTimeout` 对照 A/B |
| 4 | Waydroid-in-WSL2 的 `/mnt/wslg` 只读挂载冲突是否有可用解法 | 试 `guiApplications=false`、自定义 LXC 配置、tmpfs 覆盖 |
| 5 | WSABuilds arm64 在 GK-W76 上的实际表现（GPU 是否真直通、GApps 是否崩） | 装一次、跑 §6.1 的 workaround、测 `dumpsys SurfaceFlinger` |
| 6 | Ubuntu WSL rootfs 的再分发条款原文 | 查 Canonical 的 WSL / 镜像再分发政策（本轮未取到原文） |
| 7 | `wsl --install --no-launch` 在当前 Windows 11 ARM64 上的逐字行为 | `wsl --install --help` 对照 + 实机试跑 |
| 8 | GK-W76 的 Secure Boot / 内存完整性当前状态与 WSL2 的相容性 | `Confirm-SecureBootUEFI`；`Get-CimInstance Win32_DeviceGuard`；开启 HVCI 后 `wsl --version` |
| 9 | `dragon-waydroid` 对 SC8280XP 笔记本机型（`gaokun3`）的实际支持面；Genymotion / 云手机是否有 arm64 Windows 宿主 | 读该项目 releases / 设备列表并与本项目 `patches/` 对比；官方支持矩阵 |
| 10 | 原厂 Windows 恢复镜像对 `unattend.xml` 注入的接受度 | 与本项目 `Recovery/` 资产对照 |

---

## 9. 来源

**微软与 Android 官方**

Windows Subsystem for Android（EOL 说明，last updated 2025-03-05）— <https://learn.microsoft.com/en-us/previous-versions/windows/android/wsa/>

Install WSL（离线安装 / `--web-download`，last updated 2025-08-06）— <https://learn.microsoft.com/en-us/windows/wsl/install>

WSL 高级配置（`wsl.conf` / `.wslconfig` 全字段，last updated 2026-04-15）— <https://learn.microsoft.com/en-us/windows/wsl/wsl-config>

Import any Linux distribution（`wsl --import`）— <https://learn.microsoft.com/en-us/windows/wsl/use-custom-distro>

Microsoft Linux kernel v6 on WSL2（自建内核 + `kernel=`）— <https://learn.microsoft.com/en-us/community/content/wsl-user-msft-kernel-v6>

Microsoft Docs `MicrosoftDocs/WSL`，路径 `WSL/tutorials/gpu-compute.md`（`ms.date 2024-11-19`，**只覆盖 x86-64、全文无 arm64 字样**）— <https://raw.githubusercontent.com/MicrosoftDocs/WSL/main/WSL/tutorials/gpu-compute.md>

Android Studio 系统需求 — <https://developer.android.com/studio/install>

Android 模拟器硬件加速（Supported processors 仅 Intel / AMD / Apple silicon）— <https://developer.android.com/studio/run/emulator-acceleration>

Amazon：Appstore on Windows 11 to be discontinued（2024-03-05 公告 / 2025-03-05 终止）— <https://developer.amazon.com/apps-and-games/appstore-on-windows-11>

**GitHub issue / PR**（存活状态与日期按 API 元数据核验）

`microsoft/wslg` **#1470**（open，2026-06-13 / 2026-09-08）ARM64 Adreno 无 `/dev/dri/renderD128` — <https://github.com/microsoft/wslg/issues/1470>

`microsoft/wslg` **#143**（open）Qualcomm 缺 vGPU 驱动、copy 模式、1440p 烧 50% CPU — <https://github.com/microsoft/wslg/issues/143>

`microsoft/wslg` **#303**（open）arm64 RDP 刷新率低 — <https://github.com/microsoft/wslg/issues/303>

`microsoft/WSL` **#13370**（open，2025-08-10 / 2026-05-17）2.5.9 → 2.5.10 打断 ARM64 GPU 加速 — <https://github.com/microsoft/WSL/issues/13370>

`microsoft/WSL` **#9154**（2022-11 创建 / closed 2024-07）8cx Gen 3 曾成功硬件加速（2023-06-29 评论）— <https://github.com/microsoft/WSL/issues/9154>

`microsoft/WSL` **#13796**（closed，2025-11-28 创建 / 2025-12-04 关闭）ARM64 无嵌套虚拟化 — <https://github.com/microsoft/WSL/issues/13796>

`microsoft/WSL` **#12601**（open，2025-02-18 创建 / 2025-10-12 更新）*"Works with 6.6. self-built kernel"* — <https://github.com/microsoft/WSL/issues/12601>

`microsoft/WSL` **#14033**（open，2026-01-07 创建 / 2026-07-17 更新）OpenGL 硬件加速损坏并影响整个 Windows — <https://github.com/microsoft/WSL/issues/14033>

`microsoft/WSL` **#12702**（open，2025-03-16 创建 / 2026-03-13 更新）2.5.1 breaks `/dev/dri` detection — <https://github.com/microsoft/WSL/issues/12702>

`microsoft/WSL` **#13291**（closed as completed，2025-07-26 创建 / 2025-07-30 关闭 / 2026-08-30 最后更新）`vmIdleTimeout=-1` 下服务仍被挂起 — <https://github.com/microsoft/WSL/issues/13291>

`microsoft/WSL` **#4837**（closed，2020-01-22 创建 / 同日关闭）WSL 的 EULA 归属（`craigloewen-msft` 答复）— <https://github.com/microsoft/WSL/issues/4837>

`microsoft/WSL` **#13671**（open，2025-11-04 创建 / 2025-11-24 更新）WSL2 能否为 Android 模拟器提供 GPU 加速 — <https://github.com/microsoft/WSL/issues/13671>

`waydroid/waydroid` **#712**（closed as not planned，2023-01-24 创建 / 同日关闭）、**#1561**（open，2024-09-10 创建 / 2026-05-17 更新；答复 2025-08-30，给出所需 CONFIG）、**#1217**（open，2023-12-24 创建 / 2025-02-23 更新）、**#801**（open，2023-03-11 创建 / 2026-01-10 更新）、**#1544**（open，2024-08-31 创建 / 2024-09-27 更新）、**#590**（状态与日期【未核实】）— 见 <https://github.com/waydroid/waydroid/issues>

`remote-android/redroid-doc`（README）— <https://github.com/remote-android/redroid-doc>

`microsoft/WSL` releases（最新 2.9.12 / 2026-09-14，LTS 线 2.7.14 / 2026-09-11）— <https://github.com/microsoft/WSL/releases>

**社区 WSA 魔改**

`MustardChef/WSABuilds` **#593**（open，2025-07-13 / 2026-09-09，272 条评论）GApps 构建崩溃 — <https://github.com/MustardChef/WSABuilds/issues/593>

WSABuilds 安装手册（须先卸载官方 WSA、`Install.ps1`、安装目录不能删）— <https://raw.githubusercontent.com/MustardChef/WSABuilds/master/Documentation/WSABuilds/Installation.md>

`MustardChef/WSABuilds` releases（arm64 release `Windows_11_2407.40000.4.0_LTS_8_arm64`，published 2026-09-04）— <https://github.com/MustardChef/WSABuilds/releases>

`LSPosed/MagiskOnWSALocal`（末次提交 2025-09-20）— <https://github.com/LSPosed/MagiskOnWSALocal>

`microsoft/WSA`（仓库 **archived**）— <https://github.com/microsoft/WSA>

**项目内依据**（不作为对外来源）

**本轮只做调研：未安装、未下载、未改动目标机任何内容。**

本文未读取目标机，未执行任何安装或下载；GPU / 硬解的裸机对照见
[`video-decode.md`](video-decode.md) 与 [`gpu-telemetry.md`](gpu-telemetry.md)。
