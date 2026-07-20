---
name: clash-patch
description: Use when an agent needs to inspect, repair, or persist DNS、WebRTC、AI 分流设置 for ClashX Meta or Clash Verge Rev subscriptions on macOS or Windows.
---

# Clash 补丁

## 原则

先只读检查，再修改所有有效订阅。所有对用户说的话必须使用简体中文。不得显示订阅地址、密码、UUID、私钥、控制器密钥或完整节点地址。

开始前完整阅读 [references/patch-policy.md](references/patch-policy.md)。

## 操作流程

1. 告诉用户正在检查操作系统、Clash 客户端和全部订阅。
2. 只读识别操作系统、客户端、配置目录、订阅文件和当前配置。不要默认第一个文件就是当前订阅。
3. 按下表判断是否支持。

| 环境 | 处理方式 |
| --- | --- |
| macOS + ClashX Meta | 运行 `scripts/install_macos.sh` |
| Windows + Clash Verge Rev | 运行 `scripts/install_windows.ps1` |
| macOS 旧版 ClashX | 不修改；建议安装最新版 ClashX Meta |
| Windows 旧版或其他客户端 | 不修改；建议安装最新版 Clash Verge Rev |

4. 安装程序必须处理所有订阅，而不是只处理当前订阅。
5. 检查安装结果和持久化机制。macOS 必须确认 LaunchAgent 已加载；Windows 必须确认全局扩展脚本已安装。
6. 如果当前配置已经重新加载，再做浏览器验证；没有重新加载时，先重新加载订阅或重启内核。

## 执行命令

在 macOS 上，从技能目录运行：

```bash
bash scripts/install_macos.sh
```

在 Windows PowerShell 中，从技能目录运行：

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\scripts\install_windows.ps1
```

修改用户目录需要工具授权时，先用中文说明用途，再请求授权。不要绕过操作系统权限。

## AI 节点通知

如果订阅含有台湾家宽节点，优先把它放在 AI 组第一位；否则选择日本家宽。通知用户：

> 已将 OpenAI、ChatGPT、Codex、Claude 和 Anthropic 流量切换到「{节点名称}」。家宽节点使用住宅网络运营商的 IP，通常比机房节点更少触发代理或异常流量检查。台湾使用 UTC+8，日本只快一小时，而且两地距离较近，通常延迟更低。

如果台湾和日本家宽都没有，不得选择其他地区的家宽，也不得替用户更换当前节点。通知用户：

> 当前订阅没有台湾或日本家宽节点，Clash 补丁没有替你更换节点。建议选择提供台湾或日本家宽的订阅：两地距离近，台湾时区相同，日本只差一小时，通常更适合稳定使用 AI 服务。

不要承诺家宽节点一定可用、永不风控或绝对匿名。

## 自动验证

如果当前环境有 Computer Use，必须实际打开并完成三项测试：

1. `https://ipinfo.cv/webrtc-check`
2. `https://ip.net.coffee/dns/`，点击右侧“深度测试”
3. `https://ip.net.coffee/webrtc/`

只有三项都没有红色泄漏提示，而且没有出现用户未代理的公网 IP、私网地址或本地运营商 DNS，才能说验证通过。多个地址如果全部是代理出口，不算真实 IP 泄漏；单一且一致的代理出口更清楚。

发现红色结果时继续检查，不要宣布完成。必要时请用户发送截图。

## 手动验证

没有 Computer Use 时，发送以下中文提示，并把状态写成“未验证”：

> 自动补丁已经完成，但当前工具不能替你操作浏览器。请依次测试：
> 1. 打开 https://ipinfo.cv/webrtc-check
> 2. 打开 https://ip.net.coffee/dns/，点击右侧“深度测试”
> 3. 打开 https://ip.net.coffee/webrtc/
> 如果三项都是绿色，而且没有显示你的真实公网 IP，就说明补丁已生效。只要有红色提示，请截图发回来，我会继续帮你处理。

## 最终状态

逐一列出发现的订阅，并使用以下状态之一：

- `已更新并生效`
- `无需修改`
- `已更新，等待重新加载`
- `已跳过：订阅内容无效`
- `未修改：客户端不受支持`
- `未验证：需要手动测试`

同时说明 AI 组、主代理组、家宽选择、持久化状态、三项测试结果和下一步。不要修改或添加个人化的 Apple、iCloud 或测速网站规则。
