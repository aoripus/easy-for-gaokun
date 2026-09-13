# Windows `qcdxkm8280.sys` 视频核（IRIS/Venus，`Ved*`）上电寄存器写序列还原

- 目标文件：`/root/wdrv/qcdxkm8280.sys`（Windows ARM64 PE，3 329 656 B，ImageBase `0x140000000`）
- 反汇编：`/root/wdrv/qcdx.dis`（`objdump --no-show-raw-insn`，641 927 行，地址列含基址）
- 分析脚本：`/root/wdrv/scratch/`（`hwio.py` `resolve.py` `mmio2.py` `tree.py` `lit.py` `dump.py` `fstr.py` `strs.py`）
- 分析方式：**只读**。除 `scratch/` 下脚本外未修改虚拟机任何文件，未执行任何 git 命令，未编译任何东西。

---

## 1. 寄存器访问器（`VED_HWIO_OUT` / `VED_HWIO_IN`）的还原

### 1.1 结论先行

| 项 | 结论 | 置信度 |
|---|---|---|
| 定义位置 | `platformV1.c`（路径串 `Z:\b\WP\direct3d_kmd\rel\10.6\kmd\driver\vidLib\platform\ved_v1\platformV1.c`，VA `0x1403d7d70`） | 【已核实】 |
| 是否有可调用函数体 | **没有** —— 被**完全内联**到每个调用点 | 【已核实】 |
| 偏移→地址映射 | **直接线性相加**：`addr = 窗口基址(ctx[0x70F8] 或 ctx[0x7100]) + 偏移`，**不查表** | 【已核实】 |
| 合法性校验 | **纯范围检查**（对比 `ctx[0x7570]` / `ctx[0x7110]` / `ctx[0x7574]` 三个界），无偏移白名单、无查表 | 【已核实】 |
| 读/写是否同一函数 | **两个不同的内联函数**：`VED_HWIO_IN`（失败日志 `NON_FATAL:`）与 `VED_HWIO_OUT`（失败日志 `FATAL:` 并断言） | 【已核实】 |

### 1.2 日志串（三个不同 VA，说明是逐调用点内联）

| 串 | VA |
|---|---|
| `NON_FATAL:Invalid register offset in VED_HWIO_IN` | `0x140169948`（.text 内嵌常量区） |
| `NON_FATAL:Invalid register offset in VED_HWIO_IN 0x%.8x 0x%.8x \n` | `0x140169980` |
| `FATAL:Invalid register offset in VED_HWIO_OUT` | `0x1401699e0` |
| `FATAL:Invalid register offset in VED_HWIO_OUT 0x%.8x 0x%.8x \n` | `0x140169a10` |
| `NON_FATAL:Invalid register offset in VED_HWIO_IN`（PAGE 区副本） | `0x1403d66b8` |
| `NON_FATAL:Invalid register offset in VED_HWIO_IN 0x%.8x 0x%.8x \n` | `0x1403d66f0` |
| `FATAL:Invalid register offset in VED_HWIO_OUT`（PAGE 区副本，platformV1.c 用） | `0x1403d7e10` |
| `FATAL:Invalid register offset in VED_HWIO_OUT 0x%.8x 0x%.8x \n` | `0x1403d7e40` |

> 任务给的 RVA `0x1699e6` 对应 VA `0x1401699e6`，落在 `0x1401699e0` 这个串内部（串首偏移 +6），是同一份常量。

唯一存在的“独立日志包装”函数（罕见路径用，入参是指向 `{offset,value}` 的指针）：

| 函数 VA | 作用 | 调用者 |
|---|---|---|
| `0x140013438` | 打印 OUT 非法偏移 | `0x14001e0a4`、`0x14001e12c`、`0x14001e258`（均在 fn `0x14001dc30` 内） |
| `0x140013928` | 打印 IN 非法偏移 | `0x14030ab88`（fn `0x14030ab30` 内） |

### 1.3 内联形态（以 `fn 0x1400514c0` 的 `0xA0148` 写为例，地址 `0x1400516cc`–`0x140051728`）

```asm
0x1400516cc  mov  x8, #0x7570            ; ctx+0x7570 = 窗口1上限
0x1400516d0  ldr  w8, [x20, x8]
0x1400516d4  ldr  w10, 0x1400532bc       ; w10 = 0x000A0148（字面量池，偏移）
0x1400516d8  mov  x12, #0x7110           ; ctx+0x7110 = 窗口2起始设备偏移
0x1400516dc  cmp  w10, w8
0x1400516e0  b.cs 0x1400516f8            ; 偏移 >= 0x7570 -> 走窗口2判定
0x1400516e4  ldr  x8, [x20, #28920]      ; x8 = ctx[0x70F8] = 窗口1 映射 VA
0x1400516e8  mov  w11, #0x1              ; ← 待写入的值
0x1400516ec  add  x9, x8, #0xa0, lsl #12 ; x9 = base + 0xA0000（页对齐部分）
0x1400516f0  str  w11, [x9, #328]        ; *(base+0xA0000+0x148) = 1  → 0xA0148
0x1400516f4  b    0x1400517e8
0x1400516f8  ldr  w9, [x20, x12]         ; w9 = ctx[0x7110]
0x1400516fc  cmp  w10, w9
0x140051700  b.cc 0x14005172c            ; 偏移 < 0x7110 -> FATAL 非法偏移
0x140051704  mov  x13, #0x7574
0x140051708  ldr  w8, [x20, x13]
0x14005170c  cmp  w10, w8
0x140051710  b.cs 0x14005172c            ; 偏移 >= 0x7574 -> FATAL 非法偏移
0x140051714  ldr  x8, [x20, #28928]      ; x8 = ctx[0x7100] = 窗口2 映射 VA
0x140051718  mov  w11, #0x1
0x14005171c  sub  x9, x8, w9, uxtw       ; x9 = base2 - ctx[0x7110]
0x140051720  add  x10, x9, #0xa0, lsl #12
0x140051724  str  w11, [x10, #328]       ; *(base2 - 0x7110 + 0xA0148) = 1
0x140051728  b    0x1400517ec
0x14005172c  ... VED_ASSERT / FATAL:Invalid register offset in VED_HWIO_OUT (vedEngineUtils.c)
```

**等价 C 伪码**

```c
void VedHwIoOut(CTX *ctx, uint32_t off, uint32_t val) {
    if (off < ctx->w1_limit /*+0x7570*/) {
        *(uint32_t *)(ctx->w1_va /*+0x70F8*/ + off) = val;
    } else if (off >= ctx->w2_lo /*+0x7110*/ && off < ctx->w2_limit /*+0x7574*/) {
        *(uint32_t *)(ctx->w2_va /*+0x7100*/ - ctx->w2_lo + off) = val;
    } else {
        VED_ASSERT("FATAL:Invalid register offset in VED_HWIO_OUT 0x%.8x 0x%.8x", off, val);
    }
}
```

**关键的编译器细节**：偏移被拆成 `#(off>>12), lsl #12` 加 `#(off & 0xFFF)` 两条。因此**检索不能只找 `mov w1,#0xA0148`**，必须识别 `ldr wN,<字面量池>` / `add xN,xBase,#P,lsl #12` + `str wV,[xN,#I]` 这一族形态。（本报告的全部结论都由字面量池反查得到，见 §5.2。）

### 1.4 窗口（映射）设置函数：VA `0x14037a6d0`

```asm
0x14037a6e0  str  x10, [x0, #28920]        ; ctx[0x70F8] = arg[8]   <- 窗口1 VA（MmMapIoSpace 结果）
0x14037a6e8  str  w9,  [x0, x8]            ; ctx[0x7108] = arg[16]
0x14037a6ec  ldr  w8,  [x0, #0x61f0]       ; w8 = ctx[0x61F0] = chip family
             ; case 0x4F / 0x67 / 0x57 / 0x71 / 0x76:
0x14037a744  str  x10, [x0, #28928]        ; ctx[0x7100] = 同一基址
0x14037a748  mov  w8, #0x200000
0x14037a754  str  w8,  [x0, x10]           ; ctx[0x7574] = 0x200000
0x14037a75c  str  w8,  [x0, x11]           ; ctx[0x7570] = 0x200000
0x14037a758  mov  w10, #0x0
             ; default:
0x14037a728  str  x8,  [x0, #28928]        ; ctx[0x7100] = arg[64]
0x14037a734  str  w8,  [x0, x10]           ; ctx[0x7570] = lit[0x14037a778] = 0x00084000
0x14037a738  str  w12, [x0, x11]           ; ctx[0x7574] = 0x100000
0x14037a73c  sub  w10, w12, w9             ; w10 = 0x100000 - arg[72]
0x14037a768  str  w9,  [x0, x8]            ; ctx[0x710C] = w9
0x14037a76c  str  w10, [x0, x11]           ; ctx[0x7110] = w10
```

即：**对 chip family ∈ {0x4F, 0x67, 0x57, 0x71, 0x76}，整块设备寄存器空间用单个 2 MB 映射，偏移就是设备绝对偏移**；其余 family 用「0x84000 窗口 + 1 MB 顶部第二窗口」。

---

## 2. ★ `VedInitVideoCore` 的寄存器访问有序清单

- 函数范围：`0x140388a08` – `0x14038a7e0`，`.pdata` FunctionLength = `0x1DD8`【已核实】
- 函数身份确认：函数内引用日志串 `0x1403dc2c8 "VedInitVideoCore:ePowerTransType"`、`0x1403dced8 "Done:VedInitVideoCore:ePowerTransType"`【已核实】

### 2.0 关于两套偏移的**强制说明**（先读）

被调用点内联的访问器里，**同一逻辑寄存器给出两个字面量偏移，用 `csel` 依 `ctx[0x7114] == 6` 二选一**：

```asm
0x1403879b0  mov  x8, #0x7114
0x1403879b4  ldr  w8, [x19, x8]        ; w8 = ctx[0x7114] = nPlatformConfig/HW 版本
0x1403879b8  ldr  w10, 0x1403882f8     ; 0x000D205C
0x1403879bc  ldr  w9,  0x1403882fc     ; 0x000A005C
0x1403879c8  cmp  w8, #0x6
0x1403879d4  csel w11, w10, w9, ne     ; w11 = (ctx[0x7114]!=6) ? 0xD205C : 0xA005C
```

**两套地址图（同一逻辑寄存器的两个设备偏移）**

| 逻辑寄存器（Linux 参考名） | `ctx[0x7114]==6`（主图） | `ctx[0x7114]!=6`（备图） |
|---|---|---|
| CTRL_INIT | `0xA0048` | `0xD2048` |
| CTRL_STATUS | `0xA004C` | `0xD204C` |
| QTBL_INFO | `0xA0050` | `0xD2050` |
| QTBL_ADDR | `0xA0054` | `0xD2054` |
| SFR_ADDR | `0xA005C` | `0xD205C` |
| （0xA0060） | `0xA0060` | `0xD2060` |
| UC_REGION_ADDR | `0xA0064` | `0xD2064` |
| UC_REGION_SIZE | `0xA0068` | `0xD2068` |
| A2HSOFTINTCLR | `0xA001C` | `0xD201C` |
| WRAPPER_INTR_STATUS | `0xB000C` | `0xE000C` |
| WRAPPER_INTR_MASK | `0xB0010` | `0xE0010` |
| （0xB0014） | `0xB0014` | `0xE0014` |
| TZ 块（0xC0010） | `0xC0010` | `0xE2014` |

`ctx[0x7114]` 的赋值在 **`vedInitPlatformConfigs`（fn `0x14037b830`）** 里按 `ctx[0x615C]`（SoC/chip ID）分支：

| chip ID | 写入 `ctx[0x7114]` | 站点 |
|---|---|---|
| `0x60100000`、`0x60400000` | **6** | `0x14037ba6c` / `0x14037ba74` |
| `0x40440000`（第一分支） | 4 | `0x14037c080` / `0x14037c084` |
| `0x50100000` | 来自寄存器（`w4`） | `0x14037bd64` / `0x14037bd6c` |

同时该函数把 **`ctx[0x7138]`（= `WRAPPER_INTR_MASK` 的写入值来源）默认置为 `0x1F`**：`0x14037b8d4 str w8,[x20,x6]`，`w8=0x1f`，`x6=0x7138`【已核实】。

> ⚠️ **未能 100% 确定**：SC8280XP 上报的 chip ID 到底是 `0x60100000` 还是 `0x60400000`（两者都→6）。二进制里没有 SoC 名字串可交叉验证（只有 `qcdxkm8280.pdb` 路径串和 `QTimer freq 8280`）。**但两支都落在 `0x60100000`/`0x60400000` 上，且备图偏移恰好是 Linux 从不使用的 `0xD2xxx`**，因此下表的「主图」列即为本机实际生效值（若 chip ID 判定有误，请整体替换为备图列）。
> 另需注意 §2.3 中一批**不走 csel、直接用绝对偏移**的写（`0xDF018`、`0xE0090`、`0xE0110`、`0xE0044`、`0xE2000/8/C/10`、`0x8019C`、`0xB0080/84/88`、`0xE0018/1C`），它们说明该 SoC 上 2 MB 单窗口内这些块**同时真实存在**。

### 2.1 清单（按执行顺序，B = 分支，★ = 我们已知 Linux 会写的锚点）

| # | 指令地址 | 方向 | 寄存器偏移 | 写入值 | 值的来源 |
|:-:|---|---|---|---|---|
| **`VedInitVideoCore` 本体（直接写 1 处）** |
| 1 | `0x140389824`（窗口A）/ `0x140389b40`（窗口B） | W | ★`0xB0010` / `0xE0010`（WRAPPER_INTR_MASK） | `ctx[0x7138]` | 运行时常量：`vedInitPlatformConfigs` @`0x14037b8d4` 默认写 `0x1F`；本处先 `str w4,[x22,#0x5944]` 复制到 `ctx[0x5944]`（`0x1403897b0`）再读回写入。日志串 `0x1403dc838 "Set Venus nIntrMask"`（引用点 `0x1403897d0`）【已核实】 |
| **子函数：`0x140392308` = `VedSetMVPCoreGDSCPowerON`（调用点 `0x140389dc4`）** |
| 2 | `0x14039238c` / `0x1403923b8` | W | `0xB0084`（CORE_POWER_CONTROL） | `0` | 立即数 `wzr`【已核实】 |
| 3 | `0x1403924ac`/`0x1403924e0`，`0x1403926b4`/`0x1403926e8` | R | ★`0xB0080`（CORE_POWER_STATUS） | — | 轮询；失败串 `0x1403925f8 "Core is not Power ON and timed out"`【已核实】 |
| **子函数：`0x140387540` = `VedPilLoadAndReset`（调用点 `0x140389fc0`）** |
| — | — | — | **无 MMIO** | — | 只做 TZ IOCTL：`0x140388328` = `VedPilLoad`（`Calling IOCTL_PIL_TZ_LOAD_IMAGE`），再经 `[ctx+0x7AD8]` 调 `IOCTL_PIL_TZ_AUTH_IMAGE_AND_RESET`【已核实】 |
| **子函数：`0x140387770` = `VedHfiReset`（调用点 `0x14038a16c`）** |
| 4 | `0x1403949d4` | W | ★`0xA0054` / `0xD2054`（QTBL_ADDR） | `ctx[0x12C]`（300） | `mem[x19+#300]` 运行时值【已核实】 |
| 5 | `0x140394af0` | W | ★`0xA0050` / `0xD2050`（QTBL_INFO） | `1` | 立即数【已核实】 |
| 6 | `0x1403879f0` | W | ★`0xA005C` / `0xD205C`（SFR_ADDR） | `ctx[0x194]`（404） | 运行时值【已核实】 |
| 7 | `0x140387b14` | W | `0xA0060` / `0xD2060` | `ctx[0x1A4]`（420） | 运行时值【已核实】 |
| 8 | `0x140387c44`（窗口A）/ `0x140387c80`（窗口B） | W | ★`0xA0064` / `0xD2064`（UC_REGION_ADDR） | `(ctx[0xB8]->[36] + ctx[0xB8]->[40]) - 0x01000000` | 代码序列（`0x140387c30`–`0x140387c44`）：`x8=ctx[184]`；`ldp w8,w9,[x8,#36]`；`add w9,w9,w8`；`w21=0x1000000`；`sub w11,w9,w21`；`str w11,[x10,w12,uxtw]`。两个 32 位字段来自 `ctx[0xB8]` 指向的结构体，静态不可解【出处已核实、数值运行期决定】 |
| 9 | `0x140387d78` | W | ★`0xA0068` / `0xD2068`（UC_REGION_SIZE） | `0x01000000` | 立即数【已核实】 |
| 10 | `0x140387de4`（并见 `0x140387e0c` 窗口B、`0x140387efc`） | W | ★`0xA0048` / `0xD2048`（CTRL_INIT） | `1` | 立即数；日志串 `0x1403dc038 "Setting HFI_CTRL_INIT"`【已核实】 |
| 11 | `0x140388014`（窗口A）/ `0x140388054`（窗口B） | R | ★`0xA004C` / `0xD204C`（CTRL_STATUS） | — | 轮询；日志串 `0x1403dc050 "Waiting for ctrlStatus"`【已核实】 |
| **子函数：`0x1403928b8` = `VedSetMVPCoreGDSCPowerOff`（调用点 `0x14038a320`；仅当 `w24 != 0x1003`）** |
| 12 | `0x140392940` / `0x140392970` | W | `0xB0084` | `1` | 立即数【已核实】 |
| 13 | `0x140392a64`/`0x140392a98`，`0x140392c6c`/`0x140392ca0` | R | ★`0xB0080` | — | 轮询；失败串 `0x140392bb0 "Core is not Power Off and timed out"`【已核实】 |
| **子函数：`0x140386380` = `VedHfiSysInit`（调用点 `0x14038a41c`）** |
| 14 | `0x14038645c`/`0x140386488`、`0x140386a48`/`0x140386a80`、`0x140386d8c`/`0x140386e8c` | W | `0xDF018` | `0x8000` | 立即数（共 3 轮，每轮 2 个窗口路径）【已核实】 |
| 15 | `0x1403864fc`/`0x140386528`、`0x140386b04`/`0x140386b38`、`0x140386f10`/`0x140386f44` | W | ★`0xA0148`（H2XSOFTINTEN） | `1` | 立即数【已核实】 |
| 16 | `0x140386614`/`0x140386640`、`0x140386c18`/`0x140386c44`、`0x140387034`/`0x140387060` | W | `0xA0150` | `1` | 立即数【已核实】 |
| **子函数：`0x140391c90` = `VedSetUBWCConfig`（调用点 `0x14038a514`；仅当 `ctx[0x7664]==1`）** |
| 17 | `0x140391f54`/`0x140391f8c` | W | `0xDF018` | `0x8000` | 立即数【已核实】 |
| 18 | `0x140392010`/`0x14039203c` | W | ★`0xA0148` | `1` | 立即数【已核实】 |
| 19 | `0x14039211c`/`0x140392148` | W | `0xA0150` | `1` | 立即数【已核实】 |
| **子函数：`0x140390798` = `VedCheckAndEnableFWFeatures`（调用点 `0x14038a5e0`；仅当 `ctx[0x6240]` bit24）** |
| 20 | `0x1403908b0`/`0x1403908e8` | W | `0xDF018` | `0x8000` | 立即数【已核实】 |
| 21 | `0x140390994`/`0x1403909c0` | W | ★`0xA0148` | `1` | 立即数【已核实】 |
| 22 | `0x140390aa4`/`0x140390ad0` | W | `0xA0150` | `1` | 立即数【已核实】 |
| **子函数：`0x14038ec88` = `VedCheckAndEnablePowerPlane`（调用点 `0x14038a6cc`；仅当 `w24 ∈ {0x1000,0x1001,0x1004}` 且 `ctx[0x7598]` bit3）** |
| 23 | `0x14038ed18`、`0x14038f550` | R | `0xE0090` | — | Power-Plane 状态【已核实】 |
| 24 | `0x14038ef2c`、`0x14038f66c` | R | `0xE0110` | — | Power-Plane 状态【已核实】 |
| 25 | `0x14038f2a0`、`0x14038f9b4` | W | ★`0xA0148` | `1` | 立即数【已核实】 |
| 26 | `0x14038fc00` | R | `0xE0044` | — | 【已核实】 |
| 27 | `0x14038fe84`/`0x14038feb4` | W | `0xDF018` | `0x8000` | 立即数【已核实】 |
| 28 | `0x14038ff9c`/`0x14038ffc8` | W | ★`0xA0148` | `1` | 立即数【已核实】 |
| 29 | `0x1403901d8`/`0x140390208` | R | ★`0xB0080` | — | 【已核实】 |
| 30 | `0x1403904e4`/`0x140390510` | W | ★`0xA0148` | `1` | 立即数【已核实】 |
| 31 | `0x1403905f4`/`0x140390620` | W | `0xA0150` | `1` | 立即数【已核实】 |

### 2.2 锚点对照结果（针对任务给出的 Linux 已知写集）

| Linux 寄存器 | Windows 是否写 | Windows 站点与值 |
|---|---|---|
| `0xA0048` CTRL_INIT | **写** | `0x140387de4` = `1`（`VedHfiReset`） |
| `0xA004C` CTRL_STATUS | **读**（轮询） | `0x140388014` / `0x140388054` |
| `0xA0050` QTBL_INFO | **写** | `0x140394af0` = `1` |
| `0xA0054` QTBL_ADDR | **写** | `0x1403949d4` = `ctx[0x12C]` |
| `0xA0058` CPU_CS_SCIACMDARG3 | **未发现** | 二进制中不存在 `0x000A0058` 常量 |
| `0xA005C` SFR_ADDR | **写** | `0x1403879f0` = `ctx[0x194]` |
| `0xA0064` UC_REGION_ADDR | **写** | `0x140387c44` / `0x140387c80` |
| `0xA0068` UC_REGION_SIZE | **写** | `0x140387d78` = `0x01000000` |
| `0xA0148` H2XSOFTINTEN | **写**（大量） | = `1`，见 #15/#18/#21/#25/#28/#30 |
| `0xA0160` AHB_BRIDGE_SYNC_RESET | **未发现** | 无 `0x000A0160` 常量 |
| `0xA0168` X2RPMH | **写** | `0x14038d0d0`/`0x14038d108` = `3`（`VedDeInitVideoCore`，fn `0x14038a7e0`） |
| `0xA001C` A2HSOFTINTCLR | **写** | `0x14038c540`/`0x14038c570` = `1`；另见 `0x140043cbc`、`0x140044edc`、`0x14004e2f8` |
| `0xB000C` WRAPPER_INTR_STATUS | **读** | `0x1400433c8`、`0x140044610`、`0x14004dbd0` |
| `0xB0010` WRAPPER_INTR_MASK | **写**（`VedInitVideoCore`） | `0x140389824` = `ctx[0x7138]`（默认 `0x1F`） |
| `0xB0054` / `0xB005C` / `0xB0060` | **未发现** | 无对应常量 |
| `0xB0080` CORE_POWER_STATUS | **读** | 见 #3/#13/#29 |
| `0xB0088` CORE_CLOCK_CONFIG | **写** | `0x14037a910`/`0x14037a93c` = `0`（fn `0x14037a780`） |
| `0xC0010` TZ_CPU_STATUS | **读**（轮询 `A9SS_STANDBYWFI & PC_READY_STATUS`） | `0x14038b07c`（窗口A）/ `0x14038b0bc`（窗口B），在 `VedDeInitVideoCore` 内；对应的 `ldr w22,[x8,w10,uxtw]` 之后进入 `powerCollapse: waiting PC_READY_STATUS & A9SS_STANDBYWFI` 超时判定（串 `0x14038b2f8`/`0x14038b374`） |
| `0xC0014` / `0xC0018` | **未发现** | 无对应常量 |
| `0xE0000` / `0xE0004` | **未发现**（`0xE0000` 没作为常量出现） | — |
| `0xE0018` | **写** | `0x140379dcc` = `5`，`0x14037a000` = `0x55`（fn `0x140379d90` = `VedBusInitV1`） |
| `0xE0020` / `0xE002C` / `0xE0030` | **未发现** | — |
| `0xFF000` / `0xFF004` | **未发现** | 无对应常量 |

### 2.3 ★ Windows 写了、Linux 清单里**没有**的偏移（重点产出）

**A. 确认存在、且有明确出处、值得逐条核查的：**

| 偏移 | 值 | 站点 | 语义推断 |
|---|---|---|---|
| `0xDF018` | `0x8000` | `0x14038645c`（VedHfiSysInit）、`0x140391f54`（VedSetUBWCConfig）、`0x1403908b0`（FWFeatures）、`0x14038fe84`（PowerPlane）、`0x14038aa60`（DeInit） | AXI/VBIF 相关（相邻串：`Issue AXI HALT`、`FATAL:AXI halt failed`） |
| `0xA0150` | `1` | 与 `0xA0148` **成对**出现于 45 处函数（`0x140386614` 等） | H2X 中断使能第二寄存器；Linux 只写 `0xA0148` |
| `0xB0084` | `0`（power on）/`1`（power off） | `0x14039238c`、`0x140392940` | CORE_POWER_CONTROL（Linux 只读 `0xB0080`） |
| `0xE001C` | `5` | `0x140379ef8`/`0x140379f38` | wrapper 相关 |
| `0xE0014` | `0x1F` / 运行时 | `0x14038c470`/`0x14038c4a8`、`0x140043b8c`、`0x140044ae4`、`0x14004e1e8` | `0xB0014` 的备图对应物 |
| `0xE2000` / `0xE2008` / `0xE2010` / `0xE200C` | `0` / `0x10000` / `0` / 读 | `0x14037a9f4`、`0x14037a3ac`、`0x14037aafc`、`0x14037b56c`、`0x14038bbac` | 第二 IP 块（备图 `0xC0000` 段） |
| `0x8019C` | 运行时 | `0x14038c358`/`0x14038c38c`（VedDeInitVideoCore） | — |
| `0xD2114` | `orr w9,w8,lsl #18` | `0x14037c7f0`、`0x14037cc30` | SysCache「reg prog val」 |
| `0xD2118` | `0x3698` | `0x14037c94c`、`0x14037cd8c` | 同上 |
| `0xB0024` / `0xB0028` / `0xB0064` / `0xB0068` / `0xB006C` / `0xB0070` / `0xB01FC` | 运行时 | fn `0x14004d9a0`（`0x14004f0fc` … `0x14004f3c8`） | Reset/TDR 路径 |
| `0xA0D14` | 读 | `0x140052410` | — |

**B. 备图整组（若 §2.0 的 chip ID 判定相反，则这些就是本机实际使用值，而主图整组变成「Linux 独有」）：**
`0xD201C` `0xD2048` `0xD204C` `0xD2050` `0xD2054` `0xD205C` `0xD2060` `0xD2064` `0xD2068` `0xD2104` `0xE000C` `0xE0010` `0xE0014` `0xE2000` `0xE2008` `0xE200C` `0xE2010`（`0xE2014` 为 `0xC0010` 的备图对应物，但只被**读**）

**C. Linux 写了、Windows 完全没写的偏移（反向发现）：**
`0xA0058`、`0xA0160`、`0xB0054`、`0xB005C`、`0xB0060`、`0xC0014`、`0xC0018`、`0xE0000`、`0xE0004`、`0xE0020`、`0xE002C`、`0xE0030`、`0xFF000`、`0xFF004`
→ 这些在整个 3.3 MB 驱动里**没有任何字面量常量**，也没有任何 `str` 落在这些地址上。**若 Linux 真的写了它们，需要重新确认 Linux 侧的地址是否与硬件手册一致**（可能是 Linux 用了错误/过期的偏移）。

### 2.4 一个必须避开的陷阱（错误结论来源）

`VedCheckAndEnableFWFeatures`（`0x140390798`）里有一段：

```asm
0x140390d60  mov  x9, #0x7950
0x140390d6c  str  w8, [x0, x9]        ; ctx[0x7950]     <- 软件结构体，不是 MMIO
0x140390d78  str  w11,[x10, #44]      ; ctx[0x7950+44]
0x140390d7c  str  w11,[x10, #36]
0x140390d80  str  w11,[x10, #20]
0x140390d8c  str  w9, [x10, #8]
```

朴素扫描器（把 `x0` 误认为 MMIO 基址）会把它读成 `0xA002C`/`0xA0024`/`0xA0014`/`0xA0008` 等一连串「Windows 独有寄存器」。**这是假阳性**——`x0` 在此处是上下文指针，`+0x7950` 是软件字段。【已核实】

---

## 3. `VedInitVideoCore` 的 `bl` 子函数清单

### 3.1 函数身份表（用各函数自身引用的日志串确认）

| VA | 名称 | 依据（函数内引用的串 VA / 文本） | 该函数写的寄存器 |
|---|---|---|---|
| `0x140388a08` | **`VedInitVideoCore`** | `0x1403dc2c8` / `0x1403dced8` | `0xB0010`（=`ctx[0x7138]`） |
| `0x140387540` | **`VedPilLoadAndReset`** | `0x1403dbe28` `FATAL:VedPilLoad failed in VedPilLoadAndReset`；`0x1403dbe98` `IOCTL_PIL_TZ_AUTH_IMAGE_AND_RESET` | 无（TZ IOCTL） |
| `0x140388328` | **`VedPilLoad`** | `0x14038838c` `Calling IOCTL_PIL_TZ_LOAD_IMAGE`；`0x1403887b8` `IOCTL_PIL_TZ_LOAD_IMAGE failed in VedPilLoad` | 无 |
| `0x140387770` | **`VedHfiReset`** | `0x1403dbf38` `VedHfiInterfaceQueuesInit failed in VedHfiReset`；`0x1403dbfb8` `VedHfiMMApInit failed in VedHfiReset`；`0x1403dc028` `Initialize Core`；`0x1403dc038` `Setting HFI_CTRL_INIT`；`0x1403dc050` `Waiting for ctrlStatus` | §2.1 #4–#11 |
| `0x140394818` | **`VedHfiInterfaceQueuesInit`** | `0x14039486c` `Configuring HFI Interface Queues` | `0xA0054`=`ctx[0x12C]`、`0xA0050`=`1` |
| `0x140394c10` | **`VedHfiMMApInit`** | 由 `VedHfiReset` 的失败串推得（函数体内无独立名字串） | 未检出 |
| `0x140394cf8` | **`VedSysCacheActivate`** | `0x140394db8` `VedSysCacheActivate: slice ID , slice size`；来源文件 `VedSysCache.c` | 未检出 |
| `0x140058620` / `0x1400586e8` / `0x1400581c0` | **SysCache 门控 / `VedUpdateSyscacheStatus`** | 调用点返回值判定 + `0x1403dc8c0` `VedUpdateSyscacheStatus failed in VedInitVideoCore` | 未检出 |
| `0x140392308` | **`VedSetMVPCoreGDSCPowerON`** | 调用点失败串 `0x1403dc940`；函数内 `0x1403925f8` `Core is not Power ON and timed out`、`0x140392800` `Core Clock is not ON and timed out`；来源 `vedEngineUtils.c` | `0xB0084`←`0`，读 `0xB0080` |
| `0x1403928b8` | **`VedSetMVPCoreGDSCPowerOff`** | 调用点失败串 `0x1403dcc48`；函数内 `0x140392bb0` `Core is not Power Off and timed out`、`0x140392db8` `Core Clock is not Off and timed out` | `0xB0084`←`1`，读 `0xB0080` |
| `0x140386380` | **`VedHfiSysInit`** | `0x14038679c` `VedHfiSysCacheSet failed in VedHfiSysInit`；`0x14038684c` `HFI_CMD_SYS_INIT failed in VedHfiSysInit`；`0x140386948` `VedUpdateSyscacheStatus failed in VedHfiSysInit` | `0xDF018`=`0x8000`、`0xA0148`=`1`、`0xA0150`=`1` |
| `0x140391c90` | **`VedSetUBWCConfig`** | `0x140391d40` `VedSetUBWCConfig: Due to out of range setting default highestBankBit`；`0x140392258` `VedSetUBWCConfig: HFI_PROPERTY_SYS_UBWC_CONFIG failed` | `0xDF018`=`0x8000`、`0xA0148`=`1`、`0xA0150`=`1` |
| `0x140390798` | **`VedCheckAndEnableFWFeatures`** | `0x140390834` `VedCheckAndEnableFWFeatures: Sending HFI_CMD_SYS_SET_FEATURES`；`0x140390be8` `sending HFI command failed` | 同上 |
| `0x14038ec88` | **`VedCheckAndEnablePowerPlane`** | `0x14038ee68` `Core0 HW power plane Control not enabled`；`0x14038f050` `Venus Power Plane Status`；`0x14038f4ac` `HFI_CMD_SYS_SET_PROPERTY failed in VedCheckAndEnablePowerPlane` | `0xDF018`、`0xA0148`、`0xA0150`、读 `0xE0090`/`0xE0110`/`0xE0044`/`0xB0080` |
| `0x140002080` | 未定名（`bl` 一次，`0x140389688`） | — | 未检出 |
| `0x14038a7e0` | **`VedDeInitVideoCore`** | `0x14038a83c` `VedDeInitVideoCore:ePowerTransType`；`0x14038c01c` 等 | `0xA001C`←`1`、`0xA0168`←`3`、`0xE0014`←`0x1F`、`0xE2008`←`0x10000`、`0xE2000`←`0`、`0xE2010`←`0`、`0xD2104`←`7`、`0x8019C`（运行时）、`0xDF018`、`0xA0148`、`0xA0150`；**读** `0xC0010`/`0xE2014`（A9SS_STANDBYWFI 轮询）、`0xE0090`、`0xE0110`、`0xE0044`、`0xE200C`、`0xB0080` |

### 3.2 「上电/复位/时钟/PIL/GDSC/Boot」族的额外函数（不在 `VedInitVideoCore` 直接调用图上，但会写寄存器）

| VA | 名称 | 依据 | 寄存器写 |
|---|---|---|---|
| `0x140379d90` | **`VedBusInitV1`** | `0x14037a15c` `FATAL:VedBusInitV1 unhandled HW`；来源 `platformV1.c` | `0xE0018`←`5`、`0xE001C`←`5`、`0xE0018`←`0x55` |
| `0x14037a220` | **`VedBusDeInitV1`** | `0x14037a2a4` `FATAL:VedBusDeInitV1 unhandled HW`；`0x14037a368` `Issue AXI HALT`；`0x14037a61c` `AXI halt failed` | 读 `0xB0000`、`0xE2008`←`0x10000`、读 `0xE200C` |
| `0x14037a6d0` | 窗口/MmMap 装配（见 §1.4） | 函数体 | 只写 ctx 字段，不写 MMIO |
| `0x14037a780` | 时钟/第二块初始化（未定名） | `ctx[0x7118] ∈ {0xB,0xC,0xD}` 分支 | `0xB0088`←`0`、`0xE2000`←`0`、`0xE2010`←`0`；csel(`0xE2000`/`0xC0000`) |
| `0x14037ac30` | 总线带宽配置（未定名） | `0x14037ad38` `VIDEO_CORE_CLOCK_CONTROL`、`0x14037ada8` `VIDEO_DEC_AXI_PORT0_BW`、`0x14037ade8` `VIDEO_ENC_AXI_PORT0_BW` | `0x119400`（DDR/BIMC 域，非 VED 控制寄存器） |
| `0x14037c740` / `0x14037cb80` | SysCache 寄存器编程 | `0x14037c91c` `System cache ID, reg prog val`；`0x14037ca94` `sys cache expected to be activated with in count` | `0xD2114`、`0xD2118`←`0x3698` |
| `0x14037b830` | **`vedInitPlatformConfigs`** | `0x1403d8298` `Unknown nHWVersion in vedInitPlatformConfigs V1`；`0x1403d81d0` `vedInitPlatformConfigs Venus510`；`0x1403d8278` `vedInitPlatformConfigs Venus610` | 只写 ctx（含 `ctx[0x7114]`、`ctx[0x7138]`） |
| `0x140375620` | **`VedHandlePowerChange`** | `0x140375694` `Missing parameters to VedHandlePowerChange`；`0x140375cfc` `VedInitVideoCore:ePowerTransType changed ...` | 读 `0xA0048`、`0xA004C`（判定 core 状态） |
| `0x140043090` | **`VedDecodeAndClearInterrupt`** | `0x140043670` `HFI: intrStatus =` | 读 `0xB000C`、`0xE000C`、`0xB0010`、`0xE0010`；写 `0xD2104`←`7`、`0xD201C`←`1`、`0xE0014`、`0xA001C`←`1` |
| `0x140044450` / `0x14004d9a0` | 中断/Reset 处理同类函数 | `vedEngineApi.c` | 同上族 + `0xB0024`/`0xB0028`/`0xB0064`/`0xB0068`/`0xB006C`/`0xB0070`/`0xB01FC` |
| `0x140382420` | **`VedHandleHfiCoverage`** | `0x140382484` `ENTRY: VedHandleHfiCoverage` | `0xDF018`、`0xA0148`、`0xA0150` |
| `0x1400514c0` | HFI DPC（未定名） | `0x140051914` `DPC: ePacketType sessionId` | `0xDF018`、`0xA0148`、`0xA0150` |
| `0x14005eec8` / `0x14005xxxx`–`0x14008xxxx` 共 40+ 个函数 | HFI 命令/状态机族 | `vedEngineUtils.c` `VedHfiSysInit failed for bEngineSysInitDone` | 每个都含 `0xDF018`=`0x8000` + `0xA0148`=`1` + `0xA0150`=`1` 的三连写（共 45 个函数、135 处） |

---

## 4. 上电时间线（含分支）

```
VedInitVideoCore(ctx, w24 = ePowerTransType/目标状态)
│
├─ [日志] "VedInitVideoCore:ePowerTransType"                (0x140388a70)
├─ 取互斥锁；读 ctx[0x7114]/ctx[0x7570] ...
│
├─ W 0xB0010 ← ctx[0x7138]  (WRAPPER_INTR_MASK)             (0x140389824)
│    └ 日志 "Set Venus nIntrMask"（0x1403897d0）；ctx[0x7138] 由 vedInitPlatformConfigs 预置 0x1F
│
├─ VedWrapperInit(ctx)                        [经函数指针表，静态不可解析]
├─ VedSmmuSetState(ctx, TRUE)                 [经 pSmmuFuncTab，静态不可解析]
├─ VedBusInit(ctx)                            [经函数指针；实体应为 platformV1.c 的 VedBusInitV1 族]
│    └ (若走 VedBusInitV1：W 0xE0018←5, W 0xE001C←5, W 0xE0018←0x55)
├─ VcmClearFault(ctx)                         [经函数指针]
├─ 轮询 Venus idle 状态
├─ VedVcmCreate / VedVcmAlloc / VedVcmMapPhysicalAddr / VedVcmReserveMemory / VedVcmInit  [经函数指针]
│
├─ if (0x140058620(ctx) == 0) goto END        (0x140389c08)
├─ if (0x1400586e8(ctx) != 0) goto END        (0x140389c14)
├─ VedSysCacheActivate(ctx)                   (0x140389c20 → 0x140394cf8)
├─ VedUpdateSyscacheStatus(ctx, 2)            (0x140389ce4 → 0x1400581c0)
├─ VedSetMVPCoreGDSCPowerON(ctx)              (0x140389dc4 → 0x140392308)
│     W 0xB0084 ← 0        ; CORE_POWER_CONTROL：上电
│     R 0xB0080  (轮询到上电完成，超时串 "Core is not Power ON and timed out")
│
├─ if (w24 == 0x1003) goto SKIP_GDSC_OFF      (0x140389db4/0x140389dbc)
│  [不成立时]
│  └─ VedSetMVPCoreGDSCPowerOff(ctx)          (0x14038a320 → 0x1403928b8)
│        W 0xB0084 ← 1    ; 下电（是的，就是失败串写 "PowerOff"，与上一支的 0 相反）
│        R 0xB0080  ×2
│  SKIP_GDSC_OFF:
├─ VedPilLoadAndReset(ctx)                    (0x140389fc0 → 0x140387540)
│     ├─ VedPilLoad(ctx)                      → TZ IOCTL_PIL_TZ_LOAD_IMAGE
│     └─ [ctx+0x7AD8] IOCTL_PIL_TZ_AUTH_IMAGE_AND_RESET
│
├─ VedHfiReset(ctx)                           (0x14038a16c → 0x140387770)   ← ★ 寄存器写最密集处
│     ├─ VedHfiInterfaceQueuesInit(ctx)       (0x140394818)
│     │     W 0xA0054 ← ctx[0x12C]   (QTBL_ADDR)
│     │     W 0xA0050 ← 1            (QTBL_INFO)
│     ├─ VedHfiMMApInit(ctx)                  (0x140394c10)
│     ├─ [日志] "Initialize Core"
│     ├─ W 0xA005C ← ctx[0x194]      (SFR_ADDR)
│     ├─ W 0xA0060 ← ctx[0x1A4]
│     ├─ W 0xA0064 ← 运行时地址       (UC_REGION_ADDR)
│     ├─ W 0xA0068 ← 0x01000000      (UC_REGION_SIZE)
│     ├─ [日志] "Setting HFI_CTRL_INIT"
│     ├─ W 0xA0048 ← 1               (CTRL_INIT)
│     ├─ [日志] "Waiting for ctrlStatus"
│     ├─ R 0xA004C  轮询              (CTRL_STATUS)
│     └─ [日志] "Calling IOCTL_PIL_TZ_LOAD_IMAGE"
│
├─ if (ctx[0x7598] bit11 且 [ctx+0x7590] 非空)                (0x14038a224–0x14038a254)
│  └─ 调用 [ctx+0x7590] 指向的 TZ 方法 (blr x25) —— 属 TrustZone，跳过
│
├─ if (w24 != 0x1003)                                        (0x14038a310)
│  └─ 0x1403928b8 已在上方执行（见 SKIP_GDSC_OFF 分支）
├─ if (w24 == 0x1004 或 (w24-0x1000) <= 1)                    (0x14038a3f4)
│  └─ if (ctx[0x6240] bit12 == 0)
│     └─ VedHfiSysInit([ctx])                 (0x14038a41c → 0x140386380)
│           ×3 轮： W 0xDF018 ← 0x8000 ; W 0xA0148 ← 1 ; W 0xA0150 ← 1
│           + HFI_CMD_SYS_INIT / SYS_GET_PROPERTY / SYS_CACHE_SET
│
├─ if (ctx[0x7664] == 1)                                      (0x14038a500–0x14038a50c)
│  └─ VedSetUBWCConfig(ctx)                   (0x14038a514 → 0x140391c90)
│        W 0xDF018 ← 0x8000 ; W 0xA0148 ← 1 ; W 0xA0150 ← 1
│
├─ if (ctx[0x6240] bit24 != 0)                                (0x14038a5d0)
│  └─ VedCheckAndEnableFWFeatures(ctx)        (0x14038a5e0 → 0x140390798)
│        W 0xDF018 ← 0x8000 ; W 0xA0148 ← 1 ; W 0xA0150 ← 1
│        + HFI_CMD_SYS_SET_FEATURES
│
├─ if (w24 ∈ {0x1000,0x1001,0x1004} 且 ctx[0x7598] bit3)      (0x14038a69c)
│  └─ VedCheckAndEnablePowerPlane(ctx)        (0x14038a6cc → 0x14038ec88)
│        R 0xE0090, R 0xE0110, W 0xA0148 ← 1        (Core0)
│        R 0xE0090, R 0xE0110, W 0xA0148 ← 1        (Core1)
│        R 0xE0044, W 0xDF018 ← 0x8000, W 0xA0148 ← 1,
│        R 0xB0080, W 0xA0148 ← 1, W 0xA0150 ← 1
│
└─ [日志] "Done:VedInitVideoCore:ePowerTransType"            (0x14038a7a0)
```

### 4.1 顺序依赖运行时常量的分支（必须并列给出）

| 分支条件 | 指令地址 | 影响 |
|---|---|---|
| `ctx[0x7114] == 6`（chip ID 0x60100000/0x60400000） | `0x1403879c8` / `0x1403897f4` / `0x14038aa24` 等 | 全部 `csel` 选主图 `0xA00xx`/`0xB00xx`/`0xC00xx`；否则选备图 `0xD20xx`/`0xE00xx`/`0xE20xx` |
| `w24 == 0x1003` | `0x140389db4` / `0x14038a310` | 为真则**跳过** `VedSetMVPCoreGDSCPowerOff`（`0x1403928b8`） |
| `w24 ∈ {0x1000,0x1001,0x1004}` | `0x14038a3f4` | 决定是否执行 `VedHfiSysInit` 之后的三个 Enable 步骤 |
| `ctx[0x6240]` bit12 / bit24 | `0x14038a40c` / `0x14038a5d0` | 跳过 `VedHfiSysInit` / `VedCheckAndEnableFWFeatures` |
| `ctx[0x7664] == 1` | `0x14038a508` | 是否执行 `VedSetUBWCConfig` |
| `ctx[0x7598]` bit11 / bit3 | `0x14038a22c` / `0x14038a6c4` | TZ 方法调用 / `VedCheckAndEnablePowerPlane` |
| `ctx[0x7570]` 与偏移的大小关系 | 每个访问器 | 决定走窗口1 还是窗口2 的 `<str wV,[xN,#imm]>`（**最终设备偏移相同**，只是映射路径不同） |
| `0x140058620` / `0x1400586e8` 返回值 | `0x140389c08` / `0x140389c14` | 为真则**跳过整段** SysCache→HfiReset→… 全部寄存器写 |

---

## 5. 置信度与实际执行的命令

### 5.1 置信度标注

| 结论 | 置信度 |
|---|---|
| 访问器为内联、线性映射、范围校验（非查表）、读写两个不同实现 | 【已核实】 |
| 窗口设置函数 `0x14037a6d0` 及其常量 `0x84000`/`0x100000`/`0x200000` | 【已核实】 |
| §2.1 表中每一行的**指令地址、方向、偏移字面量、立即数值** | 【已核实】（逐条从 `qcdx.dis` 打印） |
| `VedInitVideoCore` 子函数的名称映射 | 【已核实】（每个都用自己的日志串交叉验证） |
| §2.2 锚点对照「写/读/未发现」 | 【已核实】（「未发现」= 在整个 `qcdx.dis` 中对该 u32 常量零命中） |
| §2.3 A 组「Windows 独有偏移」 | 【已核实】（有明确字面量与站点） |
| §2.3 C 组「Linux 写了 Windows 没写」 | 【已核实】（零命中；**不代表 Linux 写错**，需人工复核） |
| `ctx[0x7114]==6` 对应本机 SC8280XP | 【推测】—— 只能确认 chip ID `0x60100000`/`0x60400000` → 6，无法在二进制内确定 SC8280XP 的 chip ID 数值 |
| #8 `UC_REGION_ADDR` 的运行时常量真值 | 【无法确定】—— 值是 `ctx` 内运行期字段 + 地址运算，静态不可解析 |
| `VedWrapperInit` / `VedSmmuSetState` / `VedBusInit` / `Vcm*` 的寄存器写 | 【无法确定】—— 全部经函数指针调用（`blr xN`），目标在运行期绑定；但同文件中 `VedBusInitV1`(`0x140379d90`)、`0x14037a780` 极可能是其实现（见 §3.2） |

### 5.2 实际执行过的关键命令（全部在虚拟机内，经 `vm-ssh.ps1`）

```bash
# 1. 确认入口与函数边界（.pdata）
python3 -c "..."                      # starts[i]==0x388a08 -> next 0x38a7e0, len 0x1DD8

# 2. 定位 VED_HWIO_IN/OUT 日志串（三处副本，证明逐点内联）
python3 strs.py "VED_HWIO"
grep -n "bl\t0x140013438" /root/wdrv/qcdx.dis     # 仅 3 个调用者
grep -n "bl\t0x140013928" /root/wdrv/qcdx.dis     # 仅 1 个调用者

# 3. 找到访问器内联形态（含 add #0xa0,lsl #12 + str [x9,#328]）
python3 dump.py 0x1400516c0 0x140051740

# 4. 找到窗口/MmMap 装配函数（0x84000 / 0x100000 / 0x200000）
python3 dump.py 0x14037a6d0 0x14037a800

# 5. 全镜像枚举所有 VED 寄存器偏移字面量（508 处 ldr 字面量 → 收紧到 VED 窗口）
python3 lit.py
python3 - <<'EOF'  # 收紧窗口 [0xA0000,0xA2000) 等，输出「偏移 → 函数 → 站点」
EOF

# 6. 每个站点解析「值」与「写/读」
python3 resolve.py 0x140388a08 0x14038a7e0
python3 mmio2.py  0x140388a08 0x14038a7e0

# 7. 调用树 + 每个子函数写什么
python3 tree.py 0x140388a08 1

# 8. 函数定名（函数内引用到的日志串）
python3 fstr.py 0x140392308 0x1403928b8 0x140391c90 ... 

# 9. 验证关键写（避免假阳性）
python3 dump.py 0x140392380 0x1403923c0    # str wzr,[x9,#132]  → 0xB0084 = 0
python3 dump.py 0x140390d30 0x140390dd0    # 发现 ctx+0x7950 假阳性
python3 dump.py 0x140387fd0 0x140388060    # 0xA004C 轮询读
```

### 5.3 尚未解决 / 建议下一步

1. **确认 `ctx[0x615C]`（chip ID）在 GK-W76 上的实际值**（0x60100000 vs 0x60400000 vs 两者都不是），以锁定主图/备图。可从 Windows 端读 `SOCINFO` 或从 ACPI DSDT 的 `_DSM` 取。**这是唯一影响 §2 全表数值的解释性不确定点。**
2. `UC_REGION_ADDR`（`0xA0064`）写入值的运行期真值：需动态跟踪（`ctx[0x1D148]` 类字段），静态反汇编不可解。
3. 经函数指针调用的 `VedWrapperInit` / `VedBusInit` / `VedSmmuSetState` / `Vcm*`：建议在 Windows 侧用内核调试器在 `0x140388a08` 单步，或按 §3.2 的函数按名反查（`VedBusInitV1` 与 `0x14037a780` 已给出）。
4. Linux 侧对照时，§2.4 的假阳性清单请勿采信（`0xA0008/0xA0014/0xA0020/0xA0024/0xA0028/0xA002C` **不是** MMIO）。
