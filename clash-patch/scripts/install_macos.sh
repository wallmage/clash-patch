#!/bin/sh
set -eu
set -f

# 默认本地配置目录：~/.config/clash.meta；同时自动发现 ClashX Meta 的 iCloud 配置目录。
CUSTOM_PROFILE_DIR="${CLASH_PATCH_PROFILE_DIR:-}"
INSTALL_DIR="$HOME/Library/Application Support/ClashPatch"
BACKUP_DIR="$INSTALL_DIR/backups"
STATE_PATH="$INSTALL_DIR/install-state.plist"
PLIST_PATH="$HOME/Library/LaunchAgents/com.clashpatch.profiles.plist"
LABEL="com.clashpatch.profiles"
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
PATCHER_SOURCE="$SCRIPT_DIR/macos/patch_profiles.rb"
POLICY_SOURCE="$SCRIPT_DIR/../references/policy.json"
PATCHER_TARGET="$INSTALL_DIR/patch_profiles.rb"
POLICY_TARGET="$INSTALL_DIR/policy.json"
DEFAULTS_DOMAIN="com.metacubex.ClashX.meta"
COMMIT_STARTED=0
COMMIT_COMPLETE=0
AGENT_WAS_LOADED=0
PATCHER_EXISTED=0
POLICY_EXISTED=0
STATE_EXISTED=0
PLIST_EXISTED=0
ROLLBACK_FAILED=0

say() {
  /usr/bin/printf '%s\n' "[Clash 补丁] $1"
}

launch_agent_owned() {
  candidate=$1
  [ -f "$candidate" ] && [ ! -L "$candidate" ] || return 1
  agent_label=$(/usr/bin/plutil -extract Label raw "$candidate" 2>/dev/null || true)
  agent_arg0=$(/usr/bin/plutil -extract ProgramArguments.0 raw "$candidate" 2>/dev/null || true)
  agent_arg1=$(/usr/bin/plutil -extract ProgramArguments.1 raw "$candidate" 2>/dev/null || true)
  [ "$agent_label" = "$LABEL" ] && [ "$agent_arg0" = "/usr/bin/ruby" ] && [ "$agent_arg1" = "$PATCHER_TARGET" ]
}

add_plist_string() {
  key=$1
  value=$2
  /usr/bin/plutil -insert "$key" -string "$value" "$PLIST_BUILD"
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

USER_ID=$(/usr/bin/id -u)
if [ "$USER_ID" -eq 0 ]; then
  say "请不要使用 sudo 或 root 运行安装程序；请用当前登录用户直接运行。"
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

# 所有会失败的环境检查都必须发生在创建或覆盖文件之前。
if [ -f "$PLIST_PATH" ]; then
  if ! launch_agent_owned "$PLIST_PATH"; then
    say "LaunchAgent 文件已被其他程序占用，未覆盖任何文件。"
    exit 7
  fi
fi
if /bin/launchctl print "gui/$USER_ID/$LABEL" >/dev/null 2>&1; then
  if ! launch_agent_owned "$PLIST_PATH"; then
    say "同名 LaunchAgent 已由其他程序加载，未覆盖任何文件。"
    exit 7
  fi
fi
for existing_target in "$PATCHER_TARGET" "$POLICY_TARGET" "$STATE_PATH" "$PLIST_PATH"; do
  if [ -e "$existing_target" ] && { [ ! -f "$existing_target" ] || [ -L "$existing_target" ]; }; then
    say "安装目标不是普通文件，未覆盖：$existing_target"
    exit 7
  fi
done
if [ -f "$STATE_PATH" ] && ! /usr/bin/plutil -lint "$STATE_PATH" >/dev/null 2>&1; then
  say "已有安装状态文件无效，为避免丢失恢复依据，安装已停止。"
  exit 7
fi

LEGACY_INSTALL=0
if [ ! -f "$STATE_PATH" ] && [ -f "$PLIST_PATH" ] && [ -f "$PATCHER_TARGET" ] && [ -f "$POLICY_TARGET" ]; then
  LEGACY_INSTALL=1
fi

core_status=$(/usr/bin/ruby "$PATCHER_SOURCE" --print-core-status 2>/dev/null || true)
if [ "$core_status" != "supported" ]; then
  case "$core_status" in
    too_old) say "Mihomo 内核版本过旧，需要 1.19.27 或更高版本。请先更新 ClashX Meta。" ;;
    *) say "没有找到可用的 Mihomo 内核。请先更新并启动一次 ClashX Meta。" ;;
  esac
  exit 8
fi

if [ -n "$CUSTOM_PROFILE_DIR" ]; then
  watch_paths=$CUSTOM_PROFILE_DIR
else
  watch_paths=$(/usr/bin/ruby "$PATCHER_SOURCE" --print-watch-paths)
fi
if [ -z "$watch_paths" ]; then
  say "没有找到 ClashX Meta 的本地或 iCloud 配置目录。请先打开客户端并添加订阅。"
  exit 5
fi

/bin/mkdir -p "$INSTALL_DIR" "$BACKUP_DIR" "$HOME/Library/LaunchAgents"
/bin/chmod 700 "$INSTALL_DIR" "$BACKUP_DIR"
STAGE_DIR=$(/usr/bin/mktemp -d "$INSTALL_DIR/.install.XXXXXX")
PLIST_BUILD="$STAGE_DIR/com.clashpatch.profiles.plist"
STATE_BUILD="$STAGE_DIR/install-state.plist"
cleanup() {
  cleanup_status=$?
  trap - EXIT HUP INT TERM
  if [ "$COMMIT_STARTED" -eq 1 ] && [ "$COMMIT_COMPLETE" -eq 0 ]; then
    rollback_install
  fi
  if [ "$ROLLBACK_FAILED" -eq 1 ]; then
    say "恢复快照保留在：$STAGE_DIR"
    exit "$cleanup_status"
  fi
  /bin/rm -f "$PLIST_BUILD" "$STATE_BUILD" "$STAGE_DIR/patch_profiles.rb" "$STAGE_DIR/policy.json" \
    "$STAGE_DIR/previous-patcher" "$STAGE_DIR/previous-policy" "$STAGE_DIR/previous-state" "$STAGE_DIR/previous-plist"
  /bin/rmdir "$STAGE_DIR" >/dev/null 2>&1 || true
  exit "$cleanup_status"
}
trap cleanup EXIT HUP INT TERM

restore_snapshot() {
  existed=$1
  snapshot=$2
  target=$3
  if [ "$existed" -eq 1 ]; then
    rollback_temp="$target.clash-patch-rollback.$$"
    /bin/cp -p "$snapshot" "$rollback_temp" || return 1
    /bin/mv -f "$rollback_temp" "$target" || return 1
  else
    /bin/rm -f "$target" || return 1
  fi
}

rollback_install() {
  set +e
  rollback_failed=0
  /bin/launchctl bootout "gui/$USER_ID/$LABEL" >/dev/null 2>&1 || true
  restore_snapshot "$PATCHER_EXISTED" "$STAGE_DIR/previous-patcher" "$PATCHER_TARGET" || rollback_failed=1
  restore_snapshot "$POLICY_EXISTED" "$STAGE_DIR/previous-policy" "$POLICY_TARGET" || rollback_failed=1
  restore_snapshot "$STATE_EXISTED" "$STAGE_DIR/previous-state" "$STATE_PATH" || rollback_failed=1
  restore_snapshot "$PLIST_EXISTED" "$STAGE_DIR/previous-plist" "$PLIST_PATH" || rollback_failed=1
  if [ "$AGENT_WAS_LOADED" -eq 1 ] && [ "$PLIST_EXISTED" -eq 1 ]; then
    /bin/launchctl bootstrap "gui/$USER_ID" "$PLIST_PATH" >/dev/null 2>&1 || rollback_failed=1
  fi
  if [ "$rollback_failed" -eq 0 ]; then
    say "安装未完成，已恢复原来的文件和 LaunchAgent。"
  else
    ROLLBACK_FAILED=1
    say "安装未完成，而且有文件或 LaunchAgent 未能自动恢复；请保留错误信息并停止重复安装。"
  fi
}

/bin/cp "$PATCHER_SOURCE" "$STAGE_DIR/patch_profiles.rb"
/bin/cp "$POLICY_SOURCE" "$STAGE_DIR/policy.json"
/bin/chmod 700 "$STAGE_DIR/patch_profiles.rb"

# 使用 plutil 逐项写入，路径中的 &、<、引号等字符不会破坏 plist。
/usr/bin/plutil -create xml1 "$PLIST_BUILD"
add_plist_string "Label" "$LABEL"
/usr/bin/plutil -insert "ProgramArguments" -array "$PLIST_BUILD"
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
/usr/bin/plutil -insert "RunAtLoad" -bool true "$PLIST_BUILD"
/usr/bin/plutil -insert "WatchPaths" -array "$PLIST_BUILD"

watch_index=0
old_ifs=$IFS
IFS='
'
for watch_path in $watch_paths; do
  [ -n "$watch_path" ] || continue
  add_plist_string "WatchPaths.$watch_index" "$watch_path"
  watch_index=$((watch_index + 1))
done
IFS=$old_ifs
if [ "$watch_index" -eq 0 ]; then
  say "没有找到 ClashX Meta 的本地或 iCloud 配置目录。请先打开客户端并添加订阅。"
  exit 5
fi

add_plist_string "StandardOutPath" "$INSTALL_DIR/patch.log"
add_plist_string "StandardErrorPath" "$INSTALL_DIR/patch-error.log"
/usr/bin/plutil -lint "$PLIST_BUILD" >/dev/null
/bin/chmod 600 "$PLIST_BUILD"

# 只在首次安装时记录用户原来的偏好；重复安装不会覆盖这份恢复依据。
if [ -f "$STATE_PATH" ]; then
  /bin/cp "$STATE_PATH" "$STATE_BUILD"
  if ! /usr/bin/plutil -extract RestoreTunKnown raw "$STATE_BUILD" >/dev/null 2>&1; then
    # 旧状态格式无法区分首次安装与从无状态版本升级。不要声称
    # 知道更早的用户偏好，卸载时应保持现值。
    /usr/bin/plutil -insert RestoreTunKnown -bool false "$STATE_BUILD"
  fi
else
  /usr/bin/plutil -create xml1 "$STATE_BUILD"
  if [ "$LEGACY_INSTALL" -eq 1 ]; then
    /usr/bin/plutil -insert RestoreTunKnown -bool false "$STATE_BUILD"
  else
    /usr/bin/plutil -insert RestoreTunKnown -bool true "$STATE_BUILD"
    if original_tun=$(/usr/bin/defaults read "$DEFAULTS_DOMAIN" restoreTunProxy 2>/dev/null); then
      /usr/bin/plutil -insert RestoreTunPresent -bool true "$STATE_BUILD"
      case "$original_tun" in
        1|true|TRUE|yes|YES) /usr/bin/plutil -insert RestoreTunValue -bool true "$STATE_BUILD" ;;
        *) /usr/bin/plutil -insert RestoreTunValue -bool false "$STATE_BUILD" ;;
      esac
    else
      /usr/bin/plutil -insert RestoreTunPresent -bool false "$STATE_BUILD"
    fi
  fi
fi
/bin/chmod 600 "$STATE_BUILD"

# 先修改并验证订阅；失败时不会安装 LaunchAgent 或覆盖已安装文件。
if [ -n "$CUSTOM_PROFILE_DIR" ]; then
  /usr/bin/ruby "$STAGE_DIR/patch_profiles.rb" \
    --profile-dir "$CUSTOM_PROFILE_DIR" \
    --policy "$STAGE_DIR/policy.json" \
    --backup-dir "$BACKUP_DIR"
else
  /usr/bin/ruby "$STAGE_DIR/patch_profiles.rb" \
    --policy "$STAGE_DIR/policy.json" \
    --backup-dir "$BACKUP_DIR"
fi

if [ -f "$PATCHER_TARGET" ]; then
  PATCHER_EXISTED=1
  /bin/cp -p "$PATCHER_TARGET" "$STAGE_DIR/previous-patcher"
fi
if [ -f "$POLICY_TARGET" ]; then
  POLICY_EXISTED=1
  /bin/cp -p "$POLICY_TARGET" "$STAGE_DIR/previous-policy"
fi
if [ -f "$STATE_PATH" ]; then
  STATE_EXISTED=1
  /bin/cp -p "$STATE_PATH" "$STAGE_DIR/previous-state"
fi
if [ -f "$PLIST_PATH" ]; then
  PLIST_EXISTED=1
  /bin/cp -p "$PLIST_PATH" "$STAGE_DIR/previous-plist"
fi
if /bin/launchctl print "gui/$USER_ID/$LABEL" >/dev/null 2>&1; then
  AGENT_WAS_LOADED=1
fi

COMMIT_STARTED=1
/bin/mv -f "$STAGE_DIR/patch_profiles.rb" "$PATCHER_TARGET"
/bin/mv -f "$STAGE_DIR/policy.json" "$POLICY_TARGET"
/bin/mv -f "$STATE_BUILD" "$STATE_PATH"
/bin/mv -f "$PLIST_BUILD" "$PLIST_PATH"

if [ "$AGENT_WAS_LOADED" -eq 1 ]; then
  /bin/launchctl bootout "gui/$USER_ID/$LABEL"
fi
/bin/launchctl bootstrap "gui/$USER_ID" "$PLIST_PATH"
/bin/launchctl enable "gui/$USER_ID/$LABEL"
COMMIT_COMPLETE=1

if ! ensure_tun_intent; then
  say "LaunchAgent 已安装，但 TUN 启动偏好写入失败；请在 ClashX Meta 中手动确认 TUN。"
fi

say "LaunchAgent 已安装。它只在登录或订阅目录变化时运行，补完后立即退出。"
say "本地或 iCloud 订阅新增、重命名或刷新后，补丁会自动重新应用。"
