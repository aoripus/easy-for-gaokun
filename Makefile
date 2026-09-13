# ============================================================================
# easy-for-gaokun — 本地检查与辅助目标
#
# 目标名与 .github/workflows/ci.yml 的 job 一一对应：CI 只是把同一组检查
# 搬上 runner，本地 `make check` 就是"CI 会怎么判我"的答案。
#
# 依赖工具：shellcheck、yamllint（pip）、ruff（pip）、node/npx。
# Windows 开发机通常没有 make：可用 `npm run check`（等价目标）。
#
# 本文件用 TAB 缩进（Make 语法要求），见 .editorconfig。
# ============================================================================

SHELL := /bin/bash
.DEFAULT_GOAL := help

SH_FILES := $(wildcard scripts/*.sh scripts/lib/*.sh tools/*.sh)

.PHONY: help check lint-md lint-sh lint-py lint-yaml hygiene patches release-check

help: ## 显示可用目标
	@echo "easy-for-gaokun 本地检查（与 CI 的 job 一一对应）"
	@echo ""
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-16s %s\n", $$1, $$2}'
	@echo ""
	@echo "依赖：shellcheck、yamllint、ruff、node/npx；Windows 无 make 时用 npm run check"

check: lint-md lint-sh lint-py lint-yaml hygiene patches ## 跑全部检查（等价于 CI）
	@echo "全部检查通过"

lint-md: ## Markdown 风格（规则见 .markdownlint-cli2.yaml）
	npx --yes markdownlint-cli2 "**/*.md"

lint-sh: ## shellcheck -x + 逐文件 bash -n
	shellcheck -S warning -x $(SH_FILES)
	@for f in $(SH_FILES); do bash -n "$$f" || exit 1; done
	@echo "OK：shellcheck 与 bash -n 均通过"

lint-py: ## ruff + 字节码编译
	ruff check tools/
	python -m compileall -q tools/
	@echo "OK：ruff 与 compileall 均通过"

lint-yaml: ## yamllint（覆盖 .github/**）
	yamllint -c .yamllint.yml .

hygiene: ## 仓库卫生：LF / 红线文件 / 体积 / 末尾换行
	@set -euo pipefail; \
	if git grep -Il $$'\r' >/dev/null 2>&1; then \
	  echo "FAIL：以下文件含 CRLF（仓库一律 LF，见 .gitattributes）：" >&2; \
	  git grep -Il $$'\r' >&2; exit 1; \
	fi; \
	echo "OK：全仓库无 CRLF"; \
	bad=$$(git ls-files | grep -E '(^|/)(Drv|Recovery)/|(^|/)AGENTS\.md$$' || true); \
	if [ -n "$$bad" ]; then \
	  echo "FAIL：以下红线文件被跟踪（专有驱动转储 / 恢复镜像 / 本地台账）：" >&2; \
	  printf '%s\n' "$$bad" >&2; exit 1; \
	fi; \
	echo "OK：Drv/、Recovery/、AGENTS.md 均未被跟踪"; \
	big=$$(git ls-files -z | xargs -0 -r stat -c '%s %n' | awk '$$1 > 2097152 {print}'); \
	if [ -n "$$big" ]; then echo "FAIL：以下文件超过 2 MiB：" >&2; printf '%s\n' "$$big" >&2; exit 1; fi; \
	echo "OK：没有被跟踪的文件超过 2 MiB"

patches: ## 补丁序列元数据自检（series 与文件一一对应）
	@if [ -f scripts/check-patches.sh ]; then \
	  bash scripts/check-patches.sh; \
	else \
	  echo "跳过：scripts/check-patches.sh 尚未落地"; \
	fi

release-check: ## 发布前自检清单（在构建宿主上执行，本目标只打印说明）
	@echo "发布前自检（构建宿主 = 交叉编译机，不是目标机）："
	@echo "  1) include/config/kernel.release 不得含 '+' —— 构建时移开 .git，见 docs/kernel-7.2.5-el1-build.md"
	@echo "  2) 断言 CONFIG_VIDEO_QCOM_VENUS=m 且 # CONFIG_VIDEO_QCOM_IRIS is not set"
	@echo "  3) 产物 DTB 含 gpio174 / sm8350-venus / qcvss8280.mbn，且不含 shm-bridge-vmid"
	@echo "  4) 资产 8 项齐全并生成 sha256sums.txt"
	@echo "完整流程与装机复核清单见 docs/releasing.md"
