#!/bin/bash
# =============================================================================
# 在 x86_64 Linux 上交叉编译 gaokun3（SC8280XP）的 IRIS 试验内核
#
# 只编译，不安装：产物止步于 Image / dtb / modules 散件，不碰任何 ESP、
# 不跑 modules_install、不动 efibootmgr。
#
# 用法：
#   GK_LOCALVERSION="-aoripus-ml-gaokun-eog-iris-el2" ./build-iris-x86.sh
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
LOCALVER="${GK_LOCALVERSION:--aoripus-ml-gaokun-eog-iris-el2}"
TARBALL=$BASE/linux-$VER.tar.gz
SRC=$BASE/linux
OUT=$BASE/out-$VER
P=$BASE/buildbot-patches
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

# EL2 补丁组必须逐个应用。git apply 传多个文件是原子操作：
# 只要有一个失败，整组都进不去，而其中的 tzmem / SCM SHM bridge /
# qcom_q6v5_pas 补丁正是让 PAS 固件加载在 EL2 下可用的前提；
# 缺失时表现为 adsp / cdsp / slpi / venus 全部 -22，视频与音频同时失效。
step "4. EL2 补丁（逐个应用）"
apply_group el2 $P/el2/*.patch
[ "$APPLY_BAD" -le 2 ] || die "EL2 补丁组失败 $APPLY_BAD 个，超出容忍范围，中止以免产出 PAS 不可用的内核"
git add -A >/dev/null && git commit -qm "Apply EL2 patches (per-file, $(( $(ls $P/el2/*.patch | wc -l) - APPLY_BAD ))/$(ls $P/el2/*.patch | wc -l))" || true

step "4b. EL2 补丁生效性检查"
# 0011 引入 QCOM_SCM_VMID_SELF_OWNER（include/dt-bindings/firmware/qcom,scm.h）
grep -q 'QCOM_SCM_VMID_SELF_OWNER' include/dt-bindings/firmware/qcom,scm.h \
  || die "qcom,scm.h 缺少 QCOM_SCM_VMID_SELF_OWNER，EL2 补丁 0011 未生效"
# 0018 给 sc8280xp-el2.dtso 加 qcom,broken-reset
grep -q 'qcom,broken-reset' arch/arm64/boot/dts/qcom/sc8280xp-el2.dtso \
  || die "sc8280xp-el2.dtso 缺少 qcom,broken-reset，EL2 补丁 0018 未生效"
# 逐补丁回读：--check -R 成功说明该补丁的改动确实在工作区里
VERIFY_BAD=0
for f in $P/el2/*.patch; do
  git apply --check -R "$f" >/dev/null 2>&1 || { echo "   !! 回读未通过: $(basename "$f")"; VERIFY_BAD=$((VERIFY_BAD+1)); }
done
echo "EL2 回读校验：未通过 $VERIFY_BAD / $(ls $P/el2/*.patch | wc -l)（补丁间存在重叠改动时允许少量偏差）"
[ "$VERIFY_BAD" -le 4 ] || die "EL2 补丁回读校验失败 $VERIFY_BAD 个，超出容忍范围，中止"

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

step "6. 生成配置"
rm -rf "$OUT"; mkdir -p "$OUT"
make O="$OUT" ARCH=arm64 gaokun3_defconfig >/dev/null || die "gaokun3_defconfig 失败"
CFG="$SRC/scripts/config"
"$CFG" --file "$OUT/.config" --set-str LOCALVERSION "$LOCALVER"
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
echo "配置校验通过"
echo "--- 目标 release 串 ---"
cat "$OUT/include/config/kernel.release"

step "7. 编译 Image modules dtbs"
ccache -z >/dev/null 2>&1
echo "开始: $(date -Is)"
make O="$OUT" ARCH=arm64 -j"$JOBS" Image modules dtbs
rc=$?
echo "make 退出码: $rc  结束: $(date -Is)"

step "8. 产物与断言"
if [ "$rc" -eq 0 ]; then
  echo "--- 内核 release 串 ---"; cat "$OUT/include/config/kernel.release"
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
