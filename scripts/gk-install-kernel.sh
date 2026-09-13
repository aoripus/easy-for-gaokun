#!/bin/bash
# =============================================================================
# gk-install-kernel.sh —— 把本项目自编内核装进 gaokun3 的 ESP（systemd-boot BLS）
#
# 设计原则（务必遵守）：
#   1. 只**新增**菜单项，绝不修改/删除既有条目 —— 装坏了随时还能选回原内核；
#   2. 默认**不**改 loader.conf 的 default，也不碰 EFI 变量里的 BootOrder；
#   3. 所有写入前先做设备鉴别与文件校验，失败即中止（set -euo pipefail）；
#   4. 提供 --uninstall 一键回滚。
#
# 用法：
#   sudo ./gk-install-kernel.sh --kver 7.2.5-aoripus-ml-gaokun-eog-el1+ \
#        --image ./Image --dtb ./sc8280xp-huawei-gaokun3.dtb --modules ./modules.tar.zst
#   sudo ./gk-install-kernel.sh --kver <ver> --oneshot     # 装完并把下一次启动指向它
#   sudo ./gk-install-kernel.sh --kver <ver> --uninstall   # 回滚（删本内核的文件与条目）
#   sudo ./gk-install-kernel.sh --kver <ver> --el2         # 用 -el2.dtb 生成 EL2 条目
#
# 说明：
#   * 本项目 EL1 与 EL2 的差别就是 BLS 条目里 devicetree 指向哪一个 DTB：
#       EL1 -> sc8280xp-huawei-gaokun3.dtb        （slbounce 嗅探后留在 EL1）
#       EL2 -> sc8280xp-huawei-gaokun3-el2.dtb    （slbounce 切到 EL2，需 qebspil 已就位）
#   * 内核命令行（cmdline）默认从**当前默认条目**继承，避免漏掉本机必需的 quirks。
# =============================================================================
set -euo pipefail

KVER=""; IMAGE=""; DTB=""; MODULES=""; ONESHOT=0; UNINSTALL=0; USE_EL2=0
ESP="${GK_ESP:-/boot/efi}"

die() { echo "错误: $*" >&2; exit 1; }
info() { echo "[gk] $*"; }

while [ $# -gt 0 ]; do
  case "$1" in
    --kver) KVER="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --dtb) DTB="$2"; shift 2;;
    --modules) MODULES="$2"; shift 2;;
    --esp) ESP="$2"; shift 2;;
    --oneshot) ONESHOT=1; shift;;
    --uninstall) UNINSTALL=1; shift;;
    --el2) USE_EL2=1; shift;;
    -h|--help) sed -n '2,30p' "$0"; exit 0;;
    *) die "未知参数 $1";;
  esac
done

[ "$(id -u)" -eq 0 ] || die "需要 root 运行"

# ---- 设备鉴别（本项目的硬约束：只允许 GK-W76 / gaokun3 / SC8280XP）----------
COMPAT="$(tr '\0' ' ' < /proc/device-tree/compatible 2>/dev/null || true)"
case "$COMPAT" in
  *qcom,sc8280xp*) info "设备鉴别通过: SC8280XP" ;;
  *) die "不是 SC8280XP 设备（compatible=$COMPAT）—— 拒绝安装" ;;
esac

MACHINE_ID="$(cat /etc/machine-id)"
ENTRY_DIR="$ESP/loader/entries"
[ -d "$ENTRY_DIR" ] || die "找不到 $ENTRY_DIR（这不是 systemd-boot 布局？）"
[ -f "$ESP/EFI/systemd/drivers/slbounceaa64.efi" ] || \
  info "提示: $ESP/EFI/systemd/drivers/ 下没有 slbounceaa64.efi —— EL2 启动链可能不完整（EL1 不受影响）"

ENTRY="$ENTRY_DIR/${MACHINE_ID}-${KVER}.conf"
KDIR="$ESP/${MACHINE_ID}/${KVER}"

# ---- 回滚 ------------------------------------------------------------------
if [ "$UNINSTALL" = 1 ]; then
  [ -n "$KVER" ] || die "--uninstall 需要 --kver"
  info "回滚内核 $KVER"
  rm -fv "$ENTRY"
  rm -rfv "$KDIR"
  rm -fv "/boot/vmlinuz-$KVER" "/boot/initrd.img-$KVER" "/boot/dtb-$KVER" "/boot/config-$KVER"
  rm -rfv "/lib/modules/$KVER"
  info "已删除；请确认 menu 中仍有原内核条目"
  exit 0
fi

# ---- 前置校验 ---------------------------------------------------------------
[ -n "$KVER" ] || die "必须给 --kver"
[ -f "$IMAGE" ] || die "找不到 Image: $IMAGE"
[ -f "$DTB" ]   || die "找不到 DTB: $DTB"
[ -n "$MODULES" ] || die "必须给 --modules（modules.tar.zst 或已展开的目录）"
[ ! -e "$ENTRY" ] || die "$ENTRY 已存在 —— 先 --uninstall 或换个 --kver"

# 校验 Image 是 ARM64 内核镜像
if command -v file >/dev/null; then
  file "$IMAGE" | grep -qi 'aarch64\|ARM64' || info "警告: file 未把 Image 认成 ARM64（继续）"
fi

# ---- 内核命令行：从当前默认条目继承 ----------------------------------------
DEFAULT_ENTRY="$(sed -n 's/^default[[:space:]]\+//p' "$ESP/loader/loader.conf" 2>/dev/null | head -1 || true)"
CMDLINE=""
if [ -n "$DEFAULT_ENTRY" ] && [ -f "$ENTRY_DIR/$DEFAULT_ENTRY" ]; then
  CMDLINE="$(sed -n 's/^options[[:space:]]\+//p' "$ENTRY_DIR/$DEFAULT_ENTRY" | head -1)"
  info "命令行继承自默认条目 $DEFAULT_ENTRY"
fi
if [ -z "$CMDLINE" ]; then
  ROOT_UUID="$(findmnt -no UUID / 2>/dev/null || true)"
  [ -n "$ROOT_UUID" ] || die "无法确定根分区 UUID，且默认条目里没有 options"
  CMDLINE="root=UUID=$ROOT_UUID clk_ignore_unused pd_ignore_unused arm64.nopauth iommu.passthrough=0 iommu.strict=0 pcie_aspm.policy=powersupersave modprobe.blacklist=simpledrm fbcon=rotate:1 consoleblank=0 loglevel=4 psi=1 systemd.machine_id=$MACHINE_ID"
  info "命令行使用内置模板（未能从默认条目继承）"
fi

# ---- 1. 安装内核到 /boot 与 /lib/modules ------------------------------------
info "安装 Image -> /boot/vmlinuz-$KVER"
install -m 0644 "$IMAGE" "/boot/vmlinuz-$KVER"
install -m 0644 "$DTB"   "/boot/dtb-$KVER"

if [ -f "$MODULES" ]; then
  info "展开模块 -> /lib/modules/$KVER/"
  rm -rf "/lib/modules/$KVER"; mkdir -p "/lib/modules/$KVER"
  case "$MODULES" in
    *.tar.zst) tar --zstd -xf "$MODULES" -C "/lib/modules/$KVER" --strip-components=0 ;;
    *.tar.gz|*.tgz) tar -xzf "$MODULES" -C "/lib/modules/$KVER" ;;
    *.tar.xz) tar -xJf "$MODULES" -C "/lib/modules/$KVER" ;;
    *) die "不认识的模块包格式: $MODULES" ;;
  esac
elif [ -d "$MODULES" ]; then
  info "复制模块目录 -> /lib/modules/$KVER/"
  rm -rf "/lib/modules/$KVER"; mkdir -p "$(dirname "/lib/modules/$KVER")"
  cp -a "$MODULES" "/lib/modules/$KVER"
else
  die "--modules 既不是文件也不是目录: $MODULES"
fi

# 有些产物把模块装在 <ver>/ 子目录里，做一次归一化
if [ -d "/lib/modules/$KVER/$KVER" ] && [ ! -d "/lib/modules/$KVER/kernel" ]; then
  info "归一化模块目录层级"
  mv "/lib/modules/$KVER/$KVER" "/lib/modules/$KVER.tmp"
  rm -rf "/lib/modules/$KVER"
  mv "/lib/modules/$KVER.tmp" "/lib/modules/$KVER"
fi
[ -d "/lib/modules/$KVER/kernel" ] || info "警告: /lib/modules/$KVER/kernel 不存在，确认模块包内容"

if command -v depmod >/dev/null; then
  info "depmod -a $KVER"
  depmod -a "$KVER" || info "警告: depmod 返回非 0"
fi

# ---- 2. 生成 initrd ---------------------------------------------------------
info "生成 initrd"
if command -v update-initramfs >/dev/null; then
  update-initramfs -c -k "$KVER"
elif command -v mkinitramfs >/dev/null; then
  mkinitramfs -o "/boot/initrd.img-$KVER" "$KVER"
elif command -v dracut >/dev/null; then
  dracut --force "/boot/initrd.img-$KVER" "$KVER"
else
  die "没有可用的 initrd 生成工具（update-initramfs / mkinitramfs / dracut）"
fi
[ -s "/boot/initrd.img-$KVER" ] || die "initrd 生成失败"

# ---- 3. 放进 ESP 并生成 BLS 条目 -------------------------------------------
info "复制内核/initrd/DTB 到 $KDIR"
mkdir -p "$KDIR"
cp -f "$IMAGE" "$KDIR/linux"
cp -f "/boot/initrd.img-$KVER" "$KDIR/initrd.img-$KVER"
if [ "$USE_EL2" = 1 ]; then
  ESP_DTB_NAME="sc8280xp-huawei-gaokun3-el2.dtb"
  info "选用 EL2 DTB（需要 qebspil 已就位，否则音频/remoteproc 会异常）"
else
  ESP_DTB_NAME="sc8280xp-huawei-gaokun3.dtb"
  info "选用 EL1 DTB（slbounce 嗅探后留在 EL1；无 /dev/kvm）"
fi
cp -f "$DTB" "$KDIR/$ESP_DTB_NAME"

info "写 BLS 条目 $ENTRY"
cat > "$ENTRY" <<EOF
# Boot Loader Specification type#1 entry
# 由 easy-for-gaokun 的 gk-install-kernel.sh 生成（本机 machine-id 与 cmdline 继承自现有条目）
title      Ubuntu 26.04 LTS (aoripus $([ "$USE_EL2" = 1 ] && echo EL2 || echo EL1) $KVER)
version    $KVER
machine-id $MACHINE_ID
sort-key   ubuntu-aoripus
options    $CMDLINE
linux      /${MACHINE_ID}/${KVER}/linux
devicetree /${MACHINE_ID}/${KVER}/${ESP_DTB_NAME}
initrd     /${MACHINE_ID}/${KVER}/initrd.img-$KVER
EOF
[ -s "$ENTRY" ] || die "条目写入失败"

sync
info "完成。条目：$ENTRY"
ls -l "$KDIR"

# ---- 4. 可选：把下一次启动指向新条目 ---------------------------------------
if [ "$ONESHOT" = 1 ]; then
  if command -v bootctl >/dev/null; then
    info "bootctl set-oneshot ${MACHINE_ID}-${KVER}.conf"
    bootctl set-oneshot "${MACHINE_ID}-${KVER}.conf"
    info "下一次启动会尝试新内核；若挂死，长按电源强制关机后会自动回落到默认条目"
  else
    info "没有 bootctl，跳过 oneshot 设置"
  fi
else
  info "未改动默认启动项。开机时在 systemd-boot 菜单里手动选择 'aoripus' 条目，"
  info "或再执行: bootctl set-oneshot ${MACHINE_ID}-${KVER}.conf"
fi
