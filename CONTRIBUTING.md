# 贡献指南

感谢你对 vpnmax 的关注！

## 报 Bug

1. 先搜 [Issues](https://github.com/ccAzy/vpnmax/issues)，看有没有人报过
2. 没有就新建 Issue，选 `Bug report` 模板
3. 贴上：系统版本、架构、报错日志、复现步骤

## 提建议

1. 新建 Issue，选 `Feature request` 模板
2. 说清楚：你想解决什么问题、期望的行为是什么

## 提 PR

1. Fork → 新建分支（`git checkout -b fix/xxx`）
2. 改完跑一遍 `shellcheck`：`shellcheck -x *.sh lib/*.sh`
3. 改完跑一遍语法检查：`bash -n *.sh lib/*.sh`
4. 提 PR，选 PR 模板，写清楚改了什么、为什么改

## 代码风格

- 缩进 4 空格，不用 Tab
- 函数命名用 `snake_case`
- 每个脚本头部写清楚用途和用法
- 变量用双引号包裹（`"$var"`），除非你明确知道不需要
- 禁止 `eval`、禁止 `curl | bash`（一键安装除外）

## 测试

- 本地改完用 `bash -n` 检查语法
- 有 bats 的跑一遍：`bats tests/`
- 上机前先 `--dry-run`

## 许可证

本项目使用 GPL-3.0-only，提交即表示你同意你的代码也以 GPL-3.0 发布。
