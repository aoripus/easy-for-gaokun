#!/usr/bin/env python3
# =============================================================================
# gaokun-iris-dts-prep.py — 把上游的 SC8280XP IRIS 设备树节点前置进基线内核源码树
#
# 用法
# ----
#   python3 tools/gaokun-iris-dts-prep.py /path/to/linux
#
# 背景
# ----
# 目标机（GK-W76 / SC8280XP / gaokun3）的视频硬解单元是 **Qualcomm IRIS(Gen1)**，
# 不是经典 Venus。上游直到 **v7.3-rc1** 才把 sc8280xp 的 iris 节点并进
# `arch/arm64/boot/dts/qcom/sc8280xp.dtsi`（Dmitry Baryshkov 的 iris v7 系列，
# commit 3a52eef16b979617156fa6e2ead24ca4d1336f0b 与
# 595eb4144f2ecc58e8e56e07ae94407b5a696031）；v7.1/v7.2 树里**完全没有**视频节点。
#
# 而 buildbot 的 `patches/media/0006-...-Add-Venus.patch` 加的是 2023 年的旧形态
# （`compatible = "qcom,sm8350-venus"`、`iommus = <&apps_smmu 0x2e00 0x400>`、
# 缺 `mmcx` 电源域），与本配方冲突且写错了 SMMU 流 ID。**所以要整目录跳过
# `patches/media/`，改用本脚本按上游写法补节点。**
#
# 脚本做四件事（全部基于锚点插入，幂等）
# --------------------------------------
#   1. `sc8280xp.dtsi` 补 3 个 `#include`（clock / interconnect / **reset**）
#   2. 补 `pil_video_mem: video-region@86700000` 保留内存
#   3. 补 `iris: video-codec@aa00000` 与 `videocc: clock-controller@abf0000` 节点
#   4. 板级 `sc8280xp-huawei-gaokun3.dts` 追加 `&iris { firmware-name = ...; status = "okay"; }`
#
# 三个容易踩的坑（均已实机验证）
# ------------------------------
#   * **reset 定义在另一个头文件里**：`VIDEO_CC_MVS0C_CLK_ARES` 来自
#     `dt-bindings/reset/qcom,sm8350-videocc.h`，只加 clock 那份会在 DTC 阶段报
#     `Lexical error: ... Unexpected 'VIDEO_CC_MVS0C_CLK_ARES'`。
#   * **`firmware-name` 是必需的**：IRIS 的 `sm8250_data.fwname` 指向
#     `qcom/vpu-1.0/venus.mbn`，该文件已从 linux-firmware 删除；`iris_firmware.c`
#     先读设备树 `firmware-name` 才回退 `fwname`，不写必然 `firmware download failed`。
#   * **IRIS 与 VENUS 在本基线互斥**：IRIS 驱动把 `qcom,sm8250-venus` 回退项包在
#     `#if (!IS_ENABLED(CONFIG_VIDEO_QCOM_VENUS))` 里，两者同开谁都绑不上。
#     配置阶段必须 `CONFIG_VIDEO_QCOM_IRIS=m` + `CONFIG_VIDEO_QCOM_VENUS` 关闭。
#
# 目标机实测状态（2026-09）
# ------------------------
#   v7.2-rc2 + buildbot 补丁集 + 本脚本（`patches/media/` 跳过）可成功构建
#   `Image` / `modules` / `dtbs`，产物 DTB 带 `status = "okay"` 的 iris 节点。
#   **能否 probe 成功尚未验证**：probe 走的是与 Venus 同一条 PAS/安全世界通路，
#   而该机 `qcom_scm_pas_init_image()` 已知会失败——换驱动不改变这条通路是否可用。
#
# 许可证：GPL-2.0-only（与本项目一致）
# 项目主页：https://github.com/aoripus/easy-for-gaokun
# =============================================================================

import os
import sys

DTSI_REL = "arch/arm64/boot/dts/qcom/sc8280xp.dtsi"
BOARD_REL = "arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts"

INC_CLOCK = "#include <dt-bindings/clock/qcom,sm8350-videocc.h>"
INC_ICC = "#include <dt-bindings/interconnect/qcom,icc.h>"
INC_RESET = "#include <dt-bindings/reset/qcom,sm8350-videocc.h>"

ANCHOR_INC_CLOCK = "#include <dt-bindings/clock/qcom,sc8280xp-lpasscc.h>"
ANCHOR_INC_RESET = "#include <dt-bindings/power/qcom-rpmpd.h>"
ANCHOR_PIL_GPU = "\t\tpil_gpu_mem: gpu-mem@8bf00000 {"
ANCHOR_CCI0 = "\t\tcci0: cci@ac4a000 {"

PIL_VIDEO = """\t\tpil_video_mem: video-region@86700000 {
\t\t\treg = <0 0x86700000 0 0x500000>;
\t\t\tno-map;
\t\t};

"""

IRIS_NODE = """\t\tiris: video-codec@aa00000 {
\t\t\tcompatible = "qcom,sc8280xp-iris", "qcom,sm8250-venus";
\t\t\treg = <0x0 0x0aa00000 0x0 0x100000>;
\t\t\tinterrupts = <GIC_SPI 174 IRQ_TYPE_LEVEL_HIGH>;

\t\t\tclocks = <&gcc GCC_VIDEO_AXI0_CLK>,
\t\t\t\t <&videocc VIDEO_CC_MVS0C_CLK>,
\t\t\t\t <&videocc VIDEO_CC_MVS0_CLK>;
\t\t\tclock-names = "iface", "core", "vcodec0_core";

\t\t\tpower-domains = <&videocc MVS0C_GDSC>,
\t\t\t\t\t<&videocc MVS0_GDSC>,
\t\t\t\t\t<&rpmhpd SC8280XP_MX>,
\t\t\t\t\t<&rpmhpd SC8280XP_MMCX>;
\t\t\tpower-domain-names = "venus", "vcodec0", "mx", "mmcx";

\t\t\tresets = <&gcc GCC_VIDEO_AXI0_CLK_ARES>,
\t\t\t\t <&videocc VIDEO_CC_MVS0C_CLK_ARES>;
\t\t\treset-names = "bus", "core";

\t\t\tinterconnects = <&gem_noc MASTER_APPSS_PROC QCOM_ICC_TAG_ACTIVE_ONLY
\t\t\t\t\t &config_noc SLAVE_VENUS_CFG QCOM_ICC_TAG_ACTIVE_ONLY>,
\t\t\t\t\t<&mmss_noc MASTER_VIDEO_P0 QCOM_ICC_TAG_ALWAYS
\t\t\t\t\t &mc_virt SLAVE_EBI1 QCOM_ICC_TAG_ALWAYS>;
\t\t\tinterconnect-names = "cpu-cfg", "video-mem";

\t\t\toperating-points-v2 = <&iris_opp_table>;
\t\t\tiommus = <&apps_smmu 0x2a00 0x400>;
\t\t\tmemory-region = <&pil_video_mem>;
\t\t\tstatus = "disabled";

\t\t\tiris_opp_table: opp-table {
\t\t\t\tcompatible = "operating-points-v2";

\t\t\t\topp-240000000 { opp-hz = /bits/ 64 <240000000>;
\t\t\t\t\trequired-opps = <&rpmhpd_opp_svs>, <&rpmhpd_opp_low_svs>; };
\t\t\t\topp-338000000 { opp-hz = /bits/ 64 <338000000>;
\t\t\t\t\trequired-opps = <&rpmhpd_opp_svs>, <&rpmhpd_opp_svs>; };
\t\t\t\topp-366000000 { opp-hz = /bits/ 64 <366000000>;
\t\t\t\t\trequired-opps = <&rpmhpd_opp_svs_l1>, <&rpmhpd_opp_svs_l1>; };
\t\t\t\topp-444000000 { opp-hz = /bits/ 64 <444000000>;
\t\t\t\t\trequired-opps = <&rpmhpd_opp_svs_l1>, <&rpmhpd_opp_nom>; };
\t\t\t\topp-533000000 { opp-hz = /bits/ 64 <533000000>;
\t\t\t\t\trequired-opps = <&rpmhpd_opp_nom>, <&rpmhpd_opp_turbo>; };
\t\t\t\topp-560000000 { opp-hz = /bits/ 64 <560000000>;
\t\t\t\t\trequired-opps = <&rpmhpd_opp_nom>, <&rpmhpd_opp_turbo_l1>; };
\t\t\t};
\t\t};

\t\tvideocc: clock-controller@abf0000 {
\t\t\tcompatible = "qcom,sc8280xp-videocc";
\t\t\treg = <0 0x0abf0000 0 0x10000>;
\t\t\tclocks = <&rpmhcc RPMH_CXO_CLK>,
\t\t\t\t <&rpmhcc RPMH_CXO_CLK_A>,
\t\t\t\t <&sleep_clk>;
\t\t\tpower-domains = <&rpmhpd SC8280XP_MMCX>;
\t\t\trequired-opps = <&rpmhpd_opp_low_svs>;
\t\t\t#clock-cells = <1>;
\t\t\t#reset-cells = <1>;
\t\t\t#power-domain-cells = <1>;
\t\t};

"""

BOARD_IRIS = """
/*
 * 视频硬解：本机是 Qualcomm IRIS(Gen1) 而非经典 Venus。
 * 由 drivers/media/platform/qcom/iris 驱动经 sm8250-venus 回退项绑定。
 * firmware-name 必须显式给出：iris 的 sm8250_data.fwname 指向
 * qcom/vpu-1.0/venus.mbn，该文件已从 linux-firmware 删除。
 */
&iris {
\tfirmware-name = "qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn";

\tstatus = "okay";
};
"""


def insert(text, anchor, addition, where, label):
    n = text.count(anchor)
    if n == 0:
        sys.exit("找不到锚点（%s）：%r\n（内核源码版本不对？本脚本按 v7.2-rc2 校准）" % (label, anchor.strip()))
    if n > 1:
        sys.exit("锚点不唯一（%s）：%d 处" % (label, n))
    return text.replace(anchor, (anchor + "\n" + addition.rstrip("\n")) if where == "after" else (addition + anchor), 1)


def main():
    if len(sys.argv) != 2:
        sys.exit("用法：%s <内核源码根目录>" % sys.argv[0])
    root = sys.argv[1]
    dtsi = os.path.join(root, DTSI_REL)
    board = os.path.join(root, BOARD_REL)
    for p in (dtsi, board):
        if not os.path.isfile(p):
            sys.exit("找不到 %s\n（buildbot 的 0099 补丁会导入板级 dts；确认补丁已应用）" % p)

    s = open(dtsi, encoding="utf-8").read()
    if "iris: video-codec@aa00000" in s:
        print("sc8280xp.dtsi 里已有 iris 节点，跳过前三步")

    else:
        # 1) include
        add = ""
        if INC_CLOCK not in s:
            add += INC_CLOCK + "\n"
        if INC_ICC not in s:
            add += INC_ICC + "\n"
        if add:
            s = insert(s, ANCHOR_INC_CLOCK, add, "after", "lpasscc include")
            print("已插入：" + add.strip().replace("\n", "  "))
        if INC_RESET not in s:
            s = insert(s, ANCHOR_INC_RESET, INC_RESET, "after", "qcom-rpmpd include")
            print("已插入：" + INC_RESET)

        # 2) 保留内存
        s = insert(s, ANCHOR_PIL_GPU, PIL_VIDEO, "before", "pil_gpu_mem")
        print("已插入 pil_video_mem: video-region@86700000")

        # 3) iris + videocc 节点
        s = insert(s, ANCHOR_CCI0, IRIS_NODE, "before", "cci0")
        print("已插入 iris / videocc 节点")

        open(dtsi, "w", encoding="utf-8").write(s)

    # 4) 板级使能
    b = open(board, encoding="utf-8").read()
    if "&iris" in b:
        print("板级 dts 已有 &iris，跳过")
    else:
        open(board, "w", encoding="utf-8").write(b.rstrip() + "\n" + BOARD_IRIS)
        print("已在板级 dts 追加 &iris { firmware-name = ...; status = \"okay\"; }")

    print("\n下一步（配置阶段，缺一不可）：")
    print("  scripts/config --file $KERN_OUT/.config --module  VIDEO_QCOM_IRIS")
    print("  scripts/config --file $KERN_OUT/.config --disable VIDEO_QCOM_VENUS")
    print("  make O=$KERN_OUT ARCH=arm64 olddefconfig")
    print("详见 docs/build-kernel-iris.md")


if __name__ == "__main__":
    main()
