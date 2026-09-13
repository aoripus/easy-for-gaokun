#!/bin/bash
# =============================================================================
# 在 x86_64 Linux 上交叉编译 gaokun3（SC8280XP）的 IRIS 试验内核
#
# 只编译，不安装：产物止步于 Image / dtb / modules 散件，不碰任何 ESP、
# 不跑 modules_install、不动 efibootmgr。
#
# 用法：
#   GK_LOCALVERSION="-aoripus-ml-gaokun3-eog-el2-iris-r1" ./build-iris-x86.sh
#   （不设该变量则用脚本内默认值）
#
# 修订记录
#   2026-09-13  v2：修正 EL2 补丁组被整组丢弃的问题（git apply 传多文件是原子
#              操作，一个失败则一个都不应用），改为逐个应用并在失败过多时中止；
#              新增触屏接口模式补丁（gpio174）并断言其已进入产物 DTB。
# =============================================================================
set -u
BASE=/root/gaokun
VER="${GK_KVER:-7.2-rc2}"
LOCALVER="${GK_LOCALVERSION:--aoripus-ml-gaokun3-eog-el2-iris-r1}"
TARBALL=$BASE/linux-$VER.tar.gz
SRC=$BASE/linux
OUT=$BASE/out-$VER
P=$BASE/buildbot-patches
EL2P=${GK_EL2_PATCH_DIR:-$BASE/el2-patches}
EL2RB=$BASE/el2-rebased
IRISP=${GK_IRIS_EL2_PATCH:-$BASE/iris-el2.patch}
PREP=$BASE/gaokun-iris-dts-prep.py
TOUCH_PATCH=${GK_TOUCH_PATCH:-$BASE/0001-touchscreen-gpio174.patch}
LOG=$BASE/build-$VER.log
JOBS="${GK_JOBS:-$(nproc)}"

export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-gnu-
export CCACHE_DIR=$BASE/.ccache CCACHE_BASEDIR=$BASE
export CCACHE_NOHASHDIR=true CCACHE_COMPILERCHECK=content
[ -d /usr/lib/ccache ] && export PATH="/usr/lib/ccache:$PATH"

exec > >(tee -a "$LOG") 2>&1
echo "=================== 构建开始 $(date -Is) ==================="
echo "基线 v$VER   LOCALVERSION=$LOCALVER   并行度 -j$JOBS   交叉工具链 $CROSS_COMPILE"

step() { echo; echo "----- $* -----"; }
die() { echo; echo "!!!!! 中止：$*"; exit 1; }

step "0. 前置检查"
command -v "${CROSS_COMPILE}gcc" >/dev/null || die "找不到 ${CROSS_COMPILE}gcc（先装 gcc-aarch64-linux-gnu）"
[ -f "$PREP" ] || die "找不到 $PREP"
[ -f "$TARBALL" ] || die "找不到 $TARBALL"
[ -f "$TOUCH_PATCH" ] || die "找不到触屏补丁 $TOUCH_PATCH"
[ -f "$IRISP" ] || die "找不到 IRIS EL2 补丁 $IRISP"
"${CROSS_COMPILE}gcc" --version | head -1

step "1. 解包 v$VER"
cd "$BASE"
rm -rf "$SRC"
tar xzf "$TARBALL"
mv "linux-$VER" linux
cd "$SRC"
echo "kernelversion: $(make ARCH=arm64 kernelversion 2>/dev/null)"

step "2. git 初始化"
git init -q -b main
git config user.name "gaokun builder"
git config user.email "builder@example.com"
git add -A >/dev/null
git commit -qm "linux-$VER base"

APPLY_BAD=0
apply_group() {
  local name="$1"; shift
  step "应用补丁组: $name"
  local total=$#
  if git am "$@" >/dev/null 2>&1; then echo "OK: $name（$total/$total，git am）"; return 0; fi
  echo "!! git am 失败，改用 git apply 逐个尝试"
  git am --abort >/dev/null 2>&1
  local ok=0 bad=0
  for f in "$@"; do
    if git apply --3way "$f" >/dev/null 2>&1; then echo "   3way OK: $(basename "$f")"; ok=$((ok+1))
    elif git apply "$f" >/dev/null 2>&1; then echo "   apply OK: $(basename "$f")"; ok=$((ok+1))
    else echo "   !! 失败: $(basename "$f")"; bad=$((bad+1)); fi
  done
  echo "   小结: 成功 $ok / 失败 $bad"
  APPLY_BAD=$bad
}

shopt -s nullglob
# patches/media/ 整目录跳过：0006 会在同一 unit 地址建 venus 节点且 iommus 写错，
# IRIS 节点由 gaokun-iris-dts-prep.py 按上游写法前置。
apply_group upstream      $P/upstream/*.patch
apply_group others        $P/others/*.patch
apply_group dts-defconfig $P/0099-*.patch

step "3. 关键文件检查"
[ -f arch/arm64/configs/gaokun3_defconfig ] || die "补丁未应用成功：gaokun3_defconfig 不存在"
ls -l arch/arm64/configs/gaokun3_defconfig arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts

# EL2 系列发布于 2025-07，其中有 4 个补丁无法直接落在 v7.2-rc2 上：
#   0006 是引入 enum rproc_auto_boot 的那个补丁，它的 xlnx 改动撞上上游新增的
#        "if (fw_name) auto_boot = true" 代码块；
#   0010 / 0016 依赖 0006 引入的枚举，属级联失败；
#   0011 的 scm.h 片段撞上上游新增的 QCOM_SCM_VMID_CP_ADSP_SHARED。
# 本仓库重写了这三处（0006、0006b、0011），在此覆盖 buildbot 原集中的同名文件，
# 组装出可逐个干净应用的本地 EL2 补丁目录。
step "3b. 组装 EL2 补丁目录（buildbot 原集 + 本仓库重写覆盖）"
rm -rf "$EL2P"
cp -a "$P/el2" "$EL2P"
if [ -d "$EL2RB" ]; then
  for f in "$EL2RB"/*.patch; do
    [ -e "$f" ] || continue
    cp -f "$f" "$EL2P/"
    echo "  覆盖: $(basename "$f")"
  done
else
  echo "!! 未找到 $EL2RB，将使用 buildbot 原集（预计会失败）"
fi
echo "EL2 补丁数: $(ls "$EL2P"/*.patch | wc -l)"

# EL2 补丁组必须逐个应用。git apply 传多个文件是原子操作：
# 只要有一个失败，整组都进不去，而其中的 tzmem / SCM SHM bridge /
# qcom_q6v5_pas 补丁正是让 PAS 固件加载在 EL2 下可用的前提；
# 缺失时表现为 adsp / cdsp / slpi / venus 全部 -22，视频与音频同时失效。
step "4. EL2 补丁（逐个应用）"
apply_group el2 $EL2P/*.patch
[ "$APPLY_BAD" -le 2 ] || die "EL2 补丁组失败 $APPLY_BAD 个，超出容忍范围，中止以免产出 PAS 不可用的内核"
git add -A >/dev/null && git commit -qm "Apply EL2 patches (per-file, $(( $(ls $EL2P/*.patch | wc -l) - APPLY_BAD ))/$(ls $EL2P/*.patch | wc -l))" || true

step "4b. EL2 补丁生效性检查"
# 0011 引入 QCOM_SCM_VMID_SELF_OWNER（include/dt-bindings/firmware/qcom,scm.h）
grep -q 'QCOM_SCM_VMID_SELF_OWNER' include/dt-bindings/firmware/qcom,scm.h \
  || die "qcom,scm.h 缺少 QCOM_SCM_VMID_SELF_OWNER，EL2 补丁 0011 未生效"
# 0018 给 sc8280xp-el2.dtso 加 qcom,broken-reset
grep -q 'qcom,broken-reset' arch/arm64/boot/dts/qcom/sc8280xp-el2.dtso \
  || die "sc8280xp-el2.dtso 缺少 qcom,broken-reset，EL2 补丁 0018 未生效"
# 逐补丁回读：--check -R 成功说明该补丁的改动确实在工作区里
# 逐补丁回读：--check -R 成功说明该补丁的改动确实在工作区里。
# 注意这只能作为**提示**：补丁系列里后序补丁会改写同一文件，前序补丁的反向检查
# 因此必然失败（本系列 23 个里有 9 个属此类），不作为门禁。
# 真正的门禁是上面的失败计数与两处确定标记检查。
VERIFY_BAD=0
for f in $EL2P/*.patch; do
  git apply --check -R "$f" >/dev/null 2>&1 || VERIFY_BAD=$((VERIFY_BAD+1))
done
echo "EL2 回读提示：$VERIFY_BAD / $(ls $EL2P/*.patch | wc -l) 个补丁的反向检查未通过（系列内重叠改动的正常现象）"

step "5. 前置上游 IRIS 设备树节点"
python3 "$PREP" "$SRC" || die "IRIS 设备树前置失败"
git add -A >/dev/null && git commit -qm "sc8280xp/gaokun3: bring in upstream IRIS video node" || true

# 触屏接口模式：Himax HX83121A 由 TLMM gpio174 选择上报接口，引导固件把它留在高
# 电平（I2C-HID），必须由设备树描述为低电平输出，否则 SPI 通路收不到触摸数据。
# 走 base DTS，因此 base 与 el2（= base + sc8280xp-el2.dtbo）两个 DTB 同时生效。
step "5b. 触屏接口模式补丁（gpio174 低电平输出）"
git apply "$TOUCH_PATCH" || die "触屏补丁应用失败：$TOUCH_PATCH"
git add -A >/dev/null && git commit -qm "arm64: dts: qcom: sc8280xp-huawei-gaokun3: select SPI mode for touchscreen" || true
grep -c 'gpio174' arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dts >/dev/null \
  || die "base DTS 中未出现 gpio174"

# 视频固件在 EL2 下必须走 ctx 感知的 PAS 路径：固件缓冲区的 SHM bridge 得由 Linux
# 自己建（见 qcom_scm_pas_prepare_and_auth_reset() 的注释）。上游 iris 驱动按 EL1
# 写，传 NULL ctx，本机上表现为 "error -22 initializing firmware"。
step "5c. IRIS EL2 修复补丁（tzmem + ctx 感知 auth）"
git apply "$IRISP" || die "IRIS EL2 补丁应用失败：$IRISP"
git add -A >/dev/null && git commit -qm "media: iris: use ctx-aware PAS loading for EL2" || true

step "6. 生成配置"
rm -rf "$OUT"; mkdir -p "$OUT"
make O="$OUT" ARCH=arm64 gaokun3_defconfig >/dev/null || die "gaokun3_defconfig 失败"
CFG="$SRC/scripts/config"
"$CFG" --file "$OUT/.config" --set-str LOCALVERSION "$LOCALVER"
# 必须关闭 CONFIG_LOCALVERSION_AUTO：AUTO 在源码树非 pristine（无 git tag、或工作区
# 有未提交改动）时会给内核串追加一个 "+"。同一份逻辑源码在 clean / dirty 两种状态下
# 于是得到两个不同的内核串，进而派生出两个不同的 /lib/modules/<串>/ 目录、
# initrd 名与 BLS 条目名，破坏可复现性，也让发布 tag 与产物对不上号。
# 注意：本操作是 --disable（不是 --set-val ... n），最终 .config 里应出现
# "# CONFIG_LOCALVERSION_AUTO is not set"。
"$CFG" --file "$OUT/.config" --disable LOCALVERSION_AUTO
"$CFG" --file "$OUT/.config" --module  VIDEO_QCOM_IRIS
"$CFG" --file "$OUT/.config" --disable VIDEO_QCOM_VENUS
# 交叉编译没有构建机的签名密钥，关掉模块签名与可信密钥，否则会报缺证书
"$CFG" --file "$OUT/.config" --disable MODULE_SIG
"$CFG" --file "$OUT/.config" --disable MODULE_SIG_ALL
"$CFG" --file "$OUT/.config" --disable SYSTEM_TRUSTED_KEYS
"$CFG" --file "$OUT/.config" --disable SYSTEM_REVOCATION_KEYS
make O="$OUT" ARCH=arm64 olddefconfig >/dev/null || die "olddefconfig 失败"

echo "--- 关键配置 ---"
grep -E "VIDEO_QCOM_(IRIS|VENUS)|CONFIG_LOCALVERSION=|^CONFIG_MODULE_SIG|SYSTEM_TRUSTED_KEYS|QCOM_TZMEM|QCOM_SCM" "$OUT/.config"
grep -q "^CONFIG_VIDEO_QCOM_IRIS=m" "$OUT/.config" || die "CONFIG_VIDEO_QCOM_IRIS 不是 m"
grep -q "^CONFIG_VIDEO_QCOM_VENUS=" "$OUT/.config" && die "CONFIG_VIDEO_QCOM_VENUS 仍被设置"
# olddefconfig 已跑完，此处复核 AUTO 确实处于关闭态。scripts/config 的 --state 在
# "未被设置"时返回空串（即非 y 也非 n），故优先按 .config 里的字面行断言。
grep -q '^# CONFIG_LOCALVERSION_AUTO is not set$' "$OUT/.config" \
  || die "CONFIG_LOCALVERSION_AUTO 未关闭（.config 中缺少 '# CONFIG_LOCALVERSION_AUTO is not set'），内核串会被追加 '+' 而破坏可复现性"
echo "配置校验通过"
echo "--- 目标 release 串 ---"
cat "$OUT/include/config/kernel.release" 2>/dev/null || echo "（kernel.release 尚未生成，编译后复核）"

step "7. 编译 Image modules dtbs"
ccache -z >/dev/null 2>&1
echo "开始: $(date -Is)"
make O="$OUT" ARCH=arm64 -j"$JOBS" Image modules dtbs
rc=$?
echo "make 退出码: $rc  结束: $(date -Is)"

step "8. 产物与断言"
if [ "$rc" -eq 0 ]; then
  echo "--- 内核 release 串 ---"; cat "$OUT/include/config/kernel.release"
  # ★ 复现性红线：内核串尾不得有 "+"。那个 "+" 是 CONFIG_LOCALVERSION_AUTO 在源码树
  # 非 pristine（无 tag / 有未提交改动）时的追记符，会让同一份逻辑源码在 clean 与 dirty
  # 两种状态下派生出两个不同的 /lib/modules/<串>/、initrd 名与 BLS 条目名。
  KREL=$(cat "$OUT/include/config/kernel.release")
  case "$KREL" in
    *"+"*) die "内核串 '$KREL' 含 '+'：CONFIG_LOCALVERSION_AUTO 未真正关闭，模块目录会随源码树 clean/dirty 漂移" ;;
  esac
  echo "内核串自检通过：$KREL（不含 '+'）"
  echo "--- 关键产物 ---"
  ls -l "$OUT/arch/arm64/boot/Image"
  ls -l "$OUT/drivers/media/platform/qcom/iris/qcom-iris.ko"
  for d in "$OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb" \
           "$OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3-el2.dtb"; do
    ls -l "$d"
    grep -aq gpio174 "$d"      || die "$d 缺少 gpio174 触屏修复"
    grep -aq 'sc8280xp-iris' "$d" || die "$d 缺少 IRIS 节点"
    grep -aq 'qcom,sm8350-venus' "$d" && die "$d 仍含旧 venus 兼容串"
    echo "   断言通过: $(basename "$d") 含 gpio174 与 IRIS、不含 venus"
  done
  echo "--- iris 模块 of 别名 ---"
  modinfo "$OUT/drivers/media/platform/qcom/iris/qcom-iris.ko" 2>/dev/null | grep -i alias | head
  echo "--- 模块总数 ---"
  find "$OUT" -name '*.ko' | wc -l
  echo "--- modules.builtin.modinfo ---"
  ls -l "$OUT/modules.builtin.modinfo" || echo "!! 缺少 modules.builtin.modinfo"
else
  echo "编译失败，错误摘要："
  grep -nE "error:|Error [0-9]|错误" "$LOG" | tail -30
fi
echo "=================== 构建结束 $(date -Is) rc=$rc ==================="
exit "$rc"
