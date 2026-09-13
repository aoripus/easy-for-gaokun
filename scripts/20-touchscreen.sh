#!/usr/bin/env bash
# shellcheck disable=SC2034  # MODE_LINE 等常量当前仅作说明用途，保留以便后续脚本统一引用
#
# 20-touchscreen.sh — 触屏诊断与修复（Himax HX83121A / GK-W76）
#
# 背景
# ----
# 本机的触控 IC 是一颗 Himax HX83121A 级联 IC，其"向主机上报的接口"由一个
# 模式选择脚决定：TLMM gpio174 为低 → 走 SPI 上报裸触摸数据；为高 → 暴露
# I2C-HID 接口。该脚必须在触控固件重载之前设置好，模式会被 IC 锁存。
#
# 引导固件把这个脚留在高电平，而内核加载的是 SPI 驱动（himax_hx83121a_spi）。
# 结果是：驱动正常绑定、能读到芯片 ID、能完成固件重载，但 IC 永远不上报触摸
# 数据，其中断线（gpio175，level-low）也永远不被拉低 —— 触屏表现为完全失效。
#
# 修复
# ----
# 1) 根本修复：设备树把 gpio174 描述为默认状态下的低电平输出。
#    见 patches/0001-arm64-dts-qcom-...-touchscreen.patch
# 2) 运行时方案（本脚本）：以 systemd 服务持续把该脚保持为低电平，
#    然后在低电平状态下重新初始化触控驱动，使模式被锁存。
#
# 用法
# ----
#   sudo ./scripts/20-touchscreen.sh            # 诊断 → 应用运行时修复 → 验证
#   sudo ./scripts/20-touchscreen.sh --diagnose # 仅诊断，不修改任何状态
#   sudo ./scripts/20-touchscreen.sh --revert   # 撤销运行时修复
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly TS_SPI_DEV="/sys/bus/spi/devices/spi0.0"
readonly TS_MODALIAS="spi:hx83121a-ts"
readonly TS_DRIVER="himax-spi"
readonly TLMM_LABEL="f100000.pinctrl"
readonly MODE_LINE=174
readonly HELPER_PATH="/usr/local/bin/gaokun-touch-mode"
readonly UNIT_NAME="gaokun-touch-mode.service"
readonly UNIT_PATH="/etc/systemd/system/${UNIT_NAME}"

ACTION="apply"
case "${1:-}" in
	--diagnose|-n) ACTION="diagnose" ;;
	--revert|-r)   ACTION="revert" ;;
	--help|-h)
		sed -n '3,26p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0 ;;
	"") ;;
	*) die "未知参数：${1}（可用：--diagnose / --revert / --help）" ;;
esac

# ---------------------------------------------------------------------------
# 只读探针
# ---------------------------------------------------------------------------

# 定位 TLMM 所对应的 gpiochip 设备路径（编号在不同启动间不保证稳定，必须按 label 解析）
find_gpio_chip() {
	gpiodetect 2>/dev/null | awk -v l="${TLMM_LABEL}" '$2 == "[" l "]" { print $1; exit }'
}

# gpio174 的当前电平：low / high / 未知
gpio174_level() {
	awk '/^[[:space:]]*gpio174[[:space:]]*:/ { for (i = 1; i <= NF; i++) if ($i == "low" || $i == "high") { print $i; exit } }' \
		/sys/kernel/debug/gpio 2>/dev/null
}

# gpio174 的 pinctrl 占用者（UNCLAIMED 表示没有任何驱动接管，电平来自引导固件）
gpio174_owner() {
	awk '/^pin 174 / { $1 = ""; $2 = ""; sub(/^[[:space:]]*\([^)]*\):[[:space:]]*/, ""); print; exit }' \
		/sys/kernel/debug/pinctrl/*/pinmux-pins 2>/dev/null
}

# 触控中断号
ts_irq() {
	awk '/himax-spi-ts/ { sub(/:$/, "", $1); print $1; exit }' /proc/interrupts 2>/dev/null
}

# 触控中断累计次数（0 号 CPU 列）
ts_irq_count() {
	awk '/himax-spi-ts/ { print $2; exit }' /proc/interrupts 2>/dev/null
}

# 设备树是否已经包含根本修复。
# 判据必须直接看运行中的设备树，而不能看 gpio174 的占用者 —— 运行时方案持线时
# 该脚同样会显示为被 GPIO 子系统占用，两者无法区分。
dtb_has_fix() {
	local base node=""
	for base in /proc/device-tree /sys/firmware/devicetree/base; do
		[[ -d "${base}" ]] || continue
		node="$(find "${base}" -type d -name 'ts0-default-state' 2>/dev/null | head -n1)"
		[[ -n "${node}" ]] && break
	done
	# 修复后 ts0-default-state 应有三个子节点：int-n-pins / reset-n-pins / mode-n-pins
	[[ -n "${node}" && -d "${node}/mode-n-pins" ]]
}

# ---------------------------------------------------------------------------
# 诊断
# ---------------------------------------------------------------------------

diagnose() {
	log_step "触屏诊断"
	result_section "触屏（Himax HX83121A / SPI）"

	if [[ -e "${TS_SPI_DEV}" ]]; then
		local modalias driver
		modalias="$(cat "${TS_SPI_DEV}/modalias" 2>/dev/null || echo '?')"
		driver="$(basename "$(readlink -f "${TS_SPI_DEV}/driver" 2>/dev/null)" 2>/dev/null || echo '(未绑定)')"
		if [[ "${modalias}" == "${TS_MODALIAS}" ]]; then
			result_row "SPI 设备" PASS "modalias=${modalias}，驱动=${driver}"
		else
			result_row "SPI 设备" FAIL "modalias=${modalias}，期望 ${TS_MODALIAS}"
		fi
	else
		result_row "SPI 设备" FAIL "${TS_SPI_DEV} 不存在"
	fi

	local lvl owner
	lvl="$(gpio174_level)"; owner="$(gpio174_owner)"
	if [[ "${lvl}" == "low" ]]; then
		result_row "模式脚 gpio174" PASS "电平 low（SPI 上报模式）"
	elif [[ "${lvl}" == "high" ]]; then
		result_row "模式脚 gpio174" FAIL "电平 high（I2C-HID 模式）—— 触屏必然失效"
	else
		result_row "模式脚 gpio174" WARN "无法读取电平"
	fi
	log_kv "gpio174 pinctrl 占用者" "${owner:-未知}"

	local irq
	irq="$(ts_irq)"
	if [[ -n "${irq}" ]]; then
		result_row "触控中断" PASS "IRQ ${irq}（hwirq 175），累计 $(ts_irq_count) 次"
	else
		result_row "触控中断" FAIL "未在 /proc/interrupts 中找到 himax-spi-ts"
	fi

	if dtb_has_fix; then
		log_ok "设备树已包含根本修复（gpio174 由 pinctrl 接管为输出低），无需运行时方案。"
	else
		log_warn "设备树尚未包含根本修复；需要运行时方案把 gpio174 保持为低电平。"
	fi

	result_summary
}

# ---------------------------------------------------------------------------
# 应用运行时修复
# ---------------------------------------------------------------------------

# 写辅助脚本：解析 TLMM 对应的 gpiochip，并持线
install_helper() {
	local tmp
	tmp="$(mktemp)"
	cat > "${tmp}" <<'HELPER'
#!/usr/bin/env bash
#
# easy-for-gaokun — 把触控 IC 的接口模式选择脚（TLMM gpio174）保持为低电平。
#
# 该脚必须在触控固件重载之前为低，SPI 上报通路才会生效。固件重载会在每次
# 显示器使能/复位时重新发生，因此这里持续持线，而不是只在启动时设置一次。
#
# gpiochip 的编号在不同启动间不保证稳定，故按 pinctrl label 解析。
set -euo pipefail

TLMM_LABEL="f100000.pinctrl"
LINE=174

chip=""
for _ in $(seq 1 60); do
	chip="$(gpiodetect 2>/dev/null | awk -v l="${TLMM_LABEL}" '$2 == "[" l "]" { print $1; exit }')"
	[[ -n "${chip}" ]] && break
	sleep 0.5
done

if [[ -z "${chip}" ]]; then
	echo "gaokun-touch-mode: 未能定位 ${TLMM_LABEL} 对应的 gpiochip" >&2
	exit 1
fi

# -p：持线时长（到点后由 systemd 的 Restart=always 立即重启，模式已被 IC 锁存，
#     亚秒级空窗无影响）
exec gpioset -p 3600s -C gaokun-touch-mode -c "${chip}" "${LINE}=0"
HELPER
	install -m 0755 "${tmp}" "${HELPER_PATH}"
	rm -f "${tmp}"
	log_ok "已安装 ${HELPER_PATH}"
}

install_unit() {
	local tmp
	tmp="$(mktemp)"
	cat > "${tmp}" <<UNIT
[Unit]
Description=easy-for-gaokun: 保持 TLMM gpio174 低电平（Himax HX83121A SPI 模式）
Documentation=${PROJECT_URL}
# 必须早于触控驱动的首次初始化（面板使能后约 300 ms）
DefaultDependencies=no
After=sysinit.target
Before=basic.target
Conflicts=shutdown.target
Before=shutdown.target

[Service]
Type=simple
ExecStart=${HELPER_PATH}
Restart=always
RestartSec=1

[Install]
WantedBy=basic.target
UNIT
	install -m 0644 "${tmp}" "${UNIT_PATH}"
	rm -f "${tmp}"
	log_ok "已安装 ${UNIT_PATH}"
}

# 清掉手工残留的持线进程，避免与 systemd 服务争抢同一根线
kill_stray_holders() {
	if pgrep -f 'gpioset .*174' >/dev/null 2>&1; then
		log_warn "发现手工启动的 gpioset 持线进程，正在结束它们"
		run pkill -f 'gpioset .*174' || true
		sleep 1
	fi
}

# 在低电平状态下重建 spi_device，触发完整初始化与固件重载
reinit_touchscreen() {
	log_step "在低电平状态下重新初始化触控（锁存接口模式）"
	if [[ "${DRY_RUN}" != "1" ]]; then
		echo spi0.0 > "/sys/bus/spi/drivers/${TS_DRIVER}/unbind" 2>/dev/null || true
		sleep 1
		echo spi0.0 > "/sys/bus/spi/drivers/${TS_DRIVER}/bind"
		sleep 4
	fi
}

verify() {
	log_step "验证"
	local lvl before after
	lvl="$(gpio174_level)"
	before="$(ts_irq_count)"
	log_kv "gpio174 电平" "${lvl:-未知}"

	if [[ "${lvl}" != "low" ]]; then
		log_err "模式脚未处于低电平，修复未生效。"
		return 1
	fi

	log_info "请在接下来 10 秒内持续滑动屏幕……"
	sleep 10
	after="$(ts_irq_count)"
	log_kv "中断计数" "${before} → ${after}"

	if [[ -n "${before}" && -n "${after}" && "${after}" -gt "${before}" ]]; then
		log_ok "触控中断正在增长，修复已生效。"
		return 0
	fi

	log_warn "中断计数未增长：可能这 10 秒内没有触摸，也可能是其他问题。"
	log_warn "请触摸屏幕后手工复查：grep himax-spi-ts /proc/interrupts"
	return 0
}

apply() {
	require_gpiod
	require_root

	diagnose

	if dtb_has_fix; then
		log_ok "无需运行时方案，直接验证。"
		verify
		return 0
	fi

	log_step "安装运行时修复"
	kill_stray_holders
	install_helper
	install_unit
	run systemctl daemon-reload
	run systemctl enable --now "${UNIT_NAME}"
	reinit_touchscreen
	verify

	log_info "若要让修复完全不依赖用户态服务，请套用设备树补丁："
	log_info "  patches/0001-arm64-dts-qcom-sc8280xp-huawei-gaokun3-select-SPI-mode-for-touchscreen.patch"
}

revert() {
	require_root
	log_step "撤销运行时修复"
	run systemctl disable --now "${UNIT_NAME}" || true
	run rm -f "${UNIT_PATH}"
	run systemctl daemon-reload
	kill_stray_holders
	log_warn "已移除持线服务。gpio174 将回到引导固件设定的高电平，触屏会再次失效，"
	log_warn "直到下次固件重载前由设备树修复把它设为低电平。"
}

require_gpiod() {
	have_cmd gpioset && have_cmd gpiodetect && return 0
	die "缺少 GPIO 工具。请先安装：sudo apt-get install -y gpiod"
}

main() {
	case "${ACTION}" in
		diagnose) diagnose ;;
		apply)    apply ;;
		revert)   revert ;;
	esac
}

main "$@"
