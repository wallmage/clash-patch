# 当前测试基线

本文件记录现行测试范围，不定义产品功能。产品要求见 `docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md` 和 `clash-patch/references/patch-policy.md`。

## 必须通过

- Ruby：macOS 三档用途、转换、备份/比较/恢复、安全更新事务、运行刷新、YAML 1.2、Mihomo 校验和分流验证。
- 覆盖率门槛：macOS 纯配置转换核心与独立分流验证器必须 100% 行覆盖，包含操作系统适配和 CLI 的单体补丁脚本整体不得低于 90%；Windows JavaScript 转换引擎必须 100% 行、100% 函数且分支不低于 80%。门槛只能上调；不得通过忽略正常生产行、无断言调用或删除防御代码凑数字。
- Shell/CMD 包装器：帮助、参数与退出状态、档位保存/复用、能力预检、卸载和备份保留等公开行为；不拿包装器逐行覆盖率冒充安全性。
- Node.js：Windows 全局扩展脚本与 macOS 策略一致。
- PowerShell 5.1：Windows 三档用途、安装/卸载、自动更新关闭、远程订阅清单、安全更新前后检查、嵌套配置差异、恢复校验和事务恢复。
- 合同测试：公开文件、Patch/Diagnostics、AdGuard 兼容路径、配置历史、安全更新、Sub Agent 边界、Windows Computer Use 条件、双平台分流验证、策略生成、平台边界和 CI 配置。
- 语法与格式：Ruby、JavaScript、Shell、PowerShell、策略同步和 `git diff --check`。

## 必须持续防止

- 退出、停止或重启 Clash。
- macOS 自动监听、自动重载、自动切换 TUN 或节点。
- 修改未启用的存储位置、旧 iCloud 容器、备份或废弃订阅。
- 用固定境外 DNS 覆盖节点启动解析。
- 自动创建额外安全代理组或替用户选择 AI 节点。
- 在第一、二档执行第三档泄漏检查或订阅补丁。
- 把 Windows Computer Use 当成后台或锁屏能力，或在当前会话没有工具时假装完成界面验收。
- 让 Sub Agent 并行写配置、更新/恢复订阅、抢同一界面或同时制造测试流量。
- 并发刷新覆盖、重复代理组、非幂等转换、无限等待和泄露敏感信息。

具体命令和 CI 流程见 `AGENTS.md`。
