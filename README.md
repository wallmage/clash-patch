# Clash Patch

Clash Patch 是给 AI 助手使用的网络补丁与诊断 Skill，支持 macOS 的 ClashX Meta 和 Windows 的 Clash Verge Rev。它包含 Patch 和 Diagnostics 两个模块。

## 安全原则

**绝对不要退出、停止或重启 Clash 客户端。** 中国用户通常依靠 Clash 连接 Codex；客户端退出后，修复可能中断。

补丁不会退出或重启 Clash，也不会切换 TUN、订阅、代理组或节点。macOS 修改当前订阅后会通过本地控制器自动刷新并检查；失败时恢复修改前的文件和运行配置。补丁不加入 Apple、iCloud、Speedtest 等个人规则。

## 两个模块

- **Patch**：首次使用时安全增强当前订阅，处理 DNS、TUN、AI 分流和 WebRTC 泄漏。
- **Diagnostics**：用户只要描述网络哪里不对，AI 助手就从本机复现、读取系统与应用证据、验证不同解释、完成修复并针对原问题复测。

Diagnostics 不要求用户会看日志，也不会因为提到 Clash 就先改配置。有 Computer Use 时，AI 助手必须先在用户实际使用的应用里复现，再检查必要的浏览器、应用、DNS、连接、传输和日志证据；浏览器白屏时会把主文档网络耗时、关键资源和首次显示分开记录。怀疑某个扩展或共同网络组件时，既测异常目标，也测至少两个健康对照：只影响单站就修它们之间的交互，多个无关目标都慢就修共同组件，不逐站添加例外。发现系统代理、透明过滤器、VPN/TUN 等重叠接管时，先用日志和单变量对照证明冲突，再按职责分层，让内容过滤与最终分流各自只接管需要的一层。连续两次判断无效后必须恢复试验并重新取证，没有新证据不做第三次修改。修复后回到同一应用和操作连续复测，并确认过滤覆盖、分流和泄漏防护没有变坏；不能只凭配置或命令行结果宣布完成。

## 补丁内容

- 打开配置中的 TUN、DNS 劫持、自动路由和严格路由，关闭配置中的 IPv6。
- 国内域名由 `geosite:cn` 交给阿里和 DNSPod 的大陆 IP DoH，并通过 `DIRECT` 连接，避免 Fake-IP 初次解析随代理节点位置获得境外 CDN。
- 普通国外域名继续使用通过原主代理组访问的 IP DoH；AI 域名改用通过 AI 分组访问的 IP DoH。所有受管查询均加密，不使用 ECS。
- 保留节点启动解析；缺失或仍是旧版危险固定值时才改用系统 DNS。原有 `direct-nameserver` 会替换为受管的大陆 DoH。
- 已有 AI 分组时保留成员和选择，只补全 OpenAI、ChatGPT、Codex、Claude、Anthropic、Gemini 等规则。
- 没有 AI 分组时创建独立选择器，加入订阅的全部真实节点和代理提供者。普通流量继续使用主代理组，AI 流量可以单独选择家宽节点。
- 不创建额外的安全代理分组，也不替用户选择节点。家宽通常更适合 AI；有台湾家宽时优先台湾，没有时可考虑日本。
- 所有 UDP（包括 HTTP/3/QUIC 和 WebRTC）统一交给 AI 分组；AI 分组当前选择不能是 `DIRECT`。代理不支持 UDP 时连接会失败，不会改走本地直连。
- macOS 会保护已有且有效的 REALITY `short-id` 文本；Windows 脚本不处理该字段。

同一个浏览器既能打开国内网站，也能打开 Claude 或 ChatGPT。WebRTC 连接只显示它要访问的 STUN 服务器，Clash 无法知道它来自哪个标签页，因此不能按浏览器应用或 AI 域名单独处理 WebRTC。UDP 规则必须覆盖全局，也会影响 QUIC、游戏、语音和视频通话。国内网页的 DNS 和 TCP 仍按域名直连；如果浏览器使用 QUIC，这部分 UDP 会经过 AI 分组。这是共享浏览器中避免 WebRTC 直连所需的取舍。

## 安装

```bash
git clone https://github.com/wallmage/clash-patch.git
```

把仓库中的 `clash-patch` 文件夹复制到 `~/.codex/skills/clash-patch`，然后告诉 Codex：

```text
请使用 $clash-patch 诊断当前网络问题，或检查并增强 Clash 当前存储位置中的订阅。不要退出、停止或重启 Clash。
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

安装程序单次运行，只处理 ClashX Meta 当前使用的本地目录或 iCloud 容器。每份顶层 YAML 都经过 YAML 1.2 读取、二次转换和 Mihomo 校验，最长等待 30 秒。修改前创建一次性备份。当前订阅写入后通过 Mihomo 本地控制器自动刷新，清除旧 Fake-IP 与 DNS 缓存，再检查 TUN、DNS、外网连通性和原有代理组选择；任一步失败都会恢复修改前的内容。整个过程不退出或重启 ClashX Meta。

macOS 不安装 LaunchAgent 或 `WatchPaths`。安装程序会删除能确认属于旧版 Clash Patch 的目录监听。订阅以后刷新时，需要再次运行 skill。

### Windows

Clash Verge Rev 的全局扩展脚本 `profiles/Script.js` 会在订阅加载或刷新时应用补丁，不需要计划任务或后台服务。

客户端运行时只更新全局脚本；客户端原本没有运行时，安装程序才事务式更新应用级 TUN 设置。脚本不会结束 Clash 进程。

## Patch 验证

先检查实时分流：国内网站应获得大陆 CDN 并经过 `DIRECT`；Google 应经过主代理组当前节点；OpenAI、Anthropic 和 Claude 应经过 AI 分组当前节点。然后测试：

1. [IPInfo WebRTC 检测](https://ipinfo.cv/webrtc-check)
2. [DNS 泄漏检测](https://ip.net.coffee/dns/)：点击“深度测试”
3. [IP Coffee WebRTC 检测](https://ip.net.coffee/webrtc/)

这些第三方页面会收到浏览器公网 IP。有 Computer Use 时由 AI 助手自动打开并完成测试；没有时按聊天中的中文步骤手动测试并把红色结果截图发回。三项都没有红色提示，且没有未代理公网 IP、私网地址或本地运营商 DNS，才能说验证通过。

## 卸载与隐私

```bash
bash clash-patch/scripts/uninstall_macos.sh
```

```powershell
.\clash-patch\scripts\uninstall_windows.cmd
```

卸载不要求关闭客户端，也不会删除备份。输出不包含订阅地址、密码、UUID、私钥、控制器密钥或完整节点地址。遇到问题时只发送错误提示和测试截图，不要发送整份订阅。

项目使用 [MIT License](LICENSE)。
