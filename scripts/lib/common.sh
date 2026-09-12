# shellcheck shell=bash
# =============================================================================
# easy-for-gaokun — 公共 Shell 函数库（scripts/lib/common.sh）
#
# 本文件是函数库：只能被其它脚本 source，不能被直接执行。
# 项目内所有诊断 / 修复 / 安装脚本共享同一套日志、确认、试运行与结果统计机制。
#
# 约定：
#   * 日志类函数一律写 stderr，stdout 只留给脚本的正式输出（数据与结果表格）。
#   * 颜色在 stdout 非 TTY 或设置了 NO_COLOR 时自动关闭（no-color.org 约定）。
#   * DRY_RUN=1 时 run() 只打印命令不执行；ASSUME_YES=1 时 confirm() 自动通过。
#
# 项目主页：https://github.com/aoripus/easy-for-gaokun
# 目标设备：HUAWEI MateBook E Go 2022 性能版（Snapdragon 8cx Gen 3 / SC8280XP，
#           设备树代号 gaokun3）
# =============================================================================

# 禁止直接执行：本文件只提供常量与函数，直接运行没有任何意义。
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  printf '%s\n' "common.sh 是函数库，不能被直接执行；请在脚本中 source 它。" >&2
  exit 1
fi

# 防重复 source：已加载则立即返回，避免重复定义与计数清零。
if [[ -n "${EFG_COMMON_SH_LOADED:-}" ]]; then
  return 0
fi
EFG_COMMON_SH_LOADED=1

# =============================================================================
# 严格模式
# 只在调用方尚未开启时补齐；绝不反向关闭调用方已显式开启的选项，
# 因此 source 本文件不会破坏调用脚本自身的 set 状态。
# =============================================================================
if [[ "$-" != *e* ]]; then set -e; fi
if [[ "$-" != *u* ]]; then set -u; fi
if [[ "$(set -o | awk '$1 == "pipefail" { print $2 }')" != "on" ]]; then
  set -o pipefail
fi

# =============================================================================
# 常量
# =============================================================================

PROJECT_NAME="easy-for-gaokun"
PROJECT_URL="https://github.com/aoripus/easy-for-gaokun"

# 本项目只支持 gaokun3 专用内核；官方 Ubuntu 内核不含该版本号的补丁与 DTB。
SUPPORTED_KERNEL_SUBSTR="gaokun3"
SUPPORTED_ARCH="aarch64"

# CPU 最高频率红线（单位 kHz，cpufreq 的 cpuinfo_max_freq 即以此为单位的整数）。
#   * 2022 性能版（8cx Gen 3 满血）：大核簇上限约 2 995 200 kHz ≈ 3.0 GHz
#   * 2023 降频版：大核簇上限约 2 690 000 kHz ≈ 2.69 GHz
# 阈值取 2 900 000 kHz：比降频版高约 210 MHz，比满血版低约 95 MHz，
# 两侧都留有充足余量，既不会把满血版误判为降频版，也不会放过降频版。
# 注意：仅凭型号字符串（如 GK-W76 / GK-W7X）无法区分 2022 性能版与 2023 版，
#       频率与设备树才是决定性判据。
EXPECTED_CPU_MAX_KHZ_MIN=2900000

# =============================================================================
# 结果统计（供 result_row / result_summary 使用）
# =============================================================================
EFG_RESULT_PASS=0
EFG_RESULT_WARN=0
EFG_RESULT_FAIL=0
EFG_RESULT_FAIL_NAMES=()

# 供 require_root 重新执行时复用：入口脚本路径与其原始参数。
# source 本文件时 "$@" 仍是调用脚本的位置参数，因此可以在此准确捕获。
EFG_ENTRY_SCRIPT="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
EFG_ENTRY_ARGS=("$@")

# 试运行开关：默认关闭；调用方可在 source 之后再赋值覆盖。
DRY_RUN="${DRY_RUN:-0}"

# =============================================================================
# 颜色
# stdout 不是 TTY（例如被重定向或管道）时关闭颜色；设置 NO_COLOR 亦关闭。
# =============================================================================
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
  C_CYAN=$'\033[36m'
else
  C_RESET=''
  C_BOLD=''
  C_RED=''
  C_GREEN=''
  C_YELLOW=''
  C_BLUE=''
  C_CYAN=''
fi

# =============================================================================
# 日志（一律写 stderr）
# =============================================================================

# log_info <文本...> — 一般信息
log_info() {
  printf '%s[信息]%s %s\n' "${C_CYAN}" "${C_RESET}" "$*" >&2
}

# log_ok <文本...> — 成功
log_ok() {
  printf '%s[通过]%s %s\n' "${C_GREEN}" "${C_RESET}" "$*" >&2
}

# log_warn <文本...> — 警告
log_warn() {
  printf '%s[警告]%s %s\n' "${C_YELLOW}" "${C_RESET}" "$*" >&2
}

# log_err <文本...> — 错误
log_err() {
  printf '%s[错误]%s %s\n' "${C_RED}" "${C_RESET}" "$*" >&2
}

# log_step <文本...> — 步骤
log_step() {
  printf '%s[步骤]%s %s\n' "${C_BOLD}${C_BLUE}" "${C_RESET}" "$*" >&2
}

# log_kv <键> <值> — 键值对（键左对齐补位，便于人工核对）
log_kv() {
  printf '  %s%-22s%s %s\n' "${C_BOLD}" "$1" "${C_RESET}" "${2:-}" >&2
}

# die <文本...> — 打印错误后以退出码 1 终止脚本
die() {
  log_err "$@"
  exit 1
}

# =============================================================================
# 环境与权限
# =============================================================================

# have_cmd <命令名> — 该命令是否存在
have_cmd() {
  command -v -- "$1" >/dev/null 2>&1
}

# require_root — 确保以 root 运行；否则用 sudo 以完全相同的参数重新执行本脚本
require_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    return 0
  fi
  if ! have_cmd sudo; then
    die "需要 root 权限，但系统中找不到 sudo。请先切换到 root 再执行： su -c '${EFG_ENTRY_SCRIPT}'"
  fi
  log_info "当前非 root（EUID=${EUID}），改用 sudo 重新执行：${EFG_ENTRY_SCRIPT}"
  # exec 替换当前进程，避免出现两层进程与重复的输出。
  exec sudo -- "${EFG_ENTRY_SCRIPT}" "${EFG_ENTRY_ARGS[@]}"
}

# =============================================================================
# 执行与交互
# =============================================================================

# run <命令...> — 执行命令；DRY_RUN=1 时只打印将要执行的命令而不执行
run() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '%s[试运行]%s 跳过执行：' "${C_YELLOW}" "${C_RESET}" >&2
    printf '%q ' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  "$@"
}

# confirm <提示语> — 从 /dev/tty 读取确认，默认否；ASSUME_YES=1 时直接通过
confirm() {
  local _prompt="${1:-确认继续？}" _reply=""
  if [[ "${ASSUME_YES:-0}" == "1" ]]; then
    log_info "${_prompt} —— 已由 ASSUME_YES=1 自动确认。"
    return 0
  fi
  if [[ ! -r /dev/tty || ! -w /dev/tty ]]; then
    log_warn "无法访问 /dev/tty（非交互环境），${_prompt} 按默认值处理：否。"
    return 1
  fi
  printf '%s [y/N] ' "${_prompt}" >/dev/tty
  IFS= read -r _reply </dev/tty || true
  case "${_reply}" in
    [yY] | [yY][eE][sS]) return 0 ;;
    *) return 1 ;;
  esac
}

# =============================================================================
# 结果表格与汇总（写 stdout：这是脚本的正式输出）
# =============================================================================

# result_section <标题> — 输出一个检查分区标题
result_section() {
  printf '\n%s== %s ==%s\n' "${C_BOLD}" "$1" "${C_RESET}"
}

# result_row <检查项> <PASS|WARN|FAIL> <详情> — 输出一行结果并累加统计
result_row() {
  local _name="$1" _status="$2" _detail="${3:-}" _tag _color
  case "${_status}" in
    PASS)
      _tag='通过'
      _color="${C_GREEN}"
      EFG_RESULT_PASS=$((EFG_RESULT_PASS + 1))
      ;;
    WARN)
      _tag='警告'
      _color="${C_YELLOW}"
      EFG_RESULT_WARN=$((EFG_RESULT_WARN + 1))
      ;;
    FAIL)
      _tag='失败'
      _color="${C_RED}"
      EFG_RESULT_FAIL=$((EFG_RESULT_FAIL + 1))
      EFG_RESULT_FAIL_NAMES+=("${_name}")
      ;;
    *)
      log_err "result_row: 非法状态 '${_status}'（只接受 PASS / WARN / FAIL）"
      return 2
      ;;
  esac
  printf '%s[%s]%s %-30s %s\n' "${_color}" "${_tag}" "${C_RESET}" "${_name}" "${_detail}"
  return 0
}

# result_reset — 清零统计，便于在一个脚本内跑多轮检查
result_reset() {
  EFG_RESULT_PASS=0
  EFG_RESULT_WARN=0
  EFG_RESULT_FAIL=0
  EFG_RESULT_FAIL_NAMES=()
}

# result_summary — 打印统计与失败项清单；只要出现 FAIL 就返回 1
result_summary() {
  local _name
  printf '\n%s── 检查汇总 ──%s\n' "${C_BOLD}" "${C_RESET}"
  printf '  通过 %d 项，警告 %d 项，失败 %d 项\n' \
    "${EFG_RESULT_PASS}" "${EFG_RESULT_WARN}" "${EFG_RESULT_FAIL}"
  if ((EFG_RESULT_FAIL > 0)); then
    printf '  失败检查项：\n'
    for _name in "${EFG_RESULT_FAIL_NAMES[@]}"; do
      printf '    - %s\n' "${_name}"
    done
    return 1
  fi
  return 0
}
