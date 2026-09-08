# 安全策略

## 报告漏洞

如果你发现了安全漏洞，请**不要**公开提交 Issue。

请通过以下方式私下报告：

1. **GitHub Security Advisory**（推荐）：  
   [https://github.com/ccAzy/vpnmax/security/advisories/new](https://github.com/ccAzy/vpnmax/security/advisories/new)

2. **邮件**：  
   发送到 repo owner 的 GitHub 邮箱（可在 profile 页找到）

## 你会收到什么

- 24 小时内确认收到
- 7 天内给出初步评估
- 修复后公开致谢（除非你要求匿名）

## 什么是安全漏洞

- 认证绕过（未授权访问服务器）
- 命令注入（用户输入被拼接到 shell 命令）
- 密钥/凭据泄露
- 权限提升
- 订阅链接可被伪造

## 什么不算

- 功能 bug（请走普通 Issue）
- 配置不当导致的问题（如密码太弱）
- 已知的上游组件漏洞（请报给上游）
