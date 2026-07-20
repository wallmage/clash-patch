# Clash Patch

这是一个给 AI 助手使用的 Clash 配置补丁。把它交给 Codex 或其他能读取本地文件、执行命令的工具，它会找到电脑上的 Clash 订阅，并给所有有效订阅补上 DNS 防泄漏、DNS 分流、AI 分流和 WebRTC 防护。以后订阅刷新，补丁也会自动重新应用，不用每次手改。

目前支持：

- macOS：ClashX Meta
- Windows：Clash Verge Rev

建议先升级到最新版。检测到旧版 ClashX、旧版 Clash Verge 或不兼容的客户端时，补丁只会给出升级建议，不会直接修改配置。
补丁要求 Mihomo 1.19.27 或更高版本；无法确认版本时会停止安装，不会跳过校验。

## 它会做什么

- 创建一个由补丁管理的安全代理组，让普通查询和 AI 域名查询通过确认过的代理出口，减少本地运营商 DNS 暴露；代理服务器域名则使用独立的加密启动解析。
- 打开 TUN、DNS 劫持、自动路由和严格路由，并关闭配置中的 IPv6。
- 把所有 UDP 先交给安全代理组；如果代理不支持 UDP，下一条规则立即拒绝，不会继续掉到 `DIRECT`。这会同时影响 WebRTC、在线游戏、语音和视频通话、QUIC，而不只是 STUN。
- 创建补丁专用的 AI 选择组，把 OpenAI、ChatGPT、Codex、Claude、Anthropic 和已收录的 Google AI 服务放进这个组，不改订阅自带的 AI 组。
- 不再让补丁自己的 AI 组接管 `raw.githubusercontent.com` 和 `storage.googleapis.com`；用户自己写给其他代理组的规则保持不变。
- macOS 安装时处理全部订阅；Windows 在每份订阅加载或刷新时应用同一套规则。

补丁不会加入面向个人网站、Apple、iCloud 或测速服务的专用分流规则，也不会上传订阅内容。验证时打开的第三方测试页面会收到浏览器发出的公网 IP、WebRTC 和 DNS 测试请求；这些请求受对应网站的隐私政策约束。

如果订阅里有台湾家宽，补丁专用 AI 组只放这个节点；没有台湾家宽时再找日本家宽。单成员选择组不会被 Clash 以前记住的旧选择带偏。两者都没有时，AI 组只跟随原来的主代理组，补丁不会擅自换成其他地区，只会提醒你。

家宽节点使用住宅网络运营商的 IP，通常比机房节点更少触发代理或异常流量检查。台湾是 UTC+8，日本只快一小时，两地也比较近，延迟通常更低。不过，家宽不等于一定可用，更不代表绝对匿名。

## 安装

### Codex

先克隆仓库：

```bash
git clone https://github.com/wallmage/clash-patch.git
```

把仓库里的 `clash-patch` 文件夹复制到：

```text
~/.codex/skills/clash-patch
```

重新打开 Codex，然后说：

```text
请使用 $clash-patch 检查并增强我电脑上的所有 Clash 订阅。
```

Codex 会识别操作系统和客户端、安装对应的补丁，并在 Computer Use 可用时自动完成浏览器测试。

### 其他 AI 工具

把 `clash-patch` 文件夹交给支持技能或本地文件操作的 AI 工具，让它完整读取 `SKILL.md`，然后说：

```text
请按照 Clash 补丁技能处理这台电脑上的所有 Clash 订阅。
```

没有 Computer Use 的工具无法替你操作浏览器，会让你手动打开测试网页。只要出现红色结果，截屏发回同一个对话，让它继续检查。

### 手动安装

通常交给 AI 助手执行最省事。如果想自己运行：

macOS：

```bash
bash clash-patch/scripts/install_macos.sh
```

Windows PowerShell：

```powershell
.\clash-patch\scripts\install_windows.cmd
```

Windows 安装和卸载前，请先从托盘菜单完全退出 Clash Verge Rev。`.cmd` 入口会为这一次运行启用脚本；不会改系统的执行策略。

不要把订阅文件、订阅链接或节点密码发到公开聊天。

## 订阅刷新后为什么不会失效

### macOS

安装程序会放置一个很小的 Ruby 补丁程序，并注册用户级 LaunchAgent。它使用 `RunAtLoad` 和订阅目录的 `WatchPaths`：

1. 登录时运行一次，检查全部订阅。
2. 同时检查本地和 ClashX Meta 的 iCloud 订阅目录；只处理顶层的 `.yaml`、`.yml`，包括默认的 `config.yaml`。
3. 用 YAML 1.2 规则读取订阅，避免把 `yes`、`on`、`0123`、日期等文本改成别的类型；写入前再让已安装的 Mihomo 内核检查候选配置。
4. 补上缺少的设置，处理完就退出。订阅目录再次变化时，由系统重新启动一次。

Ruby 不会常驻，也不会定时轮询。如果十天没有更新订阅，它就十天不运行；下一次刷新时才会再次启动。安装器会把补丁程序、策略、状态文件和 LaunchAgent 作为一个事务更新；加载新 LaunchAgent 失败时，恢复原文件和原服务。安装时会通过 ClashX Meta 的运行内核读取真实 TUN 状态：只有内核明确返回“关闭”时才调用客户端的 AppleScript 切换命令，并在之后再次查询确认；无法读取状态时绝不盲目切换，以免把已经开启的 TUN 关掉。客户端未运行或状态未知时，只保存 ClashX Meta 支持的“下次开启”设置，并如实提示用户确认。

### Windows

Clash Verge Rev 每次加载或刷新订阅，都会运行 `profiles/Script.js`。安装程序会把补丁加入这个全局扩展脚本，并打开所需的 TUN 设置。因此 Windows 不需要计划任务，也没有额外的后台服务。

安装程序会按 YAML 的映射层级修改 `config.yaml`，能正确处理 `tun: null`、带空格的键、行尾注释和块状 `dns-hijack`；遇到无法安全合并的锚点或多文档 YAML 会停止。所有目标文件先生成，`config.yaml` 再由 Mihomo 检查；中途任何一步失败，会按原始字节恢复本次已经写过的文件。Windows 备份只允许当前用户、SYSTEM 和 Administrators 访问。

如果原本已有全局扩展脚本，安装程序会先备份，再尝试组合：先运行原脚本，再运行 Clash Patch。无法安全组合时，它会保留原文件，并请你提供报错信息或截图。

## 移除自动补丁

移除操作不会删除备份，也不会改回已经写进 macOS 订阅的规则。macOS 会在状态文件明确记录了原值时恢复 TUN 启动偏好；从无状态旧版升级时无法推断更早的原值，因此保留当前值并说明原因。Windows 会在文件仍是安装程序最后写入的版本时，恢复原来的 `config.yaml` 与 `verge.yaml`。如果这些文件后来被其他程序修改，卸载程序会保留它们并明确提示，不会覆盖新改动。

macOS：

```bash
bash clash-patch/scripts/uninstall_macos.sh
```

Windows PowerShell：

```powershell
.\clash-patch\scripts\uninstall_windows.cmd
```

Windows 如果原来已有 `Script.js`，卸载程序只在标记完整且能确认原入口时恢复它；遇到不确定的内容就停止，不会猜。

## 验证是否生效

依次完成下面三项测试：

1. [IPInfo WebRTC 检测](https://ipinfo.cv/webrtc-check)
2. [DNS 泄漏检测](https://ip.net.coffee/dns/)：点击右侧“深度测试”
3. [IP Coffee WebRTC 检测](https://ip.net.coffee/webrtc/)

三项都没有红色泄漏提示，也没有显示未代理的公网 IP、私网地址或本地运营商 DNS，才算通过。

这些第三方页面需要接收你的公网 IP，并会主动发起 WebRTC 或 DNS 查询，才能完成检测。Clash Patch 不会向它们上传订阅、节点密码或配置文件；是否使用这些页面，由你决定。

WebRTC 页面出现多个地址不一定是泄漏。只要它们都是代理出口，就没有暴露真实 IP；单一且一致的出口只是更容易判断。

## 隐私和备份

- 所有修改都在本机完成，不会上传 Clash 配置或订阅；第三方泄漏测试仍会收到完成检测所需的 IP 与 DNS 请求。
- 输出不会包含订阅地址、密码、UUID、私钥、控制器密钥或完整节点地址。
- 首次修改前会保存一份本地备份。
- 无效订阅、HTML 错误页和 `401 unauthorized` 会被跳过，等下次刷新出有效内容再处理。
- 读取失败、写入失败、YAML 无效和 Mihomo 检查失败会分别报告，不会都说成“订阅无效”。
- macOS 补丁会保护已有的 REALITY `short-id` 文本，不会猜测、补齐或改写；Windows 脚本不处理这个字段。
- 仓库包含 Ruby、Node 和 PowerShell 回归测试；GitHub Actions 会在 Linux、macOS 系统 Ruby 2.6 和 Windows PowerShell 5.1 上自动运行。

## 已知限制

- Windows 安装程序依赖 Clash Verge Rev 当前使用的配置目录和全局扩展机制。
- 如果已有 Windows 全局脚本包含多个入口函数，自动组合会停止，以免破坏原脚本。
- Clash Verge Rev 当前不会等待异步入口的 Promise，因此安装程序拒绝已有的 `async function main`。
- 代理节点不支持 UDP 时，补丁会拒绝所有 UDP，而不是退回真实公网 IP；WebRTC、游戏、语音或视频通话、QUIC 都可能无法使用或改走 TCP。
- 没有台湾或日本家宽时，补丁不会自动选择其他国家或地区的家宽。
- 订阅引用远程 `proxy-providers` 时，Mihomo 的写入前检查可能需要网络；离线检查失败会保留原文件，可联网后重试。

项目使用 [MIT License](LICENSE)，可以复制、修改和分享，但软件按原样提供，不承诺适合所有订阅或网络环境。

遇到问题，把报错和三项测试的截图发给 AI 助手即可。不要发送整份订阅配置。
