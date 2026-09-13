# RFC-0001：仓库标准化

- **状态**：已接受，实施中
- **日期**：2026-09-13
- **相关**：[`CONTRIBUTING.md`](../../CONTRIBUTING.md)、[`docs/adr/`](../adr/)、[`.github/workflows/ci.yml`](../../.github/workflows/ci.yml)

## 背景（Context）

本项目此前的重心全在"把机器点亮、把触屏和硬解做通"，仓库只有三样东西：
`README`/`CONTRIBUTING`/`CHANGELOG`、一套编号脚本、一堆实机结论文档。缺的是**工程外壳**：

- 没有平台层：无 CI、无 issue/PR 模板、无 CODEOWNERS、无依赖更新机制；
- 没有社区健康文件：行为准则、安全策略、支持范围、治理规则全靠 README 正文里零散交代；
- 没有统一工具链：编辑器约定、lint 规则、任务入口（`make`/`npm`）、提交信息校验都缺失；
- 没有文档治理：文档索引、决策记录（ADR）、写作规范、术语表、发布流程都散落在正文里；
- 没有补丁治理：`patches/` 里既有散落补丁，也没有"应用顺序"与"是否用于当前内核"的元数据；
- 一致性缺口：README 的结构树与现状脱节、CHANGELOG 有重复章节、部分结论互相矛盾。

结果就是：外部贡献者无法判断"该改什么、怎么验、合不合规"，维护者自己也在靠记忆行事。

## 范围（Scope）

1. **平台层** `.github/`：CI（6 个静态检查 job，与 `make check` 目标一一对应）、
   release 资产校验、issue/PR 模板、CODEOWNERS、dependabot。
2. **社区健康**：`CODE_OF_CONDUCT.md`、`SECURITY.md`、`SUPPORT.md`、`GOVERNANCE.md`、`MAINTAINERS.md`。
3. **工具链**：`.editorconfig`、markdownlint / shellcheck / yamllint / ruff 配置、
   `Makefile`、`package.json`（npm 脚本）、`.pre-commit-config.yaml`、`commitlint.config.mjs`、`.gitmessage`。
4. **文档治理**：`docs/README.md`（索引与状态表）、`docs/adr/`（回溯 6 条决策）、
   `docs/rfc/`（本文件）、`docs/style-guide.md`、`docs/glossary.md`、`docs/releasing.md`、
   `docs/releases/TEMPLATE.md`、`docs/architecture.md`。
5. **补丁治理**：`patches/README.md` + 每个序列的 `series` 与统一元数据
   （用途 / 基线 / 上游状态 / 是否用于当前内核 / 验证 / 回滚），散落补丁归入序列目录。
6. **一致性**：README 结构树与现状对齐、CHANGELOG 按 Keep a Changelog 去重、
   陈旧结论更正（视频硬解的适用范围）、移除公开文档中的内网地址。
7. **远程设置**：仓库 topics、私密漏洞上报、label 分类。

## 非目标（Non-goals）

- **不启用 branch protection 强制 PR**：本仓是单人维护 + 高频实机迭代，
  既定工作流是维护者直接推 `main`（[`GOVERNANCE.md`](../../GOVERNANCE.md) 已写明）。
  是否改由维护者决定；在此之前 CI 只作**提示**，不作合并门槛。
- **不改写 git 历史**：不 rebase、不 amend 已推送提交；错误用后续提交更正并留痕。
- **不移动** `Drv/`、`Recovery/`（专有资产，永不入库），也不把它们纳入任何检查。
- **不重命名**当前可用的构建脚本（如 `tools/build-iris-x86.sh`）：名字是历史遗留，
  改名会牵动文档与 CI，收益不抵风险；仅在 `tools/README.md` 中如实说明。
- **不做全仓库表格重排**：markdownlint 的 MD060 显式关闭（见 `.markdownlint-cli2.yaml` 注释）。

## 验收标准（Acceptance）

| # | 标准 | 判定方式 |
|:-:|------|----------|
| 1 | 本地与 CI 跑同一组检查 | `make check` 的 6 个目标与 `ci.yml` 的 6 个 job 同名同内容 |
| 2 | CI 全绿 | `gh run list` 上 main 分支最近一次运行 6 个 job 全通过 |
| 3 | markdown 无告警 | `npx --yes markdownlint-cli2 "**/*.md"` → 0 issues |
| 4 | 补丁序列自洽 | `scripts/check-patches.sh` 通过（series ↔ 补丁文件一一对应） |
| 5 | 文档无孤儿、无死链 | `docs/README.md` 覆盖 `docs/` 下全部 `.md`，相对链接均存在 |
| 6 | 一文件一 commit | `git log --oneline` 中每个新增/修改文件都有独立提交 |
| 7 | 无隐私泄漏 | 公开文档中无内网 IP、无邮箱（补丁的 `Signed-off-by` 除外，那是内核补丁的硬要求） |

## 风险与回滚（Risks & Rollback）

- **风险**：新增 lint 规则可能与既有文档风格冲突（已通过配置显式放行，并在配置里写明理由）。
- **风险**：CI 若依赖尚不存在的文件会误导（已用"存在则执行、否则 `::notice::` 跳过"的方式保护）。
- **回滚**：全部改动是**新增文件为主**，逐文件 `git revert <hash>` 即可；
  被修改的既有文件也都在独立提交里，可单独回滚。
