#!/bin/sh
set -eu

# 默认本地配置目录：~/.config/clash.meta；同时自动发现 ClashX Meta 的 iCloud 配置目录。
CUSTOM_PROFILE_DIR="${CLASH_PATCH_PROFILE_DIR:-}"
INSTALL_DIR="$HOME/Library/Application Support/ClashPatch"
BACKUP_DIR="$INSTALL_DIR/backups"
PLIST_PATH="$HOME/Library/LaunchAgents/com.clashpatch.profiles.plist"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCHER_SOURCE="$SCRIPT_DIR/macos/patch_profiles.rb"
POLICY_SOURCE="$SCRIPT_DIR/../references/policy.json"
PATCHER_TARGET="$INSTALL_DIR/patch_profiles.rb"
POLICY_TARGET="$INSTALL_DIR/policy.json"
DEFAULTS_DOMAIN="com.metacubex.ClashX.meta"

say() {
  /usr/bin/printf '%s\n' "[Clash 补丁] $1"
}

add_plist_string() {
  key=$1
  value=$2
  /usr/bin/plutil -insert "$key" -string "$value" "$PLIST_PATH"
}

runtime_tun_state() {
  state=$(/usr/bin/ruby "$PATCHER_TARGET" --print-tun-state 2>/dev/null || true)
  case "$state" in
    enabled|disabled) /usr/bin/printf '%s\n' "$state" ;;
    *) /usr/bin/printf '%s\n' "unknown" ;;
  esac
}

persist_tun_intent() {
  # ClashX Meta reads this supported preference after startup/config reload.
  # It is persistence intent, not proof of the current runtime state.
  /usr/bin/defaults write "$DEFAULTS_DOMAIN" restoreTunProxy -bool true
}

ensure_tun_intent() {
  if /usr/bin/pgrep -x "ClashX Meta" >/dev/null 2>&1; then
    state=$(runtime_tun_state)
    case "$state" in
      enabled)
        persist_tun_intent
        say "已从运行内核确认 TUN 开启。"
        return 0
        ;;
      disabled)
        if /usr/bin/osascript -e 'tell application "ClashX Meta" to TunMode' >/dev/null 2>&1; then
          attempt=0
          while [ "$attempt" -lt 10 ]; do
            if [ "$(runtime_tun_state)" = "enabled" ]; then
              persist_tun_intent
              say "已通过 ClashX Meta 开启 TUN，并从运行内核确认。"
              return 0
            fi
            /bin/sleep 0.5
            attempt=$((attempt + 1))
          done
        fi
        persist_tun_intent
        say "运行内核仍显示 TUN 未开启。已保存下次启动意图；请在 ClashX Meta 中手动打开 TUN。"
        return 0
        ;;
      *)
        # TunMode is a toggle. Never call it when the runtime state is unknown,
        # because doing so could disable an already-enabled TUN device.
        persist_tun_intent
        say "无法读取运行内核的 TUN 状态，因此没有调用切换命令。已保存下次启动意图；请在 ClashX Meta 中确认 TUN 已开启。"
        return 0
        ;;
    esac
  fi

  persist_tun_intent
  say "ClashX Meta 当前没有运行；已保存 TUN 开启意图，下次启动时生效。"
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

if [ -n "$CUSTOM_PROFILE_DIR" ] && [ ! -d "$CUSTOM_PROFILE_DIR" ]; then
  say "没有找到指定的 ClashX Meta 配置目录：$CUSTOM_PROFILE_DIR"
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

# 使用 plutil 逐项写入，路径中的 &、<、引号等字符不会破坏 plist。
/usr/bin/plutil -create xml1 "$PLIST_PATH"
add_plist_string "Label" "com.clashpatch.profiles"
/usr/bin/plutil -insert "ProgramArguments" -array "$PLIST_PATH"
add_plist_string "ProgramArguments.0" "/usr/bin/ruby"
add_plist_string "ProgramArguments.1" "$PATCHER_TARGET"
argument_index=2
if [ -n "$CUSTOM_PROFILE_DIR" ]; then
  add_plist_string "ProgramArguments.$argument_index" "--profile-dir"
  argument_index=$((argument_index + 1))
  add_plist_string "ProgramArguments.$argument_index" "$CUSTOM_PROFILE_DIR"
  argument_index=$((argument_index + 1))
fi
add_plist_string "ProgramArguments.$argument_index" "--policy"
argument_index=$((argument_index + 1))
add_plist_string "ProgramArguments.$argument_index" "$POLICY_TARGET"
argument_index=$((argument_index + 1))
add_plist_string "ProgramArguments.$argument_index" "--backup-dir"
argument_index=$((argument_index + 1))
add_plist_string "ProgramArguments.$argument_index" "$BACKUP_DIR"
/usr/bin/plutil -insert "RunAtLoad" -bool true "$PLIST_PATH"
/usr/bin/plutil -insert "WatchPaths" -array "$PLIST_PATH"

watch_index=0
if [ -n "$CUSTOM_PROFILE_DIR" ]; then
  add_plist_string "WatchPaths.0" "$CUSTOM_PROFILE_DIR"
  watch_index=1
else
  watch_paths=$(/usr/bin/ruby "$PATCHER_TARGET" --print-watch-paths)
  old_ifs=$IFS
  IFS='
'
  for watch_path in $watch_paths; do
    [ -n "$watch_path" ] || continue
    add_plist_string "WatchPaths.$watch_index" "$watch_path"
    watch_index=$((watch_index + 1))
  done
  IFS=$old_ifs
fi

if [ "$watch_index" -eq 0 ]; then
  say "没有找到 ClashX Meta 的本地或 iCloud 配置目录。请先打开客户端并添加订阅。"
  exit 5
fi

add_plist_string "StandardOutPath" "$INSTALL_DIR/patch.log"
add_plist_string "StandardErrorPath" "$INSTALL_DIR/patch-error.log"
/bin/chmod 600 "$PLIST_PATH"
/usr/bin/plutil -lint "$PLIST_PATH" >/dev/null

if [ -n "$CUSTOM_PROFILE_DIR" ]; then
  /usr/bin/ruby "$PATCHER_TARGET" \
    --profile-dir "$CUSTOM_PROFILE_DIR" \
    --policy "$POLICY_TARGET" \
    --backup-dir "$BACKUP_DIR"
else
  /usr/bin/ruby "$PATCHER_TARGET" \
    --policy "$POLICY_TARGET" \
    --backup-dir "$BACKUP_DIR"
fi

ensure_tun_intent

USER_ID=$(/usr/bin/id -u)
/bin/launchctl bootout "gui/$USER_ID" "$PLIST_PATH" >/dev/null 2>&1 || true
/bin/launchctl bootstrap "gui/$USER_ID" "$PLIST_PATH"
/bin/launchctl enable "gui/$USER_ID/com.clashpatch.profiles"

say "LaunchAgent 已安装。它只在登录或订阅目录变化时运行，补完后立即退出。"
say "本地或 iCloud 订阅新增、重命名或刷新后，补丁会自动重新应用。"
