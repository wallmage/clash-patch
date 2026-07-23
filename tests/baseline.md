# 当前测试基线

本文件记录现行测试范围，不定义产品功能。产品要求见 `docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md` 和 `clash-patch/references/patch-policy.md`。

## 必须通过

- Ruby：macOS 三档用途、全部订阅共享的国内域名规则提供器、名称冲突保护、转换、备份/比较/恢复、安全更新事务、批量更新期间的路径原子替换与中途写入失败恢复、运行刷新、恢复当前订阅时保持 TUN 状态并复核运行内核、文件与内核恢复状态分别上报、YAML 1.2、Mihomo 校验和分流验证。
- 双平台 conformance：`tests/fixtures/main_group_cases.json` 由 macOS Ruby 与 Windows JavaScript 共用；每个案例用人工确认后的 `expected_config_sha256` 锁定完整结果，两端分别匹配后再做完整输出深比较，发生变化的案例再次执行后必须不再变化。
- 覆盖率门槛：macOS 纯配置转换核心与独立分流验证器必须 100% 行覆盖，每个 Ruby 生产模块不得低于 80%，包含操作系统适配、文件事务和 CLI 的全部生产模块合计不得低于 90%；Windows JavaScript 转换引擎必须 100% 行、100% 函数且分支不低于 80%。统计必须跟随生产代码拆分后的全部模块，不能因移动代码缩小范围。门槛只能上调；不得通过忽略正常生产行、无断言调用或删除防御代码凑数字。
- Shell/CMD 包装器：帮助、参数与退出状态、档位保存/复用、失败时保持原档位、档位 3 降档前强制安全卸载、能力预检、卸载和备份保留等公开行为；macOS 另以真实 Shell → 真实 Ruby 主程序 → 受控 Mihomo 可执行文件验证公开安装成功路径，不拿包装器逐行覆盖率冒充安全性。
- Node.js：Windows 全局扩展脚本与 macOS 策略一致；档位 1、2 只应用共享国内域名基线，档位 3 再应用完整增强。
- PowerShell 5.1 与 7：Windows 三档用途、安装/卸载、失败时保持原档位、档位 3 降档前强制安全卸载、自动更新关闭、远程订阅清单、安全更新前后检查、嵌套配置差异、恢复校验、事务恢复，以及分流验证公开入口的四项成功路径；全库通过 PowerShell AST 禁止在赋值、参数、循环、自增减或变量命令中写入只读自动变量。
- 合同测试：公开文件、Patch/Diagnostics、AdGuard 兼容路径、配置历史、安全更新、Sub Agent 边界、Windows Computer Use 条件、双平台分流验证、策略生成、平台边界和 CI 配置；全部公开命令的 JSON v1 必须保持单对象输出、退出码一致、稳定 `code`/`operation`、规定字段类型和脱敏边界，默认中文输出不变。
- 语法与格式：Ruby、JavaScript、Shell、PowerShell、全部 PowerShell 文件的严格 UTF-8 BOM、策略同步和 `git diff --check`。

## 必须持续防止

- 退出、停止或重启 Clash。
- macOS 自动监听、自动重载、自动切换 TUN 或节点。
- 修改未启用的存储位置、旧 iCloud 容器、备份或废弃订阅。
- 用固定境外 DNS 覆盖节点启动解析。
- 自动创建额外安全代理组或替用户选择 AI 节点。
- 在第一、二档执行第三档泄漏检查、TUN/IPv6、WebRTC 或 AI 分组增强；共享国内域名基线不属于第三档增强。
- 把 Windows Computer Use 当成后台或锁屏能力，或在当前会话没有工具时假装完成界面验收。
- 让 Sub Agent 并行写配置、更新/恢复订阅、抢同一界面或同时制造测试流量。
- 并发刷新覆盖、重复代理组、非幂等转换、无限等待和泄露敏感信息。

具体命令和 CI 流程见 `AGENTS.md`。
