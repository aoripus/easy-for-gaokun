#!/usr/bin/env bash
#
# 30-audio.sh — 音频（扬声器）诊断与调优（SC8280XP / gaokun3）
#
# 背景
# ----
# 基线镜像把本机显式映射到 Lenovo ThinkPad X13s 的 UCM2 profile。两台机器的
# codec（WCD9385）、功放（WSA8830 ×2）、DAI 链路完全相同，所以能正常出声；
# 但 X13s 是双扬声器机型，其 BootSequence 把功放增益写成 12 —— 按 wsa883x 的
# PA Volume dB 曲线（0..14 = −3.00 dB 平段），12 就是 −3.00 dB。
#
# 内核 sound/soc/qcom/sc8280xp.c 把 "SpkrLeft/Right PA Volume" 硬性限幅到 17
# （+1.50 dB），硬件本身可到 +18 dB。也就是说：跑在 −3.00 dB，而内核允许的
# 上限是 +1.50 dB，白白放弃了 4.5 dB。
#
# 本脚本做的事
# ------------
#   1) 写入一份 gaokun3 专用 UCM2 profile（config/ucm2/.../HUAWEI-GK-W7X.conf），
#      内容与上游等价，只有 PA Volume 从 12 提到 17；
#   2) 以 ${CardLongName}.conf 的形式挂进 conf.d/sc8280xp/ —— ucm2 的查找顺序是
#      conf.d/<driver>/<CardLongName>.conf 优先于 conf.d/<driver>/<driver>.conf，
#      因此本文件优先于基线镜像那份 DMI 分发器，且不会被包更新覆盖；
#   3) 重启 PipeWire / WirePlumber，使新 profile 立刻生效。
#
# 安全边界（重要）
# ----------------
# 本项目**只**把增益提到内核限幅值 17，**绝不取消内核限幅**。Linux 侧目前没有
# 任何主动扬声器保护：WSA8830 的 VISENSE（电流/电压反馈）在 UCM 里被显式关闭，
# ADSP 的 Speaker Protection 模块默认关闭且没有 ACPI/ACDB 调音数据。越过限幅
# 有烧毁扬声器的实际风险（X13s 社区有多起此类报告，见 docs/audio.md §5）。
#
# 用法
# ----
#   sudo ./scripts/30-audio.sh                 # 诊断 → 应用 → 验证
#   sudo ./scripts/30-audio.sh --diagnose      # 仅诊断，不修改任何状态
#   sudo ./scripts/30-audio.sh --revert        # 撤销本脚本的改动
#   sudo ./scripts/30-audio.sh --softclip      # 附带打开 WSA macro 软限幅（实验性，不持久化）
#   sudo ./scripts/30-audio.sh --help
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"
readonly REPO_ROOT
readonly PROFILE_SRC="${REPO_ROOT}/config/ucm2/Qualcomm/sc8280xp/HUAWEI-GK-W7X.conf"

readonly UCM_ROOT="/usr/share/alsa/ucm2"
readonly UCM_PROFILE_DIR="${UCM_ROOT}/Qualcomm/sc8280xp"
readonly UCM_PROFILE_DST="${UCM_PROFILE_DIR}/HUAWEI-GK-W7X.conf"
readonly UCM_CONFD_ROOT="${UCM_ROOT}/conf.d"
readonly UCM_DISTRO_PROFILE="${UCM_PROFILE_DIR}/LENOVO-X13s.conf"

readonly BACKUP_DIR="/var/lib/easy-for-gaokun/audio/backup"

# /proc/asound/cards 中用于定位本机声卡的 model 片段。
readonly CARD_MATCH="GAOKUN3"
# 内核实测的 PA Volume 上限（snd_soc_limit_volume(card, "SpkrLeft PA Volume", 17)）。
readonly PA_VOLUME_LIMIT=17
# 内核同时把数字音量限到 81（−3.00 dB）。
readonly DIGITAL_VOLUME_LIMIT=81
# 基线镜像里 X13s profile 写入的功放增益（−3.00 dB），--revert 时用它还原。
readonly PA_VOLUME_BASELINE=12
# 本项目 profile 在 conf.d 中的链接目标。
readonly CONF_LINK_TARGET="../../Qualcomm/sc8280xp/HUAWEI-GK-W7X.conf"
# 等待功放增益生效的最长秒数（UCM 的 BootSequence 在设备被打开时才执行，时机不确定）。
readonly VERIFY_TIMEOUT=12

ACTION="apply"
ENABLE_SOFTCLIP=0
for _arg in "$@"; do
	case "${_arg}" in
		--diagnose|-n) ACTION="diagnose" ;;
		--apply|-a)    ACTION="apply" ;;
		--revert|-r)   ACTION="revert" ;;
		--softclip)    ENABLE_SOFTCLIP=1 ;;
		--help|-h)
			sed -n '3,41p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
			exit 0 ;;
		*) die "未知参数：${_arg}（可用：--diagnose / --apply / --revert / --softclip / --help）" ;;
	esac
done
unset _arg

# ===========================================================================
# 只读探针
# ===========================================================================

# 本机声卡的卡号。
card_number() {
	awk -v m="${CARD_MATCH}" '/^ *[0-9]+ \[/ && toupper($0) ~ m { print $1; exit }' \
		/proc/asound/cards 2>/dev/null
}

# 本机声卡的驱动名（ucm2 用它选 conf.d/<driver>/ 目录）。
card_driver() {
	awk -v m="${CARD_MATCH}" '
		/^ *[0-9]+ \[/ && toupper($0) ~ m { sub(/^[^]]*\]:[[:space:]]*/, ""); print $1; exit }
	' /proc/asound/cards 2>/dev/null
}

# 本机声卡的 CardLongName。/proc/asound/cards 中紧跟在卡号行之后的缩进行即是。
card_longname() {
	local n
	n="$(card_number)"
	[ -n "${n}" ] || return 1
	awk -v n="${n}" '
		$0 ~ "^ *" n " \\[" { hit = 1; next }
		hit && NF { gsub(/^[[:space:]]+|[[:space:]]+$/, ""); print; exit }
	' /proc/asound/cards 2>/dev/null
}

# 混音器控件的当前值（多值控件取第一个）；控件不存在时输出空串。
ctl_value() {
	amixer -c "$1" cget name="$2" 2>/dev/null |
		awk -F'= *' '/: values=/ { split($2, v, ","); print v[1]; exit }'
}

# 混音器控件的取值上限（min-max 区间里的 max）。
ctl_max() {
	amixer -c "$1" cget name="$2" 2>/dev/null |
		sed -n 's/.*,max=\([0-9][0-9]*\),.*/\1/p' | head -n 1
}

# 混音器控件是否存在。
ctl_exists() {
	[ -n "$(ctl_max "$1" "$2")" ] || [ -n "$(ctl_value "$1" "$2")" ]
}

# ucm2 实际会加载的 conf.d 分发文件。
ucm_active_link() {
	local longname="$1" driver="$2" p
	for p in "${UCM_CONFD_ROOT}/${driver}/${longname}.conf" \
	         "${UCM_CONFD_ROOT}/${driver}/${driver}.conf"; do
		if [ -e "${p}" ]; then
			readlink -f "${p}"
			return 0
		fi
	done
	return 1
}

# 活跃的 PipeWire 运行时目录。
pw_runtime_dir() {
	local d
	for d in /run/user/*; do
		[ -S "${d}/pipewire-0" ] || continue
		printf '%s\n' "${d}"
		return 0
	done
	return 1
}

# 以桌面用户身份执行命令。
as_desktop_user() {
	local d="$1" uid user
	shift
	uid="$(basename -- "${d}")"
	user="$(getent passwd "${uid}" | cut -d: -f1)"
	[ -n "${user}" ] || return 1
	run sudo -u "${user}" \
		env "XDG_RUNTIME_DIR=${d}" "DBUS_SESSION_BUS_ADDRESS=unix:path=${d}/bus" "$@"
}

# 重启音频栈使 UCM 重新解析；失败不致命（重新登录亦可生效）。
restart_audio_stack() {
	local d
	if ! d="$(pw_runtime_dir)"; then
		log_warn "未找到运行中的 PipeWire 会话；UCM 改动将在下次登录时生效。"
		return 0
	fi
	if ! have_cmd systemctl; then
		log_warn "系统无 systemctl；请重新登录以使 UCM 改动生效。"
		return 0
	fi
	log_info "正在重启桌面会话的音频栈（WirePlumber / PipeWire）……"
	as_desktop_user "${d}" systemctl --user try-restart wireplumber.service >/dev/null 2>&1 || true
	as_desktop_user "${d}" systemctl --user try-restart pipewire.service pipewire-pulse.service \
		>/dev/null 2>&1 || true
	sleep 2
}

# 把两个功放增益立刻写成指定值。之所以要"立刻写"，是因为 UCM 的 BootSequence
# 只在设备被打开（由 PipeWire/WirePlumber 触发）时执行一次，时机并不可靠：
# 实测音效卡在空闲时会掉电复位，复位后控件回到驱动默认值 0，而 BootSequence 不会重跑。
# 直接写 + alsactl store 是可靠路径；UCM profile 则是声明式的长期修复，两者目标一致。
set_pa_volume() {
	local card="$1" value="$2" name
	for name in 'SpkrLeft PA Volume' 'SpkrRight PA Volume'; do
		if ! ctl_exists "${card}" "${name}"; then
			log_warn "控件 ${name} 不存在，跳过。"
			continue
		fi
		run amixer -c "${card}" cset name="${name}" "${value}" >/dev/null
	done
}

# 把当前混音器状态存到 /var/lib/alsa/asound.state，由开机时的 alsa-restore.service 恢复。
persist_mixer_state() {
	if ! have_cmd alsactl; then
		log_warn "系统无 alsactl；混音器状态不会跨重启保持，UCM profile 仍是生效路径。"
		return 0
	fi
	run alsactl store >/dev/null 2>&1 || log_warn "alsactl store 失败（混音器状态未持久化）。"
}

# 等待两个功放增益达到期望值；返回 0 表示已达到。
wait_pa_volume() {
	local card="$1" want="$2" i val
	for ((i = 0; i < VERIFY_TIMEOUT; i++)); do
		val="$(ctl_value "${card}" 'SpkrLeft PA Volume')"
		[ "${val}" = "${want}" ] && return 0
		sleep 1
	done
	return 1
}

# ===========================================================================
# 前置条件
# ===========================================================================

check_preconditions() {
	local card
	card="$(card_number)"
	if [ -z "${card}" ]; then
		die "在 /proc/asound/cards 中找不到 ${CARD_MATCH} 声卡；本脚本只适用于 MateBook E Go 2022 性能版（gaokun3）。"
	fi
	if [ ! -d "${UCM_PROFILE_DIR}" ]; then
		die "找不到 ${UCM_PROFILE_DIR}；请先安装 alsa-ucm-conf。"
	fi
	if [ ! -f "${UCM_DISTRO_PROFILE}" ]; then
		log_warn "未找到 ${UCM_DISTRO_PROFILE}（基线镜像本应提供）。继续安装本项目的 profile。"
	fi
}

# ===========================================================================
# 诊断
# ===========================================================================

do_diagnose() {
	local card driver longname link val vmax

	card="$(card_number)"
	driver="$(card_driver)"
	longname="$(card_longname)"

	result_section "声卡与 UCM 绑定"
	if [ -z "${card}" ]; then
		result_row "声卡识别" FAIL "未找到 ${CARD_MATCH} 声卡"
		return 0
	fi
	result_row "声卡" PASS "card ${card}（驱动 ${driver}）"
	result_row "CardLongName" PASS "${longname}"
	if link="$(ucm_active_link "${longname}" "${driver}")"; then
		result_row "ucm2 生效 profile" PASS "${link}"
		case "${link}" in
			*LENOVO-X13s.conf)
				result_row "gaokun3 专用 profile" WARN "当前为 X13s 双扬声器 profile（PA Volume 12 = -3.00 dB）" ;;
			*HUAWEI-GK-W7X.conf)
				result_row "gaokun3 专用 profile" PASS "已安装本项目 profile" ;;
			*)
				result_row "gaokun3 专用 profile" WARN "未知 profile" ;;
		esac
	else
		result_row "ucm2 生效 profile" FAIL "conf.d 下没有任何分发文件"
	fi

	result_section "功放增益（关键）"
	if ! ctl_exists "${card}" 'SpkrLeft PA Volume'; then
		result_row "SpkrLeft PA Volume" FAIL "控件不存在"
	else
		val="$(ctl_value "${card}" 'SpkrLeft PA Volume')"
		vmax="$(ctl_max "${card}" 'SpkrLeft PA Volume')"
		if [ "${vmax}" = "${PA_VOLUME_LIMIT}" ]; then
			result_row "SpkrLeft PA Volume" PASS "值 ${val}，上限 ${vmax}（内核限幅符合预期）"
		else
			result_row "SpkrLeft PA Volume" WARN "值 ${val}，上限 ${vmax}（预期上限 ${PA_VOLUME_LIMIT}）"
		fi
		if [ "${val}" -le 14 ] 2>/dev/null; then
			result_row "PA 增益折算" WARN "${val} → -3.00 dB（0..14 平台段，未利用可用余量）"
		elif [ "${val}" -ge 30 ] 2>/dev/null; then
			result_row "PA 增益折算" WARN "${val} → +18.00 dB（硬件最高档，已超出内核限幅）"
		else
			# TLV DB_RANGE 换算：dB(单位 0.01 dB) = min_dB + (value - min_index) * step
			local cdb=$(( -300 + (val - 15) * 150 )) sign='+'
			if [ "${cdb}" -lt 0 ]; then
				sign='-'
				cdb=$(( -cdb ))
			fi
			result_row "PA 增益折算" PASS \
				"$(printf '%s%d.%02d dB（硬件最高档 +18.00 dB）' \
					"${sign}" "$((cdb / 100))" "$((cdb % 100))")"
		fi
	fi
	val="$(ctl_value "${card}" 'SpkrRight PA Volume')"
	result_row "SpkrRight PA Volume" \
		"$([ -n "${val}" ] && printf 'PASS' || printf 'FAIL')" "值 ${val:-不存在}"

	result_section "数字侧与限幅器"
	val="$(ctl_value "${card}" 'WSA_RX0 Digital Volume')"
	vmax="$(ctl_max "${card}" 'WSA_RX0 Digital Volume')"
	if [ "${vmax}" = "${DIGITAL_VOLUME_LIMIT}" ]; then
		result_row "WSA_RX0 Digital Volume" PASS "值 ${val}，上限 ${vmax}（内核限幅 = -3.00 dB）"
	else
		result_row "WSA_RX0 Digital Volume" WARN "值 ${val}，上限 ${vmax}（预期 ${DIGITAL_VOLUME_LIMIT}）"
	fi
	for c in 'WSA_Softclip0 Enable' 'WSA_Softclip1 Enable'; do
		val="$(ctl_value "${card}" "${c}")"
		result_row "${c}" PASS "${val:-不存在}"
	done

	result_section "扬声器保护（Linux 侧当前均未启用）"
	for c in 'SpkrLeft VISENSE Switch' 'SpkrRight VISENSE Switch' \
	         'WSA_AIF_VI Mixer WSA_SPKR_VI_1' 'WSA_AIF_VI Mixer WSA_SPKR_VI_2'; do
		val="$(ctl_value "${card}" "${c}")"
		result_row "${c}" WARN "${val:-不存在}"
	done
	result_row "ADSP Speaker Protection" WARN "无公开开关，且无 ACDB 调音数据"

	result_section "DSP 拓扑与播放链路"
	local tplg="/lib/firmware/qcom/sc8280xp/SC8280XP-HUAWEI-GAOKUN3-tplg.bin"
	if [ -e "${tplg}" ]; then
		result_row "AudioReach 拓扑" PASS "$(readlink -f "${tplg}")"
	else
		result_row "AudioReach 拓扑" FAIL "缺少 ${tplg}（DSP 链路无法建立）"
	fi
	for c in 'WSA RX0 MUX' 'WSA RX1 MUX' 'WSA_RX0 INP0' 'WSA_RX1 INP0' \
	         'WSA_CODEC_DMA_RX_0 Audio Mixer MultiMedia2' \
	         'SpkrLeft DAC Switch' 'SpkrLeft COMP Switch' 'SpkrLeft BOOST Switch' \
	         'SpkrRight DAC Switch' 'SpkrRight COMP Switch' 'SpkrRight BOOST Switch'; do
		val="$(ctl_value "${card}" "${c}")"
		result_row "${c}" "$([ -n "${val}" ] && printf 'PASS' || printf 'WARN')" "${val:-不存在}"
	done
	return 0
}

# 应用后的验收：profile 是否切换、PA 增益是否达到内核上限。
do_verify() {
	local card driver longname link val ok=1

	card="$(card_number)"
	driver="$(card_driver)"
	longname="$(card_longname)"

	result_section "验收"
	if link="$(ucm_active_link "${longname}" "${driver}")"; then
		case "${link}" in
			*HUAWEI-GK-W7X.conf) result_row "ucm2 profile 已切换" PASS "${link}" ;;
			*) result_row "ucm2 profile 已切换" FAIL "仍指向 ${link}" ;;
		esac
	else
		result_row "ucm2 profile 已切换" FAIL "未找到 conf.d 分发文件"
	fi

	for c in 'SpkrLeft PA Volume' 'SpkrRight PA Volume'; do
		val="$(ctl_value "${card}" "${c}")"
		if [ "${val}" = "${PA_VOLUME_LIMIT}" ]; then
			result_row "${c}" PASS "${val}（内核限幅上限）"
		else
			result_row "${c}" WARN "值 ${val:-？}，期望 ${PA_VOLUME_LIMIT}"
			ok=0
		fi
	done
	if [ "${ok}" -eq 0 ]; then
		log_warn "功放增益未达到期望值。可能原因：音效卡空闲掉电复位后把控件恢复成驱动默认值，"
		log_warn "而 UCM 的 BootSequence 只在设备被打开时执行一次、不会重跑。"
		log_info "直接写法：amixer -c ${card} cset name='SpkrLeft PA Volume' ${PA_VOLUME_LIMIT}"
		log_info "或执行：  sudo $0 --apply   （本脚本会在安装后立即写一次并 alsactl store）"
	fi
	return 0
}

# ===========================================================================
# 应用 / 撤销
# ===========================================================================

do_apply() {
	local card driver longname confd
	check_preconditions
	card="$(card_number)"
	driver="$(card_driver)"
	longname="$(card_longname)"
	confd="${UCM_CONFD_ROOT}/${driver}"

	[ -f "${PROFILE_SRC}" ] || die "找不到项目内的 profile 源文件：${PROFILE_SRC}"
	[ -n "${longname}" ] || die "无法从 /proc/asound/cards 解析 CardLongName。"

	log_step "安装 gaokun3 专用 UCM2 profile"
	run install -d -m 0755 "${BACKUP_DIR}"
	run install -d -m 0755 "${confd}"

	# 备份 conf.d 下将被覆盖的同名普通文件（符号链接不需要备份）。
	if [ -f "${confd}/${longname}.conf" ] && [ ! -L "${confd}/${longname}.conf" ]; then
		log_info "备份既有 ${confd}/${longname}.conf → ${BACKUP_DIR}/"
		run cp -a "${confd}/${longname}.conf" "${BACKUP_DIR}/${longname}.conf"
	fi

	run install -m 0644 "${PROFILE_SRC}" "${UCM_PROFILE_DST}"
	log_ok "已写入 profile：${UCM_PROFILE_DST}"

	run ln -sfn "${CONF_LINK_TARGET}" "${confd}/${longname}.conf"
	log_ok "已挂载分发链接：${confd}/${longname}.conf → ${CONF_LINK_TARGET}"

	# 顺序很重要：UCM 的 BootSequence 在音频栈重启后约 1–2 秒才被真正执行，
	# 会覆盖此前写入的值。因此必须"先重启、等它跑完、再写最终值"。
	log_step "重启音频栈并等待 UCM 序列执行完毕"
	restart_audio_stack
	sleep 3

	log_step "写入功放增益并持久化"
	set_pa_volume "${card}" "${PA_VOLUME_LIMIT}"
	persist_mixer_state

	if [ "${ENABLE_SOFTCLIP}" -eq 1 ]; then
		log_step "启用 WSA macro 软限幅（实验性，运行期生效）"
		local c
		for c in 'WSA_Softclip0 Enable' 'WSA_Softclip1 Enable'; do
			if ctl_exists "${card}" "${c}"; then
				run amixer -c "${card}" cset name="${c}" on >/dev/null
				log_ok "${c} → on"
			else
				log_warn "控件 ${c} 不存在，跳过。"
			fi
		done
		log_warn "软限幅未写入 UCM，重启或重新打开设备后失效；需要时重新执行 --softclip。"
	fi

	restart_audio_stack
	sleep 3
	set_pa_volume "${card}" "${PA_VOLUME_LIMIT}"
	persist_mixer_state
	do_verify
	result_summary
}

do_revert() {
	local driver longname confd cur
	check_preconditions
	driver="$(card_driver)"
	longname="$(card_longname)"
	confd="${UCM_CONFD_ROOT}/${driver}"

	log_step "撤销音频调优"
	if [ -L "${confd}/${longname}.conf" ]; then
		cur="$(readlink -f "${confd}/${longname}.conf" || true)"
		if [ "${cur}" = "${UCM_PROFILE_DST}" ]; then
			run rm -f "${confd}/${longname}.conf"
			log_ok "已移除 ${confd}/${longname}.conf"
		else
			log_warn "${confd}/${longname}.conf 指向 ${cur}（非本项目文件），跳过删除。"
		fi
	elif [ -e "${confd}/${longname}.conf" ]; then
		log_warn "${confd}/${longname}.conf 是普通文件（非本项目生成），保留不动。"
	fi

	if [ -f "${UCM_PROFILE_DST}" ]; then
		run rm -f "${UCM_PROFILE_DST}"
		log_ok "已移除 ${UCM_PROFILE_DST}"
	fi

	if [ -f "${BACKUP_DIR}/${longname}.conf" ]; then
		run cp -a "${BACKUP_DIR}/${longname}.conf" "${confd}/${longname}.conf"
		log_ok "已还原备份 ${confd}/${longname}.conf"
	fi

	log_step "重启音频栈并等待 UCM 序列执行完毕"
	restart_audio_stack
	sleep 3

	log_step "把功放增益还原为基线值并持久化"
	set_pa_volume "$(card_number)" "${PA_VOLUME_BASELINE}"
	persist_mixer_state

	log_info "profile 已回退到基线镜像的 DMI 分发器（HUAWEI → LENOVO-X13s.conf，PA Volume 12 = -3.00 dB）。"
}

# ===========================================================================

case "${ACTION}" in
	diagnose)
		do_diagnose
		result_summary || true
		;;
	apply)
		require_root
		do_apply
		;;
	revert)
		require_root
		do_revert
		;;
esac
