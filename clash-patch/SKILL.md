---
name: clash-patch
description: Use when an agent needs to diagnose slow, intermittent, unavailable, misrouted, or leaking network behavior; configure ClashX Meta or Clash Verge Rev for browsing, overseas AI, Claude, or Claude Code; or interpret voice-dictated “cloud” as Claude in a proxy or AI context.
---

# Clash 补丁与诊断

## 必须遵守

1. **绝对不要退出、停止或重启 Clash 客户端。** 不得执行、建议或要求用户这样做。
2. 先只读检查，再修改。只按已保存用途档位切换 TUN 或 Clash 自己的系统代理；不得覆盖第三方代理，也不得切换订阅、代理组或节点。
3. 只处理 Clash 当前存储位置中的订阅。无法确认本地/iCloud 状态时停止，不猜。
4. 要求 Mihomo 1.19.27 或更高版本。找不到内核、版本过旧或 30 秒内没有响应时不修改。
5. 候选必须通过 YAML 重读、二次转换一致性检查和 Mihomo 校验；失败时保留原文件。
6. 所有用户消息使用简体中文，不显示订阅地址、密码、UUID、私钥、控制器密钥或完整节点地址。

开始前完整阅读 [references/patch-policy.md](references/patch-policy.md)。详细产品规则和全部状态以该文件为准。

## 模块选择

- **Patch 模块**：用户首次安装、改变用途档位或明确要求网络配置时使用；只应用满足该档位的最少改动。
- **Diagnostics 模块**：用户说网络不对劲、变慢、打不开、不稳定、分流异常或出现其他网络现象时使用。不能因为用户提到 Clash 就先运行补丁。

## 用途档位

先读取本机保存的档位：macOS 运行 `bash scripts/install_macos.sh --show-profile`；Windows 运行 `.\scripts\install_windows.cmd -ShowUsageProfile`。没有已保存档位时，修改前必须问：**“你使用网络代理主要用于哪些用途？”**

1. **档位 1｜普通浏览**：Twitter、Facebook、YouTube 等。只确认 Clash 客户端的“设置为系统代理”已开启；不修改 TUN 或订阅。用 Computer Use 测试 Google、Twitter 和一个用户常用站点。
2. **档位 2｜海外 AI**：ChatGPT、Codex、Gemini、Perplexity 等，但不用 Claude。开启 TUN，并关闭 Clash 客户端自己的系统代理开关，避免同一流量被 Clash 重复接管；这不是为了隐藏代理。不得关闭或覆盖 AdGuard、PAC 等第三方代理，不应用 DNS、WebRTC 或 AI 分组补丁。测试 Google、Twitter、ChatGPT 和 Gemini。
3. **档位 3｜Claude/Claude Code**：先完成档位 2，再应用完整增强：①配置 TUN、DNS 劫持与严格路由；②关闭 IPv6；③国内 DNS 直连大陆加密解析器；④普通国外与 AI DNS 按出站分开；⑤补全或创建 AI 分组；⑥补全 AI 规则；⑦所有 UDP 经 AI 分组并以拒绝兜底，防止 WebRTC 直连；⑧完成分流、DNS 和两项 WebRTC 验证。说明全局 UDP 会影响 QUIC、游戏、语音和视频；建议 AI 分组选择台湾家宽，其次日本家宽，但不得自动切换节点。

向小白用户展示以上三项及改动差异。用户可以随时改档；升档时只补新增能力。从档位 3 降到档位 1 或 2 时，先运行安全卸载：macOS 用 `bash scripts/uninstall_macos.sh`，Windows 用 `.\scripts\uninstall_windows.cmd`；再保存并执行新选择。卸载只能撤销能确认属于本工具且未被继续修改的设置，不能覆盖后来产生的用户改动；无法安全恢复的旧增强继续保留并说明。保存并执行选择：macOS 用 `bash scripts/install_macos.sh --profile N`，Windows 用 `.\scripts\install_windows.cmd -UsageProfile N`。

用户明确表达 Claude 或 Claude Code 的网络配置需求时，直接选择或升级为档位 3。语音输入中的 `cloud` 只有在代理、AI 工具或 Claude Code 语境中才按 Claude 处理；不得把普通云盘、云服务器或 cloud storage 当成档位 3 触发词。明确表达其他海外 AI 时选择或升级为档位 2。仅提到某网站故障仍进入 Diagnostics，不借机改档。

Diagnostics 默认只读。有 Computer Use 且症状能在界面看到时，必须在修改前复现原始症状；命令行结果不能代替用户实际使用的应用。再判断影响范围，按现场选择浏览器、应用、系统、DNS、连接、分流、传输质量和日志证据；不是每次全部检查。配置缺陷不等于故障原因，只有同一原始症状的单变量对照和独立证据同时成立，才能修改并下结论。

浏览器白屏、一直转圈或过很久突然显示时，必须把 DNS、主文档与关键资源的网络耗时、首次显示时间和加载结束时间分开记录。怀疑扩展、过滤器或共同网络组件时，除单站目标的开关对照外，还要测试至少两个健康对照：只有目标异常就修目标交互；健康对照也异常就修共同组件本身，不能继续逐站加例外。多个无关目标在内容开始传输前出现相同等待时，盘点系统代理、透明过滤器、VPN/TUN 和 DNS 过滤等接管层；用时间线、日志与单变量切换证明重叠接管后再做职责分层，每层只保留一个透明接管者。无改善立即恢复原设置。不能因为单个目标的对照结果就停用或删除整个组件。

代理必须主动完成本机可完成的检查。历史证据不足时建立有时间戳的观察窗口，不让小白用户决定该查哪个日志。两次假设或修改未改善原始症状后，必须做诊断重置：恢复全部未生效的试验，重列已确认、已排除和未知项；没有新的证据不得进行第三次修改。确认问题后执行最小、可恢复的修复，并用同一应用、目标和动作连续复测；涉及网络接管模式时还要验证原有过滤覆盖、分流和泄漏防护。本机不能解决时，再查当前官方方案。最终用简体中文说明发生了什么、证据、已做修复、复测结果和仍未确认之处。

单项 Clash 配置修复仍留在 Diagnostics，只复用 Patch 的备份、候选校验、刷新和失败恢复机制。只有档位 3 执行下述完整策略与 Patch 专用验收。普通浏览器或应用问题不得顺手改 Clash。

## 事故防线

- 保留 `default-nameserver` 和 `proxy-server-nameserver` 的安全用户值；字段缺失或属于旧版危险固定值时按策略迁移。不得把节点启动解析改成 `1.1.1.1` 或 `8.8.8.8`。把 `direct-nameserver` 统一设为策略中的大陆 IP DoH，并关闭 `direct-nameserver-follow-policy`，让已判定为 `DIRECT` 的国内域名获得大陆 CDN。不得使用明文 DNS、`system` 或 ECS 作为直连域名解析器。
- macOS 不安装 LaunchAgent、`WatchPaths` 或目录监听，并清理能确认属于旧版 Clash Patch 的监听，避免补丁写入再次触发自己。
- macOS 必须把已有且有效的 REALITY `short-id` 保持为文本；不补齐、不截断、不猜测。Windows 脚本不改该字段。
- 任何候选都必须验证并再次转换；结果不一致、内核拒绝或超时就保留原订阅。当前订阅只允许通过本地控制器自动刷新；刷新或运行检查失败时立即恢复原文件和原运行配置，绝不退出 Clash。
- macOS 当前订阅刷新成功后，必须通过本地控制器依次清除 Fake-IP 和 DNS 缓存，再做 DNS 与连接验证；缓存清理失败也要恢复原配置。
- `config.yaml` 是 ClashX Meta 的默认基础配置，不得删除；当前选择其他订阅时安静跳过它，不把它当成无效订阅报错。

## 执行

| 环境 | 命令 |
| --- | --- |
| macOS + ClashX Meta | `bash scripts/install_macos.sh --profile N` |
| Windows + Clash Verge Rev | `.\scripts\install_windows.cmd -UsageProfile N` |
| 其他客户端 | 不修改；建议安装受支持的最新版客户端 |

档位 1、2 的安装程序只保存选择，不改订阅；客户端开关由 Computer Use 操作并复测。档位 3 才继续：macOS 只单次处理当前存储位置，不安装 LaunchAgent 或 `WatchPaths`；当前订阅修改后自动刷新，并检查 TUN、DNS、外网连通性和原有代理组选择，失败时自动恢复。Windows 使用全局扩展脚本；客户端运行时只更新 `profiles/Script.js`。两个平台都必须让 Clash 保持运行。

DNS 必须按出站拆分：用 `nameserver-policy` 的 `geosite:cn` 把国内域名交给大陆加密 DNS，并通过 `DIRECT` 连接；普通国外域名使用通过原主代理组访问的受管 DoH；AI 域名使用通过 AI 分组访问的受管 DoH。`direct-nameserver` 作为直连出站的同一套后备，不得为单个国内网站添加 DNS 例外。

订阅已有可选 AI 分组时，直接复用，只补全规则；不得修改它的成员或当前选择。没有 AI 分组时才创建独立的 `🤖 AI · Clash Patch`，加入订阅全部可用的真实节点和代理提供者，让主代理组与 AI 节点互不影响。找不到任何可用节点或代理提供者时不创建无意义的分组。不得创建第二个安全代理分组，也不得替用户选择节点。

规则列表最前面必须依次放置 `NETWORK,UDP,<AI 分组>`、`NETWORK,UDP,REJECT`。所有 UDP 都先由 AI 分组处理，不能回到本地直连；所选节点不支持 UDP 时继续命中拒绝兜底。AI 分组当前选择必须是代理节点，不能是 `DIRECT`；节点不支持 UDP 时如实报告 WebRTC 未通过或 UDP 不可用。

不要设计按应用隔离。用户会在同一个浏览器里同时访问国内网站和 AI 网站，而 WebRTC 的 STUN 连接不带原网页域名，Mihomo 无法判断它来自哪个标签页。TCP 与 DNS 可以按域名区分，WebRTC 防护必须覆盖全局 UDP。QUIC 也使用 UDP，因此会经过 AI 分组；国内网页的 TCP 和 DNS 仍然直连。明确告诉用户：这会影响游戏、语音和视频通话；家宽通常更适合 AI，最终节点仍由用户选择。

逐份报告结果。当前订阅只有自动刷新和运行检查都通过才能写成“已更新并自动生效”；失败并恢复时如实报告。其他订阅写成“选择该订阅时生效”。同时说明主代理组、AI 分组、是否新建了独立节点选择器和配置中的 TUN 状态。

## Patch 专用验收（Diagnostics 不固定执行）

macOS 先运行 `ruby scripts/macos/verify_routes.rb`，通过 Mihomo 实时连接记录验证分流：访问 Google 时必须经过当前主代理节点；访问 OpenAI、Anthropic 或 Claude 时必须经过 AI 分组当前节点。任何一项走错都要继续修复，不能只看 YAML 规则。其他平台使用可用的本地控制器执行同等检查。

再验证用户报告的国内站点；没有指定站点时使用常见国内域名。通过 Mihomo `/dns/query` 读取当前 A/CNAME，同时直接查询策略中的两套大陆 DoH，确认当前结果来自同类大陆 CDN，而不是代理节点所在地的解析结果。随后记录 HTTPS 的 DNS、TCP、TLS、首字节和总耗时，并从 `/connections` 确认连接链为 `DIRECT`。解析位置、实时时间和连接链缺一项都不能写成通过。

然后使用 Computer Use 自动打开以下页面并完成操作。它们会收到浏览器公网 IP；用户已经要求运行本 skill 时可视为同意执行这些指定测试：

1. `https://ipinfo.cv/webrtc-check`
2. `https://ip.net.coffee/dns/`，点击“深度测试”
3. `https://ip.net.coffee/webrtc/`

三项都没有红色提示，而且没有未代理公网 IP、私网地址或本地运营商 DNS，才能说验证通过。macOS 或 Windows 环境只要提供 Computer Use，就由代理连续完成，不让用户代点。当前环境没有 Computer Use 时，给出中文逐步操作，写成 `未验证：需要手动测试`，要求用户在任何红色结果出现时截图发回，并继续修复直到通过。

不要修改或添加个人化的 Apple、iCloud 或测速网站规则。
