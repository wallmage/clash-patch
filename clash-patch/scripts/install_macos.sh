#!/bin/sh
set -eu

# 默认配置目录：~/.config/clash.meta
PROFILE_DIR="${CLASH_PATCH_PROFILE_DIR:-$HOME/.config/clash.meta}"
INSTALL_DIR="$HOME/Library/Application Support/ClashPatch"
BACKUP_DIR="$INSTALL_DIR/backups"
PLIST_PATH="$HOME/Library/LaunchAgents/com.clashpatch.profiles.plist"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCHER_SOURCE="$SCRIPT_DIR/macos/patch_profiles.rb"
POLICY_SOURCE="$SCRIPT_DIR/../references/policy.json"
PATCHER_TARGET="$INSTALL_DIR/patch_profiles.rb"
POLICY_TARGET="$INSTALL_DIR/policy.json"

say() {
  /usr/bin/printf '%s\n' "[Clash 补丁] $1"
}

if [ "$(uname -s)" != "Darwin" ]; then
  say "当前系统不是 macOS。Windows 请使用最新版 Clash Verge Rev 和 Windows 安装程序。"
  exit 2
fi

if [ ! -x /usr/bin/ruby ]; then
  say "这台 Mac 没有系统 Ruby，无法安装自动补丁。请先更新 macOS，或把提示发回来继续处理。"
  exit 3
fi

if [ ! -d "/Applications/ClashX Meta.app" ] && [ ! -d "$HOME/Applications/ClashX Meta.app" ]; then
  say "没有找到受支持的 ClashX Meta。请安装最新版 ClashX Meta，打开一次后再运行。"
  exit 4
fi

if [ ! -d "$PROFILE_DIR" ]; then
  say "没有找到 ClashX Meta 配置目录。请先打开 ClashX Meta 并添加订阅。"
  exit 5
fi

if [ ! -f "$PATCHER_SOURCE" ] || [ ! -f "$POLICY_SOURCE" ]; then
  say "安装包不完整：缺少补丁程序或策略文件。"
  exit 6
fi

/bin/mkdir -p "$INSTALL_DIR" "$BACKUP_DIR" "$HOME/Library/LaunchAgents"
/bin/chmod 700 "$INSTALL_DIR" "$BACKUP_DIR"
/bin/cp "$PATCHER_SOURCE" "$PATCHER_TARGET"
/bin/cp "$POLICY_SOURCE" "$POLICY_TARGET"
/bin/chmod 700 "$PATCHER_TARGET"

/bin/cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.clashpatch.profiles</string>
  <key>ProgramArguments</key>
  <array>
    <string>/usr/bin/ruby</string>
    <string>$PATCHER_TARGET</string>
    <string>--profile-dir</string>
    <string>$PROFILE_DIR</string>
    <string>--policy</string>
    <string>$POLICY_TARGET</string>
    <string>--backup-dir</string>
    <string>$BACKUP_DIR</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>WatchPaths</key>
  <array>
    <string>$PROFILE_DIR</string>
  </array>
  <key>StandardOutPath</key>
  <string>$INSTALL_DIR/patch.log</string>
  <key>StandardErrorPath</key>
  <string>$INSTALL_DIR/patch-error.log</string>
</dict>
</plist>
PLIST

/usr/bin/ruby "$PATCHER_TARGET" \
  --profile-dir "$PROFILE_DIR" \
  --policy "$POLICY_TARGET" \
  --backup-dir "$BACKUP_DIR"

USER_ID=$(/usr/bin/id -u)
/bin/launchctl bootout "gui/$USER_ID" "$PLIST_PATH" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/$USER_ID" "$PLIST_PATH"
/bin/launchctl enable "gui/$USER_ID/com.clashpatch.profiles"

say "LaunchAgent 已安装。它只在登录或订阅目录变化时运行，补完后立即退出。"
say "以后新增、重命名或刷新任何订阅，补丁都会自动重新应用。"
