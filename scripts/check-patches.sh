#!/usr/bin/env bash
# =============================================================================
# easy-for-gaokun — check-patches.sh
#
# 校验 patches/*/series 与目录内补丁文件的一致性：
#   ① series 里列出的每个补丁文件都必须存在；
#   ② 目录内每个 *.patch 都必须被 series 列出（防止"加了补丁忘了排进序列"）；
#   ③ 补丁文件必须非空，且看起来是补丁（含 `diff --git` 或 `--- ` 头）。
#
# 只读：不修改任何文件，也不调用 git（CI runner 与本机都能直接跑）。
# 真正的应用验证（`git apply --check` / `patch --dry-run`）需要内核树，在构建宿主上做。
#
# 用法：scripts/check-patches.sh [--quiet]
# 退出码：0 = 全部通过；1 = 存在不合格项
# =============================================================================
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
QUIET=0
case "${1:-}" in
  --quiet) QUIET=1 ;;
  -h|--help)
    sed -n '2,14p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
  "") ;;
  *)
    echo "未知参数：$1（可用：--quiet）" >&2
    exit 2
    ;;
esac

fail=0
dir_count=0
patch_count=0

log() { [ "$QUIET" -eq 1 ] || printf '%s\n' "$*"; }

shopt -s nullglob
for dir in "$ROOT"/patches/*/; do
  name=$(basename "$dir")
  series="$dir/series"
  dir_count=$((dir_count + 1))

  if [ ! -f "$series" ]; then
    printf '[FAIL] %-16s 缺少 series 文件（每个序列都必须声明应用顺序）\n' "$name"
    fail=1
    continue
  fi

  # series 中"有效条目"= 去掉注释、取第一个字段、跳过空行与 -pN 选项
  listed=$(sed 's/#.*//' "$series" | awk '{print $1}' | grep -v '^$' | grep -v '^-' || true)

  # ① series → 文件
  if [ -n "$listed" ]; then
    while IFS= read -r f; do
      if [ ! -f "$dir$f" ]; then
        printf '[FAIL] %-16s series 列出的补丁不存在：%s\n' "$name" "$f"
        fail=1
      fi
    done <<< "$listed"
  else
    printf '[FAIL] %-16s series 里没有任何补丁条目\n' "$name"
    fail=1
  fi

  # ② 文件 → series，③ 内容检查
  n=0
  for p in "$dir"*.patch; do
    base=$(basename "$p")
    n=$((n + 1))
    patch_count=$((patch_count + 1))

    if ! grep -qxF "$base" <<< "$listed"; then
      printf '[FAIL] %-16s 补丁未被 series 列出：%s\n' "$name" "$base"
      fail=1
    fi
    if [ ! -s "$p" ]; then
      printf '[FAIL] %-16s 补丁是空文件：%s\n' "$name" "$base"
      fail=1
    elif ! grep -qE '^(diff --git |--- )' "$p"; then
      printf '[FAIL] %-16s 不像补丁（缺 diff --git / --- 头）：%s\n' "$name" "$base"
      fail=1
    fi
  done

  log "[ OK ] $name：series 与 $n 个补丁一一对应"
done

if [ "$dir_count" -eq 0 ]; then
  echo "[FAIL] patches/ 下没有找到任何序列目录" >&2
  exit 1
fi

if [ "$fail" -ne 0 ]; then
  echo "补丁序列校验失败" >&2
  exit 1
fi

log "全部通过：$dir_count 个序列、$patch_count 个补丁"
exit 0
