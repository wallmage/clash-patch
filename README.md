# Clash Patch

Clash Patch 是给 AI 助手使用的 Clash 配置补丁，支持 macOS 的 ClashX Meta 和 Windows 的 Clash Verge Rev。它增强当前存储位置中的订阅，不处理废弃目录或另一套未启用的存储。

## 安全原则

**绝对不要退出、停止或重启 Clash 客户端。** 中国用户通常依靠 Clash 连接 Codex；客户端退出后，修复可能中断。

补丁不会重新加载当前配置，不切换 TUN、订阅、代理组或节点，也不加入 Apple、iCloud、Speedtest 等个人规则。

## 补丁内容

- 打开配置中的 TUN、DNS 劫持、自动路由和严格路由，关闭配置中的 IPv6。
- 使用通过原主代理组访问的 IP DoH，避免解析器域名错误或节点拒绝 Google、Cloudflare DNS。
- 保留节点启动解析；缺失或仍是旧版危险固定值时才改用系统 DNS。
- 已有 AI 分组时保留成员和选择，只补全 OpenAI、ChatGPT、Codex、Claude、Anthropic、Gemini 等规则；没有时才创建跟随主代理组的 AI 分组。
- 不创建额外的安全代理分组，不替用户选择节点。家宽通常更适合 AI；有台湾家宽时优先台湾，没有时可考虑日本。
- 通用 UDP 先交给原主代理组，失败后立即拒绝，减少 WebRTC 直连风险。
- macOS 会保护已有且有效的 REALITY `short-id` 文本；Windows 脚本不处理该字段。

UDP 规则也会影响游戏、语音、视频通话和 QUIC。代理不支持 UDP 时，这些功能可能失败或改走 TCP。

## 安装

```bash
git clone https://github.com/wallmage/clash-patch.git
```

把仓库中的 `clash-patch` 文件夹复制到 `~/.codex/skills/clash-patch`，然后告诉 Codex：

```text
请使用 $clash-patch 检查并增强 Clash 当前存储位置中的订阅。不要退出、停止或重启 Clash。
```

也可以手动运行：

```bash
bash clash-patch/scripts/install_macos.sh
```

```powershell
.\clash-patch\scripts\install_windows.cmd
```

两个平台都必须让 Clash 保持运行。

## 平台机制

### macOS

安装程序单次运行，只处理 ClashX Meta 当前使用的本地目录或 iCloud 容器。每份顶层 YAML 都经过 YAML 1.2 读取、二次转换和 Mihomo 校验，最长等待 30 秒。修改前创建一次性备份，写完后不重新加载配置。

macOS 不安装 LaunchAgent 或 `WatchPaths`。安装程序会删除能确认属于旧版 Clash Patch 的目录监听。订阅以后刷新时，需要再次运行 skill。

### Windows

Clash Verge Rev 的全局扩展脚本 `profiles/Script.js` 会在订阅加载或刷新时应用补丁，不需要计划任务或后台服务。

客户端运行时只更新全局脚本；客户端原本没有运行时，安装程序才事务式更新应用级 TUN 设置。脚本不会结束 Clash 进程。

## 验证

用户主动刷新或选择订阅后测试：

1. [IPInfo WebRTC 检测](https://ipinfo.cv/webrtc-check)
2. [DNS 泄漏检测](https://ip.net.coffee/dns/)：点击“深度测试”
3. [IP Coffee WebRTC 检测](https://ip.net.coffee/webrtc/)

这些第三方页面会收到浏览器公网 IP。三项都没有红色提示，且没有未代理公网 IP、私网地址或本地运营商 DNS，才能说验证通过。

## 卸载与隐私

```bash
bash clash-patch/scripts/uninstall_macos.sh
```

```powershell
.\clash-patch\scripts\uninstall_windows.cmd
```

卸载不要求关闭客户端，也不会删除备份。输出不包含订阅地址、密码、UUID、私钥、控制器密钥或完整节点地址。遇到问题时只发送错误提示和测试截图，不要发送整份订阅。

项目使用 [MIT License](LICENSE)。
