# Clash Patch

Clash Patch 是给 AI 助手使用的网络补丁与诊断 Skill，支持 macOS 的 ClashX Meta 和 Windows 的 Clash Verge Rev。它包含 Patch 和 Diagnostics 两个模块。

## 安全原则

**绝对不要退出、停止或重启 Clash 客户端。** 中国用户通常依靠 Clash 连接 Codex；客户端退出后，修复可能中断。

补丁不会退出或重启 Clash。只在用户选择的档位明确要求时，通过客户端界面切换 TUN 或 Clash 自己的系统代理；不会改写第三方 PAC，也不会切换订阅、代理组或节点。唯一的第三方兼容操作是：在符合下述条件时，通过 AdGuard for Mac 自己的界面切换过滤模式。macOS 修改当前订阅后会自动刷新并检查，失败时恢复。

## 两个模块

- **Patch**：首次使用时先了解用途，只做该用途需要的最少改动。
- **Diagnostics**：用户只要描述网络哪里不对，AI 助手就从本机复现、读取系统与应用证据、验证不同解释、完成修复并针对原问题复测。

Diagnostics 不要求用户会看日志，也不会因为提到 Clash 就先改配置。有 Computer Use 时，AI 助手必须先在用户实际使用的应用里复现，再检查当前档位允许且与症状相关的证据；浏览器白屏时会把主文档网络耗时、关键资源和首次显示分开记录。怀疑某个扩展或共同网络组件时，既测异常目标，也测至少两个健康对照：只影响单站就修它们之间的交互，多个无关目标都慢就修共同组件，不逐站添加例外。连续两次判断无效后必须恢复试验并重新取证，没有新证据不做第三次修改。修复后回到同一应用和操作连续复测，并确认当前档位要求的能力没有变坏；不能只凭配置或命令行结果宣布完成。

## 首次选择

第一次在一台电脑上配置时，Skill 会问：“你使用网络代理主要用于哪些用途？”选择会保存在本机，以后可以修改。

1. **普通浏览**：Twitter、Facebook、YouTube 等。只确认“设置为系统代理”已开启，不改 TUN 和订阅；测试 Google、Twitter 和常用站点。
2. **海外 AI**：ChatGPT、Codex、Gemini、Perplexity 等，不含 Claude。开启 TUN，关闭 Clash 自己的系统代理开关；按下述规则处理 AdGuard for Mac；不打 DNS、WebRTC 或 AI 分组补丁；测试普通站、ChatGPT、Gemini 和 Agent 联网。
3. **Claude/Claude Code**：完成第二档后，关闭订阅自动更新，再应用全部 DNS、WebRTC、AI 分流和 UDP 防护，并测试 Claude。全局 UDP 会影响 QUIC、游戏、语音和视频；AI 节点建议台湾家宽优先、其次日本家宽，但不会自动替用户切节点。

用户明确说要配置 Claude 或 Claude Code 时会直接选择或升级为第三档。从第三档降到第一、二档时会先安全卸载能确认属于本工具的持续补丁，再保存新选择；不会为了恢复旧设置覆盖用户后来的修改，无法可靠恢复的旧订阅增强会明确说明仍然保留。

档位同时约束 Patch 和 Diagnostics。以后遇到故障，Skill 会先读取这个选择：第一档只解决普通境外网站浏览，不检查 TUN、DNS 泄漏、WebRTC 或 AI；第二档再照顾 TUN、普通海外 AI 和 Agent 联网，但不增加泄漏防护；第三档的任何修复都要同时保护现有 DNS、WebRTC 和 AI 分流。网站打不开或变慢不会自动把用户升到更高档位。

## AdGuard for Mac 兼容

第二、三档会在开始和日常诊断时检查 AdGuard for Mac。发现 Clash TUN 与 AdGuard 的 `Network Extension` 同时接管网络时，Skill 直接走已验证的兼容路径：保留 Clash TUN，在 AdGuard 自己的界面中改为“自动代理”，然后复测至少三个无关网站、Safari 和 Chrome 的广告过滤，以及当前档位可能受影响的能力；不逐站添加例外。这个改动不是升档，也不会触发额外的 DNS、WebRTC 或 AI 补丁。

“自动代理”仍能过滤遵守系统代理的浏览器；不使用系统代理的非浏览器应用可能不再被 AdGuard 覆盖。第一档依赖 Clash 系统代理，不能让 AdGuard 再占用同一个系统代理位置，因此不会盲目套用第二、三档的组合。Windows 也不会照搬 macOS 模式。修改只能通过 AdGuard 界面完成；不得改写 PAC、直接编辑设置、停用或卸载 AdGuard。若切换后原始等待没有改善或过滤范围不符合用户需要，立即恢复原模式并继续取证。

## 第三档补丁内容

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

也可以手动保存并执行选择，把 `N` 换成 `1`、`2` 或 `3`：

```bash
bash clash-patch/scripts/install_macos.sh --profile N
```

```powershell
.\clash-patch\scripts\install_windows.cmd -UsageProfile N
```

两个平台都必须让 Clash 保持运行。

## 平台机制

### macOS

第一、二档只保存选择，不改订阅。第三档由安装程序直接关闭自动更新：把 ClashX Meta 的 `kAutoUpdateEnable` 设为 `0`，回读确认后才继续；不依赖 Computer Use。原值为开启时，修改前状态会保存为带日期的私密备份；已经关闭时不重复写。安装程序单次运行，只处理当前使用的本地目录或 iCloud 容器。每份顶层 YAML 都经过 YAML 1.2 读取、二次转换和 Mihomo 校验，最长等待 30 秒。第一次运行保存初始快照；以后每次写入前都创建带日期时间的版本化备份。当前订阅写入后通过本地控制器自动刷新，清除旧 Fake-IP 与 DNS 缓存，再检查运行状态；任一步失败都会恢复修改前的内容。

macOS 不安装永久监听、LaunchAgent、`WatchPaths` 或计划任务。安装程序只会删除能确认属于旧版 Clash Patch 的遗留监听。

### Windows

第一、二档不会安装全局扩展脚本。第三档直接修改 Clash Verge Rev 的 `profiles.yaml`，把每个远程订阅的 `option.allow_auto_update` 设为 `false`；本地配置和其他订阅选项保持不变。修改前备份，写入后逐项回读确认，不依赖 Computer Use。随后使用全局扩展脚本 `profiles/Script.js`，在用户主动加载或刷新订阅时应用补丁，不需要计划任务或后台服务。

客户端运行时只更新全局脚本和订阅清单中的自动更新字段，不碰 `verge.yaml`、`config.yaml` 或当前运行配置；客户端原本没有运行时，安装程序才事务式更新应用级 TUN 设置。脚本不会结束 Clash 进程。

## 安全更新

用户要求“更新节点”或“更新订阅”时，Skill 会更新当前存储位置中的全部远程订阅，而不是只更新当前使用的一份。

- macOS 使用 `bash clash-patch/scripts/install_macos.sh --safe-update`。先下载并校验全部候选；档位 3 给每份候选重打完整补丁，档位 1、2 不增加第三档改动。只有全部成功才统一替换，任一份失败时全部保持原样。
- Windows 先运行 `.\clash-patch\scripts\install_windows.cmd -SnapshotProfiles` 备份并核对全部远程订阅清单，再通过 Clash Verge Rev 的“全部更新”处理；档位 3 的全局脚本会在每份加载时重打补丁。
- 每次写入前都会留下带日期时间的备份。网络在某次改动后异常时，Skill 会先做当前配置与备份的配置差异比较；确需回滚时先备份当前版本，再校验目标和当前 SHA-256，失败时恢复回滚前版本。
- 安全更新是单次、由用户主动触发的操作。档位 3 始终保持自动更新关闭；档位 1、2 不额外修改自动更新设置。

## 配置历史与恢复

第一次运行会保存初始快照；以后每次写入前都会保存带日期时间的修改前版本，历史备份不会被下一次操作覆盖。用户说“昨天改完今天变慢”时，Skill 会先列出备份，选择症状出现前最近的一份，只比较发生变化的字段名和文件哈希，不显示节点、订阅地址或其他配置值。时间只能帮助选择候选，不能单独证明某项改动造成故障。

只有配置差异与现场证据相符时才恢复。恢复前会确认当前文件仍与比较时相同，并再备份一次当前版本；恢复后回到原应用和原操作复测。没有改善或验收失败时恢复回滚前版本。Windows 客户端正在运行时不会为了回滚而结束它，只完成安全比较并说明当前不能自动恢复。

## 第三档验证

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
