#!/bin/sh
set -eu
set -f

INSTALL_DIR="$HOME/Library/Application Support/ClashPatch"
BACKUP_DIR="$INSTALL_DIR/backups"
STATE_PATH="$INSTALL_DIR/install-state.plist"
CURRENT_LABEL="com.clashpatch.profiles"
CURRENT_PLIST="$HOME/Library/LaunchAgents/$CURRENT_LABEL.plist"
CURRENT_PATCHER="$INSTALL_DIR/patch_profiles.rb"
LEGACY_LABEL="com.wallny.clash-profile-patcher"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"
LEGACY_PATCHER="$HOME/Library/Application Support/ClashProfilePatcher/patch_profiles.rb"
DEFAULTS_DOMAIN="com.metacubex.ClashX.meta"

say() {
  /usr/bin/printf '%s\n' "[Clash 补丁] $1"
}

launch_agent_owned() {
  candidate=$1
  expected_label=$2
  expected_patcher=$3
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  agent_label=$(/usr/bin/plutil -extract Label raw "$candidate" 2>/dev/null || true)
  agent_arg0=$(/usr/bin/plutil -extract ProgramArguments.0 raw "$candidate" 2>/dev/null || true)
  agent_arg1=$(/usr/bin/plutil -extract ProgramArguments.1 raw "$candidate" 2>/dev/null || true)
  [ "$agent_label" = "$expected_label" ] && [ "$agent_arg0" = "/usr/bin/ruby" ] && [ "$agent_arg1" = "$expected_patcher" ]
}

remove_owned_agent() {
  candidate=$1
  expected_label=$2
  expected_patcher=$3
  if [ -f "$candidate" ]; then
    if launch_agent_owned "$candidate" "$expected_label" "$expected_patcher"; then
      /bin/launchctl bootout "gui/$USER_ID/$expected_label" >/dev/null 2>&1 || true
      /bin/rm -f "$candidate"
      say "已移除旧版自动目录监听：${expected_label}。"
    else
      say "发现同名但无法确认属于 Clash 补丁的 LaunchAgent，已保留：${expected_label}。"
    fi
  elif /bin/launchctl print "gui/$USER_ID/$expected_label" >/dev/null 2>&1; then
    say "发现同名 LaunchAgent，但缺少可核对的 plist；未停止该服务：${expected_label}。"
  fi
}

if [ "$(uname -s)" != "Darwin" ]; then
  say "当前系统不是 macOS。"
  exit 2
fi

USER_ID=$(/usr/bin/id -u)
if [ "$USER_ID" -eq 0 ]; then
  say "请不要使用 sudo 或 root 运行卸载程序；请用当前登录用户直接运行。"
  exit 2
fi

remove_owned_agent "$CURRENT_PLIST" "$CURRENT_LABEL" "$CURRENT_PATCHER"
remove_owned_agent "$LEGACY_PLIST" "$LEGACY_LABEL" "$LEGACY_PATCHER"

# 只有状态明确记录了安装前值时才恢复。无状态旧版的更早值无法推断。
TUN_RESTORED=0
if [ -f "$STATE_PATH" ]; then
  restore_known=$(/usr/bin/plutil -extract RestoreTunKnown raw "$STATE_PATH" 2>/dev/null || true)
  if [ "$restore_known" = "true" ] || [ "$restore_known" = "1" ]; then
    restore_present=$(/usr/bin/plutil -extract RestoreTunPresent raw "$STATE_PATH" 2>/dev/null || true)
    if [ "$restore_present" = "true" ] || [ "$restore_present" = "1" ]; then
      restore_value=$(/usr/bin/plutil -extract RestoreTunValue raw "$STATE_PATH" 2>/dev/null || true)
      case "$restore_value" in
        true|1) /usr/bin/defaults write "$DEFAULTS_DOMAIN" restoreTunProxy -bool true ;;
        *) /usr/bin/defaults write "$DEFAULTS_DOMAIN" restoreTunProxy -bool false ;;
      esac
    else
      /usr/bin/defaults delete "$DEFAULTS_DOMAIN" restoreTunProxy >/dev/null 2>&1 || true
    fi
    TUN_RESTORED=1
  fi
fi

/bin/rm -f \
  "$INSTALL_DIR/patch_profiles.rb" \
  "$INSTALL_DIR/policy.json" \
  "$STATE_PATH" \
  "$INSTALL_DIR/patch.log" \
  "$INSTALL_DIR/patch-error.log"
/bin/rmdir "$INSTALL_DIR" >/dev/null 2>&1 || true

say "自动补丁已移除，不会再在登录或订阅刷新时运行。"
if [ -d "$BACKUP_DIR" ]; then
  say "原始订阅备份仍保留在本机；卸载程序没有删除或还原它们。"
fi
if [ "$TUN_RESTORED" -eq 1 ]; then
  say "安装程序写入的 TUN 启动偏好已恢复。订阅里的 DNS、WebRTC 和 AI 设置不会自动撤销。"
else
  say "旧版安装前的 TUN 偏好无法确认，因此保留当前值。订阅里的 DNS、WebRTC 和 AI 设置不会自动撤销。"
fi
