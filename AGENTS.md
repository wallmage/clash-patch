# Clash Patch 开发约定

## 执行

- 需求明确且在已有授权范围内时，直接执行、验证并报告结果。不要为计划、方案或实现细节再次请求确认。
- 始终在 `main` 上工作，不使用 worktree、功能分支或 PR。
- 实际修改项目后，除非用户明确要求不要提交，否则自动完成本地测试、commit 和 push，让 GitHub CI 自动运行。不得把“尚未 commit 或 push”作为常规收尾。
- 文档位置固定。不得自行新增需求汇总、入口、方案或计划文档：`README.md` 面向用户，`clash-patch/SKILL.md` 规定代理流程，`clash-patch/references/patch-policy.md` 保存详细产品规则，`docs/superpowers/specs/2026-07-20-clash-patch-skill-design.md` 保存产品需求与架构。
- 功能需求变化时，代码、Skill 和相关产品文档必须在同一次改动中同步更新。

## 项目边界

- 只支持 macOS 的 ClashX Meta 和 Windows 的 Clash Verge Rev；要求受支持版本的 Mihomo。
- 绝不退出、停止或重启 Clash，也不擅自切换 TUN、订阅、代理组或节点。
- 不泄露订阅地址、密码、UUID、私钥、控制器密钥或完整节点地址。
- 不加入 Apple、iCloud、Speedtest 等个人规则。
- 文档、代码和测试必须描述同一套现行行为，不保留已经取消的方案。

## 测试与发布

提交前运行：

```sh
ruby tests/test_macos_patcher.rb
ruby tests/test_skill_contract.rb
node --test tests/test_windows_patcher.js
ruby tests/generate_windows_policy.rb --check
ruby -c clash-patch/scripts/macos/patch_profiles.rb
node --check clash-patch/scripts/windows/clash_verge_global.js
sh -n clash-patch/scripts/install_macos.sh
sh -n clash-patch/scripts/uninstall_macos.sh
git diff --check
```

Windows PowerShell 5.1 的行为由 GitHub CI 验证。

每次 commit 或 push 前读取 `main` 上一次 `Test` workflow：失败则查看日志并修复；仍在运行或暂时无法访问时如实记录，不等待。随后自动在 `main` 上 commit、push，由 GitHub 启动 CI。push 后不轮询 CI，下次提交前再检查。

完成说明只报告实际运行过的测试和 Git 状态。未读取的 CI 不能称为已经通过。
