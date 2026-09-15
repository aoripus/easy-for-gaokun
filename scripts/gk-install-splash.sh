#!/bin/bash
# =============================================================================
# gk-install-splash.sh —— 给 gaokun3（GK-W76）装「居中 LOGO + 启动日志」开机画面
#
# 设计原则（与 gk-install-kernel.sh 一致）：
#   1. 只改**我们自己那条** BLS 条目的 cmdline（追加 `splash`），绝不碰默认条目与 EFI 变量；
#   2. 一切写入前先备份（plymouthd.conf、BLS 条目），失败可原样回退；
#   3. `--uninstall` 一键还原（含 update-initramfs）；
#   4. 幂等：重复执行不会重复追加 `splash`、不会叠加 alternatives。
#
# 用法：
#   sudo ./gk-install-splash.sh --kver <内核串> [--tag r4] [--source <assets/boot-splash>]
#   sudo ./gk-install-splash.sh --kver <内核串> --rotate 3        # 只改方向常量后重装
#   sudo ./gk-install-splash.sh --kver <内核串> --uninstall
#
# 参数：
#   --kver <str>     内核 release 串（决定改哪条 BLS 条目、给哪个内核重做 initramfs）
#   --tag <str>      条目/目录后缀（同名内核装了多个条目时用，例如 r4）
#   --source <dir>   资产目录，需含 logo.png 与 theme/gaokun3-splash.{plymouth,script}
#                    默认取脚本旁边的 ../assets/boot-splash
#   --rotate <0|1|3> 覆盖主题里的 RotateQuadrant（0=不补偿 / 1=顺时针 90° / 3=逆时针 90°）
#   --no-initramfs   跳过 update-initramfs（只装文件，调试用）
#   --uninstall      卸载并还原
#   --esp <dir>      ESP 挂载点（默认 /boot/efi）
#
# 为什么必须 update-initramfs：plymouth 的 initramfs hook 只把「当前主题的 ModuleName
# 对应插件」拷进 initramfs（本机实测 initramfs 里只有 details.so / label-pango.so），
# script.so 不在里面。而且本项目的条目把 initrd 放在 ESP 目录下，所以生成后还要同步过去。
# =============================================================================

set -euo pipefail

KVER=""; TAG=""; SOURCE=""; ROTATE=""; ESP="/boot/efi"
UNINSTALL=0; NO_INITRAMFS=0
THEME_NAME="gaokun3-splash"
THEMES_DIR="/usr/share/plymouth/themes"
ALT_LINK="${THEMES_DIR}/default.plymouth"
CONF="/etc/plymouth/plymouthd.conf"

die() { echo "错误: $*" >&2; exit 1; }
info() { echo "[gk-splash] $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --kver) KVER="$2"; shift 2;;
    --tag) TAG="$2"; shift 2;;
    --source) SOURCE="$2"; shift 2;;
    --rotate) ROTATE="$2"; shift 2;;
    --esp) ESP="$2"; shift 2;;
    --no-initramfs) NO_INITRAMFS=1; shift;;
    --uninstall) UNINSTALL=1; shift;;
    -h|--help) sed -n '2,40p' "$0"; exit 0;;
    *) die "未知参数: $1";;
  esac
done

# ---- 前置条件 ---------------------------------------------------------------
[ "$(id -u)" = "0" ] || die "必须用 root 运行（sudo）"
[ -n "$KVER" ] || die "必须给 --kver"

# 设备鉴别：只允许 SC8280XP（与内核安装脚本同一红线）
if [ -r /proc/device-tree/compatible ]; then
  tr '\0' '\n' < /proc/device-tree/compatible | grep -qi 'qcom,sc8280xp' \
    || die "本机不是 SC8280XP（/proc/device-tree/compatible 不含 qcom,sc8280xp）"
else
  die "读不到 /proc/device-tree/compatible —— 无法确认机型"
fi

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -n "$SOURCE" ] || SOURCE="${SCRIPT_DIR}/../assets/boot-splash"
THEME_SRC="${SOURCE}/theme"
LOGO_SRC="${SOURCE}/logo.png"

ENTRY_NAME="${KVER}${TAG:+-${TAG}}"
ENTRY="${ESP}/loader/entries/$(cat /etc/machine-id)-${ENTRY_NAME}.conf"

# 把 initrd 从 /boot 同步进 ESP 目录（本项目条目从 ESP 读 initrd，不同步则画面不生效）
sync_initrd_to_esp() {
  local src="/boot/initrd.img-${KVER}" d
  [ -f "$src" ] || { info "警告: $src 不存在，跳过同步"; return 0; }
  for d in "${ESP}"/*/"${ENTRY_NAME}"; do
    [ -d "$d" ] || continue
    cp -f "$src" "${d}/initrd.img-${KVER}"
    info "initrd 同步 -> ${d}"
  done
}

# ---- 卸载 -------------------------------------------------------------------
if [ "$UNINSTALL" = "1" ]; then
  info "卸载开机画面"
  if [ -f "${ENTRY}.gk-backup" ]; then
    cp -f "${ENTRY}.gk-backup" "$ENTRY"
    rm -f "${ENTRY}.gk-backup"
    info "已还原 BLS 条目: $ENTRY"
  elif [ -f "$ENTRY" ] && grep -q '^options .*splash' "$ENTRY"; then
    sed -i 's/^options \(.*\) splash\(.*\)$/options \1\2/' "$ENTRY"
    sed -i 's/  \+/ /g; s/ $//' "$ENTRY"
    info "已从条目移除 splash"
  fi
  if [ -e "$ALT_LINK" ] && update-alternatives --query default.plymouth 2>/dev/null | grep -q "${THEME_NAME}"; then
    update-alternatives --remove default.plymouth "${THEMES_DIR}/${THEME_NAME}/${THEME_NAME}.plymouth" || true
  fi
  if [ -f "${CONF}.gk-backup" ]; then
    cp -f "${CONF}.gk-backup" "$CONF"; rm -f "${CONF}.gk-backup"
    info "已还原 ${CONF}"
  fi
  rm -rf "${THEMES_DIR:?}/${THEME_NAME}"
  if [ "$NO_INITRAMFS" = "0" ]; then
    info "重做 initramfs（$KVER）"
    update-initramfs -u -k "$KVER" >/dev/null 2>&1 || info "警告: update-initramfs 返回非 0"
    sync_initrd_to_esp
  fi
  info "完成。下次启动不再有开机画面（cmdline 已无 splash）。"
  exit 0
fi

# ---- 校验资产 ---------------------------------------------------------------
[ -f "$LOGO_SRC" ]                      || die "找不到 LOGO: $LOGO_SRC"
[ -f "${THEME_SRC}/${THEME_NAME}.plymouth" ] || die "找不到主题描述: ${THEME_SRC}/${THEME_NAME}.plymouth"
[ -f "${THEME_SRC}/${THEME_NAME}.script" ]   || die "找不到主题脚本: ${THEME_SRC}/${THEME_NAME}.script"

# ---- 1. 安装主题文件 --------------------------------------------------------
info "安装主题 -> ${THEMES_DIR}/${THEME_NAME}/"
mkdir -p "${THEMES_DIR}/${THEME_NAME}"
install -m 0644 "${THEME_SRC}/${THEME_NAME}.plymouth" "${THEMES_DIR}/${THEME_NAME}/"
install -m 0644 "${THEME_SRC}/${THEME_NAME}.script"   "${THEMES_DIR}/${THEME_NAME}/"
install -m 0644 "$LOGO_SRC"                           "${THEMES_DIR}/${THEME_NAME}/logo.png"
# 方向补偿：只在安装副本上改，仓库里的资产保持原样
if [ -n "$ROTATE" ]; then
  case "$ROTATE" in 0|1|3) ;; *) die "--rotate 只接受 0 / 1 / 3";; esac
  sed -i "s/^RotateQuadrant=.*/RotateQuadrant=${ROTATE}/" "${THEMES_DIR}/${THEME_NAME}/${THEME_NAME}.plymouth"
  info "方向常量 RotateQuadrant=${ROTATE}"
fi
grep -E '^(RotateQuadrant|LogLines|LogoScale)=' "${THEMES_DIR}/${THEME_NAME}/${THEME_NAME}.plymouth" | sed 's/^/    /'

# ---- 2. 让 initramfs hook 认得我们（它读 alternatives 的 Value）--------------
if [ ! -e "${CONF}.gk-backup" ]; then
  cp -a "$CONF" "${CONF}.gk-backup" 2>/dev/null || : > "${CONF}.gk-backup"
  info "已备份 $CONF"
fi
printf '[Daemon]\nTheme=%s\n' "$THEME_NAME" > "$CONF"
info "写入 $CONF: Theme=${THEME_NAME}"
update-alternatives --install "$ALT_LINK" default.plymouth \
  "${THEMES_DIR}/${THEME_NAME}/${THEME_NAME}.plymouth" 200 >/dev/null
info "default.plymouth -> $(update-alternatives --query default.plymouth | sed -n 's/^Value: //p')"

# ---- 3. 只给我们的条目加 splash ---------------------------------------------
[ -f "$ENTRY" ] || die "找不到 BLS 条目: $ENTRY（先用 gk-install-kernel.sh 装内核）"
if ! grep -q '^options .*splash' "$ENTRY"; then
  cp -a "$ENTRY" "${ENTRY}.gk-backup"
  sed -i '/^options /s/$/ splash/' "$ENTRY"
  info "已给条目追加 splash: $(basename "$ENTRY")"
else
  info "条目已有 splash，跳过"
fi

# ---- 4. 重做 initramfs 并同步到 ESP ----------------------------------------
if [ "$NO_INITRAMFS" = "0" ]; then
  info "重做 initramfs（$KVER）—— script.so 不在 initramfs 里，必须重做"
  update-initramfs -u -k "$KVER" >/dev/null 2>&1 || info "警告: update-initramfs 返回非 0"
  sync_initrd_to_esp
fi

info "完成。下次启动：居中 LOGO + 启动日志。"
info "若 LOGO 侧躺，用 --rotate 3 重跑（或 1）即可，无需改仓库文件。"
info "回滚：sudo $0 --kver $KVER${TAG:+ --tag $TAG} --uninstall"
