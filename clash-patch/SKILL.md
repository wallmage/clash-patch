---
name: clash-patch
description: Use when an agent needs to inspect, repair, or safely apply DNS, WebRTC, TUN, and AI routing settings for ClashX Meta or Clash Verge Rev subscriptions on macOS or Windows.
---

# Clash 补丁

## 必须遵守

1. **绝对不要退出、停止或重启 Clash 客户端。** 不得执行、建议或要求用户这样做。
2. 先只读检查，再修改。不得重新加载当前配置，不得切换 TUN、订阅、代理组或节点。
3. 只处理 Clash 当前存储位置中的订阅。无法确认本地/iCloud 状态时停止，不猜。
4. 要求 Mihomo 1.19.27 或更高版本。找不到内核、版本过旧或 30 秒内没有响应时不修改。
5. 候选必须通过 YAML 重读、二次转换一致性检查和 Mihomo 校验；失败时保留原文件。
6. 所有用户消息使用简体中文，不显示订阅地址、密码、UUID、私钥、控制器密钥或完整节点地址。

开始前完整阅读 [references/patch-policy.md](references/patch-policy.md)。详细产品规则和全部状态以该文件为准。

## 事故防线

- 保留 `default-nameserver`、`proxy-server-nameserver` 和 `direct-nameserver`。不得把节点启动解析改成 `1.1.1.1` 或 `8.8.8.8`；字段缺失或属于旧版危险值时按策略改用 `system`。
- macOS 不安装 LaunchAgent、`WatchPaths` 或目录监听，并清理能确认属于旧版 Clash Patch 的监听，避免补丁写入再次触发自己。
- macOS 必须把已有且有效的 REALITY `short-id` 保持为文本；不补齐、不截断、不猜测。Windows 脚本不改该字段。
- 任何候选都必须验证并再次转换；结果不一致、内核拒绝或超时就保留原订阅。绝不靠退出 Clash 或自动重新加载配置来生效。

## 执行

| 环境 | 命令 |
| --- | --- |
| macOS + ClashX Meta | `bash scripts/install_macos.sh` |
| Windows + Clash Verge Rev | `.\scripts\install_windows.cmd` |
| 其他客户端 | 不修改；建议安装受支持的最新版客户端 |

macOS 只单次处理当前存储位置，不安装 LaunchAgent 或 `WatchPaths`。Windows 使用全局扩展脚本；客户端运行时只更新 `profiles/Script.js`。两个平台都必须让 Clash 保持运行。

订阅已有可选 AI 分组时，直接复用，只补全规则；不得修改它的成员或当前选择。没有 AI 分组时才创建跟随主代理组的 `🤖 AI · Clash Patch`。不得创建第二个安全代理分组，也不得替用户选择节点。

通用 UDP 会影响 WebRTC、游戏、语音、视频通话和 QUIC，执行前告诉用户。家宽通常更适合 AI；有台湾家宽时优先建议台湾，没有时可建议日本，最终由用户选择。

逐份报告结果。文件已修改不等于已经生效；当前订阅写成“等待用户手动重新加载”，其他订阅写成“选择该订阅时生效”。同时说明主代理组、AI 分组、节点未改、配置中的 TUN 写入状态和是否安装自动机制。

## 验证

以下第三方页面会收到浏览器公网 IP。先告知用户，再测试：

1. `https://ipinfo.cv/webrtc-check`
2. `https://ip.net.coffee/dns/`，点击“深度测试”
3. `https://ip.net.coffee/webrtc/`

三项都没有红色提示，而且没有未代理公网 IP、私网地址或本地运营商 DNS，才能说验证通过。没有 Computer Use 时写成 `未验证：需要手动测试`，请用户测试并在失败时返回截图。

不要修改或添加个人化的 Apple、iCloud 或测速网站规则。
