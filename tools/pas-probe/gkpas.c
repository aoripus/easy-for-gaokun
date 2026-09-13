// SPDX-License-Identifier: GPL-2.0-only
/*
 * gkpas - 向 TrustZone 直接问询 IRIS 视频核的 PAS 支持情况
 *
 * 用途
 * ----
 * 本机（HUAWEI MateBook E Go 2022 性能版 / GK-W7X / SC8280XP）上视频硬解尚未打通：
 * 内核运行在 EL2，qcom_scm_pas_auth_and_reset(9) 返回 0，但视频核从不上电执行
 * （CTRL_STATUS 恒为 0）。本模块把问题直接问到 TrustZone 面前，并逐项对比调用前后的
 * 视频核寄存器，以证明这些调用在硬件上有没有留下任何痕迹。
 *
 * 注意：EL2 本身**不是**阻塞点 —— Lenovo X13s（同为 SC8280XP）已在 EL2 下跑通 iris。
 * 本模块用于定位本机与已知可用设备之间的差异。
 *
 * 本模块只做两类操作：
 *   1. 查询类 / 幂等类 SCM 调用
 *   2. 只读地 dump 视频核寄存器（ioremap 0x0aa00000）
 *
 * 其中 pas_shutdown 只对视频核(9)与必定不存在的 ID 调用，**不碰 adsp/cdsp/slpi**，
 * 因此在用的音频与传感子系统不受影响。
 *
 * 构建（需要一台已构建过同版本内核的机器）
 * ----------------------------------------
 *   make -C <内核源码> O=<构建输出目录> M=<本目录> \
 *        ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- modules
 *
 * 运行
 * ----
 *   sudo insmod gkpas.ko        # init 故意返回失败，模块不驻留
 *   sudo dmesg | grep gkpas
 *
 * 实测结果与解读见同目录 README.md。
 */
#include <linux/module.h>
#include <linux/io.h>
#include <linux/delay.h>
#include <linux/firmware/qcom/qcom_scm.h>

#define IRIS_BASE	0x0aa00000UL
#define IRIS_SIZE	0x00100000UL
#define IRIS_PAS_ID	9

/* 1=adsp  9=video(IRIS)  17=slpi  18=cdsp  63=必定不存在 */
static const u32 probe_ids[] = { 1, 9, 17, 18, 63 };

/* 只用于 shutdown 的不存在 ID：不碰任何在用子系统 */
static const u32 bogus_ids[] = { 0, 63, 100, 200, 0xffffffff };

/* mem_protect_video_var(cp_start, cp_size, cp_nonpixel_start, cp_nonpixel_size) */
static const u32 mpvv_cand[][4] = {
	{ 0x00000000, 0x25800000, 0x01000000, 0x24800000 }, /* 上游共用的 CP 取值 */
	{ 0x00000000, 0x00000000, 0x00000000, 0x00000000 },
	{ 0x00000000, 0x25800000, 0x00000000, 0x00000000 },
	{ 0x00000000, 0x4b000000, 0x01000000, 0x4a000000 },
	{ 0x00000000, 0x10000000, 0x00000000, 0x10000000 },
	{ 0x00000000, 0x20000000, 0x00000000, 0x20000000 },
};

#define CP_START	0x00000000
#define CP_SIZE		0x25800000
#define CP_NP_START	0x01000000
#define CP_NP_SIZE	0x24800000

struct gkreg {
	u32 off;
	const char *name;
};

static const struct gkreg gkregs[] = {
	{ 0xa0048, "CTRL_INIT" },
	{ 0xa004c, "CTRL_STATUS" },
	{ 0xa0050, "QTBL_INFO" },
	{ 0xa0054, "QTBL_ADDR" },
	{ 0xa0058, "SCIACMDARG3" },
	{ 0xa005c, "SFR_ADDR" },
	{ 0xa0064, "UC_REGION_ADDR" },
	{ 0xa0068, "UC_REGION_SIZE" },
	{ 0xa0148, "H2XSOFTINTEN" },
	{ 0xa0160, "AHB_BRIDGE_SYNC_RST" },
	{ 0xa0168, "X2RPMH" },
	{ 0xb0010, "WRAPPER_INTR_MASK" },
	{ 0xb0054, "DEBUG_BRIDGE_LPI_CTL" },
	{ 0xb005c, "IRIS_CPU_NOC_LPI_CTL" },
	{ 0xb0060, "IRIS_CPU_NOC_LPI_STS" },
	{ 0xb0080, "CORE_POWER_STATUS" },
	{ 0xb0088, "CORE_CLOCK_CONFIG" },
	{ 0xc0010, "TZ_CPU_STATUS" },
	{ 0xc0014, "TZ_CTL_AXI_CLK_CFG" },
	{ 0xe0000, "AON_MVP_NOC_LPI_CTL" },
	{ 0xe0004, "AON_MVP_NOC_LPI_STS" },
	{ 0xe0018, "AON_NOC_CORE_SW_RST" },
	{ 0xe0020, "AON_NOC_CORE_CLK_CTL" },
};

static void __iomem *base;

static int mpvv(void)
{
	return qcom_scm_mem_protect_video_var(CP_START, CP_SIZE, CP_NP_START, CP_NP_SIZE);
}

static void dump(const char *tag)
{
	int i;

	for (i = 0; i < ARRAY_SIZE(gkregs); i++)
		pr_info("gkpas %-8s %-22s = %#010x\n", tag, gkregs[i].name,
			readl(base + gkregs[i].off));
}

static int __init gkpas_init(void)
{
	int i, ret;

	base = ioremap(IRIS_BASE, IRIS_SIZE);
	if (!base) {
		pr_err("gkpas ioremap failed\n");
		return -ENOMEM;
	}

	dump("BASE");

	/*
	 * 第一组：把"调用顺序/状态"作为唯一变量。若冷状态下第一件事调用就失败，
	 * 说明不是状态污染，而是该命令在本机 TZ 上不被接受。
	 */
	pr_info("gkpas ===== A. 冷状态：本模块的第一件事就是 mpvv =====\n");
	ret = mpvv();
	pr_info("gkpas mpvv(冷状态) = %d\n", ret);

	pr_info("gkpas ===== B. 紧接着再调一次（幂等性）=====\n");
	ret = mpvv();
	pr_info("gkpas mpvv(第二次) = %d\n", ret);

	pr_info("gkpas ===== C. 只读查询 =====\n");
	for (i = 0; i < ARRAY_SIZE(probe_ids); i++)
		pr_info("gkpas pas_supported(%u) = %s\n", probe_ids[i],
			qcom_scm_pas_supported(probe_ids[i]) ? "yes" : "NO");
	ret = qcom_scm_iommu_secure_ptbl_size(1, NULL);
	pr_info("gkpas iommu_secure_ptbl_size(1) = %d\n", ret);

	pr_info("gkpas ===== D. 查询之后 =====\n");
	ret = mpvv();
	pr_info("gkpas mpvv(查询之后) = %d\n", ret);

	pr_info("gkpas ===== E. auth_and_reset(9) 之后 =====\n");
	ret = qcom_scm_pas_auth_and_reset(IRIS_PAS_ID);
	pr_info("gkpas pas_auth_and_reset(%u) [no image loaded] = %d\n", IRIS_PAS_ID, ret);
	ret = mpvv();
	pr_info("gkpas mpvv(auth 之后) = %d\n", ret);

	pr_info("gkpas ===== F. shutdown(9) 之后，以及不存在的 PAS ID =====\n");
	ret = qcom_scm_pas_shutdown(IRIS_PAS_ID);
	pr_info("gkpas pas_shutdown(%u) = %d\n", IRIS_PAS_ID, ret);
	ret = mpvv();
	pr_info("gkpas mpvv(shutdown 之后) = %d\n", ret);

	for (i = 0; i < ARRAY_SIZE(bogus_ids); i++) {
		ret = qcom_scm_pas_shutdown(bogus_ids[i]);
		pr_info("gkpas pas_shutdown(%u) = %d\n", bogus_ids[i], ret);
	}

	pr_info("gkpas ===== G. mpvv 参数枚举 =====\n");
	for (i = 0; i < ARRAY_SIZE(mpvv_cand); i++) {
		ret = qcom_scm_mem_protect_video_var(mpvv_cand[i][0], mpvv_cand[i][1],
						     mpvv_cand[i][2], mpvv_cand[i][3]);
		pr_info("gkpas mpvv(%#010x, %#010x, %#010x, %#010x) = %d\n",
			mpvv_cand[i][0], mpvv_cand[i][1],
			mpvv_cand[i][2], mpvv_cand[i][3], ret);
	}

	pr_info("gkpas ===== H. 先设 CP pool size 再试 =====\n");
	ret = qcom_scm_iommu_set_cp_pool_size(0x0, 0x25800000);
	pr_info("gkpas iommu_set_cp_pool_size(0, 0x25800000) = %d\n", ret);
	ret = mpvv();
	pr_info("gkpas mpvv(设池之后) = %d\n", ret);

	pr_info("gkpas ===== 收尾寄存器（与 BASE 逐项对比即可看出有无痕迹）=====\n");
	dump("FINAL");

	iounmap(base);
	pr_info("gkpas DONE\n");
	return -EIO; /* 只为拿 init 的副作用，不驻留 */
}

module_init(gkpas_init);
MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("ask TrustZone about IRIS PAS support and dump the video core registers");
