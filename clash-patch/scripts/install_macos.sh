#!/bin/sh
set -eu
set -f

CUSTOM_PROFILE_DIR="${CLASH_PATCH_PROFILE_DIR:-}"
INSTALL_DIR="$HOME/Library/Application Support/ClashPatch"
BACKUP_DIR="$INSTALL_DIR/backups"
CURRENT_LABEL="com.clashpatch.profiles"
CURRENT_PLIST="$HOME/Library/LaunchAgents/$CURRENT_LABEL.plist"
CURRENT_PATCHER="$INSTALL_DIR/patch_profiles.rb"
LEGACY_LABEL="com.wallny.clash-profile-patcher"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
LEGACY_PATCHER="$HOME/Library/Application Support/ClashProfilePatcher/patch_profiles.rb"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCHER_SOURCE="$SCRIPT_DIR/macos/patch_profiles.rb"
POLICY_SOURCE="$SCRIPT_DIR/../references/policy.json"

say() {
  /usr/bin/printf '%s\n' "[Clash 补丁] $1"
}

legacy_agent_owned() {
  candidate=$1
  expected_label=$2
  expected_patcher=$3
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  agent_label=$(/usr/bin/plutil -extract Label raw "$candidate" 2>/dev/null || true)
  agent_arg0=$(/usr/bin/plutil -extract ProgramArguments.0 raw "$candidate" 2>/dev/null || true)
  agent_arg1=$(/usr/bin/plutil -extract ProgramArguments.1 raw "$candidate" 2>/dev/null || true)
  [ "$agent_label" = "$expected_label" ] && [ "$agent_arg0" = "/usr/bin/ruby" ] && [ "$agent_arg1" = "$expected_patcher" ]
}

remove_legacy_agent() {
  candidate=$1
  expected_label=$2
  expected_patcher=$3
  [ -f "$candidate" ] || return 0
  if legacy_agent_owned "$candidate" "$expected_label" "$expected_patcher"; then
    /bin/launchctl bootout "gui/$USER_ID/$expected_label" >/dev/null 2>&1 || true
    /bin/rm -f "$candidate"
    say "已移除旧版自动目录监听：${expected_label}。"
  else
    say "发现同名但无法确认属于 Clash 补丁的 LaunchAgent，已保留：${expected_label}。"
  fi
}

if [ "$(uname -s)" != "Darwin" ]; then
  say "当前系统不是 macOS。Windows 请使用 Clash Verge Rev 的 Windows 安装程序。"
  exit 2
fi

USER_ID=$(/usr/bin/id -u)
if [ "$USER_ID" -eq 0 ]; then
  say "请不要使用 sudo 或 root；请用当前登录用户直接运行。"
  exit 2
fi

if [ ! -x /usr/bin/ruby ]; then
  say "这台 Mac 没有系统 Ruby，无法运行补丁。"
  exit 3
fi

if [ ! -d "/Applications/ClashX Meta.app" ] && [ ! -d "$HOME/Applications/ClashX Meta.app" ]; then
  say "没有找到受支持的 ClashX Meta。"
  exit 4
fi

if [ -n "$CUSTOM_PROFILE_DIR" ] && [ ! -d "$CUSTOM_PROFILE_DIR" ]; then
  say "没有找到指定的 ClashX Meta 配置目录。"
  exit 5
fi

if [ ! -f "$PATCHER_SOURCE" ] || [ ! -f "$POLICY_SOURCE" ]; then
  say "安装包不完整：缺少补丁程序或策略文件。"
  exit 6
fi

# 旧版目录监听会被补丁自己的写入再次触发。只移除能核对所有权的旧服务。
remove_legacy_agent "$CURRENT_PLIST" "$CURRENT_LABEL" "$CURRENT_PATCHER"
remove_legacy_agent "$LEGACY_PLIST" "$LEGACY_LABEL" "$LEGACY_PATCHER"

core_status=$(/usr/bin/ruby "$PATCHER_SOURCE" --print-core-status 2>/dev/null || true)
if [ "$core_status" != "supported" ]; then
  case "$core_status" in
    too_old) say "Mihomo 内核版本过旧，需要 1.19.27 或更高版本。" ;;
    timeout) say "Mihomo 内核检查超过 30 秒，未修改任何订阅。" ;;
    *) say "没有找到可用的 Mihomo 内核，或无法确认版本。" ;;
  esac
  exit 8
fi

/bin/mkdir -p "$BACKUP_DIR"
/bin/chmod 700 "$INSTALL_DIR" "$BACKUP_DIR"

if [ -n "$CUSTOM_PROFILE_DIR" ]; then
  /usr/bin/ruby "$PATCHER_SOURCE" \
    --profile-dir "$CUSTOM_PROFILE_DIR" \
    --policy "$POLICY_SOURCE" \
    --backup-dir "$BACKUP_DIR"
else
  /usr/bin/ruby "$PATCHER_SOURCE" \
    --policy "$POLICY_SOURCE" \
    --backup-dir "$BACKUP_DIR"
fi

say "本次为单次运行，只处理 ClashX Meta 当前存储位置中的订阅。"
say "脚本没有退出、停止或重启 ClashX Meta，也没有重新加载当前配置。"
say "订阅以后刷新时，请再次运行本 skill。"
