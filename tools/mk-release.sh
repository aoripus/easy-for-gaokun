#!/bin/bash
# 打包内核产物 + 生成 GPL-2.0 合规的构建溯源清单 + 校验和
set -u
BASE=/root/gaokun
VER=7.2-rc2
SRC=$BASE/linux
OUT=$BASE/out-$VER
REL=$(cat "$OUT/include/config/kernel.release" 2>/dev/null)
[ -n "$REL" ] || { echo "读不到 kernel.release，构建是否成功？"; exit 1; }
# ★ 复现性红线：内核串尾不得有 "+"。那个 "+" 是 CONFIG_LOCALVERSION_AUTO 在源码树非
# pristine（无 tag / 有未提交改动）时的追记符。带 "+" 的串意味着一份逻辑源码会派生出
# 两个不同的 /lib/modules/<串>/、initrd 名与 BLS 条目名，产物不可复现，拒绝打包。
case "$REL" in
  *"+"*) echo "!! 内核串 '$REL' 含 '+'：CONFIG_LOCALVERSION_AUTO 未关闭，拒绝打包"; exit 1 ;;
esac
STAGE=$BASE/stage-${REL%-}
rm -rf "$STAGE"; mkdir -p "$STAGE"

echo "release 串: $REL"
echo "暂存目录 : $STAGE"

echo "=== 1. 收集产物 ==="
cp -v "$OUT/arch/arm64/boot/Image"                              "$STAGE/Image"
cp -v "$OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3.dtb"     "$STAGE/"
cp -v "$OUT/arch/arm64/boot/dts/qcom/sc8280xp-huawei-gaokun3-el2.dtb" "$STAGE/" 2>/dev/null || echo "  (无 el2 dtb)"
cp -v "$OUT/.config"                                            "$STAGE/config-$REL"
cp -v "$OUT/System.map"                                         "$STAGE/System.map-$REL"
cp -v "$OUT/vmlinux"                                            "$STAGE/vmlinux-$REL" 2>/dev/null || true
cp -v "$OUT/modules.order" "$OUT/modules.builtin"               "$STAGE/" 2>/dev/null || true
cp -v "$OUT/modules.builtin.modinfo" "$STAGE/" 2>/dev/null || true

echo
echo "=== 2. 打包模块 ==="
MODSTAGE=$BASE/modstage
rm -rf "$MODSTAGE"; mkdir -p "$MODSTAGE"
# 只收 .ko 与模块元数据，不要中间对象
find "$OUT" -name '*.ko' -print0 | while IFS= read -r -d '' ko; do
  rel=${ko#"$OUT"/}
  mkdir -p "$MODSTAGE/$(dirname "$rel")"
  cp "$ko" "$MODSTAGE/$rel"
done
cp "$OUT/Module.symvers" "$MODSTAGE/" 2>/dev/null || true
cp "$OUT/modules.order" "$OUT/modules.builtin" "$MODSTAGE/" 2>/dev/null || true
cp "$OUT/modules.builtin.modinfo" "$MODSTAGE/" 2>/dev/null || true
KO_COUNT=$(find "$MODSTAGE" -name '*.ko' | wc -l)
echo "  模块数: $KO_COUNT"
tar -C "$MODSTAGE" -cf - . | zstd -19 -T0 -q -o "$STAGE/modules-$REL.tar.zst"
echo "  模块包: $(du -h "$STAGE/modules-$REL.tar.zst" | cut -f1)"

echo
echo "=== 3. 生成构建溯源清单 BUILD-PROVENANCE.md ==="
{
  echo "# 构建溯源清单（BUILD-PROVENANCE）"
  echo
  echo "本文件随内核二进制产物一同发布，用于满足 **GPL-2.0** 的对应源码要求，并保证可复现。"
  echo "本仓库自身以 GPL-2.0-only 发布；内核源码派生自 Linux 内核（GPL-2.0）。"
  echo
  echo "## 产物"
  echo
  echo '| 项 | 值 |'
  echo '|---|---|'
  echo "| 内核 release 串 | \`$REL\` |"
  echo "| 构建时间（UTC） | $(date -u -Is) |"
  echo "| 目标机型 | HUAWEI MateBook E Go 2022 性能版（GK-W76 / GK-W7X / SC8280XP / 设备树代号 gaokun3） |"
  echo "| 架构 | arm64 |"
  echo "| 模块数 | $KO_COUNT |"
  echo
  echo "## 源码来源"
  echo
  echo '| 项 | 值 |'
  echo '|---|---|'
  echo "| 上游仓库 | \`https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git\` |"
  echo "| 基线 tag | \`v$VER\` |"
  echo "| tag 指向 commit | \`$(git -C "$SRC" rev-list -n1 "v$VER" 2>/dev/null || echo '(tree squashed, see base commit)')\` |"
  echo "| 打补丁后的树 | \`$(git -C "$SRC" rev-parse HEAD)\` |"
  echo "| 源码快照 URL | \`https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/snapshot/linux-$VER.tar.gz\` |"
  echo
  echo "## 补丁集"
  echo
  echo "按顺序应用，全部来自 \`KawaiiHachimi/linux-gaokun-buildbot\` 的 \`patches/\`："
  echo
  echo '```text'
  echo "patches/upstream/*.patch        （$(ls $BASE/buildbot-patches/upstream/*.patch | wc -l) 个）"
  echo "patches/others/*.patch          （$(ls $BASE/buildbot-patches/others/*.patch | wc -l) 个）"
  echo "patches/0099-*.patch            （导入 gaokun3 板级 DTS 与 defconfig）"
  echo "patches/el2/*.patch             （$(ls $BASE/el2-patches/*.patch 2>/dev/null | wc -l) 个；其中 0006、0006z、0011 使用 easy-for-gaokun 的 v7.2-rc2 适配版，见该仓库 patches/el2-v7.2/）"
  echo "patches/media/                  **整目录跳过**（0006 是过时的 venus 形态，与本产物的 IRIS 方案冲突）"
  echo '```'
  echo
  echo "补丁集来源：\`https://github.com/KawaiiHachimi/linux-gaokun-buildbot\`（commit \`$(cat $BASE/buildbot-patches.commit 2>/dev/null || echo archived-with-release)\`）"
  echo
  echo "## 设备树改动（本仓库）"
  echo
  echo "### 触屏接口模式"
  echo
  echo "补丁 \`patches/0001-arm64-dts-qcom-sc8280xp-huawei-gaokun3-select-SPI-mode-for-touchscreen.patch\`"
  echo "在触屏默认引脚状态里把 TLMM \`gpio174\` 描述为低电平输出。引导固件把它留在高电平，会使"
  echo "Himax HX83121A 停在 I2C-HID 模式，SPI 通路收不到触摸数据。改动落在 base DTS，因此 base 与"
  echo "el2（= base + \`sc8280xp-el2.dtbo\`）两个 DTB 同时生效。"
  echo
  echo "### IRIS 视频节点"
  echo
  echo "由 \`tools/gaokun-iris-dts-prep.py\` 前置上游 IRIS 节点，等价于 Linux v7.3-rc1 引入的："
  echo
  echo '```text'
  echo "3a52eef16b979617156fa6e2ead24ca4d1336f0b  arm64: dts: qcom: sc8280xp: Add Iris"
  echo "595eb4144f2ecc58e8e56e07ae94407b5a696031  arm64: dts: qcom: sc8280xp-lenovo-thinkpad-x13s: Enable Iris"
  echo '```'
  echo
  echo "改动内容：\`sc8280xp.dtsi\` 补 3 个 include、\`pil_video_mem\`、\`iris\` 与 \`videocc\` 节点；"
  echo "板级 dts 追加 \`&iris { firmware-name = \"qcom/sc8280xp/HUAWEI/gaokun3/qcvss8280.mbn\"; status = \"okay\"; };\`"
  echo
  echo "## 配置要点"
  echo
  echo '```text'
  grep -E "CONFIG_LOCALVERSION(=|_AUTO)|CONFIG_VIDEO_QCOM_(IRIS|VENUS)|CONFIG_MODULE_SIG=|CONFIG_DEBUG_INFO_BTF=" "$OUT/.config"
  echo '```'
  echo
  echo "## 构建环境"
  echo
  echo '```text'
  echo "构建机    : $(uname -srm)  ($(nproc) 线程)"
  echo "交叉工具链: $(${CROSS_COMPILE:-aarch64-linux-gnu-}gcc --version | head -1)"
  echo "构建命令  : make O=<out> ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc) Image modules dtbs"
  echo '```'
  echo
  echo "## 复现步骤"
  echo
  echo '```bash'
  echo "# 1) 取源码"
  echo "curl -LO https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/snapshot/linux-$VER.tar.gz"
  echo "# 2) 取补丁集"
  echo "git clone https://github.com/KawaiiHachimi/linux-gaokun-buildbot"
  echo "# 3) 取本项目的设备树前置工具"
  echo "git clone https://github.com/aoripus/easy-for-gaokun"
  echo "# 4) 按 https://github.com/aoripus/easy-for-gaokun/blob/main/docs/build-kernel-iris.md 执行"
  echo '```'
  echo
  echo "## 校验和"
  echo
  echo "见同目录的 \`sha256sums.txt\`。"
} > "$STAGE/BUILD-PROVENANCE.md"

echo
echo "=== 4. 生成校验和 ==="
( cd "$STAGE" && sha256sum * > sha256sums.txt && cat sha256sums.txt )

echo
echo "=== 5. 清单 ==="
ls -lh "$STAGE"

# 记下补丁集来源 commit，便于溯源
git -C "$SRC" log --oneline | head -20 > "$STAGE/git-log-patched-tree.txt"
echo "已写出 $STAGE/git-log-patched-tree.txt"
