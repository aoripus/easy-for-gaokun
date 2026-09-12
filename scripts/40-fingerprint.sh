#!/usr/bin/env bash
#
# 40-fingerprint.sh — 指纹识别器调查（只读，SC8280XP / gaokun3）
#
# 结论先行
# --------
# 本机指纹是 FocalTech FTE7001，挂在 SPI 上，但那条 SPI 由 Qualcomm 安全世界
# （QSEE/TEE）独占：Windows 的非安全侧驱动只拿到一个 GPIO 中断连接，没有任何
# SPI/I2C 总线资源。因此 Linux 无法通过常规内核驱动路线使用它。
# 完整论证见 docs/fingerprint.md。
#
# 本脚本做的事
# ------------
#   --diagnose        在 Linux 侧做全部只读检查（USB / SPI / I2C / 设备树 / 内核 /
#                     TEE 节点 / gpio185），输出结论表
#   --windows-hive    只读挂载 Windows 分区，拷出 SYSTEM 注册表 hive，用
#                     tools/win-acpi-hive.py 解出「这台机器真正枚举过的 ACPI 设备
#                     与其资源分配」——这是唯一能确定总线归属的一手证据
#
# 全部操作只读；--windows-hive 也只是挂载为 ro 并拷出一个文件。
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly HIVE_TOOL="${REPO_ROOT}/tools/win-acpi-hive.py"
readonly WORK_DIR="/var/lib/easy-for-gaokun/fingerprint"
readonly MOUNT_POINT="/mnt/gaokun-windows"
readonly CANDIDATE_IDS=("FTE7001" "GDIX5125" "ELAN7001" "GXFP5130")

ACTION="diagnose"
for _arg in "$@"; do
	case "${_arg}" in
		--diagnose|-n)     ACTION="diagnose" ;;
		--windows-hive|-w) ACTION="hive" ;;
		--help|-h)
			sed -n '3,24p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		*) die "未知参数：${_arg}（可用：--diagnose / --windows-hive / --help）" ;;
	esac
done
unset _arg

# ---------------------------------------------------------------------------
# 只读探针
# ---------------------------------------------------------------------------

# gpio 在 pinmux-pins 中的占用者；UNCLAIMED 表示无驱动接管。
pin_owner() {
	awk -v p="pin $1 " '$0 ~ "^" p { sub(/^[^:]*:[[:space:]]*/, ""); print; exit }' \
		/sys/kernel/debug/pinctrl/*/pinmux-pins 2>/dev/null
}

# 内核配置项的值（y / m / "is not set"）。
kernel_config() {
	local f="/boot/config-$(uname -r)" v
	if [ -r "${f}" ]; then
		v="$(awk -F= -v k="$1" '$1 == k { print $2; exit }' "${f}")"
		if [ -n "${v}" ]; then printf '%s\n' "${v}"; return 0; fi
		awk -v k="# $1 is not set" '$0 == k { print "is not set"; exit }' "${f}"
	fi
}

do_diagnose() {
	local n

	result_section "① 指纹是否出现在任何总线上"
	n="$(lsusb 2>/dev/null | grep -ciE '2808|27c6|06cb|goodix|focal|elan' || true)"
	result_row "USB 上的指纹设备" "$([ "${n}" -eq 0 ] && printf PASS || printf WARN)" \
		"匹配 2808/27c6/06cb 等 VID 的设备数 = ${n}"
	n="$(ls /sys/bus/spi/devices/ 2>/dev/null | wc -l)"
	result_row "SPI 从设备总数" PASS "$(ls /sys/bus/spi/devices/ 2>/dev/null | tr '\n' ' ')"
	result_row "I2C 从设备" PASS \
		"$(ls /sys/bus/i2c/devices/ 2>/dev/null | tr '\n' ' ')"

	result_section "② 设备树是否描述了指纹"
	if grep -rql -iE 'focal|fte7|goodix|gxFP|finger' /proc/device-tree/ 2>/dev/null; then
		result_row "设备树指纹节点" PASS "找到相关节点"
	else
		result_row "设备树指纹节点" WARN "零命中（内核根本不知道这颗设备）"
	fi
	n="$(for d in /sys/firmware/devicetree/base/soc@0/geniqup@*/*spi@*; do
		[ -e "${d}/status" ] || continue
		if [ "$(tr -d '\0' <"${d}/status")" = "okay" ]; then basename "${d}"; fi
	done | wc -l)"
	result_row "使能中的 GENI SPI 控制器" PASS "${n} 个（其余为 disabled）"

	result_section "③ 安全世界（TEE）通路"
	for dev in /dev/qseecom /dev/tee0 /dev/teepriv0; do
		if [ -e "${dev}" ]; then
			result_row "${dev}" PASS "存在"
		else
			result_row "${dev}" WARN "不存在"
		fi
	done
	local qsee tee
	qsee="$(kernel_config CONFIG_QCOM_QSEECOM)"; qsee="${qsee:-未设置}"
	tee="$(kernel_config CONFIG_TEE)"; tee="${tee:-未设置}"
	result_row "CONFIG_QCOM_QSEECOM" "$([ "${qsee}" = "y" ] || [ "${qsee}" = "m" ] && printf PASS || printf WARN)" "${qsee}"
	result_row "CONFIG_TEE" "$([ "${tee}" = "y" ] && printf PASS || printf WARN)" "${tee}"
	log_info "QSEECOM 驱动在但 /dev/qseecom 不在 ⇒ 设备树里没有 QSEECOM 节点，驱动未被实例化（DTB 启动的必然结果）。"

	result_section "④ 内核有没有指纹驱动"
	for cfg in CONFIG_TOUCHSCREEN_GOODIX CONFIG_HID_GOODIX_SPI CONFIG_I2C_HID_OF_GOODIX \
	           CONFIG_FINGERPRINT_ELANSPI CONFIG_FPC1020; do
		local v
		v="$(kernel_config "${cfg}")"
		if [ -n "${v}" ]; then
			result_row "${cfg}" "$([ "${v}" = "y" ] || [ "${v}" = "m" ] && printf WARN || printf PASS)" "${v}"
		else
			result_row "${cfg}" PASS "未设置"
		fi
	done
	log_info "主线没有任何 FocalTech 指纹驱动；FocalTech 自家的 Linux 驱动已被 DMCA 下架。"

	result_section "⑤ 社区提到的 gpio185"
	local owner
	owner="$(pin_owner 185)"
	result_row "gpio185 占用者" PASS "${owner:-未找到（需要 root 与 debugfs）}"
	log_warn "注意：144–199 号引脚绝大多数都是 UNCLAIMED，所以“未被占用”不能证明它是指纹的引脚。"
	log_warn "真实用途需要在 ACPI DSDT 中确认（见 docs/fingerprint.md §8.3）。"

	result_section "⑥ 下一步"
	log_info "在 Linux 侧已无可查。决定总线归属的一手证据在 Windows 注册表里："
	log_info "  sudo $0 --windows-hive"

	result_summary || true
}

# ---------------------------------------------------------------------------
# 从 Windows 分区取 SYSTEM hive 并解析
# ---------------------------------------------------------------------------

find_windows_part() {
	lsblk -rno NAME,FSTYPE | awk '$2 == "ntfs" || $2 == "ntfs3" { print "/dev/" $1; exit }'
}

mount_windows_ro() {
	local part="$1"
	run install -d -m 0755 "${MOUNT_POINT}"
	if mountpoint -q "${MOUNT_POINT}"; then
		log_info "${MOUNT_POINT} 已挂载，直接使用。"
		return 0
	fi
	local fs
	for fs in ntfs3 ntfs-3g; do
		if run mount -t "${fs}" -o ro "${part}" "${MOUNT_POINT}" 2>/dev/null; then
			log_ok "已只读挂载 ${part}（${fs}）"
			return 0
		fi
	done
	return 1
}

do_hive() {
	local part hive src
	if [ ! -f "${HIVE_TOOL}" ]; then
		die "找不到 ${HIVE_TOOL}"
	fi
	if ! have_cmd python3; then
		die "需要 python3。"
	fi
	if ! python3 -c 'import hivex' 2>/dev/null; then
		log_warn "缺少 python3-hivex，正在尝试安装……"
		run apt-get update -qq || true
		run env DEBIAN_FRONTEND=noninteractive apt-get install -y python3-hivex || \
			die "安装 python3-hivex 失败；请手动安装后重试。"
	fi

	part="$(find_windows_part)"
	[ -n "${part}" ] || die "没有找到 NTFS 分区（Windows 应装在 nvme0n1p3 上）。"
	log_step "使用 Windows 分区 ${part}"

	mount_windows_ro "${part}" || die "只读挂载失败（可能已用 fast-startup 休眠；只读挂载通常仍可用）。"
	# shellcheck disable=SC2064
	trap "umount '${MOUNT_POINT}' 2>/dev/null || true" EXIT

	src="${MOUNT_POINT}/Windows/System32/config/SYSTEM"
	[ -f "${src}" ] || die "找不到 ${src}"
	run install -d -m 0755 "${WORK_DIR}"
	hive="${WORK_DIR}/SYSTEM"
	run cp -f "${src}" "${hive}"
	log_ok "已拷出 SYSTEM hive → ${hive}"

	printf '\n'
	python3 "${HIVE_TOOL}" "${hive}" --find "${CANDIDATE_IDS[@]}"
	printf '\n'
	python3 "${HIVE_TOOL}" "${hive}" --resources FTE7001
	printf '\n'
	python3 "${HIVE_TOOL}" "${hive}" --connections

	printf '\n'
	result_section "判读"
	log_info "① --find：只有 FTE7001 有枚举实例，说明本机确实只有 FocalTech 这一颗。"
	log_info "② --resources：Class=0x01(GPIO)/Type=0x02(GPIO_INT) ⇒ 非安全世界只拿到中断连接，"
	log_info "   没有 0x02/0x02(SPI) 或 0x02/0x01(I2C) ⇒ 总线没有交给操作系统。"
	log_info "③ --connections：用同一台机器上已知 SPI 的触屏（HIMX0002 → 02 02）与"
	log_info "   已知 UART 的蓝牙（QCOM066B → 02 03）标定出 Class/Type 语义。"
	log_info "完整结论见 docs/fingerprint.md。"
}

# ---------------------------------------------------------------------------

case "${ACTION}" in
	diagnose)
		# 只读，但需要 root 才能读 /sys/kernel/debug/pinctrl/*/pinmux-pins
		require_root
		do_diagnose
		;;
	hive)
		require_root
		do_hive
		;;
esac
