---
name: clash-patch
description: Use when an agent needs to inspect, repair, or safely apply DNS, WebRTC, TUN, and AI routing settings for ClashX Meta or Clash Verge Rev subscriptions on macOS or Windows.
---

# Clash 补丁

## 先遵守这些规则

1. **绝对不要退出、停止或重启 Clash 客户端。** 不得执行、建议或要求用户执行这类操作。中国用户通常依靠 Clash 连接 Codex；客户端一旦退出，修复会失去连接并中断。
2. 先只读检查，再修改。不得自动重新加载当前配置，不得切换 TUN，不得替用户切换当前节点。
3. 只处理 Clash 当前存储位置中的订阅。使用本地存储时不扫描 iCloud；使用 iCloud 时只选当前容器。读不到存储模式或多个 iCloud 容器无法唯一判断时停止，不猜。忽略旧容器、备份、缓存、日志和已废弃目录。
4. 保留订阅原有的 `default-nameserver`、`proxy-server-nameserver` 和 `direct-nameserver`。`proxy-server-nameserver` 缺失时只补 `system`；发现旧版补丁的固定境外解析器组合时迁移为 `system`。不得把节点域名启动解析改成需要先翻墙才能访问的地址。
5. 每份候选配置必须完成 YAML 重读、二次转换一致性检查和 Mihomo 校验。任何一步失败都保留原文件。Mihomo 命令超过 30 秒时终止该校验子进程，把该订阅记为超时并继续处理其他订阅。
6. 不得显示订阅地址、密码、UUID、私钥、控制器密钥或完整节点地址。所有用户消息使用简体中文。

开始前完整阅读 [references/patch-policy.md](references/patch-policy.md)。

## 操作流程

1. 只读识别操作系统、Clash 客户端、当前存储位置、订阅文件和当前配置。不要默认第一个文件就是当前订阅。
2. 只支持以下环境：

| 环境 | 处理方式 |
| --- | --- |
| macOS + ClashX Meta | 运行 `scripts/install_macos.sh` |
| Windows + Clash Verge Rev | 运行 `scripts/install_windows.cmd` |
| 其他客户端 | 不修改；建议安装受支持的最新版客户端 |

3. 要求 Mihomo 1.19.27 或更高版本。找不到内核、版本过旧、30 秒内没有响应或无法确认版本时不修改。
4. macOS 安装程序只单次处理当前存储位置，并移除能确认所有权的旧版目录监听；不安装 LaunchAgent，不使用 `WatchPaths`，不自动重新加载配置。
5. Windows 使用全局扩展脚本。客户端正在运行时只更新 `profiles/Script.js`，不修改 `config.yaml`、`verge.yaml` 或当前运行配置；客户端原本没有运行时才允许事务式更新应用设置。无论哪种情况，都不能要求用户退出客户端。
6. 逐份报告结果。文件被修改不等于已经生效；只有用户后来主动刷新或选择订阅，并完成验证，才能说已生效。

## 执行命令

macOS：

```bash
bash scripts/install_macos.sh
```

Windows：

```powershell
.\scripts\install_windows.cmd
```

修改用户目录需要工具授权时，先用中文说明用途，再请求授权。不要绕过操作系统权限。

## DNS、AI 和 WebRTC

订阅已有可选 AI 分组时，直接复用该分组，只补全 OpenAI、Anthropic、Claude、Gemini 等 AI 服务的域名与 IP 规则；不得修改它的成员或当前选择。只有确认订阅没有 AI 分组时，才创建 `🤖 AI · Clash Patch`，并让它只跟随主代理组。不得创建第二个安全代理分组。

普通查询和 AI 域名查询使用带主代理组标签的加密解析器。启动解析字段保持订阅原值；仅在 `proxy-server-nameserver` 缺失或仍是旧版危险固定值时使用 `system`。这样可以避免代理节点域名依赖代理本身才能解析。

通用 UDP 先交给原有主代理组，紧接 `NETWORK,UDP,REJECT`，不创建额外分组。这会影响 WebRTC、游戏、语音、视频通话和 QUIC，执行前必须告诉用户。

绝对不要替用户选择 AI 节点，也不要改写已有 AI 分组成员。聊天中说明：家宽通常更适合 AI 服务；有台湾家宽时优先建议台湾，没有时可建议日本。只提供建议，由用户自己选择。本 skill 不自动重新加载或切换节点，所以不得发送“已切换”通知，也不得承诺一定可用、永不风控或绝对匿名。

## 旧版自动补丁

macOS 新版只单次运行。`scripts/install_macos.sh` 会核对 `Label` 和程序参数，只移除本工具旧版的 `com.clashpatch.profiles` 与 `com.wallny.clash-profile-patcher` LaunchAgent；不碰无法确认所有权的服务。`scripts/uninstall_macos.sh` 可单独清理旧版残留，备份不会删除。

Windows 卸载时也保持客户端运行。运行中只移除全局脚本的受管块，保留应用设置和安装状态；客户端原本没有运行时才恢复能确认未被后续修改的应用设置。

## 验证

以下第三方页面会收到浏览器公网 IP，并发起 WebRTC 或 DNS 测试请求；不会收到订阅或配置文件。先向用户说明，再测试：

1. `https://ipinfo.cv/webrtc-check`
2. `https://ip.net.coffee/dns/`，点击右侧“深度测试”
3. `https://ip.net.coffee/webrtc/`

三项都没有红色泄漏提示，而且没有出现未代理公网 IP、私网地址或本地运营商 DNS，才能说验证通过。没有 Computer Use 时，把状态写成 `未验证：需要手动测试`，请用户截图返回。

## 最终状态

每份订阅只使用以下状态之一：

- `已更新，等待用户手动重新加载`
- `已更新，选择该订阅时生效`
- `无需修改`
- `未修改：找不到可用的主代理组`
- `已跳过：订阅内容无效`
- `已跳过：内核校验失败`
- `已跳过：订阅响应超时`
- `已跳过：二次转换不一致`
- `已跳过：策略版本无效`
- `已跳过：订阅正在刷新，稍后重试`
- `已跳过：读取或写入失败`
- `已跳过：处理失败`
- `未修改：客户端不受支持`
- `未验证：需要手动测试`

同时说明主代理组、复用或新建的 AI 分组、AI 规则覆盖、节点未改、TUN、是否安装自动机制以及三项测试结果。聊天中建议用户自行选择家宽，台湾优先、没有台湾时可选日本。不要修改或添加个人化的 Apple、iCloud 或测速网站规则。
