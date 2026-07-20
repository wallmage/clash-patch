# Clash Patch

这是一个给 AI 助手使用的 Clash 配置补丁。把它交给 Codex 或其他能读取本地文件、执行命令的工具，它会找到电脑上的 Clash 订阅，并给所有有效订阅补上 DNS 防泄漏、DNS 分流、AI 分流和 WebRTC 防护。以后订阅刷新，补丁也会自动重新应用，不用每次手改。

目前支持：

- macOS：ClashX Meta
- Windows：Clash Verge Rev

建议先升级到最新版。检测到旧版 ClashX、旧版 Clash Verge 或不兼容的客户端时，补丁只会给出升级建议，不会直接修改配置。

## 它会做什么

- 让普通 DNS 查询和 AI 域名查询走带代理标签的 DoH，减少本地运营商 DNS 暴露。
- 打开 TUN、DNS 劫持、自动路由和严格路由，并关闭配置中的 IPv6。
- 拦住可能绕过代理的 WebRTC/STUN UDP 流量，避免网页看到真实公网 IP。
- 创建或复用 AI 选择组，把 OpenAI、ChatGPT、Codex、Claude、Anthropic 和已收录的 AI 服务放进这个组。
- 删除两条不该由 AI 组接管的宽泛规则：`raw.githubusercontent.com` 和 `storage.googleapis.com`。
- 一次处理全部订阅，订阅更新后自动补回这些设置。

如果订阅里有台湾家宽，AI 组会优先选它；没有台湾家宽时再找日本家宽。两者都没有，补丁不会擅自换成其他地区，只会提醒你。

家宽节点使用住宅网络运营商的 IP，通常比机房节点更少触发代理或异常流量检查。台湾是 UTC+8，日本只快一小时，两地也比较近，延迟通常更低。不过，家宽不等于一定可用，更不代表绝对匿名。

补丁不会加入个人专用的 Apple、iCloud 或测速网站规则，也不会上传订阅内容。

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
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\clash-patch\scripts\install_windows.ps1
```

不要把订阅文件、订阅链接或节点密码发到公开聊天。

## 订阅刷新后为什么不会失效

### macOS

安装程序会放置一个很小的 Ruby 补丁程序，并注册用户级 LaunchAgent。它使用 `RunAtLoad` 和订阅目录的 `WatchPaths`：

1. 登录时运行一次，检查全部订阅。
2. 补上缺少的设置，处理完就退出。
3. 订阅目录再次变化时，由系统重新启动一次。

Ruby 不会常驻，也不会定时轮询。如果十天没有更新订阅，它就十天不运行；下一次刷新时才会再次启动。

### Windows

Clash Verge Rev 每次加载或刷新订阅，都会运行 `profiles/Script.js`。安装程序会把补丁加入这个全局扩展脚本，并打开所需的 TUN 设置。因此 Windows 不需要计划任务，也没有额外的后台服务。

如果原本已有全局扩展脚本，安装程序会先备份，再尝试组合：先运行原脚本，再运行 Clash Patch。无法安全组合时，它会保留原文件，并请你提供报错信息或截图。

## 验证是否生效

依次完成下面三项测试：

1. [IPInfo WebRTC 检测](https://ipinfo.cv/webrtc-check)
2. [DNS 泄漏检测](https://ip.net.coffee/dns/)：点击右侧“深度测试”
3. [IP Coffee WebRTC 检测](https://ip.net.coffee/webrtc/)

三项都没有红色泄漏提示，也没有显示未代理的公网 IP、私网地址或本地运营商 DNS，才算通过。

WebRTC 页面出现多个地址不一定是泄漏。只要它们都是代理出口，就没有暴露真实 IP；单一且一致的出口只是更容易判断。

## 隐私和备份

- 所有修改都在本机完成，不会上传 Clash 配置或订阅。
- 输出不会包含订阅地址、密码、UUID、私钥、控制器密钥或完整节点地址。
- 首次修改前会保存一份本地备份。
- 无效订阅、HTML 错误页和 `401 unauthorized` 会被跳过，等下次刷新出有效内容再处理。
- 已有的 REALITY `short-id` 只做格式保护，不会猜测、补齐或改写。

## 已知限制

- Windows 安装程序依赖 Clash Verge Rev 当前使用的配置结构。
- 如果已有 Windows 全局脚本包含多个入口函数，自动组合会停止，以免破坏原脚本。
- 代理节点不支持 UDP 时，WebRTC 可能无法使用，但不应该退回真实公网 IP。
- 没有台湾或日本家宽时，补丁不会自动选择其他国家或地区的家宽。

遇到问题，把报错和三项测试的截图发给 AI 助手即可。不要发送整份订阅配置。
