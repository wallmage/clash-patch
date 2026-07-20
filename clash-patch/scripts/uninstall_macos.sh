#!/bin/sh
set -eu

INSTALL_DIR="$HOME/Library/Application Support/ClashPatch"
BACKUP_DIR="$INSTALL_DIR/backups"
PLIST_PATH="$HOME/Library/LaunchAgents/com.clashpatch.profiles.plist"
LABEL="com.clashpatch.profiles"

say() {
  /usr/bin/printf '%s\n' "[Clash 补丁] $1"
}

if [ "$(uname -s)" != "Darwin" ]; then
  say "当前系统不是 macOS。"
  exit 2
fi

USER_ID=$(/usr/bin/id -u)
if [ -f "$PLIST_PATH" ]; then
  plist_label=$(/usr/bin/plutil -extract Label raw "$PLIST_PATH" 2>/dev/null || true)
  if [ "$plist_label" != "$LABEL" ]; then
    say "LaunchAgent 文件不是 Clash 补丁创建的，已停止，未删除任何文件。"
    exit 1
  fi
  /bin/launchctl bootout "gui/$USER_ID" "$PLIST_PATH" >/dev/null 2>&1 || true
  /bin/rm -f "$PLIST_PATH"
else
  /bin/launchctl bootout "gui/$USER_ID/$LABEL" >/dev/null 2>&1 || true
fi

/bin/rm -f \
  "$INSTALL_DIR/patch_profiles.rb" \
  "$INSTALL_DIR/policy.json" \
  "$INSTALL_DIR/patch.log" \
  "$INSTALL_DIR/patch-error.log"
/bin/rmdir "$INSTALL_DIR" >/dev/null 2>&1 || true

say "自动补丁已移除，不会再在登录或订阅刷新时运行。"
if [ -d "$BACKUP_DIR" ]; then
  say "原始订阅备份仍保留在本机；卸载程序没有删除或还原它们。"
fi
say "已经写入订阅的 DNS、WebRTC 和 AI 设置不会自动撤销。"
