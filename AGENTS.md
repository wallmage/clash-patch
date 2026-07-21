# Clash Patch 开发约定

## 项目边界

- 只支持 macOS 的 ClashX Meta 和 Windows 的 Clash Verge Rev；核心必须是受支持版本的 Mihomo。
- 绝不退出、停止或重启 Clash，也不擅自切换 TUN、订阅、代理组或节点。
- 修改必须兼顾安全、可恢复和隐私；不得在输出中泄露订阅地址、密码、UUID、私钥、控制器密钥或完整节点地址。
- 不加入 Apple、iCloud、Speedtest 等个人专用规则。
- 当前行为以 `README.md`、`clash-patch/SKILL.md`、`clash-patch/references/patch-policy.md`、代码和测试为准；`docs/` 中的旧方案只作背景参考。

## 开发与发布流程

始终在 `main` 上工作，不使用 worktree、功能分支或 PR。

### 1. 本地测试

提交前运行与改动相关的测试，并运行完整测试：

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

Windows PowerShell 5.1 的实际行为由 GitHub CI 的 Windows runner 验证。

### 2. 提交前检查上一次 CI

每次准备 commit 或 push 前，先读取 `main` 上一次 `Test` workflow 的结果：

- 失败：读取失败步骤的完整日志，确认问题并修复，与本次改动一起测试和提交。
- 仍在运行：记录状态即可，不等待；可以继续本次开发。
- 成功：继续提交。
- GitHub 或日志暂时无法访问：如实说明未检查，不把它说成已通过。

### 3. Commit 和 push

本地测试通过后，commit 并 push 到 `main`。GitHub Actions 会自动启动 macOS 和 Windows 测试。

### 4. CI 完全异步

push 后不等待、不轮询 CI，也不设置倒计时。下一次准备 commit 或 push 时，再按第 2 步检查上一次结果。用户也可以随时单独要求读取 CI 日志。

## 完成说明

说明实际运行过的本地测试、commit 和 push 状态。只有已经读取过的 CI 才能称为“CI 已通过”；尚未读取时写“CI 将异步检查”。
