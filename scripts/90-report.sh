#!/usr/bin/env bash
#
# 90-report.sh — 一键生成诊断报告
#
# 收集本机与 easy-for-gaokun 相关的全部关键状态，输出到 **stdout**，
# 便于重定向成文件后附在 issue 里：
#
#   sudo ./scripts/90-report.sh > gaokun-report.txt
#
# 本脚本**严格只读**：不修改任何系统状态，不写入任何路径。
# 部分项目需要 root 才能读到（debugfs 等）；非 root 运行时会标注为"需要 root"。
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

TLMM_DEBUGFS="/sys/kernel/debug/pinctrl/f100000.pinctrl"

# ---- 输出小工具 -----------------------------------------------------------

section() { printf '\n===== %s =====\n' "$1"; }

# 打印一条键值；值不存在时打印占位符而不是报错
kv() {
	local key="$1" val="$2"
	printf '  %-26s %s\n' "${key}" "${val:-（无）}"
}

# 读取一个文件（首个非空行）
read_one() {
	[[ -r "$1" ]] && head -n1 "$1" 2>/dev/null || true
}

# 从 NUL 分隔的设备树字符串里取值
dt_string() {
	local f="$1"
	[[ -r "${f}" ]] && tr '\0' ' ' < "${f}" 2>/dev/null | sed 's/ $//' || true
}

# 当前是否 root
is_root() { [[ "${EUID}" -eq 0 ]]; }

# ---------------------------------------------------------------------------
section "报告元信息"
kv "生成时间"       "$(date -Is 2>/dev/null || date)"
kv "运行身份"       "$(id -un)（EUID=$(id -u)）$([[ $(is_root) ]] || echo '—— 部分项目需要 root')"
kv "主机名"         "$(hostname 2>/dev/null)"
kv "内核"           "$(uname -sr)"
kv "架构"           "$(uname -m)"
kv "运行时长"       "$(uptime -p 2>/dev/null || uptime)"

# ---------------------------------------------------------------------------
section "设备身份（★ 变体判据）"

for base in /proc/device-tree /sys/firmware/devicetree/base; do
	[[ -d "${base}" ]] || continue
	DT="${base}"
	break
done
DT="${DT:-}"

kv "设备树根"       "${DT:-未找到}"
kv "model"          "$(dt_string "${DT}/model")"
COMpat="$(dt_string "${DT}/compatible")"
kv "compatible"     "${COMpat}"
kv "chassis-type"   "$(dt_string "${DT}/chassis-type")"
kv "DMI 厂商"       "$(read_one /sys/class/dmi/id/sys_vendor)"
kv "DMI 产品名"     "$(read_one /sys/class/dmi/id/product_name)"
kv "DMI 主板"       "$(read_one /sys/class/dmi/id/board_name)"

MAXKHZ=0
for f in /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq; do
	[[ -r "${f}" ]] || continue
	v="$(cat "${f}")"
	(( v > MAXKHZ )) && MAXKHZ="${v}"
done
if (( MAXKHZ > 0 )); then
	kv "大核最高频率" "${MAXKHZ} kHz（$(awk -v k="${MAXKHZ}" 'BEGIN{printf "%.3f", k/1000000}') GHz）"
	if (( MAXKHZ >= 2900000 )); then
		printf '  → 判定：符合 2022 性能版（满血 8cx Gen 3）\n'
	else
		printf '  → 判定：⚠️ 疑似 2023 降频版，本项目不支持该变体\n'
	fi
fi

case "${COMpat}" in
	*huawei,gaokun3*) printf '  → 判定：设备树为 gaokun3（本项目目标）\n' ;;
	*gaokun2*|*sc8180x*) printf '  → 判定：⚠️ 疑似 2022 LTE 版（8cx Gen 2），本项目不支持\n' ;;
	*) printf '  → 判定：⚠️ 无法确认为 gaokun3\n' ;;
esac

case "$(read_one /sys/class/dmi/id/product_name)" in
	*GK-W7*) printf '  → 提示：DMI 报 %s。型号字符串不可靠，以上面两条判据为准\n' \
		"$(read_one /sys/class/dmi/id/product_name)" ;;
esac

# ---------------------------------------------------------------------------
section "系统与引导"

kv "发行版"         "$(grep -E '^PRETTY_NAME=' /etc/os-release 2>/dev/null | cut -d= -f2- | tr -d '"')"
kv "内核 release"   "$(uname -r)"
kv "cmdline"        "$(cat /proc/cmdline 2>/dev/null)"
kv "内核设备树"     "$(read_one /etc/kernel/devicetree)"
for f in /proc/device-tree/chosen/bootargs /sys/firmware/devicetree/base/chosen/bootargs; do
	[[ -r "${f}" ]] && { kv "固件 bootargs" "$(dt_string "${f}")"; break; }
done

if [[ -r /boot/efi/loader/loader.conf ]]; then
	section "systemd-boot"
	printf '  loader.conf:\n'
	sed 's/^/    /' /boot/efi/loader/loader.conf
	printf '  引导条目:\n'
	ls -1 /boot/efi/loader/entries/ 2>/dev/null | sed 's/^/    /'
fi

if have_cmd efibootmgr; then
	printf '  efibootmgr:\n'
	efibootmgr 2>/dev/null | sed 's/^/    /' || printf '    （需要 root）\n'
fi

# ---------------------------------------------------------------------------
section "块设备与分区"

if have_cmd lsblk; then
	lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS 2>/dev/null | sed 's/^/  /'
fi
printf '  挂载点:\n'
findmnt -no SOURCE,TARGET,FSTYPE /          2>/dev/null | sed 's/^/    /'
findmnt -no SOURCE,TARGET,FSTYPE /boot/efi  2>/dev/null | sed 's/^/    /'

# ---------------------------------------------------------------------------
section "触屏（Himax HX83121A / SPI）"

TS="/sys/bus/spi/devices/spi0.0"
if [[ -e "${TS}" ]]; then
	kv "SPI 设备"     "${TS}"
	kv "modalias"     "$(read_one "${TS}/modalias")"
	kv "已绑定驱动"   "$(basename "$(readlink -f "${TS}/driver" 2>/dev/null)" 2>/dev/null)"
else
	kv "SPI 设备"     "未找到（触屏可能未被枚举）"
fi

if [[ -r /sys/kernel/debug/gpio ]]; then
	kv "gpio174（接口模式脚）" "$(awk '/^[[:space:]]*gpio174[[:space:]]*:/{ $1=""; $2=""; sub(/^[[:space:]]*/,""); print }' /sys/kernel/debug/gpio)"
	kv "gpio175（中断脚）"     "$(awk '/^[[:space:]]*gpio175[[:space:]]*:/{ $1=""; $2=""; sub(/^[[:space:]]*/,""); print }' /sys/kernel/debug/gpio)"
	kv "gpio99（复位脚）"      "$(awk '/^[[:space:]]*gpio99[[:space:]]*:/{ $1=""; $2=""; sub(/^[[:space:]]*/,""); print }' /sys/kernel/debug/gpio)"
	printf '  → 期望 gpio174 为 "out low"；若为 "out high" 则触屏必失效（见 README §2.1）\n'
else
	kv "GPIO 状态" "需要 root（cat /sys/kernel/debug/gpio）"
fi

if [[ -r "${TLMM_DEBUGFS}/pinmux-pins" ]]; then
	printf '  pinctrl 占用:\n'
	grep -E '^pin (99|174|175) ' "${TLMM_DEBUGFS}/pinmux-pins" 2>/dev/null | sed 's/^/    /'
else
	printf '  pinctrl 占用: 需要 root\n'
fi

if [[ -r /proc/interrupts ]]; then
	printf '  触屏中断:\n'
	grep 'himax-spi-ts' /proc/interrupts 2>/dev/null | sed 's/^/    /' || printf '    （未注册）\n'
fi

for d in ${DT}/soc@0/*pinctrl*/*ts0-default-state; do
	[[ -d "${d}" ]] || continue
	printf '  设备树 ts0-default-state 子节点:\n'
	ls -1 "${d}" 2>/dev/null | sed 's/^/    /'
	printf '    → 若缺少 mode-n-pins，说明 DTB 未含 gpio174 修复\n'
done

# ---------------------------------------------------------------------------
section "子系统抽查"

kv "内屏连接器"     "$(read_one /sys/class/drm/card0-DSI-1/status)"
kv "背光"           "$(cat /sys/class/backlight/*/brightness 2>/dev/null | head -n1) / $(cat /sys/class/backlight/*/max_brightness 2>/dev/null | head -n1)"
kv "热区最高温"     "$(cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -rn | head -n1)（毫摄氏度）"
for f in /sys/class/power_supply/*/uevent; do
	[[ -r "${f}" ]] || continue
	n="$(grep -m1 '^POWER_SUPPLY_NAME=' "${f}" | cut -d= -f2)"
	printf '  %-26s %s\n' "电源 ${n}" \
		"$(grep -E 'POWER_SUPPLY_(STATUS|CAPACITY|ONLINE)=' "${f}" | cut -d= -f2 | paste -sd' ' -)"
done

if have_cmd aplay; then
	printf '  ALSA 播放设备:\n'
	aplay -l 2>/dev/null | sed 's/^/    /' || true
fi

printf '  Wi-Fi / 网络:\n'
	ip -brief addr show 2>/dev/null | sed 's/^/    /'

# ---------------------------------------------------------------------------
section "已知问题相关日志"

if have_cmd dmesg || [[ -r /var/log/kern.log ]]; then
	DMESG="$(dmesg 2>/dev/null || cat /var/log/kern.log 2>/dev/null || true)"
	printf '  himax / 触屏:\n'
	printf '%s\n' "${DMESG}" | grep -iE 'himax|hx831' | tail -n 8 | sed 's/^/    /' || true
	printf '  视频硬解 (venus):\n'
	printf '%s\n' "${DMESG}" | grep -iE 'venus|video-codec' | tail -n 6 | sed 's/^/    /' || true
	printf '  音频:\n'
	printf '%s\n' "${DMESG}" | grep -iE 'snd_soc|soundwire|qcom-apm|gprsvc' | tail -n 8 | sed 's/^/    /' || true
	printf '  EC:\n'
	printf '%s\n' "${DMESG}" | grep -iE 'gaokun-ec|ucsi' | tail -n 6 | sed 's/^/    /' || true
else
	printf '  （无法读取内核日志，需要 root）\n'
fi

if have_cmd systemctl; then
	printf '  失败的 systemd 单元:\n'
	systemctl --failed --no-legend 2>/dev/null | sed 's/^/    /' || true
fi

# ---------------------------------------------------------------------------
section "报告结束"
printf '  请把本文件完整附在 issue 中，并说明你的机型属于三者中的哪一个。\n'
printf '  项目：%s\n' "${PROJECT_URL}"
