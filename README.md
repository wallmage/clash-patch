# Clash 补丁

Clash 补丁是一套给 AI 助手使用的自动配置技能。它会检查电脑上的 Clash 订阅，并为所有有效订阅补上 DNS 防泄漏、DNS 分流、AI 专用分流和 WebRTC 防护。订阅刷新以后，补丁也会自动重新应用。

适合这些客户端：

- macOS：最新版 ClashX Meta
- Windows：最新版 Clash Verge Rev

如果检测到旧版或不兼容的客户端，技能不会冒险修改配置，而是建议升级。

## 有什么好处

- 减少 DNS 查询暴露本地运营商和真实位置的机会。
- 防止 WebRTC 的 STUN 流量绕开代理并显示真实公网 IP。
- 把 OpenAI、ChatGPT、Codex、Claude、Anthropic 和已收录的 AI 服务统一放进 AI 组。
- 有台湾家宽时优先选择台湾，其次选择日本家宽。
- 没有台湾或日本家宽时不乱选其他地区，只给出建议。
- 一次处理所有订阅，不需要逐个手改。
- 订阅更新后自动恢复补丁。

家宽节点使用住宅网络运营商的 IP，通常比机房节点更少触发代理或异常流量检查。台湾使用 UTC+8，日本只快一小时，而且两地距离较近，通常延迟更低。这不代表家宽节点一定可用，也不代表它绝对匿名。

## 工作方式

### macOS

安装程序会放置一个很小的 Ruby 配置补丁程序，并注册一个用户级 LaunchAgent。

LaunchAgent 使用 `RunAtLoad` 和订阅目录的 `WatchPaths`：

1. 登录时运行一次。
2. 检查全部订阅。
3. 补上缺少的设置。
4. 处理完成后退出。
5. 订阅目录以后发生变化时，系统再启动它一次。

它不是 24 小时常驻进程，也不会不停轮询。十天没有订阅更新，它就十天不运行；下一次刷新订阅时才会再次启动。

### Windows

Clash Verge Rev 原生支持全局扩展脚本。安装程序把 Clash 补丁写入 `profiles/Script.js`，并打开所需的 TUN 应用设置。

每次 Clash Verge Rev 加载或刷新任何订阅，都会自动运行全局扩展脚本。因此 Windows 不需要计划任务，也不需要额外后台服务。

如果已经有全局扩展脚本，安装程序会先备份，再尝试组合：原脚本先运行，Clash 补丁后运行。无法安全组合时保持原文件不变，并要求用户提供截图。

## 会修改什么

- 关闭代理配置中的 IPv6，避免未代理的 IPv6 路径。
- 打开 TUN、DNS 劫持、自动路由和严格路由。
- 使用经过代理的 DoH 处理普通查询和 AI 查询。
- 创建或复用 AI 选择组。
- 加入完整的 OpenAI、Codex、Claude、Anthropic 和相关 AI 规则。
- 删除两条过于宽泛的 AI 规则：`raw.githubusercontent.com` 和 `storage.googleapis.com`。
- 把未被前面窄范围规则处理的 UDP 交给主代理组，防止 WebRTC 绕过代理。
- 保护已有的 REALITY `short-id` 文本格式。

它不会加入个人专用的网站规则，也不会上传订阅内容。

## 安装给 Codex

克隆仓库：

```bash
git clone https://github.com/wallmage/clash-patch.git
```

把仓库中的 `clash-patch` 文件夹复制到：

```text
~/.codex/skills/clash-patch
```

重新打开 Codex，然后说：

```text
请使用 $clash-patch 检查并增强我电脑上的所有 Clash 订阅。
```

Codex 会识别系统和客户端、安装对应机制，并在有 Computer Use 时自动完成浏览器测试。

## 安装给其他 AI 工具

把 `clash-patch` 文件夹交给支持技能或本地文件操作的 AI 工具，让它完整读取 `SKILL.md`，然后说：

```text
请按照 Clash 补丁技能处理这台电脑上的所有 Clash 订阅。
```

其他工具如果没有 Computer Use，会提示用户手动打开测试网页。看到红色结果时，截图发回同一个对话继续处理。

## 手动运行安装程序

通常让 AI 助手执行最省事。需要手动运行时：

macOS：

```bash
bash clash-patch/scripts/install_macos.sh
```

Windows PowerShell：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\clash-patch\scripts\install_windows.ps1
```

运行前请关闭敏感信息共享。不要把订阅文件、订阅链接或节点密码发到公开聊天。

## 验证

依次测试：

1. [IPInfo WebRTC 检测](https://ipinfo.cv/webrtc-check)
2. [DNS 泄漏检测](https://ip.net.coffee/dns/)：点击右侧“深度测试”
3. [IP Coffee WebRTC 检测](https://ip.net.coffee/webrtc/)

三项都没有红色泄漏提示，而且没有显示未代理的公网 IP、私网地址或本地运营商 DNS，才算验证通过。

WebRTC 页面出现多个地址不一定是泄漏：如果它们都是代理出口，就没有暴露真实 IP。单一且一致的出口会更容易判断。

## 隐私和安全

- 所有修改都在本机完成。
- 不上传 Clash 配置或订阅。
- 输出不会包含订阅地址、密码、UUID、私钥、控制器密钥或完整节点地址。
- 首次修改前保留一份本地备份。
- 无效订阅、HTML 错误页和 `401 unauthorized` 会被跳过，等待下一次有效刷新。

## 已知限制

- Windows 安装程序需要 Clash Verge Rev 的当前配置结构。
- 自定义 Windows 全局脚本如果有多个入口函数，自动组合会停止，避免破坏原脚本。
- 代理节点不支持 UDP 时，WebRTC 可能无法使用，但不应退回真实公网 IP。
- 订阅没有台湾或日本家宽时，技能不会自动选择其他国家的家宽。

出现问题时，把错误提示和三项测试截图发回给 AI 助手，不要发送整份订阅配置。
