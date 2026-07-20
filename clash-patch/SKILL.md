---
name: clash-patch
description: Use when an agent needs to inspect, repair, or persist DNS, WebRTC, and AI routing settings for ClashX Meta or Clash Verge Rev subscriptions on macOS or Windows.
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

客户端必须使用 Mihomo 1.19.27 或更高版本；找不到内核、版本过旧或无法确认版本时停止，不修改配置。

4. macOS 安装程序必须处理所有订阅，而不是只处理当前订阅，并同时检查本地与 ClashX Meta 的 iCloud 目录。Windows 由全局脚本在每份订阅加载或刷新时处理，安装当下不应声称所有订阅已经处理。
5. 检查安装结果和持久化机制。macOS 必须确认 LaunchAgent 已加载，并从运行内核读取 TUN 状态；只有明确读到关闭时才能调用 AppleScript 切换，状态未知时不得切换。无法确认开启就写成“等待用户开启”。Windows 必须确认全局扩展脚本已安装。
6. 只有当前配置重新加载成功，而且 macOS 已通过控制器确认 AI 节点选择时，才能说相应设置已经生效。否则如实写成等待重新加载。
7. 当前配置生效后再做浏览器验证。

## 执行命令

在 macOS 上，从技能目录运行：

```bash
bash scripts/install_macos.sh
```

在 Windows PowerShell 中，从技能目录运行：

```powershell
.\scripts\install_windows.cmd
```

运行 Windows 安装或卸载程序前，先确认 Clash Verge Rev 已从托盘完全退出。

修改用户目录需要工具授权时，先用中文说明用途，再请求授权。不要绕过操作系统权限。

## AI 节点通知

补丁使用自己管理的 AI 选择组，不修改订阅原有的同名组。如果订阅含有台湾家宽节点，AI 组只放这个节点；否则只放日本家宽。只有当前配置已重新加载，且 macOS 已通过控制器切换并回读成功时，才能发送下面这条“已切换”通知：

> 已将 OpenAI、ChatGPT、Codex、Claude 和 Anthropic 流量切换到「{节点名称}」。家宽节点使用住宅网络运营商的 IP，通常比机房节点更少触发代理或异常流量检查。台湾使用 UTC+8，日本只快一小时，而且两地距离较近，通常延迟更低。

如果文件已经修改但当前配置尚未重新加载，改为说明：“重新加载或选择该订阅后，AI 流量将使用「{节点名称}」”，不得提前说已经切换。

如果台湾和日本家宽都没有，不得选择其他地区的家宽，也不得替用户更换当前节点。通知用户：

> 当前订阅没有台湾或日本家宽节点，Clash 补丁没有替你更换节点。建议选择提供台湾或日本家宽的订阅：两地距离近，台湾时区相同，日本只差一小时，通常更适合稳定使用 AI 服务。

不要承诺家宽节点一定可用、永不风控或绝对匿名。

## 安全出口

补丁会另外创建一个不含 `DIRECT`、`REJECT`、`PASS`、`COMPATIBLE`、`REMATCH` 或同类出口的安全代理组。DNS 只使用带这个组标签的加密解析器。通用 UDP 先交给安全代理组，紧接一条 `NETWORK,UDP,REJECT`；代理不支持 UDP 时必须停止，不能继续匹配后面的直连规则。

## 移除持久化

用户只想关闭自动补丁时运行：

```bash
bash scripts/uninstall_macos.sh
```

或：

```powershell
.\scripts\uninstall_windows.cmd
```

卸载不删除备份。macOS 会恢复安装前的 TUN 启动偏好，但不改回订阅内容；Windows 只在 `config.yaml` 与 `verge.yaml` 没有安装后新改动时恢复原始字节，检测到新改动就保留文件并提示。

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
- `已更新，选择该订阅时生效`
- `未修改：找不到可用的主代理组`
- `已跳过：订阅内容无效`
- `已跳过：内核校验失败`
- `已跳过：读取或写入失败`
- `已跳过：处理失败`
- `未修改：客户端不受支持`
- `未验证：需要手动测试`

同时说明补丁专用 AI 组、安全代理组、主代理组、家宽选择、TUN、持久化状态、三项测试结果和下一步。不要修改或添加个人化的 Apple、iCloud 或测速网站规则。
