# Clash Patch

这是一个给 AI 助手使用的 Clash 配置补丁，支持 macOS 的 ClashX Meta 和 Windows 的 Clash Verge Rev。它为当前订阅添加 DNS、TUN、AI 分流和 WebRTC 防护，并把安全放在自动化之前。

## 最重要的安全规则

**绝对不要退出、停止或重启 Clash 客户端。** 中国用户通常依靠 Clash 连接 Codex。客户端一旦退出，AI 助手会断线，修复也可能停在一半。

新版还增加了以下保护：

- 只处理 Clash 当前存储位置中的订阅；读不到本地/iCloud 状态时停止，不猜，也不扫描未启用的本地目录、旧 iCloud 容器、备份或废弃订阅。
- 保留原有的 `default-nameserver`、`proxy-server-nameserver` 和 `direct-nameserver`；节点启动解析缺失或仍是旧版危险固定值时改用系统 DNS，不再强制直连 `1.1.1.1` 或 `8.8.8.8`。
- macOS 只单次运行，不安装 LaunchAgent，也不使用 `WatchPaths`。补丁写入不会再次触发自己。
- 每份候选先重读 YAML，再做二次转换；两次结果不同就拒绝写入，避免代理组重复增殖。
- Mihomo 版本检查和候选校验最多等待 30 秒。超时后终止校验子进程，保留原订阅并继续下一份。
- 不自动重新加载当前配置，不切换 TUN，不替用户切换当前节点。
- Windows 客户端运行时只更新全局扩展脚本，不改 `config.yaml`、`verge.yaml` 或当前运行配置。

## 补丁内容

- 已有 AI 分组时保留分组和节点原样，只补全 OpenAI、ChatGPT、Codex、Claude、Anthropic、Gemini 等服务的域名与 IP 规则。
- 没有 AI 分组时才创建 `🤖 AI · Clash Patch`，并让它跟随原主代理组，不替用户选择节点。
- 不创建额外的安全代理分组；旧版已经创建的安全分组会在升级时删除。
- 把通用 UDP 先交给原主代理组，下一条规则立即拒绝失败流量。
- 打开配置中的 TUN、DNS 劫持、自动路由和严格路由，并关闭配置中的 IPv6。
- 保留用户自己编写的规则、规则目标和同名代理组。
- macOS 保护已有的 REALITY `short-id` 文本；Windows 脚本不处理这个字段。

通用 UDP 防护会影响 WebRTC、在线游戏、语音、视频通话和 QUIC。代理不支持 UDP 时，这些功能可能失败或改走 TCP。

补丁不会替用户选择 AI 节点。通常建议自行选择家宽；有台湾家宽时优先台湾，没有台湾时可以考虑日本。

## 安装 skill

```bash
git clone https://github.com/wallmage/clash-patch.git
```

把仓库中的 `clash-patch` 文件夹复制到：

```text
~/.codex/skills/clash-patch
```

然后对 Codex 说：

```text
请使用 $clash-patch 检查并增强 Clash 当前存储位置中的订阅。不要退出、停止或重启 Clash。
```

## 手动运行

macOS：

```bash
bash clash-patch/scripts/install_macos.sh
```

Windows：

```powershell
.\clash-patch\scripts\install_windows.cmd
```

两个平台都允许 Clash 保持运行。`.cmd` 只为本次命令启用 PowerShell 脚本，不修改系统执行策略。

## 平台行为

### macOS

安装程序执行一次，只读取 ClashX Meta 当前使用的存储位置：

- 本地模式只看 `~/.config/clash.meta`；
- iCloud 模式只选当前容器；
- 每份顶层 `.yaml` 或 `.yml` 都经过 YAML 1.2 读取、二次转换和 Mihomo 校验；
- 修改前创建一次性备份；
- 写完后不重新加载当前配置。

安装程序会识别并移除本工具旧版的 `com.clashpatch.profiles` 和 `com.wallny.clash-profile-patcher` 目录监听。它会同时核对 `Label` 和程序参数，不碰无法确认所有权的 LaunchAgent。以后订阅刷新后，需要再次运行本 skill。

### Windows

Clash Verge Rev 每次加载或刷新订阅都会运行 `profiles/Script.js`。安装程序把补丁组合到这个全局扩展脚本中，不创建计划任务或后台服务。

客户端运行时，安装程序只写全局脚本，不碰应用设置或当前运行配置。客户端原本没有运行时，安装程序可以事务式更新 TUN 设置；候选先由 Mihomo 校验，失败后按原始字节恢复。无论哪种情况，脚本都不会结束 Clash 进程。

已有全局脚本会先备份再组合。入口结构不明确、包含异步 `main`、保留标识符冲突或递归入口时，安装程序保持原文件不变。

## DNS 为什么这样处理

有些节点会拒绝 Google 或 Cloudflare 的加密 DNS；解析器写成 `dns.google` 这类域名时，还可能在启动阶段拿到错误地址，最后表现为很多新网站一起 `SERVFAIL`。这不是给某个网站补一条规则能解决的。

Clash Patch 改用三个直接连接 IP 的 DoH 地址：AdGuard 的非过滤服务 `94.140.14.140`、`94.140.14.141`，以及 TWNIC Quad 101 的 `101.101.101.101`。它们仍然通过原主代理组访问。已有 `nameserver-policy` 的分流目标会保留，但解析器地址会换成这组受管地址。补丁不会顺便替用户拦广告。

节点域名的启动解析不跟着改。`proxy-server-nameserver`、`default-nameserver` 和 `direct-nameserver` 优先保留订阅原值；只有字段缺失，或仍是旧版补丁写入的固定境外组合时，才迁移到 `system`。这样普通 DNS 不依赖解析器域名，代理节点也不会陷入“要先连上代理，才能解析代理地址”的循环。

如果换一个节点后原 DNS 立刻恢复，问题通常在节点本身，补丁不会把这种情况误判成解析器故障。

## 卸载

macOS：

```bash
bash clash-patch/scripts/uninstall_macos.sh
```

Windows：

```powershell
.\clash-patch\scripts\uninstall_windows.cmd
```

卸载也不要求关闭客户端。macOS 只清理能确认所有权的旧版自动机制。Windows 运行中只移除全局脚本的受管块，保留应用设置和恢复状态；客户端原本没有运行时才恢复能确认未被后续修改的设置。备份不会删除。

## 验证

依次完成：

1. [IPInfo WebRTC 检测](https://ipinfo.cv/webrtc-check)
2. [DNS 泄漏检测](https://ip.net.coffee/dns/)：点击右侧“深度测试”
3. [IP Coffee WebRTC 检测](https://ip.net.coffee/webrtc/)

这些第三方页面会收到浏览器公网 IP，并发起 WebRTC 或 DNS 请求；Clash Patch 不会向它们上传订阅、节点密码或配置文件。

三项都没有红色提示，而且没有出现未代理公网 IP、私网地址或本地运营商 DNS，才能说验证通过。文件已修改但用户还没有主动刷新订阅时，只能写“等待用户手动重新加载”，不能提前说已经生效。

## 隐私与失败处理

- 输出不包含订阅地址、密码、UUID、私钥、控制器密钥或完整节点地址。
- 无效 YAML、HTML、`401 unauthorized`、读取错误、写入错误、Mihomo 拒绝、30 秒超时和二次转换不一致会分别报告。
- 任何校验失败都保留原订阅。
- 首次备份使用独占创建，不会被并发运行覆盖。
- 仓库在 Ruby 3.3、macOS 系统 Ruby 2.6、Node.js 和 Windows PowerShell 5.1 上运行回归测试。

项目使用 [MIT License](LICENSE)。遇到问题时，只发送错误提示和测试截图，不要发送整份订阅。
