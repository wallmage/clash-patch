# Clash 补丁策略

## 目录

- [支持范围](#支持范围)
- [检查顺序](#检查顺序)
- [DNS 与 TUN](#dns-与-tun)
- [主代理组](#主代理组)
- [AI 组](#ai-组)
- [家宽选择](#家宽选择)
- [AI 规则](#ai-规则)
- [WebRTC](#webrtc)
- [订阅刷新](#订阅刷新)
- [异常处理](#异常处理)
- [验证标准](#验证标准)
- [输出格式](#输出格式)

## 支持范围

支持：

- macOS 上使用 Mihomo 内核的最新版 ClashX Meta；
- Windows 上使用 Mihomo 内核的最新版 Clash Verge Rev。

旧版 ClashX、旧版 Clash Verge 或无法确认内核能力的客户端只检查，不修改。macOS 建议升级到 ClashX Meta；Windows 建议升级到 Clash Verge Rev。

## 检查顺序

1. 识别操作系统和客户端。
2. 找到客户端配置目录。
3. 枚举全部订阅、代理组和规则。
4. 排除运行时配置、缓存、备份、日志和临时文件。
5. 找到当前订阅和主代理组。
6. 执行平台安装程序。
7. 检查持久化机制。
8. 重新加载当前配置。
9. 完成浏览器测试。

任何时候都不能输出整份配置。日志只能出现配置显示名称、处理状态、代理组名称和节点显示名称。

## DNS 与 TUN

共同策略：

```yaml
ipv6: false
tun:
  enable: true
  stack: system
  dns-hijack:
    - any:53
    - tcp://any:53
  auto-route: true
  auto-detect-interface: true
  strict-route: true
dns:
  enable: true
  ipv6: false
  respect-rules: true
  use-hosts: true
  use-system-hosts: true
```

普通查询使用带主代理组标签的 DoH。AI 域名使用带 AI 组标签的 DoH。代理服务器域名使用单独的加密启动解析，避免代理必须先通过自己才能解析。

如 `nameserver-policy` 把多个域名写在同一个逗号分隔键中，拆成独立键。保留已有的有效代理组标签；明文 DNS、`DIRECT` DNS 和没有代理组标签的普通查询改为受管 DoH。

不要为测速成绩额外添加国内 DNS 例外。以真实泄漏测试结果为准。

## 主代理组

按以下顺序选择：

1. 最后一个 `MATCH` 指向的可选代理组；
2. 订阅规则反复引用的最终代理组；
3. `Proxy`、`PROXY`、`Final`、`Fallback`、`节点选择`、`节点列表` 或 `兜底分流`；
4. 第一个非纯 `DIRECT` 的 `select` 组。

找不到主代理组时不要猜单个节点。保持原文件不变，并告诉用户需要一个可选主代理组。

## AI 组

优先复用名称明确表示 AI 的 `select` 组，例如 `AI`、`🤖 AI`、`OpenAI` 或 `人工智能`。

没有时创建 `🤖 AI`。如果同名组不是 `select`，保留原组并创建不冲突的新组。新组至少包含主代理组作为后备。

AI 组负责 OpenAI、ChatGPT、Codex、Claude、Anthropic，以及策略文件中列出的 Google AI 和相关服务流量。

## 家宽选择

节点显示名称必须同时满足：

- 包含 `家宽`；
- 属于台湾或日本。

台湾标记包括 `台湾`、`台灣`、`Taiwan`、独立的 `TW` 或 `🇹🇼`。日本标记包括 `日本`、`Japan`、独立的 `JP` 或 `🇯🇵`。

顺序固定为台湾优先、日本其次。同一区域有多个候选时，使用订阅中出现最早的节点。

找到候选后，把它放在 AI 组第一位。当前运行配置能通过控制器切换时，同时选择该节点。

如果只有美国、新加坡或其他地区的家宽，不做特别选择。保留用户当前选择，只提示台湾和日本家宽通常更适合附近地区的 AI 服务。

## AI 规则

唯一数据来源是 [policy.json](policy.json)。两个平台必须使用相同列表。

规则覆盖：

- `anthropic.com`、Claude 应用、内容、MCP 和静态服务；
- `openai.com`、`chatgpt.com`、Codex 所使用的 OpenAI 域名；
- OpenAI 实时语音、LiveKit、静态资源、登录、上传、验证和可观测服务；
- 已有补丁中的 Google AI 和 Gemini 域名；
- 已有 OpenAI 服务和语音 IP 段，并使用 `no-resolve`；
- `DOMAIN-KEYWORD,openai` 后备规则。

明确禁止把以下通用域名整体交给 AI 组：

- `raw.githubusercontent.com`
- `storage.googleapis.com`

只删除目标为受管 AI 组的上述规则。其他用途的规则保持不变。

AI 明确规则必须出现在国内直连、GEO、通用规则集和 `MATCH` 之前。

## WebRTC

加入：

```text
NETWORK,UDP,<主代理组>
```

把它放在已有窄范围规则之后、国内直连和通用规则之前。已有 Apple 或其他专用规则保持原目标和相对顺序。

这样 STUN 的 UDP 不会绕开代理。节点不支持 UDP 时，WebRTC 可能无法建立，但不能退回到未代理的公网 IP。

网页流量和 UDP 尽量使用同一主代理选择。多个结果如果全是代理出口，不属于真实 IP 泄漏；单一结果更容易确认。

## 订阅刷新

### macOS

LaunchAgent 使用 `RunAtLoad` 和整个订阅目录的 `WatchPaths`。目录变化时启动补丁程序，补完后立即退出。没有常驻 Ruby 进程，也没有轮询。

订阅十天不更新，补丁程序就十天不运行。第十一天刷新订阅，目录变化会再次触发。

### Windows

Clash Verge Rev 每次加载或刷新订阅都会运行 `profiles/Script.js`。全局扩展脚本对传入配置应用相同策略。TUN 和顶层 IPv6 使用 Clash Verge Rev 的应用配置，因此不会被脚本后的应用设置覆盖。

Windows 不安装计划任务或后台服务。

## 异常处理

- `401 unauthorized`、HTML、空文件或损坏 YAML：跳过，等待以后刷新出有效订阅。
- 找不到主代理组：不修改，不猜节点。
- 已有 Windows 全局脚本只有一个标准 `main`：先运行原脚本，再运行 Clash 补丁。
- 已有 Windows 脚本结构无法安全组合：保留原文件，请用户发送提示和 `Script.js` 截图。
- REALITY `short-id`：只保护已有且格式有效的十六进制文本；不补齐、不截断、不猜缺失值。
- 当前配置无法重新加载：文件修改保留，但状态写成“已更新，等待重新加载”。

## 验证标准

必须测试：

1. `https://ipinfo.cv/webrtc-check`
2. `https://ip.net.coffee/dns/` 的“深度测试”
3. `https://ip.net.coffee/webrtc/`

三项都没有红色提示，并且不显示用户未代理的公网 IP、私网地址或本地运营商 DNS，才算通过。

没有 Computer Use 时，要求用户手动测试。只要有红色结果，就让用户发截图并继续处理，不得说已经验证。

## 输出格式

逐一输出订阅：

```text
订阅名称：已更新并生效
AI 组：🤖 AI
主代理组：节点选择
家宽节点：台湾家宽 01
持久化：已安装
DNS 测试：通过
WebRTC 测试 1：通过
WebRTC 测试 2：通过
```

未完成浏览器测试时把测试状态写成“未验证”。
