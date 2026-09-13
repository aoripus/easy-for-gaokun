#!/usr/bin/env bash
# shellcheck disable=SC2034  # 本脚本的常量含"仅作文档/预留"者（如 BASE_IMAGE_TAG 与 --yes 的 ASSUME_YES），见各声明处注释
#
# 10-install-dualboot.sh — 把社区镜像安装到内置盘，与 Windows 共存
#
# 本脚本自动化的是「分区级 dd」安装法：社区镜像是整盘镜像（GPT + 1 GiB ESP +
# ~11 GiB ext4 rootfs），无法整个 dd 进一个分区，因此改为在目标盘上新建两个分区，
# 再把镜像里的 p1 / p2 分别 dd 进去。
#
# 因为 dd 会原样保留文件系统 UUID，而镜像的 /etc/fstab 与 BLS 的 root=UUID= 完全
# 依赖 UUID，所以安装后这两处配置一字不用改——这是本方法最大的优势。
#
# ⚠️ 危险操作。执行前请务必确认：
#   1. 目标分区里的数据已备份（脚本会销毁它）
#   2. 目标盘的分区表已备份（脚本会自动备份一份）
#   3. 手上有可启动的备用介质
#   本机型没有 EDL / 9008 救援通道。
#
# 用法
# ----
#   sudo ./scripts/30-install-dualboot.sh --target /dev/nvme0n1p4 --image ubuntu-26.04-gaokun3.img
#   sudo ./scripts/30-install-dualboot.sh --target /dev/nvme0n1p4 --image X.img --dry-run
#
# 选项
# ----
#   --target DEV       安装 Linux 用的现有分区；其内容会被销毁（必填）
#   --image PATH       已解压的镜像文件 .img（必填）
#   --esp-size MiB     ESP 分区大小，默认 1024
#   --no-dtb-patch     跳过把 gpio174 触屏修复编译进 DTB 的步骤
#   --yes, -y          跳过所有交互确认（请自行承担风险）
#   --dry-run          只打印将要执行的操作，不做任何修改
#   --help, -h         显示本帮助
#
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"

readonly BASE_IMAGE_TAG="ubuntu26.04-7.1.0-rc3-gaokun3+el2-20260514004329"
readonly BASE_IMAGE_URL="https://github.com/KawaiiHachimi/linux-gaokun-buildbot/releases/download/ubuntu26.04-7.1.0-rc3-gaokun3%2B-el2-20260514004329/ubuntu-26.04-gaokun3.img.zst"
readonly EL2_KREL="7.1.0-rc3-gaokun3-el2+"

TARGET=""
IMAGE=""
ESP_SIZE_MIB=1024
DO_DTB_PATCH=1

usage() { sed -n '3,29p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }

while [[ $# -gt 0 ]]; do
	case "$1" in
		--target)       TARGET="${2:-}"; shift 2 ;;
		--image)        IMAGE="${2:-}"; shift 2 ;;
		--esp-size)     ESP_SIZE_MIB="${2:-}"; shift 2 ;;
		--no-dtb-patch) DO_DTB_PATCH=0; shift ;;
		--yes|-y)       ASSUME_YES=1; shift ;;
		--dry-run)      DRY_RUN=1; shift ;;
		--help|-h)      usage; exit 0 ;;
		*) die "未知参数：$1（--help 查看用法）" ;;
	esac
done

[[ -n "${TARGET}" ]] || die "缺少 --target（要安装 Linux 用的分区，例如 /dev/nvme0n1p4）"
[[ -n "${IMAGE}"  ]] || die "缺少 --image（已解压的镜像 .img 路径）"

# ---------------------------------------------------------------------------
# 辅助函数
# ---------------------------------------------------------------------------

# 该块设备是否被挂载（含其上的子设备）
is_mounted() {
	local dev="$1"
	grep -q "^${dev}" /proc/mounts && return 0
	lsblk -no MOUNTPOINT "${dev}" 2>/dev/null | grep -q . && return 0
	return 1
}

# 找出磁盘上编号最小的空闲分区号（排除 keep）
free_partition_number() {
	local disk="$1" keep="$2"
	sgdisk -p "${disk}" |
		awk -v keep="${keep}" '
			$1 ~ /^[0-9]+$/ { used[$1] = 1 }
			END { for (i = 1; i <= 128; i++) if (!(i in used) && i != keep) { print i; exit } }'
}

# 取分区在磁盘上的起止扇区
partition_range() {
	sgdisk -p "$1" | awk -v n="$2" '$1 == n { print $2, $3; exit }'
}

# 安装完成后的收尾提示
post_install_notes() {
	local esp="$1" root="$2"
	log_step "安装完成"
	log_kv "Linux ESP"    "${esp}"
	log_kv "Linux rootfs" "${root}"
	echo
	log_info "首次启动后建议执行："
	log_info "  sudo chown root:root /          # 修镜像缺陷：根目录属主被错设为 uid 1001"
	log_info "  sudo ./scripts/00-preflight.sh  # 复核设备"
	log_info "  grep -E '^ ?gpio174 ' /sys/kernel/debug/gpio   # 期望 out low … 2mA no pull"
	echo
	log_warn "本机型没有 EDL / 9008 救援通道。若引导损坏，只能用备用介质挂载 ESP 回滚。"
}

# ---------------------------------------------------------------------------
# 主流程
# ---------------------------------------------------------------------------

main() {
	require_root

	echo
	log_step "安装计划"
	log_kv "目标分区"   "${TARGET}（内容将被销毁）"
	log_kv "镜像"       "${IMAGE}"
	log_kv "ESP 大小"   "${ESP_SIZE_MIB} MiB"
	log_kv "DTB 触屏修复" "$([[ ${DO_DTB_PATCH} -eq 1 ]] && echo '启用' || echo '跳过')"
	log_kv "试运行"     "$([[ ${DRY_RUN} -eq 1 ]] && echo '是（不做任何修改）' || echo '否')"
	echo

	# ---- 1. 前置校验 ----
	log_step "1/9 前置校验"

	[[ -b "${TARGET}" ]] || die "${TARGET} 不是块设备"
	[[ -f "${IMAGE}"  ]] || die "镜像不存在：${IMAGE}"

	local running_root target_disk target_num
	running_root="$(findmnt -no SOURCE /)"
	target_disk="/dev/$(lsblk -no PKNAME "${TARGET}")"
	target_num="$(cat "/sys/class/block/$(basename "${TARGET}")/partition" 2>/dev/null || true)"
	[[ -n "${target_num}" ]] || die "${TARGET} 不是分区"

	log_kv "当前根文件系统" "${running_root}"
	log_kv "目标分区所在盘" "${target_disk}"
	log_kv "目标分区编号"   "${target_num}"

	[[ "${TARGET}" == "${running_root}" ]] && die "目标分区就是当前根文件系统，拒绝继续"
	[[ "${TARGET}" == "$(findmnt -no SOURCE /boot/efi 2>/dev/null || echo '')" ]] && \
		die "目标分区是当前的 /boot/efi，拒绝继续"
	is_mounted "${TARGET}" && die "${TARGET} 正在被挂载，请先卸载"

	# 设备身份复核：只对本项目支持的机型操作
	local compatible=""
	for f in /proc/device-tree/compatible /sys/firmware/devicetree/base/compatible; do
		[[ -r "${f}" ]] && { compatible="$(tr '\0' ' ' < "${f}")"; break; }
	done
	case "${compatible}" in
		*huawei,gaokun3*) : ;;
		*) log_warn "设备树 compatible 未包含 huawei,gaokun3（读到：${compatible:-无}）" ;;
	esac

	have_cmd sgdisk || die "缺少 sgdisk，请先安装：sudo apt-get install -y gdisk"
	have_cmd losetup || die "缺少 losetup（util-linux）"
	have_cmd e2fsck  || die "缺少 e2fsck（e2fsprogs）"
	have_cmd blkid   || die "缺少 blkid（util-linux）"

	log_ok "前置校验通过"

	# ---- 2. 备份分区表 ----
	log_step "2/9 备份目标盘分区表"
	local bkdir="/root/gaokun-install-backup"
	run mkdir -p "${bkdir}"
	run sgdisk --backup="${bkdir}/$(basename "${target_disk}")-gpt.bin" "${target_disk}"
	if [[ "${DRY_RUN}" != "1" ]]; then
		sgdisk -p "${target_disk}" > "${bkdir}/$(basename "${target_disk}")-gpt-before.txt"
		log_ok "已备份到 ${bkdir}（还原：sgdisk --load-backup=... ${target_disk}）"
	fi

	# ---- 3. 检查镜像结构 ----
	log_step "3/9 检查镜像结构"
	local loop
	if [[ "${DRY_RUN}" == "1" ]]; then
		log_info "[试运行] 跳过镜像挂载与 UUID 读取"
		echo
		log_info "后续将执行："
		log_info "  • losetup -Pf ${IMAGE}"
		log_info "  • dd 镜像 p1 → 新建 ESP、p2 → 新建 rootfs"
		log_info "  • 核对 UUID 一致后 resize2fs 扩容"
		log_info "  • 改写 loader.conf 的 default 为 el2 条目"
		[[ ${DO_DTB_PATCH} -eq 1 ]] && log_info "  • 把 gpio174 触屏修复编译进 ESP 上的 DTB"
		log_info "  • efibootmgr 建立引导项并置为第一顺位"
		echo
		log_warn "试运行结束，未做任何修改。"
		return 0
	fi

	loop="$(losetup --show -fP "${IMAGE}")"
	# shellcheck disable=SC2064
	trap "losetup -d '${loop}' 2>/dev/null || true" EXIT

	[[ -b "${loop}p1" && -b "${loop}p2" ]] || die "镜像里没有两个分区，可能不是本项目支持的镜像"

	local src_p1_type src_p2_type src_p1_uuid src_p2_uuid
	src_p1_type="$(blkid -s TYPE -o value "${loop}p1" || true)"
	src_p2_type="$(blkid -s TYPE -o value "${loop}p2" || true)"
	src_p1_uuid="$(blkid -s UUID -o value "${loop}p1" || true)"
	src_p2_uuid="$(blkid -s UUID -o value "${loop}p2" || true)"

	log_kv "镜像 p1" "${src_p1_type}  UUID=${src_p1_uuid}"
	log_kv "镜像 p2" "${src_p2_type}  UUID=${src_p2_uuid}"

	[[ "${src_p1_type}" == "vfat" ]] || die "镜像 p1 不是 vfat（ESP），拒绝继续"
	[[ "${src_p2_type}" == "ext4" ]] || die "镜像 p2 不是 ext4（rootfs），拒绝继续"
	log_ok "镜像结构正确"

	# ---- 4. 确认并重建分区 ----
	log_step "4/9 重建分区"
	read -r ts te < <(partition_range "${target_disk}" "${target_num}")
	[[ -n "${ts:-}" && -n "${te:-}" ]] || die "无法读取 ${TARGET} 的起止扇区"

	local esp_start esp_end root_start root_end root_num
	esp_start="${ts}"
	esp_end=$((ts + ESP_SIZE_MIB * 2048 - 1))
	root_start=$((esp_end + 1))
	root_end="${te}"
	root_num="$(free_partition_number "${target_disk}" "${target_num}")"
	[[ -n "${root_num}" ]] || die "找不到空闲分区号"

	local esp_dev="${target_disk}p${target_num}"
	local root_dev="${target_disk}p${root_num}"
	# NVMe / mmcblk 之外的设备命名不带 p
	[[ -e "${esp_dev}" ]] || esp_dev="${target_disk}${target_num}"
	[[ -e "${root_dev}" ]] || root_dev="${target_disk}${root_num}"

	local root_mib=$(( (root_end - root_start + 1) / 2048 ))
	echo
	log_warn "即将销毁 ${TARGET} 及其全部数据，并重建为："
	log_kv "  ESP"    "分区 ${target_num}  ${ESP_SIZE_MIB} MiB  → ${esp_dev}"
	log_kv "  rootfs" "分区 ${root_num}  ${root_mib} MiB  → ${root_dev}"
	echo

	confirm "确认销毁 ${TARGET} 并重建分区？" || die "已取消"

	run sgdisk -d "${target_num}" "${target_disk}"
	run sgdisk -n "${target_num}:${esp_start}:${esp_end}" -t "${target_num}:ef00" -c "${target_num}:LINUX-ESP" "${target_disk}"
	run sgdisk -n "${root_num}:${root_start}:${root_end}" -t "${root_num}:8300" -c "${root_num}:rootfs" "${target_disk}"
	run partprobe "${target_disk}"
	sleep 3
	run wipefs -a "${esp_dev}"
	run wipefs -a "${root_dev}"
	log_ok "分区已重建"

	# ---- 5. dd ----
	log_step "5/9 写入镜像分区（dd）"
	confirm "开始 dd 写入？" || die "已取消"
	run dd if="${loop}p1" of="${esp_dev}"  bs=4M  status=progress conv=fsync
	run dd if="${loop}p2" of="${root_dev}" bs=16M status=progress conv=fsync
	run sync
	log_ok "写入完成"

	# ---- 6. 核对 UUID ----
	log_step "6/9 核对 UUID（关键）"
	local got_p1_uuid got_p2_uuid
	got_p1_uuid="$(blkid -s UUID -o value "${esp_dev}"  || true)"
	got_p2_uuid="$(blkid -s UUID -o value "${root_dev}" || true)"
	log_kv "ESP"    "期望 ${src_p1_uuid}  实际 ${got_p1_uuid}"
	log_kv "rootfs" "期望 ${src_p2_uuid}  实际 ${got_p2_uuid}"

	if [[ "${got_p1_uuid}" != "${src_p1_uuid}" || "${got_p2_uuid}" != "${src_p2_uuid}" ]]; then
		log_err "UUID 不一致！"
		log_err "这说明 dd 没有完整写入。此时 fstab 与 root=UUID= 都会失效，系统无法启动。"
		log_err "请勿重启，先检查目标设备与镜像，必要时用 ${bkdir} 里的备份还原分区表。"
		return 1
	fi
	log_ok "UUID 完全一致 —— fstab 与 root=UUID= 无需修改"

	# ---- 7. 扩容 + 修 loader.conf ----
	log_step "7/9 扩容 rootfs 并修正 loader.conf"
	run e2fsck -f -y "${root_dev}"
	run resize2fs "${root_dev}"

	local mnt=/mnt/gaokun-newesp
	run mkdir -p "${mnt}"
	run mount "${esp_dev}" "${mnt}"

	local mid entry
	mid="$(ls "${mnt}/loader/entries/" 2>/dev/null | head -n1 | sed 's/-7\.1\.0.*//')"
	if [[ -z "${mid}" ]]; then
		log_warn "无法从引导条目推导 machine-id，跳过 loader.conf 修正"
	else
		entry="${mid}-${EL2_KREL}.conf"
		if [[ -f "${mnt}/loader/entries/${entry}" ]]; then
			log_info "把 default 改为 ${entry}"
			printf 'default %s\ntimeout 5\nconsole-mode keep\neditor no\n' "${entry}" > "${mnt}/loader/loader.conf"
			cat "${mnt}/loader/loader.conf" | sed 's/^/  /'
			log_ok "loader.conf 已修正（镜像自带 default 指向会卡住的非 el2 条目）"
		else
			log_warn "未找到 ${entry}，保留原 loader.conf"
		fi
	fi

	# ---- 8. DTB 触屏修复 ----
	if [[ ${DO_DTB_PATCH} -eq 1 ]]; then
		log_step "8/9 把 gpio174 触屏修复编译进 DTB"
		if ! have_cmd dtc; then
			log_warn "缺少 dtc，跳过。装完后可执行：sudo apt-get install -y device-tree-compiler 后重跑"
		elif [[ -z "${mid}" || ! -d "${mnt}/${mid}/${EL2_KREL}" ]]; then
			log_warn "未找到 ${mnt}/${mid}/${EL2_KREL}，跳过 DTB 修补"
		else
			local dtb="${mnt}/${mid}/${EL2_KREL}/sc8280xp-huawei-gaokun3-el2.dtb"
			if [[ ! -f "${dtb}" ]]; then
				log_warn "未找到 ${dtb}，跳过"
			else
				cp -a "${dtb}" "${dtb}.orig"
				dtc -I dtb -O dts -o /tmp/gaokun-el2.dts "${dtb}" 2>/dev/null
				python3 - <<'PY'
import sys
p = "/tmp/gaokun-el2.dts"
s = open(p, encoding="utf-8", errors="surrogateescape").read()
anchor = 'pins = "gpio99";'
if anchor not in s:
    sys.exit("锚点未找到")
if "gpio174" in s:
    print("已包含 gpio174，跳过")
    sys.exit(0)
i = s.index(anchor)
j = s.index("};", i) + 2
block = '''

			/*
			 * easy-for-gaokun: host-interface select for the Himax
			 * HX83121A cascade IC.  The boot firmware leaves this pin
			 * high, which puts the IC into I2C-HID mode: the SPI driver
			 * then reads registers but never receives touch data, and
			 * the level-low interrupt is never asserted.
			 */
			mode-n-pins {
				pins = "gpio174";
				function = "gpio";
				drive-strength = <2>;
				bias-disable;
				output-low;
			};'''
open(p, "w", encoding="utf-8", errors="surrogateescape").write(s[:j] + block + s[j:])
print("已插入 mode-n-pins")
PY
				dtc -I dts -O dtb -o /tmp/gaokun-el2-new.dtb /tmp/gaokun-el2.dts 2>/dev/null
				if dtc -I dtb -O dts -o /dev/null /tmp/gaokun-el2-new.dtb 2>/dev/null; then
					cp /tmp/gaokun-el2-new.dtb "${dtb}"
					log_ok "DTB 已修补（原文件保留为 ${dtb##*/}.orig）"
				else
					log_err "重新编译出的 DTB 非法，保留原文件不动"
				fi
			fi
		fi
	else
		log_step "8/9 跳过 DTB 触屏修复"
	fi

	run sync
	run umount "${mnt}"

	# ---- 9. 引导项 ----
	log_step "9/9 建立 UEFI 引导项"
	local esp_short boot_num
	esp_short="${esp_dev#/dev/}"
	boot_num="$(efibootmgr 2>/dev/null | awk '/^Boot[0-9A-F]{4}/{print substr($1,5,4)}' | sort -n | tail -n1)"
	if [[ -z "${boot_num}" ]]; then
		log_warn "无法读取现有引导项编号，请手工执行 efibootmgr -c"
	elif efibootmgr -c -d "${target_disk}" -p "${target_num}" \
			-L "Ubuntu (gaokun3)" -l '\EFI\systemd\systemd-bootaa64.efi' >/dev/null 2>&1; then
		log_ok "已建立引导项（固件可能把它重命名为 \"Windows Boot Manager\"，属正常现象）"
		log_info "可用 efibootmgr -v 查看设备路径来区分：Linux 项指向 \\EFI\\systemd\\systemd-bootaa64.efi"
	else
		log_warn "efibootmgr 建项失败；可在开机时按 F12 手动选择，或进固件设置手工添加"
	fi

	echo
	efibootmgr 2>/dev/null | sed 's/^/  /' || true
	echo
	log_info "如需让 Linux 默认启动，请把 Linux 项的编号排到第一位，例如："
	log_info "  sudo efibootmgr -o <Linux编号>,<Windows编号>,0000"

	post_install_notes "${esp_dev}" "${root_dev}"
}

main "$@"
