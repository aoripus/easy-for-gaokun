// ============================================================================
// easy-for-gaokun — commitlint 配置
//
// 与 CONTRIBUTING.md「提交信息格式」一致：`<type>(<scope>): <subject>`，
// 首行 ≤ 72 字符，正文说明「改了什么、为什么」。type 列表在 CONTRIBUTING
// 的基础上补齐 style / ci / revert（都是本项目实际会用到的类别）。
//
// 用法：npx --yes commitlint --edit "$1"（或由 .pre-commit-config.yaml 之外的
// commit-msg 钩子调用；CI 侧只做 header 长度的格式检查）。
// ============================================================================

export default {
  extends: ['@commitlint/config-conventional'],
  rules: {
    'header-max-length': [2, 'always', 72],
    'type-empty': [2, 'never'],
    'subject-empty': [2, 'never'],
    'subject-full-stop': [0, 'never'], // 中文标题不以句号结尾由人判断
    'subject-case': [0, 'always'],     // 中文标题没有大小写概念
    'body-max-line-length': [0, 'always'],
    'type-enum': [
      2,
      'always',
      [
        'feat',
        'fix',
        'docs',
        'style',
        'refactor',
        'perf',
        'test',
        'build',
        'ci',
        'chore',
        'revert',
      ],
    ],
  },
};
