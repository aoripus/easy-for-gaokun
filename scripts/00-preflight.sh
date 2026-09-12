#!/usr/bin/env bash
# =============================================================================
# easy-for-gaokun — 00-preflight.sh
#
# 设备预检：在改动系统之前确认这台机器确实是本项目唯一支持的机型
#   HUAWEI MateBook E Go 2022 性能版
#   Snapdragon 8cx Gen 3（Qualcomm SC8280XP），设备树代号 gaokun3
# 并确认运行环境（Ubuntu 26.04 aarch64 + gaokun3 专用内核）符合项目基线。
#
# 本脚本严格只读：
#   * 不写任何路径（连 /tmp 也不写）；
#   * 不调用 apt / dpkg / systemctl / modprobe 等任何改变系统状态的命令；
#   * 不加载模块，不写 /sys、/proc 下的任何节点。
#
# 退出码：
#   0 = 全部检查通过（允许存在 WARN）
#   1 = 存在 FAIL（不是目标机型 / 不满足项目基线 / 关键项无法确认）
#
# 用法：  sudo ./scripts/00-preflight.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)" || {
  printf '无法定位脚本所在目录：%s\n' "${BASH_SOURCE[0]}" >&2
  exit 1
}

if [[ ! -r "${SCRIPT_DIR}/lib/common.sh" ]]; then
  printf '缺少依赖：%s\n' "${SCRIPT_DIR}/lib/common.sh" >&2
  exit 1
fi
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

# =============================================================================
# 判定依据（与实机逐项核对过的判据，不是"观测值的硬编码"）
# =============================================================================
readonly DT_ROOT_PRIMARY="/proc/device-tree"
readonly DT_ROOT_FALLBACK="/sys/firmware/devicetree/base"

# 设备身份：compatible 必须同时包含这两项。
# ★ 实测目标机的 model 字符串只有 "Matebook E Go"，既不含 gaokun3 也不含 GK-W76，
#   因此 model 只用于展示，身份判定以 compatible 为准。
readonly EXPECTED_COMPAT_HUAWEI="huawei,gaokun3"
readonly EXPECTED_COMPAT_SOC="qcom,sc8280xp"

# 变体红线：2022 LTE 版 = Snapdragon 8cx Gen 2（SC8180X），设备树为 gaokun2。
readonly REJECT_DT_NAME="gaokun2"
readonly REJECT_COMPAT_SOC="qcom,sc8180x"

# 内屏面板：CSOT ppc357db1-4 为主，BOE ppc357db1-4 亦属同一变体。
readonly PANEL_DT_PATH="soc@0/display-subsystem@ae00000/dsi@ae94000/panel@0"
readonly PANEL_COMPAT_CSOT="csot,ppc357db1-4"
readonly PANEL_COMPAT_BOE="boe,ppc357db1-4"

# 触摸屏：Himax HX83121A，SPI 挂载于 998000.spi。
readonly EXPECTED_TOUCH_MODALIAS="spi:hx83121a-ts"
readonly TOUCH_SPI_DEVICE="/sys/bus/spi/devices/spi0.0"

# 引导：UEFI + systemd-boot，DTB 由 /etc/kernel/devicetree 显式指定。
readonly BOOT_EFI="/boot/efi"
readonly KERNEL_DEVICETREE_FILE="/etc/kernel/devicetree"

# =============================================================================
# 全局状态
# =============================================================================
DT_ROOT=""
PREFLIGHT_REDLINES=()

# =============================================================================
# 通用小工具
# =============================================================================

# redline_note <说明> — 记录一条已触发的设备鉴别红线，最终裁决时逐条列出
redline_note() {
  PREFLIGHT_REDLINES+=("$1")
}

# detail_line <标签> <值> — 输出一行缩进说明（stdout；仅展示，不参与判定）
detail_line() {
  printf '    %-28s %s\n' "$1" "${2:-}"
}

# read_first_line <文件> — 读取文件首行；文件不可读时返回 1
read_first_line() {
  local _path="$1" _line=""
  [[ -r "${_path}" ]] || return 1
  read -r _line <"${_path}" 2>/dev/null || true
  printf '%s' "${_line}"
}

# join_lines <分隔符> — 把 stdin 的每一行拼成单行输出
join_lines() {
  local _sep="$1" _out="" _line=""
  while IFS= read -r _line; do
    [[ -n "${_line}" ]] || continue
    if [[ -z "${_out}" ]]; then
      _out="${_line}"
    else
      _out="${_out}${_sep}${_line}"
    fi
  done
  printf '%s' "${_out}"
}

# os_release_value <键名> — 读取 /etc/os-release 中指定键的值（去掉包裹的引号）
os_release_value() {
  local _key="$1" _line=""
  [[ -r /etc/os-release ]] || return 1
  while IFS= read -r _line; do
    case "${_line}" in
      "${_key}="*)
        _line="${_line#*=}"
        _line="${_line%\"}"
        _line="${_line#\"}"
        printf '%s' "${_line}"
        return 0
        ;;
    esac
  done </etc/os-release
  return 1
}

# is_mounted <路径> — 该路径当前是否为挂载点（直接解析 /proc/self/mountinfo）
is_mounted() {
  local _target="$1"
  [[ -r /proc/self/mountinfo ]] || return 1
  awk -v t="${_target}" '$5 == t { found = 1 } END { exit(found ? 0 : 1) }' /proc/self/mountinfo
}

# mount_info <路径> — 输出 "<文件系统类型> <源设备>"；未知时输出空
mount_info() {
  local _target="$1"
  [[ -r /proc/self/mountinfo ]] || return 1
  awk -v t="${_target}" '
    $5 == t {
      for (i = 1; i <= NF; i++) {
        if ($i == "-") { print $(i + 1) " " $(i + 2); exit }
      }
    }
  ' /proc/self/mountinfo
}

# =============================================================================
# 设备树读取（一律做可读性保护，缺文件只会让该项检查降级，不会中止脚本）
# =============================================================================

# dt_string <DT 相对路径> — 读取设备树字符串属性并去掉结尾 NUL
dt_string() {
  local _path="${DT_ROOT}/$1"
  [[ -r "${_path}" ]] || return 1
  tr -d '\0' <"${_path}" 2>/dev/null
}

# dt_string_list <DT 相对路径> — 读取设备树字符串列表（NUL 分隔），逐行输出
dt_string_list() {
  local _path="${DT_ROOT}/$1"
  [[ -r "${_path}" ]] || return 1
  tr '\0' '\n' <"${_path}" 2>/dev/null
}

# dt_join <DT 相对路径> <分隔符> — 把字符串列表拼成单行
dt_join() {
  local _sep="$2" _out="" _line=""
  while IFS= read -r _line; do
    if [[ -n "${_line}" ]]; then
      if [[ -z "${_out}" ]]; then
        _out="${_line}"
      else
        _out="${_out}${_sep}${_line}"
      fi
    fi
  done < <(dt_string_list "$1")
  printf '%s' "${_out}"
}

# panel_compatibles — 全树搜索 panel* 节点并输出其 compatible 列表（逐行）
panel_compatibles() {
  local _dir
  [[ -n "${DT_ROOT}" ]] || return 1
  while IFS= read -r _dir; do
    if [[ -r "${_dir}/compatible" ]]; then
      tr '\0' '\n' <"${_dir}/compatible" 2>/dev/null || true
    fi
  done < <(find "${DT_ROOT}" -type d -name 'panel*' -print 2>/dev/null)
}

# =============================================================================
# 硬件状态读取
# =============================================================================

# max_cpu_khz — 取全部 CPU 的 cpuinfo_max_freq 最大值（kHz）；全部读不到时输出 0
max_cpu_khz() {
  local _file="" _val="" _max=0
  for _file in /sys/devices/system/cpu/cpu*/cpufreq/cpuinfo_max_freq; do
    [[ -r "${_file}" ]] || continue
    _val=""
    read -r _val <"${_file}" 2>/dev/null || true
    [[ "${_val}" =~ ^[0-9]+$ ]] || continue
    if ((_val > _max)); then
      _max="${_val}"
    fi
  done
  printf '%d' "${_max}"
}

# fmt_ghz <kHz> — 把 kHz 格式化为 GHz（保留三位小数，便于与标称频率对照）
fmt_ghz() {
  local _khz="$1"
  printf '%d.%03d GHz' "$((_khz / 1000000))" "$(((_khz / 1000) % 1000))"
}

# connected_connectors — 输出所有 status=connected 的 DRM 连接器名（每行一个）
connected_connectors() {
  local _dir="" _status=""
  for _dir in /sys/class/drm/*; do
    [[ -r "${_dir}/status" ]] || continue
    _status=""
    read -r _status <"${_dir}/status" 2>/dev/null || true
    if [[ "${_status}" == "connected" ]]; then
      printf '%s\n' "${_dir##*/}"
    fi
  done
}

# drm_card_names — 输出 DRM 卡设备名（如 card0），每行一个
drm_card_names() {
  local _dir=""
  for _dir in /sys/class/drm/card[0-9]; do
    if [[ -e "${_dir}" ]]; then printf '%s\n' "${_dir##*/}"; fi
  done
}

# devfreq_names — 输出 devfreq 设备名（如 3d00000.gpu），每行一个
devfreq_names() {
  local _dir=""
  for _dir in /sys/class/devfreq/*; do
    if [[ -e "${_dir}" ]]; then printf '%s\n' "${_dir##*/}"; fi
  done
}

# gpu_nodes — 输出平台总线上的 GPU 设备节点名（如 3d00000.gpu），每行一个
gpu_nodes() {
  local _dir=""
  for _dir in /sys/bus/platform/devices/*.gpu; do
    if [[ -e "${_dir}" ]]; then printf '%s\n' "${_dir##*/}"; fi
  done
}

# loader_entry_matches <条目名（不含 .conf）> <default 值> — 默认项是否指向该条目
loader_entry_matches() {
  local _name="$1" _default="$2"
  [[ -n "${_default}" ]] || return 1
  # 精确匹配：systemd-boot 允许 default 写条目名，也允许写带 .conf 的文件名。
  if [[ "${_name}" == "${_default}" || "${_name}.conf" == "${_default}" ]]; then
    return 0
  fi
  # 通配符匹配：systemd-boot 的 default 支持 glob 写法（如 ubuntu-*）。
  case "${_default}" in
    *[*?[]*) ;;
    *) return 1 ;;
  esac
  # shellcheck disable=SC2053  # 此处有意让右侧按通配符解释
  if [[ "${_name}" == ${_default} || "${_name}.conf" == ${_default} ]]; then
    return 0
  fi
  return 1
}

# =============================================================================
# 检查 1：系统与架构
# =============================================================================
check_os_arch() {
  result_section "1. 系统与架构"
  local _arch="" _os_id="" _os_ver="" _os_name=""

  _arch="$(uname -m)"
  if [[ "${_arch}" == "${SUPPORTED_ARCH}" ]]; then
    result_row "CPU 架构" PASS "uname -m = ${_arch}"
  else
    result_row "CPU 架构" FAIL "期望 ${SUPPORTED_ARCH}，实际 ${_arch}；本项目的内核、DTB 与补丁仅面向 aarch64"
    redline_note "架构不匹配：当前 ${_arch}，本项目仅支持 ${SUPPORTED_ARCH}"
  fi

  _os_id="$(os_release_value ID || true)"
  _os_ver="$(os_release_value VERSION_ID || true)"
  _os_name="$(os_release_value PRETTY_NAME || true)"
  detail_line "/etc/os-release" "${_os_name:-<不可读>}"

  if [[ "${_os_id}" != "ubuntu" ]]; then
    result_row "发行版" FAIL "期望 ID=ubuntu，实际 ID=${_os_id:-<不可读>}；本项目基线为 Ubuntu 26.04 LTS aarch64"
    redline_note "发行版不匹配：本项目基线为 Ubuntu 26.04 aarch64（当前 ID=${_os_id:-未知}）"
  elif [[ "${_os_ver}" == "26.04" ]]; then
    result_row "发行版" PASS "Ubuntu ${_os_ver}（项目基线版本）"
  else
    result_row "发行版" WARN "Ubuntu ${_os_ver}，项目基线为 26.04；其它版本未经验证"
  fi
  return 0
}

# =============================================================================
# 检查 2：内核
# =============================================================================
check_kernel() {
  result_section "2. 内核"
  local _rel=""

  _rel="$(uname -r)"
  if [[ "${_rel}" == *"${SUPPORTED_KERNEL_SUBSTR}"* ]]; then
    result_row "内核代号" PASS "uname -r = ${_rel}，含 '${SUPPORTED_KERNEL_SUBSTR}'"
  else
    result_row "内核代号" FAIL "uname -r = ${_rel}，不含 '${SUPPORTED_KERNEL_SUBSTR}'；未运行 gaokun3 专用内核，DTB 与补丁均不成立"
    redline_note "内核不含 '${SUPPORTED_KERNEL_SUBSTR}'：请刷入基线内核 7.1.0-rc3-gaokun3-el2+"
  fi

  if [[ "${_rel}" == *"el2"* ]]; then
    result_row "EL2 标记" PASS "release 含 'el2'（基线构建为 7.1.0-rc3-gaokun3-el2+）"
  else
    result_row "EL2 标记" WARN "release 不含 'el2'；基线构建为 7.1.0-rc3-gaokun3-el2+，可能不是同一构建"
  fi
  return 0
}

# =============================================================================
# 检查 3：设备树身份（含变体红线）
# =============================================================================
check_devicetree() {
  result_section "3. 设备树身份"
  local _model="" _compat="" _chassis="" _dmi_vendor="" _dmi_product="" _dmi_board=""

  if [[ -z "${DT_ROOT}" ]]; then
    result_row "设备树可读性" FAIL "既无法读取 ${DT_ROOT_PRIMARY}，也无法读取 ${DT_ROOT_FALLBACK}；无法完成设备身份鉴别"
    redline_note "设备树不可读：无法确认目标机型"
    return 0
  fi

  detail_line "设备树根路径" "${DT_ROOT}"
  _model="$(dt_string model || true)"
  _compat="$(dt_join compatible ', ' || true)"
  _chassis="$(dt_string chassis-type || true)"
  detail_line "型号（model）" "${_model:-<不可读>}"
  detail_line "兼容性（compatible）" "${_compat:-<不可读>}"
  detail_line "机身形态（chassis-type）" "${_chassis:-<不可读>}"

  # DMI 仅作信息展示，不参与判定。
  # ★ 实测目标机的 DMI product_name 为 GK-W7X（不是 GK-W76）；型号字符串无论
  #   是 GK-W76 还是 GK-W7X 都不足以区分 2022 性能版 / 2023 版，
  #   因此这里不做任何基于型号字符串的硬匹配，身份判定只认 compatible。
  _dmi_vendor="$(read_first_line /sys/class/dmi/id/sys_vendor || true)"
  _dmi_product="$(read_first_line /sys/class/dmi/id/product_name || true)"
  _dmi_board="$(read_first_line /sys/class/dmi/id/board_name || true)"
  detail_line "DMI 厂商/产品/主板" "${_dmi_vendor:-?} / ${_dmi_product:-?} / ${_dmi_board:-?}"

  if [[ "${_compat}" == *"${REJECT_DT_NAME}"* || "${_compat}" == *"${REJECT_COMPAT_SOC}"* ||
        "${_model}" == *"${REJECT_DT_NAME}"* ]]; then
    result_row "设备身份" FAIL "compatible 中出现 ${REJECT_DT_NAME} / ${REJECT_COMPAT_SOC} —— 这是 MateBook E Go 2022 LTE 版（8cx Gen 2 / Adreno 680），不是本项目目标机型"
    redline_note "触犯红线：MateBook E Go 2022 LTE 版（${REJECT_DT_NAME} / SC8180X）"
  elif [[ "${_compat}" != *"qcom,"* ]]; then
    result_row "设备身份" FAIL "compatible 中没有任何 qcom, 条目（实际：${_compat:-空}）—— 非 Qualcomm 平台"
    redline_note "触犯红线：非 Qualcomm 平台（${_compat:-compatible 为空}）"
  elif [[ "${_compat}" == *"${EXPECTED_COMPAT_HUAWEI}"* && "${_compat}" == *"${EXPECTED_COMPAT_SOC}"* ]]; then
    result_row "设备身份" PASS "compatible 同时含 ${EXPECTED_COMPAT_HUAWEI} 与 ${EXPECTED_COMPAT_SOC}（model=${_model:-?}）"
  else
    result_row "设备身份" FAIL "compatible 未同时包含 ${EXPECTED_COMPAT_HUAWEI} 与 ${EXPECTED_COMPAT_SOC}（实际：${_compat:-空}）"
    redline_note "触犯红线：设备树身份不是 gaokun3 / SC8280XP（${_compat:-compatible 为空}）"
  fi
  return 0
}

# =============================================================================
# 检查 4：CPU 变体红线（2022 性能版 vs 2023 降频版）
# =============================================================================
check_cpu_freq() {
  result_section "4. CPU 变体红线"
  local _max_khz=""

  _max_khz="$(max_cpu_khz)"
  detail_line "全部 CPU 最高频率" "$(fmt_ghz "${_max_khz}")（${_max_khz} kHz）"
  detail_line "判定阈值" "$(fmt_ghz "${EXPECTED_CPU_MAX_KHZ_MIN}")（${EXPECTED_CPU_MAX_KHZ_MIN} kHz）"

  if ((_max_khz == 0)); then
    result_row "CPU 最高频率" WARN "读不到任何 .../cpufreq/cpuinfo_max_freq（cpufreq 未启用？），无法判定变体"
  elif ((_max_khz >= EXPECTED_CPU_MAX_KHZ_MIN)); then
    result_row "CPU 最高频率" PASS "最高 ${_max_khz} kHz（$(fmt_ghz "${_max_khz}")）≥ 阈值 ${EXPECTED_CPU_MAX_KHZ_MIN} kHz，符合 2022 性能版（满血 8cx Gen 3，约 3.0 GHz）"
  else
    result_row "CPU 最高频率" FAIL "最高 ${_max_khz} kHz（$(fmt_ghz "${_max_khz}")）低于阈值 ${EXPECTED_CPU_MAX_KHZ_MIN} kHz；约 2.69 GHz 说明这是 MateBook E Go 2023 降频版，本项目不支持该变体"
    redline_note "触犯红线：CPU 最高频率 ${_max_khz} kHz（$(fmt_ghz "${_max_khz}")），疑似 2023 降频版（约 2.69 GHz）"
  fi
  return 0
}

# =============================================================================
# 检查 5：显示、面板与 GPU
# =============================================================================
check_display() {
  result_section "5. 显示、面板与 GPU"
  local _connectors="" _panel_compat="" _dri_name="" _tok=""
  local _gpu_nodes="" _devfreq="" _drm_cards=""
  local _found_csot=0 _found_boe=0
  local -a _tokens=()

  _connectors="$(connected_connectors | join_lines ', ' || true)"
  if [[ -z "${_connectors}" ]]; then
    result_row "显示连接器" FAIL "没有任何 status=connected 的 DRM 连接器；内屏未点亮或显示子系统未初始化"
  elif [[ ", ${_connectors}," == *", card0-DSI-1,"* ]]; then
    result_row "显示连接器" PASS "内屏 card0-DSI-1 已连接（全部 connected：${_connectors}）"
  else
    result_row "显示连接器" WARN "存在 connected 连接器，但未见内屏 card0-DSI-1（实际：${_connectors}）"
  fi

  # 面板 compatible：优先读实机确认过的 DT 路径，读不到再全树搜索 panel 节点。
  if [[ -n "${DT_ROOT}" && -r "${DT_ROOT}/${PANEL_DT_PATH}/compatible" ]]; then
    _panel_compat="$(dt_join "${PANEL_DT_PATH}/compatible" ' ' || true)"
  elif [[ -n "${DT_ROOT}" ]]; then
    _panel_compat="$(panel_compatibles | join_lines ' ' || true)"
  fi
  detail_line "内屏 panel compatible" "${_panel_compat:-<不可读>}"

  if [[ -n "${_panel_compat}" ]]; then
    IFS=' ' read -r -a _tokens <<<"${_panel_compat}"
    for _tok in "${_tokens[@]}"; do
      if [[ "${_tok}" == "${PANEL_COMPAT_CSOT}" ]]; then _found_csot=1; fi
      if [[ "${_tok}" == "${PANEL_COMPAT_BOE}" ]]; then _found_boe=1; fi
    done
  fi

  if ((_found_csot == 1 || _found_boe == 1)); then
    result_row "内屏面板" PASS "compatible 含 ppc357db1-4（${_panel_compat}）"
  elif [[ -n "${_panel_compat}" ]]; then
    result_row "内屏面板" FAIL "面板 compatible 为 '${_panel_compat}'，既不含 ${PANEL_COMPAT_CSOT} 也不含 ${PANEL_COMPAT_BOE}"
    redline_note "内屏面板不匹配：期望 ppc357db1-4，实际 ${_panel_compat}"
  else
    result_row "内屏面板" WARN "未能从设备树定位 panel 节点，无法确认面板型号"
  fi

  # GPU 仅作信息展示、不参与判定：
  # ★ sysfs 中并不存在 "Adreno 690" 之类的可读名称，GPU 只能通过平台设备节点、
  #   devfreq 条目与 DRM 卡设备辨认，因此这里不做任何基于 GPU 名称字符串的匹配。
  _gpu_nodes="$(gpu_nodes | join_lines ', ' || true)"
  _devfreq="$(devfreq_names | join_lines ', ' || true)"
  _drm_cards="$(drm_card_names | join_lines ', ' || true)"
  detail_line "GPU 设备节点" "${_gpu_nodes:-（无）}"
  detail_line "devfreq 设备" "${_devfreq:-（无）}"
  detail_line "DRM 卡设备" "${_drm_cards:-（无）}"
  if [[ -r /sys/kernel/debug/dri/0/name ]]; then
    _dri_name="$(read_first_line /sys/kernel/debug/dri/0/name || true)"
    detail_line "DRM 名称（debugfs）" "${_dri_name:-<不可读>}"
  fi
  return 0
}

# =============================================================================
# 检查 6：触摸屏设备
# =============================================================================
check_touch() {
  result_section "6. 触摸屏设备"
  local _modalias="" _driver_path="" _driver=""

  if [[ ! -e "${TOUCH_SPI_DEVICE}" ]]; then
    result_row "触控 SPI 设备" FAIL "${TOUCH_SPI_DEVICE} 不存在；未枚举到 Himax HX83121A 触控 IC"
    redline_note "触屏设备缺失：${TOUCH_SPI_DEVICE}（期望 modalias ${EXPECTED_TOUCH_MODALIAS}）"
    return 0
  fi

  detail_line "设备路径" "${TOUCH_SPI_DEVICE}"
  _modalias="$(read_first_line "${TOUCH_SPI_DEVICE}/modalias" || true)"
  _driver_path="$(readlink -f -- "${TOUCH_SPI_DEVICE}/driver" 2>/dev/null || true)"
  _driver="${_driver_path##*/}"
  detail_line "modalias" "${_modalias:-<不可读>}"
  detail_line "已绑定驱动" "${_driver:-<无>}"

  if [[ "${_modalias}" != "${EXPECTED_TOUCH_MODALIAS}" ]]; then
    result_row "触控 IC" FAIL "modalias 期望 '${EXPECTED_TOUCH_MODALIAS}'，实际 '${_modalias:-<不可读>}'"
    redline_note "触控 IC 不匹配：期望 ${EXPECTED_TOUCH_MODALIAS}，实际 ${_modalias:-不可读}"
  elif [[ -z "${_driver}" ]]; then
    result_row "触控 IC" WARN "modalias 正确（${_modalias}），但当前没有驱动绑定到 ${TOUCH_SPI_DEVICE}"
  else
    result_row "触控 IC" PASS "modalias = ${_modalias}，驱动 ${_driver} 已绑定"
  fi
  return 0
}

# =============================================================================
# 检查 7：引导配置（UEFI + systemd-boot + 显式 DTB）
# =============================================================================
check_boot() {
  result_section "7. 引导配置"
  local _mount="" _line="" _dtb="" _default="" _entries_joined="" _file=""
  local _matched=0
  local _loader_conf="${BOOT_EFI}/loader/loader.conf"
  local -a _entries=()

  if is_mounted "${BOOT_EFI}"; then
    _mount="$(mount_info "${BOOT_EFI}" || true)"
    result_row "${BOOT_EFI} 挂载" PASS "已挂载${_mount:+（${_mount}）}"
  else
    result_row "${BOOT_EFI} 挂载" FAIL "未挂载；EFI 系统分区不可见，无法维护引导项与 DTB"
  fi

  if [[ -r "${KERNEL_DEVICETREE_FILE}" ]]; then
    printf '    %s 内容：\n' "${KERNEL_DEVICETREE_FILE}"
    while IFS= read -r _line; do
      if [[ -n "${_line}" ]]; then printf '      %s\n' "${_line}"; fi
    done <"${KERNEL_DEVICETREE_FILE}"
    _dtb="$(join_lines ' ' <"${KERNEL_DEVICETREE_FILE}" || true)"
    if [[ -n "${_dtb}" ]]; then
      result_row "内核 DTB 指定" PASS "已显式指定：${_dtb}"
    else
      result_row "内核 DTB 指定" WARN "${KERNEL_DEVICETREE_FILE} 为空；systemd-boot 可能未显式指定 DTB"
    fi
  else
    result_row "内核 DTB 指定" FAIL "${KERNEL_DEVICETREE_FILE} 不存在或不可读；未显式指定 DTB，无法保证加载 gaokun3 设备树"
  fi

  if [[ -d "${BOOT_EFI}/loader/entries" ]]; then
    for _file in "${BOOT_EFI}"/loader/entries/*.conf; do
      if [[ -e "${_file}" ]]; then _entries+=("${_file##*/}"); fi
    done
  fi
  if ((${#_entries[@]} == 0)); then
    result_row "systemd-boot 引导项" WARN "未在 ${BOOT_EFI}/loader/entries 下找到任何 *.conf（EFI 未挂载或未使用 systemd-boot）"
  else
    printf '    %s/loader/entries（%d 个）：\n' "${BOOT_EFI}" "${#_entries[@]}"
    for _file in "${_entries[@]}"; do
      printf '      - %s\n' "${_file}"
    done
    _entries_joined="$(printf '%s\n' "${_entries[@]}" | join_lines ', ')"
    result_row "systemd-boot 引导项" PASS "共 ${#_entries[@]} 个：${_entries_joined}"
  fi

  if [[ -r "${_loader_conf}" ]]; then
    printf '    %s 内容：\n' "${_loader_conf}"
    while IFS= read -r _line; do
      if [[ -n "${_line}" ]]; then printf '      %s\n' "${_line}"; fi
    done <"${_loader_conf}"
    _default="$(awk '$1 == "default" { print $2; exit }' "${_loader_conf}" || true)"
    _default="${_default%\"}"
    _default="${_default#\"}"
    if [[ -z "${_default}" ]]; then
      result_row "systemd-boot 默认项" WARN "${_loader_conf} 未设置 default；systemd-boot 将自行选择条目"
    else
      if ((${#_entries[@]} > 0)); then
        for _file in "${_entries[@]}"; do
          if loader_entry_matches "${_file%.conf}" "${_default}"; then _matched=1; fi
        done
      fi
      if ((_matched == 1)); then
        result_row "systemd-boot 默认项" PASS "default=${_default}，对应条目存在"
      else
        result_row "systemd-boot 默认项" WARN "default=${_default} 未匹配任何现有条目；引导时不会进入预期内核"
      fi
    fi
  else
    result_row "systemd-boot 配置" WARN "${_loader_conf} 不可读（EFI 未挂载或未使用 systemd-boot）"
  fi
  return 0
}

# =============================================================================
# 检查 8：权限
# =============================================================================
check_privileges() {
  result_section "8. 权限"
  if [[ "${EUID}" -eq 0 ]]; then
    result_row "运行身份" PASS "root（EUID=0）"
  else
    result_row "运行身份" WARN "非 root（EUID=${EUID}）；本脚本为只读检查，但部分信息（如 debugfs）可能读不到"
  fi
  return 0
}

# =============================================================================
# 调度
# =============================================================================

# run_check <说明> <函数...> — 执行检查函数；函数异常中止时补记一条 FAIL，保证退出码正确
run_check() {
  local _label="$1"
  shift
  if ! "$@"; then
    log_warn "检查「${_label}」异常中止（已按失败记录）"
    result_row "${_label}" FAIL "检查过程异常中止，请检查上方 stderr 输出"
  fi
  return 0
}

# main — 逐项执行检查、打印裁决，并以 0/1 返回结论
main() {
  DT_ROOT=""
  if [[ -d "${DT_ROOT_PRIMARY}" ]]; then
    DT_ROOT="${DT_ROOT_PRIMARY}"
  elif [[ -d "${DT_ROOT_FALLBACK}" ]]; then
    DT_ROOT="${DT_ROOT_FALLBACK}"
  fi

  printf '%s%s%s\n' "${C_BOLD}" "easy-for-gaokun — 设备预检（00-preflight.sh）" "${C_RESET}"
  printf '  项目：%s <%s>\n' "${PROJECT_NAME}" "${PROJECT_URL}"
  printf '  时间：%s\n' "$(date -Is 2>/dev/null || date 2>/dev/null || printf '未知')"
  printf '  说明：本脚本严格只读，不会修改任何系统状态。\n'

  run_check "系统与架构" check_os_arch
  run_check "内核" check_kernel
  run_check "设备树身份" check_devicetree
  run_check "CPU 变体" check_cpu_freq
  run_check "显示与面板" check_display
  run_check "触摸屏" check_touch
  run_check "引导配置" check_boot
  run_check "权限" check_privileges

  result_summary || true

  if ((EFG_RESULT_FAIL > 0)); then
    printf '\n%s%s%s\n' "${C_RED}" "❌ 设备校验未通过：共 ${EFG_RESULT_FAIL} 项失败" "${C_RESET}"
    if ((${#PREFLIGHT_REDLINES[@]} > 0)); then
      printf '  触犯的设备鉴别红线：\n'
      local _redline=""
      for _redline in "${PREFLIGHT_REDLINES[@]}"; do
        printf '    - %s\n' "${_redline}"
      done
    fi
    printf '  本项目仅支持 HUAWEI MateBook E Go 2022 性能版（Snapdragon 8cx Gen 3 / SC8280XP / 设备树 gaokun3）。\n'
    printf '  明确排除：2022 LTE 版（8cx Gen 2 / SC8180X / gaokun2）与 2023 降频版（大核上限约 2.69 GHz）。\n'
    printf '  请在排除上述失败项之前，不要在本机执行后续脚本。\n'
    return 1
  fi

  printf '\n%s%s%s\n' "${C_GREEN}" "✅ 设备校验通过：GK-W76 (2022 性能版)，可以继续。" "${C_RESET}"
  if ((EFG_RESULT_WARN > 0)); then
    printf '  注意：存在 %d 项警告，建议在继续之前人工确认。\n' "${EFG_RESULT_WARN}"
  fi
  printf '  提示：本次预检未修改任何系统状态。\n'
  return 0
}

rc=0
main "$@" || rc=$?
exit "${rc}"
